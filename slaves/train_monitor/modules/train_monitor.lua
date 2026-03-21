-- modules/train_monitor.lua
-- Monitors the railroad network: collects per-train, per-station, and global statistics.
-- Also explores the track graph for topology data (signals, switches, track segments).
-- Requires a RailroadStation UUID to access the TrackGraph.

local TrainMonitor = {}

-- Self-driving error labels
TrainMonitor.ERROR_LABELS = {
  [0] = "No Error",
  [1] = "No Power",
  [2] = "No Time Table",
  [3] = "Invalid Next Stop",
  [4] = "Invalid Locomotive Placement",
  [5] = "No Path",
}

-- Dock state labels
TrainMonitor.DOCK_STATE_LABELS = {
  [0] = "Idle",
  [1] = "Entering Station",
  [2] = "Docked",
  [3] = "Leaving Station",
}

-- Signal aspect labels
TrainMonitor.SIGNAL_ASPECTS = {
  [0] = "Unknown",
  [1] = "Clear",
  [2] = "Stop",
  [3] = "Dock",
}

-- Signal block validation labels
TrainMonitor.BLOCK_VALIDATION = {
  [0] = "Unknown",
  [1] = "OK",
  [2] = "No Exit Signal",
  [3] = "Contains Loop",
  [4] = "Mixed Entry Signals",
}

-- Persistent state tracking across scans (keyed by train ID)
local trainStates = {}
local MAX_TRIP_HISTORY = 10

-- Slowdown hysteresis thresholds
local CRUISE_THRESHOLD = 0.80
local SLOWDOWN_THRESHOLD = 0.50

-- ============================================================================
-- Inventory helpers
-- ============================================================================

local function getInventoryFill(inventory)
  if not inventory then
    return { fillPercent = 0, itemCount = 0, capacity = 0, slotsUsed = 0, totalSlots = 0 }
  end

  local totalSlots = inventory.size or 0
  if totalSlots == 0 then
    return { fillPercent = 0, itemCount = 0, capacity = 0, slotsUsed = 0, totalSlots = 0 }
  end

  local slotsUsed, totalCount, totalMaxUsedSlots = 0, 0, 0
  local itemCounts = {}

  for slot = 0, totalSlots - 1 do
    local success, stack = pcall(inventory.getStack, inventory, slot)
    if success and stack and stack.count > 0 then
      slotsUsed = slotsUsed + 1
      totalCount = totalCount + stack.count
      local maxOk, maxSize = pcall(function() return stack.item.type.max end)
      totalMaxUsedSlots = totalMaxUsedSlots + ((maxOk and maxSize and maxSize > 0) and maxSize or stack.count)
      local nameOk, itemName = pcall(function() return stack.item.type.name end)
      if nameOk and itemName then
        itemCounts[itemName] = (itemCounts[itemName] or 0) + stack.count
      end
    end
  end

  local itemBreakdown = {}
  for itemName, count in pairs(itemCounts) do
    table.insert(itemBreakdown, {
      name = itemName,
      count = count,
      percent = totalCount > 0 and math.floor((count / totalCount) * 100 + 0.5) or 0,
    })
  end
  table.sort(itemBreakdown, function(a, b) return a.count > b.count end)

  local capacity, fillPercent = 0, 0
  if slotsUsed > 0 then
    local avgMaxPerSlot = totalMaxUsedSlots / slotsUsed
    capacity = math.floor(avgMaxPerSlot * totalSlots)
    fillPercent = (totalCount / capacity) * 100
  end

  return {
    fillPercent = math.floor(fillPercent * 10) / 10,
    itemCount = totalCount,
    capacity = capacity,
    slotsUsed = slotsUsed,
    totalSlots = totalSlots,
    itemBreakdown = itemBreakdown,
  }
end

local function collectActorInventories(actor)
  local result = {}
  local ok, inventories = pcall(actor.getInventories, actor)
  if not ok or not inventories then return result end
  for index, inv in ipairs(inventories) do
    local fillData = getInventoryFill(inv)
    fillData.index = index
    table.insert(result, fillData)
  end
  return result
