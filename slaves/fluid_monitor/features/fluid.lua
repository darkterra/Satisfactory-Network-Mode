-- features/fluid.lua
-- Fluid network monitoring feature for Slave satellite computers.
--
-- Scans pumps, reservoirs, valves, and water extractors connected to
-- the FicsIt network, groups them by nick convention or pipe network ID,
-- aggregates flow and fill data, and displays results on a GPU T1 screen
-- in table or topology mode.
--
-- Supports:
--   - Flexible element grouping via nick convention (GroupName:ElementName)
--   - Overview and detail broadcast modes via network bus
--   - GPU T1 screen display (table list or 2D topology schematic)
--   - Direct click to toggle pumps, valves, reservoirs, extractors on/off
--   - Incoming commands via network bus (rescan, ping)
--
-- Nick convention:
--   Set the network nick on each fluid element to "GroupName:ElementName".
--   Example: "WaterLoop:Pump1", "OilRefinery:Tank1"
--   Elements without the separator go into the default group.

local scanner = filesystem.doFile(DRIVE_PATH .. "/modules/fluid_scanner.lua")
local display = filesystem.doFile(DRIVE_PATH .. "/modules/fluid_display.lua")
local controller = filesystem.doFile(DRIVE_PATH .. "/modules/fluid_controller.lua")
local rulesEngine = filesystem.doFile(DRIVE_PATH .. "/modules/fluid_rules.lua")
local topology = filesystem.doFile(DRIVE_PATH .. "/modules/fluid_topology.lua")

-- ============================================================================
-- Configuration
-- ============================================================================

CONFIG_MANAGER.register("fluid", {
  { key = "scanInterval",     label = "Scan interval (sec)",                type = "number",  default = 2 },
  { key = "fluidClasses",     label = "Fluid classes (comma-sep)",          type = "string",  default = "PipelinePump,PipeReservoir,FGBuildablePipelineAttachment,FGBuildableWaterPump" },
  { key = "nickQuery",        label = "Nick search query (empty=all)",      type = "string",  default = "" },
  { key = "broadcastResults", label = "Broadcast via network",             type = "boolean", default = true },
  { key = "broadcastMode",    label = "Broadcast (overview/detail/both)",  type = "string",  default = "both" },
  { key = "outputMode",       label = "Output (auto/screen/console)",      type = "string",  default = "auto" },
  { key = "displayMode",      label = "Display (table/topology)",          type = "string",  default = "table" },
  { key = "screenId",         label = "Screen UUID (if mode=screen)",      type = "string" },
  { key = "nickSeparator",    label = "Nick separator for groups",         type = "string",  default = ":" },
  { key = "defaultGroup",     label = "Default group name",                type = "string",  default = "default" },
  { key = "groupFilter",      label = "Groups to track (comma-sep, empty=all)", type = "string", default = "" },
})

local fluidConfig = CONFIG_MANAGER.getSection("fluid")

-- Register fluid element classes via REGISTRY for discovery
local fluidCategories = {}
local classesStr = fluidConfig.fluidClasses or ""
if classesStr ~= "" then
  for cls in classesStr:gmatch("[^,]+") do
    local trimmed = cls:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      local catName = "fluid_" .. trimmed
      REGISTRY.registerNetworkCategory(catName, trimmed)
      table.insert(fluidCategories, catName)
      print("[FLUID] Registered class for discovery: " .. trimmed)
    end
  end
end

-- ============================================================================
-- Module initialization
-- ============================================================================

scanner.init({
  separator = fluidConfig.nickSeparator or ":",
  defaultGroup = fluidConfig.defaultGroup or "default",
  groupFilter = fluidConfig.groupFilter or "",
})

-- Initialize rules engine
rulesEngine.init({
  filePath = DRIVE_PATH .. "/data/fluid_rules.dat",
  controller = controller,
})

-- Initialize topology layout manager
topology.init({
  filePath = DRIVE_PATH .. "/data/fluid_topology.dat",
})

