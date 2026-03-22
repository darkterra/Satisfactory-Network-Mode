-- modules/train_controller.lua
-- Provides control operations on trains: timetable management, autopilot,
-- naming, docking, and forced switch routing.
--
-- Used by features/train.lua and the display module for interactive control.
-- Also handles commands from the network bus for remote control.

local TrainController = {}

-- Shared reference to the NETWORK_BUS for forwarding switch commands to rail_controllers
local networkBusRef = nil

-- Cache of train proxies (keyed by trainId) refreshed each scan
local trainProxies = {}

-- Forced routes: per-train switch positions to enforce when the train approaches
-- Key: trainId, Value: { { switchId, position } ... }
local forcedRoutes = {}

-- ============================================================================
-- Initialization
-- ============================================================================

function TrainController.init(options)
  options = options or {}
  networkBusRef = options.networkBus or NETWORK_BUS or nil
  print("[TRAIN_CTRL] Controller initialized")
end

--- Update the internal proxy cache from latest scan data.
-- Called by the feature after each scan.
-- @param trains table - array of raw train proxies from trackGraph:getTrains()
function TrainController.updateProxyCache(trains)
  trainProxies = {}
  for _, train in ipairs(trains) do
    local id = tostring(train)
    trainProxies[id] = train
  end
end

--- Retrieve a cached train proxy by its trainId string.
local function getProxy(trainId)
  return trainProxies[trainId]
end

-- ============================================================================
-- Autopilot control
-- ============================================================================

--- Toggle self-driving mode for a train.
-- @param trainData table - from train_monitor scan (needs trainId)
function TrainController.toggleAutopilot(trainData)
  local train = getProxy(trainData.trainId)
  if not train then
    print("[TRAIN_CTRL] Train proxy not found: " .. tostring(trainData.trainId))
    return false
  end
  local newState = not trainData.isSelfDriving
  local ok, err = pcall(train.setSelfDriving, train, newState)
  if not ok then
    print("[TRAIN_CTRL] Failed to set self-driving: " .. tostring(err))
    return false
  end
  print("[TRAIN_CTRL] Autopilot " .. (newState and "enabled" or "disabled") .. " for " .. trainData.name)
  return true
end

--- Explicitly set autopilot state.
function TrainController.setAutopilot(trainData, enabled)
  local train = getProxy(trainData.trainId)
  if not train then return false end
  local ok, err = pcall(train.setSelfDriving, train, enabled)
  if not ok then
    print("[TRAIN_CTRL] Failed to set self-driving: " .. tostring(err))
    return false
  end
  return true
end

-- ============================================================================
-- Train naming
-- ============================================================================

--- Rename a train.
-- @param trainData table - needs trainId
-- @param newName string - the new name
function TrainController.renameTrain(trainData, newName)
  local train = getProxy(trainData.trainId)
  if not train then
    print("[TRAIN_CTRL] Train proxy not found for rename")
    return false
  end
  local ok, err = pcall(train.setName, train, newName)
  if not ok then
    print("[TRAIN_CTRL] Failed to rename: " .. tostring(err))
    return false
  end
  print("[TRAIN_CTRL] Renamed train to: " .. newName)
  return true
end

-- ============================================================================
-- Docking
-- ============================================================================

--- Force a train to dock at its current station.
function TrainController.dockTrain(trainData)
  local train = getProxy(trainData.trainId)
  if not train then return false end
  local ok, err = pcall(train.dock, train)
  if not ok then
    print("[TRAIN_CTRL] Failed to dock: " .. tostring(err))
    return false
  end
  return true
end

-- ============================================================================
-- Timetable management
-- ============================================================================

--- Get the full timetable for a train as an array of stop info.
-- @return table array of { index, stationName, ruleSet }
function TrainController.getTimetable(trainData)
  local train = getProxy(trainData.trainId)
  if not train then return nil end

  if not train.hasTimeTable then return {} end
  local tt = train:getTimeTable()
  if not tt then return {} end

  local stops = {}
  for i = 0, tt.numStops - 1 do
    local ok, stop = pcall(tt.getStop, tt, i)
    if ok and stop then
      local nameOk, name = pcall(function() return stop.station.name end)
      table.insert(stops, {
        index = i,
        stationName = nameOk and name or ("Stop#" .. i),
        station = stop.station,
        ruleSet = stop.ruleSet,
      })
    end
  end
  return stops