end

-- ============================================================================
-- Trip state tracking
-- ============================================================================

local function updateTrainState(trainName, trainData)
  local now = computer.millis()

  if not trainStates[trainName] then
    trainStates[trainName] = {
      lastDockState = trainData.dockState,
      lastSpeed = trainData.speed,
      isSlowedDown = false,
      segmentStartTime = nil,
      departureStation = nil,
      destinationStation = nil,
      segmentDurations = {},
      lastSegmentKey = nil,
      lastSegmentDuration = nil,
      roundTripStartTime = nil,
      stopsVisitedThisRound = 0,
      roundTripDurations = {},
      lastRoundTripDuration = nil,
      dockStartTime = nil,
      segmentDockedTime = 0,
      roundTripDockedTime = 0,
      currentSlowdowns = 0,
      lastSegmentSlowdowns = 0,
    }
    if trainData.isMoving and trainData.dockState == 0 then
      local st = trainStates[trainName]
      st.segmentStartTime = now
      st.departureStation = trainData.prevStationName
      st.destinationStation = trainData.nextStationName
      st.roundTripStartTime = now
    end
  end

  local st = trainStates[trainName]
  local prevDock = st.lastDockState
  local currDock = trainData.dockState

  -- Docked time tracking
  if currDock ~= 0 and not st.dockStartTime then st.dockStartTime = now end
  if currDock == 0 and st.dockStartTime then
    local dur = now - st.dockStartTime
    st.segmentDockedTime = st.segmentDockedTime + dur
    st.roundTripDockedTime = st.roundTripDockedTime + dur
    st.dockStartTime = nil
  end

  -- Transit -> docked: segment ended
  if prevDock == 0 and currDock ~= 0 then
    if st.segmentStartTime and st.departureStation and st.destinationStation then
      local segDur = (now - st.segmentStartTime - st.segmentDockedTime) / 1000
      local segKey = st.departureStation .. " -> " .. st.destinationStation
      st.segmentDurations[segKey] = st.segmentDurations[segKey] or {}
      table.insert(st.segmentDurations[segKey], segDur)
      if #st.segmentDurations[segKey] > MAX_TRIP_HISTORY then
        table.remove(st.segmentDurations[segKey], 1)
      end
      st.lastSegmentKey = segKey
      st.lastSegmentDuration = segDur
      st.lastSegmentSlowdowns = st.currentSlowdowns
    end
    st.stopsVisitedThisRound = st.stopsVisitedThisRound + 1
    if st.stopsVisitedThisRound >= (trainData.totalStops or 0) and st.roundTripStartTime then
      local rtDur = (now - st.roundTripStartTime - st.roundTripDockedTime) / 1000
      st.lastRoundTripDuration = rtDur
      table.insert(st.roundTripDurations, rtDur)
      if #st.roundTripDurations > MAX_TRIP_HISTORY then table.remove(st.roundTripDurations, 1) end
      st.roundTripStartTime = now
      st.stopsVisitedThisRound = 0
      st.roundTripDockedTime = 0
    end
    st.segmentStartTime = nil
    st.segmentDockedTime = 0
    st.currentSlowdowns = 0
    st.isSlowedDown = false
  end

  -- Docked -> transit: new segment started
  if prevDock ~= 0 and currDock == 0 then
    st.segmentStartTime = now
    st.segmentDockedTime = 0
    st.departureStation = trainData.prevStationName
    st.destinationStation = trainData.nextStationName
    st.currentSlowdowns = 0
    st.isSlowedDown = false
    if not st.roundTripStartTime then
      st.roundTripStartTime = now
      st.stopsVisitedThisRound = 0
      st.roundTripDockedTime = 0
    end
  end

  -- Slowdown detection
  if currDock == 0 and trainData.isMoving and trainData.maxSpeed > 0 then
    local ratio = trainData.speed / trainData.maxSpeed
    if not st.isSlowedDown then
      if ratio < SLOWDOWN_THRESHOLD then st.isSlowedDown = true; st.currentSlowdowns = st.currentSlowdowns + 1 end
    else
      if ratio >= CRUISE_THRESHOLD then st.isSlowedDown = false end
    end
  end

  st.lastDockState = currDock
  st.lastSpeed = trainData.speed

  local activeSegKey = (st.departureStation and st.destinationStation)
    and (st.departureStation .. " -> " .. st.destinationStation) or nil
  local segKey = activeSegKey or st.lastSegmentKey
  local segAvg = nil
  if segKey and st.segmentDurations[segKey] then
    local durs = st.segmentDurations[segKey]
    if #durs > 0 then
      local sum = 0
      for _, d in ipairs(durs) do sum = sum + d end
      segAvg = sum / #durs
    end
  end

  local segEta = nil
  if segAvg and st.segmentStartTime then
    local paused = st.segmentDockedTime + (st.dockStartTime and (now - st.dockStartTime) or 0)
    segEta = math.max(0, segAvg - (now - st.segmentStartTime - paused) / 1000)
  end

  local rtAvg = nil
  if #st.roundTripDurations > 0 then
    local sum = 0
    for _, d in ipairs(st.roundTripDurations) do sum = sum + d end
    rtAvg = sum / #st.roundTripDurations
  end

  local rtEta = nil
  if rtAvg and st.roundTripStartTime then
    local paused = st.roundTripDockedTime + (st.dockStartTime and (now - st.dockStartTime) or 0)
    rtEta = math.max(0, rtAvg - (now - st.roundTripStartTime - paused) / 1000)
  end

  return {
    segment = {
      key = segKey,
      averageDuration = segAvg,
      lastDuration = st.lastSegmentDuration,
      eta = segEta,
    },
    roundTrip = {
      averageDuration = rtAvg,
      lastDuration = st.lastRoundTripDuration,
      eta = rtEta,
      stopsRemaining = (trainData.totalStops or 0) - st.stopsVisitedThisRound,
    },
    slowdownCount = currDock ~= 0 and st.lastSegmentSlowdowns or st.currentSlowdowns,
  }