-- ============================================================================
-- Display setup
-- ============================================================================

local outputMode = fluidConfig.outputMode or "auto"
local displayReady = false

if outputMode == "console" then
  print("[FLUID] Output mode: console (forced)")

elseif outputMode == "screen" then
  if fluidConfig.screenId and fluidConfig.screenId ~= "" then
    local targetScreen = component.proxy(fluidConfig.screenId)
    if targetScreen then
      local spareGpu = REGISTRY.pci.gpuT2[1] or REGISTRY.pci.gpuT1[1]
      if spareGpu then
        displayReady = display.init(spareGpu, targetScreen, {
          displayMode = fluidConfig.displayMode,
          controller = controller,
          rules = rulesEngine,
          topology = topology,
        })
      else
        print("[FLUID] No spare GPU available to drive screen " .. fluidConfig.screenId)
      end
    else
      print("[FLUID] Screen not found: " .. fluidConfig.screenId)
    end
  else
    print("[FLUID] outputMode=screen but no Screen UUID configured")
  end

elseif outputMode == "auto" then
  local autoGpu, autoScreen, autoGpuType = REGISTRY.getAvailableDisplay()
  if autoGpu and autoScreen then
    displayReady = display.init(autoGpu, autoScreen, {
      displayMode = fluidConfig.displayMode,
      controller = controller,
      rules = rulesEngine,
      topology = topology,
    })
    print("[FLUID] Auto-selected display (GPU " .. autoGpuType .. ")")
  else
    local hasGpu = REGISTRY.pci.gpuT2[1] or REGISTRY.pci.gpuT1[1]
    if not hasGpu then
      print("[FLUID] No spare GPU available - falling back to console")
    else
      print("[FLUID] No spare screen available - falling back to console")
    end
  end
end

-- ============================================================================
-- Network broadcast
-- ============================================================================

local broadcastEnabled = fluidConfig.broadcastResults ~= false
local broadcastMode = fluidConfig.broadcastMode or "both"

-- ============================================================================
-- Incoming commands
-- ============================================================================

local discoverFluidElements

