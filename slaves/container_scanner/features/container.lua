-- features/container.lua
-- Container inventory scanning feature for Slave satellite computers.
--
-- Scans containers connected to the FicsIt network, groups them by their
-- network nick convention (GroupName:ContainerName), aggregates inventory
-- data, and optionally broadcasts results over the network bus.
--
-- Supports:
--   - Flexible container grouping via nick convention
--   - Overview and detail broadcast modes
--   - GPU T1 screen display (overview, detail, or both)
--   - Modular Indicator Pole fill-level visualization
--   - Modular Buzzer module alerts on empty containers
--   - Incoming commands via network bus (bidirectional ready)
--
-- Nick convention for containers:
--   Set the network nick on each container to "GroupName:ContainerName".
--   Example: "Storage:Iron", "Storage:Copper", "Production:Screws"
--   Containers without the separator go into the default group.
--
-- Nick convention for indicator poles:
--   Set the same nick on a ModularIndicatorPole as on the container it
--   should monitor. The pole's indicator modules light up proportionally
--   to the container fill level, and buzzers activate when empty.

local scanner = filesystem.doFile(DRIVE_PATH .. "/modules/container_scanner.lua")
local display = filesystem.doFile(DRIVE_PATH .. "/modules/container_display.lua")
local indicators = filesystem.doFile(DRIVE_PATH .. "/modules/indicator_controller.lua")

-- ============================================================================
-- Configuration
-- ============================================================================

CONFIG_MANAGER.register("container", {
  { key = "scanInterval",       label = "Scan interval (sec)",                type = "number",  default = 2 },
  { key = "containerClasses",   label = "Container classes (comma-sep)",       type = "string",  default = "FGBuildableStorage" },
  { key = "nickQuery",          label = "Nick search query (empty=all)",       type = "string",  default = "" },
  { key = "broadcastResults",   label = "Broadcast via network",              type = "boolean", default = true },
  { key = "broadcastMode",      label = "Broadcast (overview/detail/both)",   type = "string",  default = "both" },
  { key = "outputMode",         label = "Output (auto/screen/console)",       type = "string",  default = "auto" },
  { key = "displayMode",        label = "Display (overview/detail/both)",     type = "string",  default = "both" },
  { key = "screenId",           label = "Screen UUID (if mode=screen)",       type = "string" },
  { key = "nickSeparator",      label = "Nick separator for groups",          type = "string",  default = ":" },
  { key = "defaultGroup",       label = "Default group name",                 type = "string",  default = "default" },
  { key = "groupFilter",        label = "Groups to track (comma-sep, empty=all)", type = "string",  default = "" },
  { key = "enableIndicators",   label = "Enable indicator poles",             type = "boolean", default = true },
  { key = "enableBuzzer",       label = "Buzzer on empty container",          type = "boolean", default = true },
  { key = "buzzerFrequency",    label = "Buzzer frequency (Hz)",              type = "number",  default = 800 },
  { key = "indicatorThreshLow", label = "Indicator low threshold (%)",        type = "number",  default = 33 },
  { key = "indicatorThreshHigh",label = "Indicator high threshold (%)",       type = "number",  default = 66 },
})

-- Register network component categories for indicator poles
REGISTRY.registerNetworkCategory("indicatorPoles", "ModularIndicatorPole")

local containerConfig = CONFIG_MANAGER.getSection("container")

-- Register container classes via REGISTRY (if configured)
-- This gives engine-level class filtering, which is faster and more reliable
-- than nick-based search when the class names are known.
local containerCategories = {}
local classesStr = containerConfig.containerClasses or ""
if classesStr ~= "" then
  for cls in classesStr:gmatch("[^,]+") do
    local trimmed = cls:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      local catName = "containers_" .. trimmed
      REGISTRY.registerNetworkCategory(catName, trimmed)
      table.insert(containerCategories, catName)
      print("[CONTAINER] Registered class for discovery: " .. trimmed)
    end
  end
end

-- ============================================================================
-- Module initialization
-- ============================================================================