end

-- ============================================================================
-- Per-train data collection
-- ============================================================================

local function collectTrainData(train, cargoPlatforms)
  local trainId = tostring(train)
  local trainData = {
    trainId = trainId,
    name = train:getName(),
    isSelfDriving = train.isSelfDriving,
    isPlayerDriven = train.isPlayerDriven,
    isDocked = train.isDocked,
    dockState = train.dockState,
    dockStateLabel = TrainMonitor.DOCK_STATE_LABELS[train.dockState] or ("Unknown:" .. tostring(train.dockState)),
    selfDrivingError = train.selfDrivingError,
    selfDrivingErrorLabel = TrainMonitor.ERROR_LABELS[train.selfDrivingError] or ("Err:" .. tostring(train.selfDrivingError)),
    hasTimeTable = train.hasTimeTable,
    vehicles = {},
    vehicleCount = 0,
    locomotiveCount = 0,
    freightCarCount = 0,
    totalMass = 0,
    totalPayload = 0,
    speed = 0,
    maxSpeed = 0,
    isMoving = false,
    currentStop = nil,
    totalStops = 0,
    nextStationName = nil,
    prevStationName = nil,
    timetableStops = {},
    wagonFills = {},
    dockingDetails = nil,
    tripStats = nil,
  }

  local vehicleList = train:getVehicles()
  trainData.vehicleCount = #vehicleList

  -- Actual world position of the first vehicle (locomotive) via Actor.location
  if #vehicleList > 0 then
    local locOk, loc = pcall(function() return vehicleList[1].location end)
    if locOk and loc then
      trainData.worldLocation = { x = loc.x, y = loc.y, z = loc.z }
    end
  end

  for vIdx, vehicle in ipairs(vehicleList) do
    local movement = vehicle:getMovement()
    table.insert(trainData.vehicles, {
      index = vIdx,
      length = vehicle.length,
      isDocked = vehicle.isDocked,
      isReversed = vehicle.isReversed,
      mass = movement.mass,
      tareMass = movement.tareMass,
      payloadMass = movement.payloadMass,
      speed = movement.speed,
      maxSpeed = movement.maxSpeed,
      isMoving = movement.isMoving,
    })

    trainData.totalMass = trainData.totalMass + movement.mass
    trainData.totalPayload = trainData.totalPayload + movement.payloadMass

    if vIdx == 1 then
      trainData.speed = math.abs(movement.speed)
      trainData.maxSpeed = movement.maxSpeed
      trainData.isMoving = movement.isMoving
    end

    local wagonInvs = collectActorInventories(vehicle)
    if #wagonInvs > 0 then
      table.insert(trainData.wagonFills, { vehicleIndex = vIdx, inventories = wagonInvs })
    end
  end

  if trainData.dockState == 0 and trainData.isMoving then
    trainData.dockStateLabel = "In Transit"
  end

  -- Timetable
  if trainData.hasTimeTable then
    local timeTable = train:getTimeTable()
    if timeTable then
      trainData.totalStops = timeTable.numStops
      trainData.currentStop = timeTable:getCurrentStop()
      for stopIdx = 0, trainData.totalStops - 1 do
        local ok, stopData = pcall(timeTable.getStop, timeTable, stopIdx)
        if ok and stopData and stopData.station then
          local nameOk, name = pcall(function() return stopData.station.name end)
          trainData.timetableStops[stopIdx] = nameOk and name or ("Stop#" .. stopIdx)
        else
          trainData.timetableStops[stopIdx] = "Stop#" .. stopIdx
        end
      end
      trainData.nextStationName = trainData.timetableStops[trainData.currentStop]
      if trainData.totalStops > 0 then
        local prevIdx = (trainData.currentStop - 1 + trainData.totalStops) % trainData.totalStops
        trainData.prevStationName = trainData.timetableStops[prevIdx]
      end
    end
  end

  -- Docking details
  if trainData.isDocked and cargoPlatforms and #cargoPlatforms > 0 then
    local dockingPlats = {}
    for _, plat in ipairs(cargoPlatforms) do
      local dOk, dockedVehicle = pcall(plat.getDockedVehicle, plat)
      if dOk and dockedVehicle then
        local mOk, matchResult = pcall(function() return tostring(dockedVehicle:getTrain()) == trainId end)
        if mOk and matchResult then
          local ok1, v1 = pcall(function() return plat.isInLoadMode end)
          local ok2, v2 = pcall(function() return plat.inputFlow end)
          local ok3, v3 = pcall(function() return plat.outputFlow end)
          local ok4, v4 = pcall(function() return plat.fullLoad end)
          local ok5, v5 = pcall(function() return plat.fullUnload end)
          table.insert(dockingPlats, {
            isInLoadMode = ok1 and v1 or false,
            inputFlow = ok2 and v2 or 0,
            outputFlow = ok3 and v3 or 0,
            fullLoad = ok4 and v4 or false,
            fullUnload = ok5 and v5 or false,
            inventories = collectActorInventories(plat),
          })
        end
      end
    end
    if #dockingPlats > 0 then
      trainData.dockingDetails = { platforms = dockingPlats }
    end
  end

  if trainData.isSelfDriving then
    trainData.tripStats = updateTrainState(trainId, trainData)
  else
    trainStates[trainId] = nil
  end

  return trainData
