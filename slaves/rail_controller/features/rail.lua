-- features/rail.lua
-- Railroad infrastructure controller feature for Slave satellite computers.
--
-- Two scan phases:
--   1. Topology scan (boot + peer change + every N minutes):
--      Full BFS track walk + signal/switch topology probe.
--   2. State scan (every 1-2 seconds):
--      Lightweight read of signal aspects and switch positions.
--
-- Peer change detection triggers topology rescan so controllers
-- dynamically repartition the network as peers are added or removed.

local scanner = filesystem.doFile(DRIVE_PATH .. "/modules/rail_scanner.lua")

-- ============================================================================
-- Configuration
-- ============================================================================

CONFIG_MANAGER.register("rail", {
  { key = "stateInterval",     label = "State poll interval (sec)",     type = "number",  default = 2 },
  { key = "topologyInterval",  label = "Topology rescan interval (sec)", type = "number",  default = 300 },
  { key = "outputMode",        label = "Output (auto/console)",         type = "string",  default = "console" },
  { key = "broadcastResults",  label = "Broadcast via network",         type = "boolean", default = true },
})

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

  if #proxies["rail_signals"] == 0 and #proxies["rail_switches"] == 0 then
    local allIds = { component.findComponent("") }
    for _, id in ipairs(allIds) do
      local proxy = component.proxy(id)
      if proxy then
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

-- Peer tracking for dynamic territory repartitioning
local knownPeers = {}       -- peerIdentity → lastSeenMs
local knownPeerCount = 0
local PEER_TIMEOUT_MS = 45000

local function checkPeerChanges()
  local now = computer.millis()
  local expired = {}
  local currentCount = 0
  for id, lastSeen in pairs(knownPeers) do
    if now - lastSeen > PEER_TIMEOUT_MS then
      table.insert(expired, id)
    else
      currentCount = currentCount + 1
    end
  end
  for _, id in ipairs(expired) do
    knownPeers[id] = nil
  end
  if currentCount ~= knownPeerCount then
    knownPeerCount = currentCount
    return true
  end
  return false
end

if NETWORK_BUS then
  NETWORK_BUS.registerChannel("rail_states")
  NETWORK_BUS.registerChannel("rail_commands")

  NETWORK_BUS.subscribe("rail_commands", function(senderCardId, senderIdentity, cmd)
    if not cmd or not cmd.action then return end
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
    elseif action == "request_topology" then
      local result = scanner.getResults()
      if result and result.trackCount > 0 then
        local payload = scanner.buildPayload(result)
        payload.identity = identity
        payload.action = "state_update"
        NETWORK_BUS.publish("rail_states", payload)
      end
    elseif action == "ping" then
      NETWORK_BUS.publish("rail_states", {
        action = "pong",
        identity = identity,
      })
    end
  end)

  NETWORK_BUS.subscribe("rail_states", function(senderCardId, senderIdentity, data)
    if not data then return end
    local key = data.identity or senderIdentity or senderCardId
    if key == identity then return end

    knownPeers[key] = computer.millis()

    local peerSigs, peerSws = {}, {}
    for _, sig in ipairs(data.signals or {}) do
      if sig.id then peerSigs[sig.id] = true end
    end
    for _, sw in ipairs(data.switches or {}) do
      if sw.id then peerSws[sw.id] = true end
    end
    scanner.updatePeerEquipment(peerSigs, peerSws)
  end)
end

-- ============================================================================
-- Task: single loop with topology/state phases
-- ============================================================================

local stateInterval = railConfig.stateInterval or 2
local topologyIntervalMs = (railConfig.topologyInterval or 300) * 1000
local nextTopologyAt = 0

TASK_MANAGER.register("rail_controller", {
  interval = 120,
  factory = function()
    return async(function()
      while true do
        TASK_MANAGER.heartbeat("rail_controller")

        local peerChanged = checkPeerChanges()
        if peerChanged then
          nextTopologyAt = 0
        end

        local now = computer.millis()
        local isTopologyScan = (now >= nextTopologyAt)

        local scanOk, scanErr = pcall(function()
          if isTopologyScan then
            discoverElements(true)
            scanner.scanTopology()
            nextTopologyAt = computer.millis() + topologyIntervalMs
          else
            scanner.scanStates()
          end
        end)
        if not scanOk then
          print("[RAIL] Scan error: " .. tostring(scanErr))
        end

        if broadcastEnabled and NETWORK_BUS and scanOk then
          local result = scanner.getResults()
          local payload = scanner.buildPayload(result)
          payload.identity = identity
          payload.action = "state_update"
          if not isTopologyScan then
            payload.tracks = nil
          end
          NETWORK_BUS.publish("rail_states", payload)
        end

        sleep(stateInterval)
      end
    end)
  end,
})

print("[RAIL] Controller active - states every " .. stateInterval .. "s, topology every "
  .. math.floor(topologyIntervalMs / 1000) .. "s"
  .. (broadcastEnabled and " (broadcasting)" or "")
  .. " identity=" .. identity)
