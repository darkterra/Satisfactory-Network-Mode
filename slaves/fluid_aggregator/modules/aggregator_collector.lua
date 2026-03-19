-- modules/aggregator_collector.lua
-- Collects and aggregates data from multiple fluid_monitor slaves
-- via network bus subscriptions.
--
-- Each known slave is tracked with its latest overview, detail,
-- controllables, and rules data. Stale slaves (no data received
-- within the timeout) are marked offline.
--
-- Public API:
--   .init(options)              - subscribe to network bus channels
--   .getSlaves()                - ordered list of slave entries
--   .getSlaveData(identity)     - single slave's cached data
--   .pingAll()                  - request all fluid_monitors to respond
--   .requestRuleList(identity)  - ask a specific slave for its rules
--   .sendCommand(identity, payload) - send targeted command to a slave
--   .updateStates()             - mark stale slaves as offline

local Collector = {}

-- ============================================================================
-- State
-- ============================================================================

-- { [identity] = { identity, lastSeen, state, overview, detail,
--                  controllables, rules, elementCount, groupCount, ruleCount } }
local slaves = {}
local slaveOrder = {}     -- ordered array of identity strings
local staleTimeout = 15000 -- ms before a slave is marked offline

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the collector and subscribe to network bus channels.
-- @param options table - { staleTimeout }
function Collector.init(options)
  options = options or {}
  staleTimeout = options.staleTimeout or staleTimeout

  if not NETWORK_BUS then
    print("[AGG_COL] WARNING: NETWORK_BUS not available - collector disabled")
    return false
  end

  -- Register channels so network_bus opens the ports
  -- (consolidated: fewer channels, each carrying a type field where needed)
  NETWORK_BUS.registerChannel("fluid_states")
  NETWORK_BUS.registerChannel("fluid_detail")
  NETWORK_BUS.registerChannel("fluid_status")
  NETWORK_BUS.registerChannel("fluid_rules")
  NETWORK_BUS.registerChannel("fluid_commands")

  -- Subscribe: overview data from fluid_monitors
  NETWORK_BUS.subscribe("fluid_states", function(sender, senderIdentity, payload)
    if not payload then return end
    -- Type filter: ignore non-fluid_monitor broadcasts
    if payload.slaveType and payload.slaveType ~= "fluid_monitor" then return end
    local identity = payload.identity or senderIdentity
    Collector._ensureSlave(identity)
    local s = slaves[identity]
    s.overview = payload
    s.lastSeen = computer.millis()
    s.state = "online"
    if payload.stats then
      s.elementCount = payload.stats.totalElements or 0
      s.groupCount = payload.stats.groupCount or 0
      s.pumpCount = payload.stats.pumpCount or 0
      s.reservoirCount = payload.stats.reservoirCount or 0
      s.valveCount = payload.stats.valveCount or 0
      s.extractorCount = payload.stats.extractorCount or 0
      s.networkCount = payload.stats.networkCount or 0
      s.avgFill = 0
      s.activeCount = 0
      if payload.groups then
        local totalFill, fillCount = 0, 0
        for _, g in ipairs(payload.groups) do
          s.activeCount = s.activeCount + (g.activeCount or 0)
          if g.avgFillPercent and g.avgFillPercent > 0 then
            totalFill = totalFill + g.avgFillPercent
            fillCount = fillCount + 1
          end
        end
        if fillCount > 0 then s.avgFill = totalFill / fillCount end
      end
    end
  end)

  -- Subscribe: detailed per-element data (now includes controllables)
  NETWORK_BUS.subscribe("fluid_detail", function(sender, senderIdentity, payload)
    if not payload then return end
    if payload.slaveType and payload.slaveType ~= "fluid_monitor" then return end
    local identity = payload.identity or senderIdentity
    Collector._ensureSlave(identity)
    slaves[identity].detail = payload
    -- Extract controllables from detail payload
    if payload.controllables then
      slaves[identity].controllables = { controllables = payload.controllables }
    end
    slaves[identity].lastSeen = computer.millis()
    slaves[identity].state = "online"
  end)

  -- Subscribe: ping responses
  NETWORK_BUS.subscribe("fluid_status", function(sender, senderIdentity, payload)
    if not payload then return end
    if payload.slaveType and payload.slaveType ~= "fluid_monitor" then return end
    local identity = payload.identity or senderIdentity
    Collector._ensureSlave(identity)
    local s = slaves[identity]
    s.lastSeen = computer.millis()
    s.state = "online"
    s.elementCount = payload.elements or s.elementCount
    s.groupCount = payload.groups or s.groupCount
    s.ruleCount = payload.rules or s.ruleCount
  end)

  -- Subscribe: consolidated rules channel (list, created, updated, deleted, toggled)
  NETWORK_BUS.subscribe("fluid_rules", function(sender, senderIdentity, payload)
    if not payload or not payload.type then return end
    local identity = payload.identity or senderIdentity
    if payload.type == "list" then
      Collector._ensureSlave(identity)
      slaves[identity].rules = payload.rules or {}
      slaves[identity].ruleCount = #(payload.rules or {})
      slaves[identity].lastSeen = computer.millis()
    elseif payload.type == "created" or payload.type == "updated"
        or payload.type == "deleted" or payload.type == "toggled" then
      -- Request full list to stay in sync
      Collector._ensureSlave(senderIdentity)
      Collector.requestRuleList(senderIdentity)
    end
  end)

  print("[AGG_COL] Initialized - listening for fluid_monitor broadcasts")
  return true