end

--- Set the current stop target (where the train drives to next).
function TrainController.setCurrentStop(trainData, stopIndex)
  local train = getProxy(trainData.trainId)
  if not train or not train.hasTimeTable then return false end

  local tt = train:getTimeTable()
  if not tt then return false end

  local ok, err = pcall(tt.setCurrentStop, tt, stopIndex)
  if not ok then
    print("[TRAIN_CTRL] Failed to set current stop: " .. tostring(err))
    return false
  end
  return true
end

--- Add a stop to the timetable at a given index.
-- @param trainData table - needs trainId
-- @param stationProxy Trace<RailroadStation> - the station to add
-- @param index number - zero-based index
-- @param ruleSet Struct<TrainDockingRuleSet> (optional)
function TrainController.addStop(trainData, stationProxy, index, ruleSet)
  local train = getProxy(trainData.trainId)
  if not train then return false end

  local tt = train.hasTimeTable and train:getTimeTable()
  if not tt then
    -- Create a new timetable if none exists
    local ok, newTT = pcall(train.newTimeTable, train)
    if not ok or not newTT then
      print("[TRAIN_CTRL] Failed to create timetable")
      return false
    end
    tt = newTT
  end

  ruleSet = ruleSet or {}
  local ok, added = pcall(tt.addStop, tt, index, stationProxy, ruleSet)
  if not ok then
    print("[TRAIN_CTRL] Failed to add stop: " .. tostring(added))
    return false
  end
  return added
end

--- Remove a stop from the timetable.
function TrainController.removeStop(trainData, stopIndex)
  local train = getProxy(trainData.trainId)
  if not train or not train.hasTimeTable then return false end

  local tt = train:getTimeTable()
  if not tt then return false end

  local ok, err = pcall(tt.removeStop, tt, stopIndex)
  if not ok then
    print("[TRAIN_CTRL] Failed to remove stop: " .. tostring(err))
    return false
  end
  return true
end

--- Replace the entire timetable with a new set of stops.
-- @param trainData table
-- @param stops array of { station = Trace<RailroadStation>, ruleSet = Struct<TrainDockingRuleSet> }
function TrainController.setStops(trainData, stops)
  local train = getProxy(trainData.trainId)
  if not train then return false end

  local tt = train.hasTimeTable and train:getTimeTable()
  if not tt then
    local ok, newTT = pcall(train.newTimeTable, train)
    if not ok or not newTT then return false end
    tt = newTT
  end

  local ttStops = {}
  for _, s in ipairs(stops) do
    table.insert(ttStops, {
      station = s.station,
      ruleSet = s.ruleSet or {},
    })
  end

  local ok, result = pcall(tt.setStops, tt, ttStops)
  if not ok then
    print("[TRAIN_CTRL] Failed to set stops: " .. tostring(result))
    return false
  end
  return result
end

--- Clear the entire timetable (remove all stops).
function TrainController.clearTimetable(trainData)
  local train = getProxy(trainData.trainId)
  if not train or not train.hasTimeTable then return true end

  local tt = train:getTimeTable()
  if not tt then return true end

  while tt.numStops > 0 do
    local ok, err = pcall(tt.removeStop, tt, 0)
    if not ok then
      print("[TRAIN_CTRL] Failed to clear stop: " .. tostring(err))
      return false
    end
  end
  print("[TRAIN_CTRL] Timetable cleared for " .. trainData.name)
  return true
end

-- ============================================================================
-- Forced routing (switch positions per train)
-- ============================================================================

