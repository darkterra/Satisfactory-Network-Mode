-- features/rail.lua
-- Railroad infrastructure controller feature for Slave satellite computers.
--
-- This slave type monitors railroad signals and switches connected to its
-- local FicsIt component network. It publishes their state (signal aspects,
-- switch positions, track direction/length) to the network bus so that
-- the train_monitor can aggregate and display them on the map.
--
-- It also listens for commands from train_monitor to:
--   - Toggle or set switch positions
--   - Force/release switch positions for routed trains
--   - Apply forced routes (series of switch positions for a specific train)
--
-- Deployment: place one rail_controller slave per section of track,
-- connected via FicsIt network cable to the signals and switches in that area.

local scanner = filesystem.doFile(DRIVE_PATH .. "/modules/rail_scanner.lua")

-- ============================================================================
-- Configuration
-- ============================================================================

CONFIG_MANAGER.register("rail", {
  { key = "scanInterval",     label = "Scan interval (sec)",           type = "number",  default = 2 },
  { key = "outputMode",       label = "Output (auto/console)",         type = "string",  default = "console" },
  { key = "broadcastResults", label = "Broadcast via network",         type = "boolean", default = true },
})

-- Register component categories for auto-discovery
REGISTRY.registerNetworkCategory("rail_signals", "RailroadSignal")
REGISTRY.registerNetworkCategory("rail_switches", "RailroadSwitchControl")

local railConfig = CONFIG_MANAGER.getSection("rail")
local identity = (CONFIG_MANAGER.get("slave", "identity")) or "rail_unknown"

-- ============================================================================
-- Discovery
-- ============================================================================

local discovered = false

local function discoverElements(force)
  if discovered and not force then return end

  local proxies = {}
  for _, catName in ipairs({ "rail_signals", "rail_switches" }) do
    local cat = REGISTRY.getCategory(catName)
    if cat and #cat > 0 then
      proxies[catName] = cat
    else
      proxies[catName] = {}
    end
  end

  -- Fallback: scan all network components if REGISTRY gave nothing
  if #proxies["rail_signals"] == 0 and #proxies["rail_switches"] == 0 then
    local allIds = { component.findComponent("") }
    for _, id in ipairs(allIds) do
      local proxy = component.proxy(id)
      if proxy then
        local classOk, className = pcall(function()
          local t = tostring(proxy)
          return t
        end)
        -- Try to detect signal/switch by available properties
        local isSignal = pcall(function() local _ = proxy.aspect end)
        local isSwitch = pcall(function() proxy.switchPosition(proxy) end)
        if isSignal then
          table.insert(proxies["rail_signals"], proxy)
        elseif isSwitch then
          table.insert(proxies["rail_switches"], proxy)
        end
      end
    end
  end

  scanner.discover(proxies)
  discovered = true
end

-- ============================================================================
-- Network bus channels
-- ============================================================================

local broadcastEnabled = railConfig.broadcastResults ~= false

if NETWORK_BUS then
  NETWORK_BUS.registerChannel("rail_states")
  NETWORK_BUS.registerChannel("rail_commands")

  -- Listen for commands from train_monitor or other controllers
  NETWORK_BUS.subscribe("rail_commands", function(senderCardId, senderIdentity, cmd)
    if not cmd or not cmd.action then return end

    -- Optional targeting: only respond if targeted at us or broadcast
    if cmd.targetIdentity and cmd.targetIdentity ~= identity then return end

    local action = cmd.action

    if action == "toggle_switch" and cmd.switchId then
      scanner.toggleSwitch(cmd.switchId)

    elseif action == "set_switch" and cmd.switchId and cmd.position then
      scanner.setSwitchPosition(cmd.switchId, cmd.position)

    elseif action == "force_switch" and cmd.switchId and cmd.position then
      scanner.forceSwitchPosition(cmd.switchId, cmd.position)

    elseif action == "release_switch" and cmd.switchId then
      scanner.forceSwitchPosition(cmd.switchId, -1)

    elseif action == "set_forced_route" and cmd.route then
      scanner.applyForcedRoute(cmd)

    elseif action == "clear_forced_route" and cmd.trainId then
      scanner.releaseForcedRoute(cmd.trainId)

    elseif action == "rescan" then
      discoverElements(true)

    elseif action == "ping" then
      if NETWORK_BUS then
        NETWORK_BUS.publish("rail_states", {
          action = "pong",
          identity = identity,
        })
      end

    else
      print("[RAIL] Unknown command: " .. tostring(action))
    end
  end)
end

-- ============================================================================
-- Periodic scan
-- ============================================================================

local scanInterval = railConfig.scanInterval or 2

local function performScan()
  discoverElements(false)

  local scanResult = scanner.scan()
  if not scanResult then return end

  -- Console output (minimal)
  if railConfig.outputMode ~= "console" then
    -- Could add screen output here in the future
  end

  -- Broadcast state to the network
  if broadcastEnabled and NETWORK_BUS then
    local payload = scanner.buildPayload(scanResult)
    payload.identity = identity
    payload.action = "state_update"
    NETWORK_BUS.publish("rail_states", payload)
  end
end

-- ============================================================================
-- Task registration
-- ============================================================================

TASK_MANAGER.register("rail_scan", {
  interval = scanInterval,
  factory = function()
    return async(function()
      while true do
        TASK_MANAGER.heartbeat("rail_scan")
        performScan()
        sleep(scanInterval)
      end
    end)
  end,
})

print("[RAIL] Controller active - scanning every " .. scanInterval .. "s"
  .. (broadcastEnabled and " (broadcasting)" or "")
  .. " identity=" .. identity)