-- Initialize the scanner
scanner.init({
  separator = containerConfig.nickSeparator or ":",
  defaultGroup = containerConfig.defaultGroup or "default",
  groupFilter = containerConfig.groupFilter or "",
})

-- Initialize the indicator controller
indicators.init({
  enabled = containerConfig.enableIndicators ~= false,
  buzzerEnabled = containerConfig.enableBuzzer ~= false,
  buzzerFrequency = containerConfig.buzzerFrequency or 800,
  thresholdLow = containerConfig.indicatorThreshLow or 33,
  thresholdHigh = containerConfig.indicatorThreshHigh or 66,
})

-- ============================================================================
-- Display setup
-- ============================================================================

local outputMode = containerConfig.outputMode or "auto"
local displayReady = false

if outputMode == "console" then
  print("[CONTAINER] Output mode: console (forced)")

elseif outputMode == "screen" then
  -- Use a specifically configured screen UUID
  if containerConfig.screenId and containerConfig.screenId ~= "" then
    local targetScreen = component.proxy(containerConfig.screenId)
    if targetScreen then
      local spareGpu = REGISTRY.pci.gpuT2[1] or REGISTRY.pci.gpuT1[1]
      if spareGpu then
        displayReady = display.init(spareGpu, targetScreen, containerConfig.displayMode)
      else
        print("[CONTAINER] No spare GPU available to drive screen " .. containerConfig.screenId)
      end
    else
      print("[CONTAINER] Screen not found: " .. containerConfig.screenId)
    end
  else
    print("[CONTAINER] outputMode=screen but no Screen UUID configured")
  end

elseif outputMode == "auto" then
  local autoGpu, autoScreen, autoGpuType = REGISTRY.getAvailableDisplay()
  if autoGpu and autoScreen then
    displayReady = display.init(autoGpu, autoScreen, containerConfig.displayMode)
    print("[CONTAINER] Auto-selected display (GPU " .. autoGpuType .. ")")
  else
    local hasGpu = REGISTRY.pci.gpuT2[1] or REGISTRY.pci.gpuT1[1]
    if not hasGpu then
      print("[CONTAINER] No spare GPU available - falling back to console")
    else
      print("[CONTAINER] No spare screen available - falling back to console")
    end
  end
end

-- ============================================================================
-- Network broadcast
-- ============================================================================

local broadcastEnabled = containerConfig.broadcastResults ~= false
local broadcastMode = containerConfig.broadcastMode or "both"

-- ============================================================================
-- Incoming commands (bidirectional communication)
-- ============================================================================

-- Forward declaration for discovery function (used by rescan command)
local discoverContainers

-- Subscribe to commands from a central controller.
-- This prepares the ground for receiving orders (rescan, config changes, etc.).
if NETWORK_BUS then
  NETWORK_BUS.subscribe("container_commands", function(sender, senderIdentity, payload)
    if not payload or type(payload) ~= "table" then return end

    if payload.action == "rescan" then
      -- Re-discover containers on the network
      print("[CONTAINER] Remote rescan command from " .. senderIdentity)
      discoverContainers(true)

    elseif payload.action == "set_interval" and type(payload.value) == "number" then
      print("[CONTAINER] Remote interval change: " .. payload.value .. "s")
      -- Note: interval change takes effect on next task restart

    elseif payload.action == "ping" then
      -- Respond with status (targeted reply if senderCardId available)
      if NETWORK_BUS.publish then
        NETWORK_BUS.publish("container_status", {
          identity = NETWORK_BUS.getIdentity(),
          containers = #scanner.getContainers(),
          groups = #scanner.getGroupOrder(),
          indicators = indicators.getPoleCount(),
        })
      end
    end
  end)
  print("[CONTAINER] Command listener registered on 'container_commands' channel")
end

-- ============================================================================
-- Discovery and scanning
-- ============================================================================

local discovered = false
local scanInterval = containerConfig.scanInterval or 10