if NETWORK_BUS then
  NETWORK_BUS.subscribe("fluid_commands", function(sender, senderIdentity, payload)
    if not payload or type(payload) ~= "table" then return end

    -- Optional targeting: commands with targetIdentity are only for that slave
    if payload.targetIdentity and NETWORK_BUS.getIdentity() ~= payload.targetIdentity then return end

    if payload.action == "rescan" then
      print("[FLUID] Remote rescan command from " .. senderIdentity)
      discoverFluidElements(true)

    elseif payload.action == "toggle" and payload.elementId then
      -- Remote toggle: find element and toggle it
      local elements = scanner.getElements()
      for _, e in ipairs(elements) do
        if e.id == payload.elementId then
          controller.toggle(e)
          print("[FLUID] Remote toggle on " .. (e.elementName or e.id))
          break
        end
      end

    elseif payload.action == "set_state" and payload.elementId then
      -- Remote set_state: force an element to a specific state (on/off)
      -- Used by centralized orchestrator or rules engine
      local elements = scanner.getElements()
      for _, e in ipairs(elements) do
        if e.id == payload.elementId then
          local targetActive = payload.active
          -- Only toggle if current state differs from target
          if targetActive ~= nil and e.active ~= targetActive then
            -- We need to read current state from the scan result
            local lastScan = scanner.getLastScanResult and scanner.getLastScanResult()
            local currentElem = nil
            if lastScan then
              for _, se in ipairs(lastScan.elements) do
                if se.id == e.id then currentElem = se; break end
              end
            end
            local curActive = currentElem and currentElem.active or e.active
            if curActive ~= targetActive then
              controller.toggle(e)
              print("[FLUID] Remote set_state on " .. (e.elementName or e.id) .. " -> " .. (targetActive and "ON" or "OFF"))
            end
          end
          break
        end
      end

    elseif payload.action == "ping" then
      if NETWORK_BUS.publish then
        NETWORK_BUS.publish("fluid_status", {
          identity = NETWORK_BUS.getIdentity(),
          slaveType = "fluid_monitor",
          elements = #scanner.getElements(),
          groups = #scanner.getGroupOrder(),
          rules = #rulesEngine.getOrder(),
        })
      end

    -- ================================================================
    -- Rules CRUD via network bus
    -- ================================================================
    elseif payload.action == "rule_create" then
      -- Create a new automation rule
      -- payload: { name, triggers, targets, logic, enabled }
      local rule = rulesEngine.create({
        name = payload.name,
        triggers = payload.triggers,
        targets = payload.targets,
        logic = payload.logic,
        enabled = payload.enabled,
      })
      if rule and NETWORK_BUS.publish then
        NETWORK_BUS.publish("fluid_rules", { type = "created", rule = rule })
      end

    elseif payload.action == "rule_update" and payload.ruleId then
      -- Update an existing rule
      -- payload: { ruleId, name, triggers, targets, logic, enabled }
      local rule = rulesEngine.update(payload.ruleId, {
        name = payload.name,
        triggers = payload.triggers,
        targets = payload.targets,
        logic = payload.logic,
        enabled = payload.enabled,
      })
      if rule and NETWORK_BUS.publish then
        NETWORK_BUS.publish("fluid_rules", { type = "updated", rule = rule })
      end

    elseif payload.action == "rule_delete" and payload.ruleId then
      local ok = rulesEngine.delete(payload.ruleId)
      if ok and NETWORK_BUS.publish then
        NETWORK_BUS.publish("fluid_rules", { type = "deleted", ruleId = payload.ruleId })
      end

    elseif payload.action == "rule_toggle" and payload.ruleId then
      local newState = rulesEngine.toggleEnabled(payload.ruleId)
      if newState ~= nil and NETWORK_BUS.publish then
        NETWORK_BUS.publish("fluid_rules", { type = "toggled", ruleId = payload.ruleId, enabled = newState })
      end

    elseif payload.action == "rule_list" then
      -- Return all rules to the requester
      if NETWORK_BUS.publish then
        NETWORK_BUS.publish("fluid_rules", {
          type = "list",
          identity = NETWORK_BUS.getIdentity(),
          rules = rulesEngine.getAll(),
        })
      end

    -- ================================================================
    -- Topology layout commands
    -- ================================================================
    elseif payload.action == "topo_set_node" then
      -- Move/place a node in the topology grid
      -- payload: { networkId, elementId, gridX, gridY }
      topology.setNodePosition(payload.networkId, payload.elementId, payload.gridX, payload.gridY)
      print("[FLUID] Topology node placed: " .. tostring(payload.elementId))

    elseif payload.action == "topo_remove_node" then
      topology.removeNode(payload.networkId, payload.elementId)

    elseif payload.action == "topo_add_connection" then
      topology.addConnection(payload.networkId, payload.fromId, payload.toId)

    elseif payload.action == "topo_remove_connection" then
      topology.removeConnection(payload.networkId, payload.fromId, payload.toId)

    elseif payload.action == "topo_save" then
      topology.save()

    elseif payload.action == "topo_reset" then
      topology.reset()

    elseif payload.action == "topo_export" then
      if NETWORK_BUS.publish then
        NETWORK_BUS.publish("fluid_topo_layout", {
          identity = NETWORK_BUS.getIdentity(),
          layout = topology.export(),
        })
      end

    elseif payload.action == "topo_import" and payload.layout then
      topology.import(payload.layout)
      topology.save()
    end
  end)
  print("[FLUID] Command listener registered on 'fluid_commands' channel")
end

-- ============================================================================
-- Discovery and scanning
-- ============================================================================

local discovered = false
local scanInterval = fluidConfig.scanInterval or 2