end

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Ensure a slave entry exists.
function Collector._ensureSlave(identity)
  if slaves[identity] then return end
  slaves[identity] = {
    identity = identity,
    lastSeen = computer.millis(),
    state = "online",
    overview = nil,
    detail = nil,
    controllables = nil,
    rules = nil,
    elementCount = 0,
    groupCount = 0,
    ruleCount = 0,
    pumpCount = 0,
    reservoirCount = 0,
    valveCount = 0,
    extractorCount = 0,
    networkCount = 0,
    avgFill = 0,
    activeCount = 0,
  }
  -- Insert into ordered list (sorted alphabetically)
  table.insert(slaveOrder, identity)
  table.sort(slaveOrder)
  print("[AGG_COL] New fluid_monitor discovered: " .. identity)
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Get ordered list of all known slave entries.
-- @return table - array of slave data tables
function Collector.getSlaves()
  local result = {}
  for _, id in ipairs(slaveOrder) do
    if slaves[id] then
      table.insert(result, slaves[id])
    end
  end
  return result
end

--- Get the number of known slaves.
-- @return number
function Collector.getSlaveCount()
  return #slaveOrder
end

--- Get a specific slave's data.
-- @param identity string
-- @return table|nil
function Collector.getSlaveData(identity)
  return slaves[identity]
end

--- Get the ordered identity list.
-- @return table
function Collector.getSlaveOrder()
  return slaveOrder
end

--- Update slave states (mark stale ones as offline).
function Collector.updateStates()
  local now = computer.millis()
  for _, s in pairs(slaves) do
    if s.state == "online" and (now - s.lastSeen) > staleTimeout then
      s.state = "offline"
    end
  end
end

--- Ping all fluid_monitors to discover/refresh.
function Collector.pingAll()
  if not NETWORK_BUS then return end
  NETWORK_BUS.publish("fluid_commands", { action = "ping" })
end

--- Request a specific slave to send its rules list.
-- @param identity string
function Collector.requestRuleList(identity)
  if not NETWORK_BUS then return end
  NETWORK_BUS.publish("fluid_commands", {
    action = "rule_list",
    targetIdentity = identity,
  })
end

--- Request all slaves to send their rules.
function Collector.requestAllRuleLists()
  if not NETWORK_BUS then return end
  NETWORK_BUS.publish("fluid_commands", { action = "rule_list" })
end

--- Send a targeted command to a specific fluid_monitor slave.
-- @param identity string - target slave identity
-- @param payload table - command payload (action, ...)
function Collector.sendCommand(identity, payload)
  if not NETWORK_BUS then return end
  payload.targetIdentity = identity
  NETWORK_BUS.publish("fluid_commands", payload)
end

--- Send a broadcast command to ALL fluid_monitors.
-- @param payload table - command payload
function Collector.sendBroadcast(payload)
  if not NETWORK_BUS then return end
  NETWORK_BUS.publish("fluid_commands", payload)
end

return Collector