--- Set forced route for a train.
-- A forced route is a list of switch positions that should be set when the
-- train approaches. Sent to rail_controller slaves via network bus.
-- @param trainId string
-- @param route table - array of { switchId, position }
function TrainController.setForcedRoute(trainId, route)
  forcedRoutes[trainId] = route
  print("[TRAIN_CTRL] Forced route set for " .. trainId .. " (" .. #route .. " switches)")
  if networkBusRef then
    networkBusRef.publish("rail_commands", {
      action = "set_forced_route",
      trainId = trainId,
      route = route,
    })
  end
  return true
end

--- Clear forced route for a train.
function TrainController.clearForcedRoute(trainId)
  forcedRoutes[trainId] = nil
  if networkBusRef then
    networkBusRef.publish("rail_commands", {
      action = "clear_forced_route",
      trainId = trainId,
    })
  end
  return true
end

--- Get forced route for a train.
function TrainController.getForcedRoute(trainId)
  return forcedRoutes[trainId]
end

--- Get all forced routes.
function TrainController.getAllForcedRoutes()
  return forcedRoutes
end

-- ============================================================================
-- Flag enforcement state
-- ============================================================================

local noReverseState = {}     -- trainId → { handled, turnaroundName, insertedIndex }
local pausedByPriority = {}   -- trainId → true

local PRIORITY_APPROACH_DIST = 20000   -- 200m — priority train "near switch"
local PRIORITY_CONFLICT_DIST = 40000   -- 400m — non-priority train "near same switch"

local function vecDist(a, b)
  if not a or not b then return math.huge end
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function findTrainById(scanResult, trainId)
  if not scanResult or not scanResult.trains then return nil end
  for _, td in ipairs(scanResult.trains) do
    if td.trainId == trainId then return td end
  end
  return nil
end

--- Remove the turnaround stop we previously inserted by searching the timetable.
local function removeTurnaroundStop(trainId, nrState)
  if not nrState or not nrState.turnaroundName then return end
  local train = getProxy(trainId)
  if not train or not train.hasTimeTable then return end
  local ok, tt = pcall(train.getTimeTable, train)
  if not ok or not tt then return end

  local idx = nrState.insertedIndex
  if idx and idx < tt.numStops then
    local sOk, stop = pcall(tt.getStop, tt, idx)
    if sOk and stop and stop.station then
      local nOk, name = pcall(function() return stop.station.name end)
      if nOk and name == nrState.turnaroundName then
        pcall(tt.removeStop, tt, idx)
        return
      end
    end
  end

  for i = 0, tt.numStops - 1 do
    local sOk, stop = pcall(tt.getStop, tt, i)
    if sOk and stop and stop.station then
      local nOk, name = pcall(function() return stop.station.name end)
      if nOk and name == nrState.turnaroundName then
        pcall(tt.removeStop, tt, i)
        return
      end
    end
  end
end

-- ============================================================================
-- No-Reverse enforcement
-- ============================================================================

--- Monitors noReverse-flagged trains. When one drives in reverse,
--- inserts the nearest dead-end station as an immediate turnaround stop.
--- Removes the turnaround stop once the train is going forward again.
local function enforceNoReverse(scanResult, trainFlags)
  if not scanResult.trains or not scanResult.stations then return end

  local deadEndNoCargo = {}
  local deadEndAll = {}
  for _, st in ipairs(scanResult.stations) do
    if st.isDeadEnd and st.proxy and st.location then
      table.insert(deadEndAll, st)
      local cargoCount = 0
      for _, plat in ipairs(st.platforms or {}) do
        if plat.isCargo then cargoCount = cargoCount + 1 end
      end
      if cargoCount == 0 then table.insert(deadEndNoCargo, st) end
    end
  end
  local deadEndStations = #deadEndNoCargo > 0 and deadEndNoCargo or deadEndAll

  for _, td in ipairs(scanResult.trains) do
    local flags = trainFlags[td.trainId]
    if not flags or not flags.noReverse then
      if noReverseState[td.trainId] then
        removeTurnaroundStop(td.trainId, noReverseState[td.trainId])
        noReverseState[td.trainId] = nil
      end
    else
      local nrs = noReverseState[td.trainId]

      if td.rawSpeed and td.rawSpeed < -1 and (not nrs or not nrs.handled) then
        if #deadEndStations == 0 then goto nextTrain end

        local nearest, nearestDist = nil, math.huge
        if td.worldLocation then
          for _, st in ipairs(deadEndStations) do
            local dist = vecDist(td.worldLocation, st.location)
            if dist < nearestDist then nearest = st; nearestDist = dist end
          end
        end

        if nearest and nearest.proxy then
          local train = getProxy(td.trainId)
          if train then
            local tt = train.hasTimeTable and train:getTimeTable() or nil
            if not tt then
              local cOk, newTT = pcall(train.newTimeTable, train)
              if cOk and newTT then tt = newTT end
            end
            if tt then
              local currentIdx = tt:getCurrentStop() or 0
              local aOk = pcall(tt.addStop, tt, currentIdx, nearest.proxy, {})
              if aOk then
                pcall(tt.setCurrentStop, tt, currentIdx)
                noReverseState[td.trainId] = {
                  handled = true,
                  turnaroundName = nearest.name,
                  insertedIndex = currentIdx,
                }
              end
            end
          end
        end

      elseif td.rawSpeed and td.rawSpeed >= 0 and nrs and nrs.handled then
        removeTurnaroundStop(td.trainId, nrs)
        noReverseState[td.trainId] = nil
      end
    end
    ::nextTrain::
  end
end

-- ============================================================================
-- Priority enforcement
-- ============================================================================

--- Pauses non-priority trains that are near the same switch as an approaching
--- priority train. Re-enables them once the conflict is resolved.
local function enforcePriority(scanResult, trainFlags, railStates)
  if not scanResult.trains then return end

  local allSwitches = {}
  if railStates then
    for _, rs in pairs(railStates) do
      for _, sw in ipairs(rs.switches or {}) do
        if sw.location then table.insert(allSwitches, sw) end
      end
    end
  end

  local priorityTrains, nonPriorityTrains = {}, {}
  for _, td in ipairs(scanResult.trains) do
    if td.worldLocation then
      local flags = trainFlags[td.trainId]
      if flags and flags.priority then
        table.insert(priorityTrains, td)
      else
        table.insert(nonPriorityTrains, td)
      end
    end
  end

  if #priorityTrains == 0 then
    for trainId, _ in pairs(pausedByPriority) do
      local td = findTrainById(scanResult, trainId)
      if td then TrainController.setAutopilot(td, true) end
    end
    pausedByPriority = {}
    return
  end

  if #allSwitches == 0 then return end

  local conflictSwitchIds = {}
  for _, sw in ipairs(allSwitches) do
    for _, pt in ipairs(priorityTrains) do
      if vecDist(pt.worldLocation, sw.location) < PRIORITY_APPROACH_DIST then
        conflictSwitchIds[sw.id] = true
        break
      end
    end
  end

  local shouldPause = {}
  for _, td in ipairs(nonPriorityTrains) do
    for _, sw in ipairs(allSwitches) do
      if conflictSwitchIds[sw.id] and vecDist(td.worldLocation, sw.location) < PRIORITY_CONFLICT_DIST then
        local isOpposite = false
        for _, pt in ipairs(priorityTrains) do
          if vecDist(pt.worldLocation, sw.location) < PRIORITY_APPROACH_DIST then
            local dx1 = pt.worldLocation.x - sw.location.x
            local dy1 = pt.worldLocation.y - sw.location.y
            local dx2 = td.worldLocation.x - sw.location.x
            local dy2 = td.worldLocation.y - sw.location.y
            if dx1 * dx2 + dy1 * dy2 <= 0 then
              isOpposite = true
              break
            end
          end
        end
        if isOpposite then
          shouldPause[td.trainId] = true
          break
        end
      end
    end
  end

  for trainId, _ in pairs(shouldPause) do
    if not pausedByPriority[trainId] then
      local td = findTrainById(scanResult, trainId)
      if td and td.isSelfDriving then
        TrainController.setAutopilot(td, false)
        pausedByPriority[trainId] = true
      end
    end
  end

  local toResume = {}
  for trainId, _ in pairs(pausedByPriority) do
    if not shouldPause[trainId] then table.insert(toResume, trainId) end
  end
  for _, trainId in ipairs(toResume) do
    local td = findTrainById(scanResult, trainId)
    if td then TrainController.setAutopilot(td, true) end
    pausedByPriority[trainId] = nil
  end
end

-- ============================================================================
-- Public enforcement entry point
-- ============================================================================

--- Run all flag enforcement logic. Called after each scan cycle.
--- @param scanResult table - latest scan data with trains, stations, railStates
--- @param trainFlags table - trainId → { priority, noReverse }
function TrainController.enforceFlags(scanResult, trainFlags)
  if not scanResult or not trainFlags or not next(trainFlags) then return end
  local ok1, err1 = pcall(enforceNoReverse, scanResult, trainFlags)
  if not ok1 then print("[TRAIN_CTRL] noReverse error: " .. tostring(err1)) end
  local ok2, err2 = pcall(enforcePriority, scanResult, trainFlags, scanResult.railStates)
  if not ok2 then print("[TRAIN_CTRL] priority error: " .. tostring(err2)) end
end

--- Returns the set of trains currently paused by priority enforcement.
function TrainController.getPausedByPriority()
  return pausedByPriority
end

-- ============================================================================
-- Remote command handler (from network bus)
-- ============================================================================

--- Handle an incoming control command.
-- Called by the feature's network bus subscriber.
-- @param cmd table - { action, trainId, ... }
-- @param scanResult table - latest scan result to find trainData
function TrainController.handleCommand(cmd, scanResult)
  if not cmd or not cmd.action then return end

  -- Find trainData by trainId
  local trainData = nil
  if cmd.trainId and scanResult then
    for _, td in ipairs(scanResult.trains) do
      if td.trainId == cmd.trainId then
        trainData = td
        break
      end
    end
  end

  local action = cmd.action

  if action == "toggle_autopilot" and trainData then
    TrainController.toggleAutopilot(trainData)

  elseif action == "set_autopilot" and trainData then
    TrainController.setAutopilot(trainData, cmd.enabled)

  elseif action == "rename" and trainData and cmd.name then
    TrainController.renameTrain(trainData, cmd.name)

  elseif action == "dock" and trainData then
    TrainController.dockTrain(trainData)

  elseif action == "set_current_stop" and trainData and cmd.stopIndex then
    TrainController.setCurrentStop(trainData, cmd.stopIndex)

  elseif action == "remove_stop" and trainData and cmd.stopIndex then
    TrainController.removeStop(trainData, cmd.stopIndex)

  elseif action == "clear_timetable" and trainData then
    TrainController.clearTimetable(trainData)

  elseif action == "set_forced_route" and cmd.trainId then
    TrainController.setForcedRoute(cmd.trainId, cmd.route or {})

  elseif action == "clear_forced_route" and cmd.trainId then
    TrainController.clearForcedRoute(cmd.trainId)

  elseif action == "toggle_switch" and cmd.switchId then
    if networkBusRef then
      networkBusRef.publish("rail_commands", {
        action = "toggle_switch",
        switchId = cmd.switchId,
        targetIdentity = cmd.targetIdentity,
      })
    end

  elseif action == "set_switch" and cmd.switchId then
    if networkBusRef then
      networkBusRef.publish("rail_commands", {
        action = "set_switch",
        switchId = cmd.switchId,
        position = cmd.position,
        targetIdentity = cmd.targetIdentity,
      })
    end

  elseif action == "force_switch" and cmd.switchId then
    if networkBusRef then
      networkBusRef.publish("rail_commands", {
        action = "force_switch",
        switchId = cmd.switchId,
        position = cmd.position,
        targetIdentity = cmd.targetIdentity,
      })
    end

  elseif action == "ping" then
    if networkBusRef then
      networkBusRef.publish("train_status", {
        action = "pong",
        identity = (CONFIG_MANAGER and CONFIG_MANAGER.get("slave", "identity")) or "unknown",
      })
    end

  else
    print("[TRAIN_CTRL] Unknown command: " .. tostring(action))
  end
end

return TrainController