end

-- ============================================================================
-- Station data collection
-- ============================================================================

--- Persistent cache: once we know a platform ID is cargo (or not), never probe again.
--- First scan emits a few FIN warnings for non-cargo platforms, then zero forever.
local cargoTypeCache = {} -- platId → boolean

--- Collect platform info from a station.
local function collectPlatforms(stationProxy, knownCargoIds)
  local platforms = {}
  local pOk, allPlats = pcall(stationProxy.getAllConnectedPlatforms, stationProxy)
  if not pOk or not allPlats then return platforms end

  for _, plat in ipairs(allPlats) do
    local platId = tostring(plat)
    local platInfo = { id = platId }

    local isCargo = cargoTypeCache[platId]
    if isCargo == nil then
      if knownCargoIds and knownCargoIds[platId] then
        isCargo = true
      else
        local probeOk, probeVal = pcall(function() return plat.isInLoadMode end)
        isCargo = probeOk and type(probeVal) == "boolean"
      end
      cargoTypeCache[platId] = isCargo
    end

    if isCargo then
      platInfo.isCargo = true
      local ok1, v1 = pcall(function() return plat.isInLoadMode end)
      platInfo.isInLoadMode = ok1 and v1 or false
      local ok2, v2 = pcall(function() return plat.inputFlow end)
      platInfo.inputFlow = ok2 and v2 or 0
      local ok3, v3 = pcall(function() return plat.outputFlow end)
      platInfo.outputFlow = ok3 and v3 or 0
      local ok6, v6 = pcall(function() return plat.fullLoad end)
      platInfo.fullLoad = ok6 and v6 or false
      local ok7, v7 = pcall(function() return plat.fullUnload end)
      platInfo.fullUnload = ok7 and v7 or false
      platInfo.inventories = collectActorInventories(plat)
    else
      platInfo.isCargo = false
    end
    table.insert(platforms, platInfo)
  end
  return platforms