--- Collect fluid element proxies from REGISTRY categories + nick-query fallback.
-- @param force boolean - if true, rediscover even if already done
-- @return boolean - true if elements were found
function discoverFluidElements(force)
  if discovered and not force then return true end
  discovered = false

  local proxiesByCategory = {}
  local seen = {}

  -- Method 1: REGISTRY class-based discovery
  for _, catName in ipairs(fluidCategories) do
    local catProxies = REGISTRY.getCategory(catName)
    if #catProxies > 0 then
      proxiesByCategory[catName] = {}
      for _, proxy in ipairs(catProxies) do
        local idOk, id = pcall(function() return proxy.id end)
        if idOk and id and not seen[id] then
          seen[id] = true
          table.insert(proxiesByCategory[catName], proxy)
        end
      end
      print("[FLUID] REGISTRY '" .. catName .. "' provided " .. #proxiesByCategory[catName] .. " candidates")
    end
  end

  -- Method 2: Nick-query fallback
  local totalFound = 0
  for _, t in pairs(proxiesByCategory) do totalFound = totalFound + #t end

  if totalFound == 0 then
    local nickQuery = fluidConfig.nickQuery or ""
    local ok, ids
    if nickQuery ~= "" then
      ok, ids = pcall(component.findComponent, nickQuery)
      print("[FLUID] Nick query '" .. nickQuery .. "': " .. (ok and #(ids or {}) or "error") .. " results")
    else
      ok, ids = pcall(component.findComponent)
      print("[FLUID] All network components: " .. (ok and #(ids or {}) or "error") .. " results")
    end
    if ok and ids then
      local fallbackProxies = {}
      for _, id in ipairs(ids) do
        if not seen[id] then
          seen[id] = true
          local proxyOk, proxy = pcall(component.proxy, id)
          if proxyOk and proxy then
            table.insert(fallbackProxies, proxy)
          end
        end
      end
      if #fallbackProxies > 0 then
        proxiesByCategory["fallback"] = fallbackProxies
      end
    end
  end

  -- Pass categorized proxies to scanner
  local count = scanner.discover(proxiesByCategory)
  if count == 0 then
    print("[FLUID] No fluid elements matched after filtering - will retry next scan")
    return false
  end

  discovered = true
  return true
end

--- Perform a full scan cycle: discover → scan → display → broadcast.
local function performScan()
  discoverFluidElements(false)
  if not discovered then return end

  local scanResult = scanner.scan()
  if not scanResult then return end

  -- Update display
  if displayReady then
    display.render(scanResult)
  else
    display.printReport(scanResult)
  end

  -- Evaluate automation rules
  rulesEngine.evaluate(scanResult)

  -- Broadcast over network bus
  if broadcastEnabled and NETWORK_BUS then
    if broadcastMode == "overview" or broadcastMode == "both" then
      local overview = scanner.buildOverview(scanResult)
      overview.identity = NETWORK_BUS.getIdentity()
      overview.slaveType = "fluid_monitor"
      NETWORK_BUS.publish("fluid_states", overview)
    end
    if broadcastMode == "detail" or broadcastMode == "both" then
      local detail = scanner.buildDetail(scanResult)
      detail.identity = NETWORK_BUS.getIdentity()
      detail.slaveType = "fluid_monitor"
      -- Include controllable elements in detail payload
      local controllables = scanner.buildControllables(scanResult)
      detail.controllables = controllables.controllables or {}
      NETWORK_BUS.publish("fluid_detail", detail)
    end
  end
end

-- ============================================================================
-- Task registration
-- ============================================================================

TASK_MANAGER.register("fluid_scan", {
  interval = scanInterval,
  factory = function()
    return async(function()
      while true do
        TASK_MANAGER.heartbeat("fluid_scan")
        performScan()
        sleep(scanInterval)
      end
    end)
  end,
})

local modeStr = displayReady and "screen" or "console"
if broadcastEnabled then modeStr = modeStr .. "+network" end
print("[FLUID] Monitoring active - scanning every " .. scanInterval .. "s (" .. modeStr .. ")")