--- Collect container proxies from REGISTRY categories + nick-query fallback.
-- @param force boolean - if true, rediscover even if already done
-- @return boolean - true if containers were found
function discoverContainers(force)
  if discovered and not force then return true end
  discovered = false

  local allProxies = {}
  local seen = {} -- deduplicate by id

  -- Method 1: REGISTRY class-based discovery (fast, reliable when class names known)
  for _, catName in ipairs(containerCategories) do
    for _, proxy in ipairs(REGISTRY.getCategory(catName)) do
      local idOk, id = pcall(function() return proxy.id end)
      if idOk and id and not seen[id] then
        seen[id] = true
        table.insert(allProxies, proxy)
      end
    end
  end

  if #allProxies > 0 then
    print("[CONTAINER] REGISTRY provided " .. #allProxies .. " candidates")
  end

  -- Method 2: Nick-query fallback (finds by nick substring on component network)
  if #allProxies == 0 then
    local nickQuery = containerConfig.nickQuery or ""
    local ok, ids
    if nickQuery ~= "" then
      ok, ids = pcall(component.findComponent, nickQuery)
      print("[CONTAINER] Nick query '" .. nickQuery .. "': " .. (ok and #(ids or {}) or "error") .. " results")
    else
      -- Universal fallback: get ALL network components
      ok, ids = pcall(component.findComponent)
      print("[CONTAINER] All network components: " .. (ok and #(ids or {}) or "error") .. " results")
    end
    if ok and ids then
      for _, id in ipairs(ids) do
        if not seen[id] then
          seen[id] = true
          local proxyOk, proxy = pcall(component.proxy, id)
          if proxyOk and proxy then
            table.insert(allProxies, proxy)
          end
        end
      end
    end
  end

  if #allProxies == 0 then
    print("[CONTAINER] No container candidates found - will retry next scan")
    return false
  end

  -- Pass proxies to scanner (filters by nick + inventory)
  local count = scanner.discover(allProxies)
  if count == 0 then
    print("[CONTAINER] No containers matched after filtering - will retry next scan")
    return false
  end

  -- Discover indicator poles
  if containerConfig.enableIndicators ~= false then
    local poleProxies = REGISTRY.getCategory("indicatorPoles")
    indicators.discover(poleProxies)
  end

  discovered = true
  return true
end

--- Perform a full scan cycle: scan → display → indicators → broadcast.
local function performScan()
  -- Lazy discovery (waits for network to be ready)
  discoverContainers(false)
  if not discovered then return end

  -- Scan all containers
  local scanResult = scanner.scan()
  if not scanResult then return end

  -- Update display
  if displayReady then
    display.render(scanResult)
  else
    display.printReport(scanResult)
  end

  -- Update indicator poles
  if containerConfig.enableIndicators ~= false then
    indicators.update(scanResult)
  end

  -- Broadcast over network bus
  if broadcastEnabled and NETWORK_BUS then
    if broadcastMode == "overview" or broadcastMode == "both" then
      local overview = scanner.buildOverview(scanResult)
      NETWORK_BUS.publish("container_states", overview)
    end
    if broadcastMode == "detail" or broadcastMode == "both" then
      local detail = scanner.buildDetail(scanResult)
      NETWORK_BUS.publish("container_detail", detail)
    end
  end
end

-- ============================================================================
-- Task registration
-- ============================================================================

-- Register periodic scan as a managed async task (auto-restarts after game reload)
TASK_MANAGER.register("container_scan", {
  interval = scanInterval,
  factory = function()
    return async(function()
      while true do
        TASK_MANAGER.heartbeat("container_scan")
        performScan()
        sleep(scanInterval)
      end
    end)
  end,
})

local modeStr = displayReady and "screen" or "console"
if broadcastEnabled then modeStr = modeStr .. "+network" end
if containerConfig.enableIndicators ~= false and indicators.getPoleCount() > 0 then
  modeStr = modeStr .. "+indicators"
end
print("[CONTAINER] Monitoring active - scanning every " .. scanInterval .. "s (" .. modeStr .. ")")