end

--- Collect detailed info about all railroad stations accessible from the track graph.
-- @param trackGraph TrackGraph proxy
-- @param knownCargoIds table|nil set of platform IDs known to be TrainPlatformCargo
-- @return table { stations, topologyEdges }
local function collectStationData(trackGraph, knownCargoIds)
  local stationData = {}
  local topologyEdges = {}

  local ok, trains = pcall(trackGraph.getTrains, trackGraph)
  if not ok or not trains then return stationData, topologyEdges end

  local stationsSeen = {}
  local stationByName = {}
  local edgesSeen = {}

  for _, train in ipairs(trains) do
    if train.hasTimeTable then
      local tt = train:getTimeTable()
      if tt then
        local stopNames = {}

        for i = 0, tt.numStops - 1 do
          local sOk, stop = pcall(tt.getStop, tt, i)
          if sOk and stop and stop.station then
            local stId = tostring(stop.station)
            local nameOk, name = pcall(function() return stop.station.name end)
            local stName = nameOk and name or "Unknown"
            table.insert(stopNames, stName)

            if not stationsSeen[stId] then
              stationsSeen[stId] = true

              local platforms = collectPlatforms(stop.station, knownCargoIds)

              -- World position via Actor.location (reliable on all Actor subclasses)
              local location = nil
              local locOk, loc = pcall(function() return stop.station.location end)
              if locOk and loc then
                location = { x = loc.x, y = loc.y, z = loc.z }
              end

              local stInfo = {
                id = stId,
                name = stName,
                proxy = stop.station,
                platforms = platforms,
                platformCount = #platforms,
                location = location,
              }
              table.insert(stationData, stInfo)
              stationByName[stName] = stInfo
            end
          end
        end

        -- Build topology edges from consecutive timetable stops
        for i = 1, #stopNames do
          local fromName = stopNames[i]
          local toName = stopNames[(i % #stopNames) + 1]
          local edgeKey = fromName .. " -> " .. toName
          if not edgesSeen[edgeKey] then
            edgesSeen[edgeKey] = true
            local fromSt = stationByName[fromName]
            local toSt = stationByName[toName]
            if fromSt and toSt and fromSt.location and toSt.location then
              table.insert(topologyEdges, {
                from = fromName,
                to = toName,
                fromLocation = fromSt.location,
                toLocation = toSt.location,
              })
            end
          end
        end
      end
    end
  end

  -- Discover ALL stations on the track graph (not just those in timetables)
  local gsOk, allGraphStations = pcall(trackGraph.getStations, trackGraph)
  if gsOk and allGraphStations then
    for _, station in ipairs(allGraphStations) do
      local stId = tostring(station)
      if not stationsSeen[stId] then
        stationsSeen[stId] = true
        local nameOk, name = pcall(function() return station.name end)
        local stName = nameOk and name or "Unknown"

        local platforms = collectPlatforms(station, knownCargoIds)

        local location = nil
        local locOk, loc = pcall(function() return station.location end)
        if locOk and loc then
          location = { x = loc.x, y = loc.y, z = loc.z }
        end

        local stInfo = {
          id = stId,
          name = stName,
          proxy = station,
          platforms = platforms,
          platformCount = #platforms,
          location = location,
        }
        table.insert(stationData, stInfo)
        stationByName[stName] = stInfo
      end
    end
  end

  return stationData, topologyEdges
end

-- ============================================================================
-- Global stats
-- ============================================================================

local function computeGlobalStats(allTrainData)
  local stats = {
    totalTrains = #allTrainData,
    trainsMoving = 0, trainsDocked = 0, trainsIdle = 0,
    trainsSelfDriving = 0, trainsWithErrors = 0,
    totalVehicles = 0, totalMass = 0, totalPayload = 0,
    averageSpeed = 0, maxSpeedObserved = 0,
    selfDrivingSpeedSum = 0, selfDrivingCount = 0,
    movingSpeedSum = 0, movingTrainCount = 0,
    averageMovingSpeed = 0,
  }

  for _, td in ipairs(allTrainData) do
    stats.totalVehicles = stats.totalVehicles + td.vehicleCount
    stats.totalMass = stats.totalMass + td.totalMass
    stats.totalPayload = stats.totalPayload + td.totalPayload
    if td.speed > stats.maxSpeedObserved then stats.maxSpeedObserved = td.speed end

    if td.isMoving then
      stats.trainsMoving = stats.trainsMoving + 1
      stats.movingSpeedSum = stats.movingSpeedSum + td.speed
      stats.movingTrainCount = stats.movingTrainCount + 1
    end
    if td.isDocked then stats.trainsDocked = stats.trainsDocked + 1 end
    if not td.isMoving and not td.isDocked then stats.trainsIdle = stats.trainsIdle + 1 end
    if td.isSelfDriving then
      stats.trainsSelfDriving = stats.trainsSelfDriving + 1
      stats.selfDrivingSpeedSum = stats.selfDrivingSpeedSum + td.speed
      stats.selfDrivingCount = stats.selfDrivingCount + 1
    end
    if td.selfDrivingError ~= 0 then stats.trainsWithErrors = stats.trainsWithErrors + 1 end
  end

  if stats.selfDrivingCount > 0 then stats.averageSpeed = stats.selfDrivingSpeedSum / stats.selfDrivingCount end
  if stats.movingTrainCount > 0 then stats.averageMovingSpeed = stats.movingSpeedSum / stats.movingTrainCount end
  return stats
end

-- ============================================================================
-- Full scan
-- ============================================================================

--- Perform a full scan of the railroad network.
-- Returns train data, global stats, station data, and raw train proxies.
function TrainMonitor.scan(stationId, cargoPlatforms)
  local station = component.proxy(stationId)
  if not station then
    print("[TRAIN_MON] Station not found: " .. tostring(stationId))
    return nil
  end

  local trackGraph = station:getTrackGraph()
  if not trackGraph then
    print("[TRAIN_MON] Failed to get TrackGraph")
    return nil
  end

  local trains = trackGraph:getTrains()
  if not trains then
    print("[TRAIN_MON] Failed to get trains")
    return nil
  end

  local allTrainData = {}
  for _, train in ipairs(trains) do
    local ok, trainData = pcall(collectTrainData, train, cargoPlatforms or {})
    if ok then
      table.insert(allTrainData, trainData)
    else
      print("[TRAIN_MON] Error: " .. tostring(trainData))
    end
  end

  -- Build cargo platform ID lookup from REGISTRY data (zero-warning detection)
  local knownCargoIds = nil
  if cargoPlatforms and #cargoPlatforms > 0 then
    knownCargoIds = {}
    for _, cp in ipairs(cargoPlatforms) do
      knownCargoIds[tostring(cp)] = true
    end
  end

  local globalStats = computeGlobalStats(allTrainData)
  local stations, topologyEdges = collectStationData(trackGraph, knownCargoIds)

  return {
    trains = allTrainData,
    globalStats = globalStats,
    stations = stations,
    topologyEdges = topologyEdges,
    rawTrainProxies = trains,
    trackGraph = trackGraph,
  }
end

-- ============================================================================
-- Format helpers (for console)
-- ============================================================================

function TrainMonitor.formatSpeed(speed)
  return string.format("%.1f km/h", math.abs(speed) * 0.036)
end

function TrainMonitor.formatMass(mass)
  if mass >= 1000 then return string.format("%.1f t", mass / 1000) end
  return string.format("%.0f kg", mass)
end

function TrainMonitor.formatDuration(seconds)
  if not seconds then return "--" end
  seconds = math.floor(seconds)
  if seconds >= 3600 then
    return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  elseif seconds >= 60 then
    return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60)
  end
  return string.format("%ds", seconds)
end

-- ============================================================================
-- Console report
-- ============================================================================

function TrainMonitor.printReport(scanResult)
  if not scanResult then
    print("[TRAIN_MON] No scan data")
    return
  end

  local s = scanResult.globalStats
  print("========== RAILROAD NETWORK REPORT ==========")
  print("Trains: " .. s.totalTrains .. "  Moving: " .. s.trainsMoving
    .. "  Docked: " .. s.trainsDocked .. "  Idle: " .. s.trainsIdle
    .. "  Self-drv: " .. s.trainsSelfDriving .. "  Errors: " .. s.trainsWithErrors)
  print("Vehicles: " .. s.totalVehicles .. "  Mass: " .. TrainMonitor.formatMass(s.totalMass)
    .. "  Payload: " .. TrainMonitor.formatMass(s.totalPayload))
  print("Speed avg(auto): " .. TrainMonitor.formatSpeed(s.averageSpeed)
    .. "  avg(moving): " .. TrainMonitor.formatSpeed(s.averageMovingSpeed)
    .. "  max: " .. TrainMonitor.formatSpeed(s.maxSpeedObserved))

  -- Stations
  if scanResult.stations then
    print("--- Stations (" .. #scanResult.stations .. ") ---")
    for _, st in ipairs(scanResult.stations) do
      print("  " .. st.name .. " (" .. st.platformCount .. " platforms)")
    end
  end

  print("=============================================")
  for index, td in ipairs(scanResult.trains) do
    print("--- Train #" .. index .. ": " .. td.name .. " ---")
    print("  State: " .. td.dockStateLabel .. "  Speed: " .. TrainMonitor.formatSpeed(td.speed))
    print("  Vehicles: " .. td.vehicleCount .. "  Self-drv: " .. tostring(td.isSelfDriving))
    if td.selfDrivingError ~= 0 then
      print("  ERROR: " .. td.selfDrivingErrorLabel)
    end
    if td.nextStationName then
      print("  Next: " .. td.nextStationName .. " (" .. (td.currentStop or "?") .. "/" .. td.totalStops .. ")")
    end
    if td.tripStats then
      local trip = td.tripStats
      if trip.segment.key then print("  Segment: " .. trip.segment.key) end
      if trip.segment.eta then print("  Seg ETA: " .. TrainMonitor.formatDuration(trip.segment.eta)) end
      if trip.roundTrip.eta then print("  Route ETA: " .. TrainMonitor.formatDuration(trip.roundTrip.eta)) end
      print("  Slowdowns: " .. trip.slowdownCount)
    end
    if td.wagonFills then
      for _, wf in ipairs(td.wagonFills) do
        for _, inv in ipairs(wf.inventories) do
          print("  Wagon#" .. wf.vehicleIndex .. ": " .. inv.fillPercent .. "%")
        end
      end
    end
  end
end

return TrainMonitor
