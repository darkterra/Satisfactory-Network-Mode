-- modules/train_monitor.lua
-- Monitors the railroad network: collects per-train and global statistics.
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

-- Dock state labels (best-known mapping)
TrainMonitor.DOCK_STATE_LABELS = {
  [0] = "Idle",
  [1] = "Entering Station",
  [2] = "Docked",
  [3] = "Leaving Station",
}

-- Persistent state tracking across scans (keyed by train name)
local trainStates = {}
local MAX_TRIP_HISTORY = 10

-- Slowdown hysteresis thresholds (as fraction of maxSpeed)
local CRUISE_THRESHOLD = 0.80
local SLOWDOWN_THRESHOLD = 0.50

--- Compute fill data for a single Inventory.
-- @param inventory Trace<Inventory>
-- @return table { fillPercent, itemCount, capacity, slotsUsed, totalSlots }
local function getInventoryFill(inventory)
  if not inventory then
    return { fillPercent = 0, itemCount = 0, capacity = 0, slotsUsed = 0, totalSlots = 0 }
  end

  local totalSlots = inventory.size or 0
  if totalSlots == 0 then
    return { fillPercent = 0, itemCount = 0, capacity = 0, slotsUsed = 0, totalSlots = 0 }
  end

  local slotsUsed = 0
  local totalCount = 0
  local totalMaxUsedSlots = 0
  local itemCounts = {} -- track count per item name to find the dominant one

  for slot = 0, totalSlots - 1 do
    local success, stack = pcall(inventory.getStack, inventory, slot)
    if success and stack and stack.count > 0 then
      slotsUsed = slotsUsed + 1
      totalCount = totalCount + stack.count
      local maxSuccess, maxSize = pcall(function() return stack.item.type.max end)
      if maxSuccess and maxSize and maxSize > 0 then
        totalMaxUsedSlots = totalMaxUsedSlots + maxSize
      else
        totalMaxUsedSlots = totalMaxUsedSlots + stack.count
      end
      -- Track item name for dominant item detection
      local nameSuccess, itemName = pcall(function() return stack.item.type.name end)
      if nameSuccess and itemName then
        itemCounts[itemName] = (itemCounts[itemName] or 0) + stack.count
      end
    end
  end

  -- Build item breakdown sorted by count descending, with intra-wagon percentage
  local itemBreakdown = {}
  for itemName, count in pairs(itemCounts) do
    table.insert(itemBreakdown, {
      name = itemName,
      count = count,
      percent = totalCount > 0 and math.floor((count / totalCount) * 100 + 0.5) or 0,
    })
  end
  table.sort(itemBreakdown, function(lhs, rhs) return lhs.count > rhs.count end)

  -- Extrapolate capacity to all slots (wagons typically carry one item type)
  local capacity = 0
  local fillPercent = 0
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

--- Collect fill data for all inventories of an actor (vehicle, platform, etc.).
-- @param actor any Actor-derived object
-- @return table - array of inventory fill data
local function collectActorInventories(actor)
  local result = {}
  local success, inventories = pcall(actor.getInventories, actor)
  if not success or not inventories then
    return result
  end
  for index, inventory in ipairs(inventories) do
    local fillData = getInventoryFill(inventory)
    fillData.index = index
    table.insert(result, fillData)
  end
  return result
end

--- Update persistent state for a train and detect trip transitions.
-- Tracks per-segment durations, round-trip durations, ETA, and slowdown counts.
-- @param trainName string
-- @param trainData table - current scan data (includes prevStationName, nextStationName, totalStops)
-- @return table { segment = {...}, roundTrip = {...}, slowdownCount }
local function updateTrainState(trainName, trainData)
  local now = computer.millis()

  if not trainStates[trainName] then
    trainStates[trainName] = {
      lastDockState = trainData.dockState,
      lastSpeed = trainData.speed,
      isSlowedDown = false,

      -- Per-segment tracking (keyed by "Station A -> Station B")
      segmentStartTime = nil,
      departureStation = nil,
      destinationStation = nil,
      segmentDurations = {},
      lastSegmentKey = nil,
      lastSegmentDuration = nil,

      -- Round-trip tracking (full timetable cycle)
      roundTripStartTime = nil,
      stopsVisitedThisRound = 0,
      roundTripDurations = {},
      lastRoundTripDuration = nil,

      -- Docked-time exclusion (ETAs only count travel time)
      dockStartTime = nil,
      segmentDockedTime = 0,
      roundTripDockedTime = 0,

      -- Slowdowns
      currentSlowdowns = 0,
      lastSegmentSlowdowns = 0,
    }
    -- If train is currently in transit, assume segment started now
    if trainData.isMoving and trainData.dockState == 0 then
      local state = trainStates[trainName]
      state.segmentStartTime = now
      state.departureStation = trainData.prevStationName
      state.destinationStation = trainData.nextStationName
      state.roundTripStartTime = now
    end
    -- Fall through to normal computation (no early return)
  end

  local state = trainStates[trainName]
  local prevDockState = state.lastDockState
  local currDockState = trainData.dockState

  -- Track docked time: start pause when entering dock
  if currDockState ~= 0 and not state.dockStartTime then
    state.dockStartTime = now
  end

  -- Track docked time: end pause when leaving dock
  if currDockState == 0 and state.dockStartTime then
    local dockedDuration = now - state.dockStartTime
    state.segmentDockedTime = state.segmentDockedTime + dockedDuration
    state.roundTripDockedTime = state.roundTripDockedTime + dockedDuration
    state.dockStartTime = nil
  end

  -- Transition: was in transit (dockState 0) -> now docking/docked (segment ended)
  if prevDockState == 0 and currDockState ~= 0 then
    -- Complete the segment (exclude docked time from duration)
    if state.segmentStartTime and state.departureStation and state.destinationStation then
      local segmentDuration = (now - state.segmentStartTime - state.segmentDockedTime) / 1000
      local segmentKey = state.departureStation .. " -> " .. state.destinationStation

      if not state.segmentDurations[segmentKey] then
        state.segmentDurations[segmentKey] = {}
      end
      local durations = state.segmentDurations[segmentKey]
      table.insert(durations, segmentDuration)
      if #durations > MAX_TRIP_HISTORY then
        table.remove(durations, 1)
      end

      state.lastSegmentKey = segmentKey
      state.lastSegmentDuration = segmentDuration
      state.lastSegmentSlowdowns = state.currentSlowdowns
    end

    -- Track stops visited for round-trip
    state.stopsVisitedThisRound = state.stopsVisitedThisRound + 1

    -- Check if round-trip is complete (visited all timetable stops)
    if state.stopsVisitedThisRound >= (trainData.totalStops or 0) and state.roundTripStartTime then
      local roundTripDuration = (now - state.roundTripStartTime - state.roundTripDockedTime) / 1000
      state.lastRoundTripDuration = roundTripDuration
      table.insert(state.roundTripDurations, roundTripDuration)
      if #state.roundTripDurations > MAX_TRIP_HISTORY then
        table.remove(state.roundTripDurations, 1)
      end
      state.roundTripStartTime = now
      state.stopsVisitedThisRound = 0
      state.roundTripDockedTime = 0
    end

    state.segmentStartTime = nil
    state.segmentDockedTime = 0
    state.currentSlowdowns = 0
    state.isSlowedDown = false
  end

  -- Transition: was docked/entering/leaving (any non-transit) -> now in transit (new segment started)
  if prevDockState ~= 0 and currDockState == 0 then
    state.segmentStartTime = now
    state.segmentDockedTime = 0
    state.departureStation = trainData.prevStationName
    state.destinationStation = trainData.nextStationName
    state.currentSlowdowns = 0
    state.isSlowedDown = false

    -- Start round-trip timer if not already running
    if not state.roundTripStartTime then
      state.roundTripStartTime = now
      state.stopsVisitedThisRound = 0
      state.roundTripDockedTime = 0
    end
  end

  -- Slowdown detection with hysteresis (only while in transit)
  if currDockState == 0 and trainData.isMoving and trainData.maxSpeed > 0 then
    local speedRatio = trainData.speed / trainData.maxSpeed
    if not state.isSlowedDown then
      -- Currently cruising: detect significant slowdown
      if speedRatio < SLOWDOWN_THRESHOLD then
        state.isSlowedDown = true
        state.currentSlowdowns = state.currentSlowdowns + 1
      end
    else
      -- Currently slowed: detect recovery to cruising speed
      if speedRatio >= CRUISE_THRESHOLD then
        state.isSlowedDown = false
      end
    end
  end

  state.lastDockState = currDockState
  state.lastSpeed = trainData.speed

  -- Build the active segment key
  local activeSegmentKey = nil
  if state.departureStation and state.destinationStation then
    activeSegmentKey = state.departureStation .. " -> " .. state.destinationStation
  end

  -- Compute per-segment average from history
  local segmentKey = activeSegmentKey or state.lastSegmentKey
  local segmentAvg = nil
  if segmentKey and state.segmentDurations[segmentKey] then
    local durations = state.segmentDurations[segmentKey]
    if #durations > 0 then
      local sum = 0
      for _, dur in ipairs(durations) do sum = sum + dur end
      segmentAvg = sum / #durations
    end
  end

  -- Segment ETA (only counts travel time, paused while docked)
  local segmentEta = nil
  if segmentAvg and state.segmentStartTime then
    local paused = state.segmentDockedTime
    if state.dockStartTime then
      paused = paused + (now - state.dockStartTime)
    end
    local elapsed = (now - state.segmentStartTime - paused) / 1000
    segmentEta = math.max(0, segmentAvg - elapsed)
  end

  -- Compute round-trip average
  local roundTripAvg = nil
  if #state.roundTripDurations > 0 then
    local sum = 0
    for _, dur in ipairs(state.roundTripDurations) do sum = sum + dur end
    roundTripAvg = sum / #state.roundTripDurations
  end

  -- Round-trip ETA (only counts travel time, paused while docked)
  local roundTripEta = nil
  if roundTripAvg and state.roundTripStartTime then
    local paused = state.roundTripDockedTime
    if state.dockStartTime then
      paused = paused + (now - state.dockStartTime)
    end
    local elapsed = (now - state.roundTripStartTime - paused) / 1000
    roundTripEta = math.max(0, roundTripAvg - elapsed)
  end

  local stopsRemaining = (trainData.totalStops or 0) - state.stopsVisitedThisRound

  -- Slowdown count: current segment if in transit, last segment if docked
  local slowdowns = state.currentSlowdowns
  if currDockState ~= 0 then
    slowdowns = state.lastSegmentSlowdowns
  end

  return {
    segment = {
      key = segmentKey,
      averageDuration = segmentAvg,
      lastDuration = state.lastSegmentDuration,
      eta = segmentEta,
    },
    roundTrip = {
      averageDuration = roundTripAvg,
      lastDuration = state.lastRoundTripDuration,
      eta = roundTripEta,
      stopsRemaining = stopsRemaining,
    },
    slowdownCount = slowdowns,
  }
end

--- Gather data for a single train.
-- @param train Trace<Train>
-- @param cargoPlatforms table - array of TrainPlatformCargo proxies
-- @return table with all train metrics
local function collectTrainData(train, cargoPlatforms)
  local trainId = tostring(train)
  local trainData = {
    trainId        = trainId,
    name           = train:getName(),
    isSelfDriving  = train.isSelfDriving,
    isPlayerDriven = train.isPlayerDriven,
    isDocked       = train.isDocked,
    dockState      = train.dockState,
    dockStateLabel = TrainMonitor.DOCK_STATE_LABELS[train.dockState] or ("Unknown:" .. tostring(train.dockState)),
    selfDrivingError      = train.selfDrivingError,
    selfDrivingErrorLabel = TrainMonitor.ERROR_LABELS[train.selfDrivingError] or ("Unknown:" .. tostring(train.selfDrivingError)),
    hasTimeTable   = train.hasTimeTable,
    vehicles       = {},
    vehicleCount   = 0,
    locomotiveCount = 0,
    freightCarCount = 0,
    totalMass      = 0,
    totalPayload   = 0,
    speed          = 0,
    maxSpeed       = 0,
    isMoving       = false,
    currentStop    = nil,
    totalStops     = 0,
    nextStationName = nil,
    prevStationName = nil,
    timetableStops  = {},
    wagonFills     = {},
    dockingDetails = nil,
    tripStats      = nil,
  }

  -- Vehicles analysis
  local vehicleList = train:getVehicles()
  trainData.vehicleCount = #vehicleList

  for vehicleIndex, vehicle in ipairs(vehicleList) do
    local movement = vehicle:getMovement()
    local vehicleInfo = {
      index       = vehicleIndex,
      length      = vehicle.length,
      isDocked    = vehicle.isDocked,
      isReversed  = vehicle.isReversed,
      mass        = movement.mass,
      tareMass    = movement.tareMass,
      payloadMass = movement.payloadMass,
      speed       = movement.speed,
      maxSpeed    = movement.maxSpeed,
      isMoving    = movement.isMoving,
    }

    table.insert(trainData.vehicles, vehicleInfo)

    trainData.totalMass = trainData.totalMass + movement.mass
    trainData.totalPayload = trainData.totalPayload + movement.payloadMass

    -- Use first vehicle's speed as representative
    if vehicleIndex == 1 then
      trainData.speed = math.abs(movement.speed)
      trainData.maxSpeed = movement.maxSpeed
      trainData.isMoving = movement.isMoving
    end

    -- Collect wagon inventory fill data
    local wagonInventories = collectActorInventories(vehicle)
    if #wagonInventories > 0 then
      table.insert(trainData.wagonFills, {
        vehicleIndex = vehicleIndex,
        inventories = wagonInventories,
      })
    end
  end

  -- Refine dock state label: "In Transit" when moving on track
  if trainData.dockState == 0 and trainData.isMoving then
    trainData.dockStateLabel = "In Transit"
  end

  -- Timetable analysis: collect all stop names for segment tracking
  if trainData.hasTimeTable then
    local timeTable = train:getTimeTable()
    if timeTable then
      trainData.totalStops = timeTable.numStops
      trainData.currentStop = timeTable:getCurrentStop()

      -- Collect all timetable stop names
      for stopIndex = 0, trainData.totalStops - 1 do
        local success, stopData = pcall(timeTable.getStop, timeTable, stopIndex)
        if success and stopData and stopData.station then
          local nameSuccess, name = pcall(function() return stopData.station.name end)
          trainData.timetableStops[stopIndex] = nameSuccess and name or ("Stop#" .. stopIndex)
        else
          trainData.timetableStops[stopIndex] = "Stop#" .. stopIndex
        end
      end

      -- Next station = where the train is heading
      trainData.nextStationName = trainData.timetableStops[trainData.currentStop]

      -- Previous station = where the train departed from
      if trainData.totalStops > 0 then
        local prevIndex = (trainData.currentStop - 1 + trainData.totalStops) % trainData.totalStops
        trainData.prevStationName = trainData.timetableStops[prevIndex]
      end
    end
  end

  -- Docking details: when train is docked, find associated cargo platforms
  if trainData.isDocked and cargoPlatforms and #cargoPlatforms > 0 then
    local dockingPlatforms = {}
    for _, platform in ipairs(cargoPlatforms) do
      local dockSuccess, dockedVehicle = pcall(platform.getDockedVehicle, platform)
      if dockSuccess and dockedVehicle then
        -- Match via unique train ID (proxy identity, not name)
        local matchSuccess, matchResult = pcall(function()
          return tostring(dockedVehicle:getTrain()) == trainId
        end)
        if matchSuccess and matchResult then
          local platformInfo = {
            isLoading    = platform.isLoading,
            isUnloading  = platform.isUnloading,
            inputFlow    = platform.inputFlow,
            outputFlow   = platform.outputFlow,
            fullLoad     = platform.fullLoad,
            fullUnload   = platform.fullUnload,
            isInLoadMode = platform.isInLoadMode,
            inventories  = collectActorInventories(platform),
          }
          table.insert(dockingPlatforms, platformInfo)
        end
      end
    end
    if #dockingPlatforms > 0 then
      trainData.dockingDetails = { platforms = dockingPlatforms }
    end
  end

  -- Trip statistics: only track and expose for self-driving trains.
  -- Reset state when not self-driving so no stale data persists,
  -- but a fresh state will be created if the train becomes self-driving again.
  if trainData.isSelfDriving then
    trainData.tripStats = updateTrainState(trainId, trainData)
  else
    trainStates[trainId] = nil
  end

  return trainData
end

--- Compute global aggregated statistics from all train data.
-- @param allTrainData table - array of train data tables
-- @return table with global stats
local function computeGlobalStats(allTrainData)
  local stats = {
    totalTrains       = #allTrainData,
    trainsMoving      = 0,
    trainsDocked      = 0,
    trainsIdle        = 0,
    trainsSelfDriving = 0,
    trainsWithErrors  = 0,
    totalVehicles     = 0,
    totalMass         = 0,
    totalPayload      = 0,
    averageSpeed        = 0,
    maxSpeedObserved    = 0,
    selfDrivingSpeedSum = 0,
    selfDrivingCount    = 0,
    movingSpeedSum      = 0,
    movingTrainCount    = 0,
    averageMovingSpeed  = 0,
  }

  for _, trainData in ipairs(allTrainData) do
    stats.totalVehicles = stats.totalVehicles + trainData.vehicleCount
    stats.totalMass = stats.totalMass + trainData.totalMass
    stats.totalPayload = stats.totalPayload + trainData.totalPayload

    if trainData.speed > stats.maxSpeedObserved then
      stats.maxSpeedObserved = trainData.speed
    end

    if trainData.isMoving then
      stats.trainsMoving = stats.trainsMoving + 1
      stats.movingSpeedSum = stats.movingSpeedSum + trainData.speed
      stats.movingTrainCount = stats.movingTrainCount + 1
    end

    if trainData.isDocked then
      stats.trainsDocked = stats.trainsDocked + 1
    end

    if not trainData.isMoving and not trainData.isDocked then
      stats.trainsIdle = stats.trainsIdle + 1
    end

    if trainData.isSelfDriving then
      stats.trainsSelfDriving = stats.trainsSelfDriving + 1
      stats.selfDrivingSpeedSum = stats.selfDrivingSpeedSum + trainData.speed
      stats.selfDrivingCount = stats.selfDrivingCount + 1
    end

    if trainData.selfDrivingError ~= 0 then
      stats.trainsWithErrors = stats.trainsWithErrors + 1
    end
  end

  -- Average speed only for self-driving trains
  if stats.selfDrivingCount > 0 then
    stats.averageSpeed = stats.selfDrivingSpeedSum / stats.selfDrivingCount
  end
  if stats.movingTrainCount > 0 then
    stats.averageMovingSpeed = stats.movingSpeedSum / stats.movingTrainCount
  end

  return stats
end

--- Perform a full scan of the railroad network.
-- @param stationId string - UUID of any RailroadStation on the network
-- @return table { trains = { ... }, globalStats = { ... } } or nil on error
function TrainMonitor.scan(stationId, cargoPlatforms)
  local station = component.proxy(stationId)
  if not station then
    print("[TRAIN_MON] Station not found: " .. tostring(stationId))
    return nil
  end

  local trackGraph = station:getTrackGraph()
  if not trackGraph then
    print("[TRAIN_MON] Failed to get TrackGraph from station")
    return nil
  end

  local trains = trackGraph:getTrains()
  if not trains then
    print("[TRAIN_MON] Failed to get trains from TrackGraph")
    return nil
  end

  local allTrainData = {}
  for _, train in ipairs(trains) do
    local success, trainData = pcall(collectTrainData, train, cargoPlatforms or {})
    if success then
      table.insert(allTrainData, trainData)
    else
      print("[TRAIN_MON] Error collecting data for a train: " .. tostring(trainData))
    end
  end

  local globalStats = computeGlobalStats(allTrainData)

  return {
    trains = allTrainData,
    globalStats = globalStats,
  }
end

--- Format a speed value to km/h for display.
-- @param speed number - raw speed value from the API
-- @return string formatted speed
function TrainMonitor.formatSpeed(speed)
  -- FicsIt-Networks speed is in cm/s, convert to km/h
  local kmh = math.abs(speed) * 0.036
  return string.format("%.1f km/h", kmh)
end

--- Format a mass value for display.
-- @param mass number - raw mass value (kg)
-- @return string formatted mass
function TrainMonitor.formatMass(mass)
  if mass >= 1000 then
    return string.format("%.1f t", mass / 1000)
  end
  return string.format("%.0f kg", mass)
end

--- Format a time duration for display.
-- @param seconds number - duration in seconds
-- @return string formatted duration
function TrainMonitor.formatDuration(seconds)
  if not seconds then return "--" end
  seconds = math.floor(seconds)
  if seconds >= 3600 then
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    return string.format("%dh %02dm", hours, minutes)
  elseif seconds >= 60 then
    local minutes = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%dm %02ds", minutes, secs)
  end
  return string.format("%ds", seconds)
end

--- Print a full report to the console.
-- @param scanResult table - result from TrainMonitor.scan()
function TrainMonitor.printReport(scanResult)
  if not scanResult then
    print("[TRAIN_MON] No scan data available")
    return
  end

  local stats = scanResult.globalStats
  print("========== RAILROAD NETWORK REPORT ==========")
  print("Total trains:        " .. stats.totalTrains)
  print("  Moving:            " .. stats.trainsMoving)
  print("  Docked:            " .. stats.trainsDocked)
  print("  Idle:              " .. stats.trainsIdle)
  print("  Self-driving:      " .. stats.trainsSelfDriving)
  print("  With errors:       " .. stats.trainsWithErrors)
  print("Total vehicles:      " .. stats.totalVehicles)
  print("Total payload:       " .. TrainMonitor.formatMass(stats.totalPayload))
  print("Total mass:          " .. TrainMonitor.formatMass(stats.totalMass))
  print("Avg speed (auto):    " .. TrainMonitor.formatSpeed(stats.averageSpeed))
  print("Avg speed (moving):  " .. TrainMonitor.formatSpeed(stats.averageMovingSpeed))
  print("Max speed observed:  " .. TrainMonitor.formatSpeed(stats.maxSpeedObserved))
  print("=============================================")

  for index, trainData in ipairs(scanResult.trains) do
    print("--- Train #" .. index .. ": " .. trainData.name .. " ---")
    print("  State:     " .. trainData.dockStateLabel)
    print("  Speed:     " .. TrainMonitor.formatSpeed(trainData.speed))
    print("  Vehicles:  " .. trainData.vehicleCount)
    print("  Payload:   " .. TrainMonitor.formatMass(trainData.totalPayload))
    print("  Mass:      " .. TrainMonitor.formatMass(trainData.totalMass))
    print("  Self-drv:  " .. tostring(trainData.isSelfDriving))
    if trainData.selfDrivingError ~= 0 then
      print("  ERROR:     " .. trainData.selfDrivingErrorLabel)
    end
    if trainData.nextStationName then
      print("  Next stop: " .. trainData.nextStationName .. " (" .. trainData.currentStop .. "/" .. trainData.totalStops .. ")")
    end

    -- Trip statistics (per-segment)
    if trainData.tripStats then
      local trip = trainData.tripStats
      if trip.segment.key then
        print("  Segment:    " .. trip.segment.key)
      end
      if trip.segment.lastDuration then
        print("  Seg last:   " .. TrainMonitor.formatDuration(trip.segment.lastDuration))
      end
      if trip.segment.averageDuration then
        print("  Seg avg:    " .. TrainMonitor.formatDuration(trip.segment.averageDuration))
      end
      if trip.segment.eta then
        print("  Seg ETA:    " .. TrainMonitor.formatDuration(trip.segment.eta))
      end
      -- Round-trip statistics (full timetable)
      if trip.roundTrip.lastDuration then
        print("  Route last: " .. TrainMonitor.formatDuration(trip.roundTrip.lastDuration))
      end
      if trip.roundTrip.averageDuration then
        print("  Route avg:  " .. TrainMonitor.formatDuration(trip.roundTrip.averageDuration))
      end
      if trip.roundTrip.eta then
        print("  Route ETA:  " .. TrainMonitor.formatDuration(trip.roundTrip.eta)
          .. " (" .. trip.roundTrip.stopsRemaining .. " stops left)")
      end
      print("  Slowdowns:  " .. trip.slowdownCount)
    end

    -- Wagon fill percentages
    if trainData.wagonFills and #trainData.wagonFills > 0 then
      for _, wagonFill in ipairs(trainData.wagonFills) do
        for _, inv in ipairs(wagonFill.inventories) do
          print("  Wagon #" .. wagonFill.vehicleIndex .. ": "
            .. inv.fillPercent .. "% (" .. inv.itemCount .. "/" .. inv.capacity
            .. " items, " .. inv.slotsUsed .. "/" .. inv.totalSlots .. " slots)")
        end
      end
    end

    -- Docking details (transfer rates, platform buffer fill)
    if trainData.dockingDetails then
      print("  -- Docking --")
      for platformIndex, platform in ipairs(trainData.dockingDetails.platforms) do
        local mode = platform.isLoading and "LOADING" or (platform.isUnloading and "UNLOADING" or "IDLE")
        local flow = platform.isLoading and platform.inputFlow or platform.outputFlow
        print("  Platform #" .. platformIndex .. ": " .. mode
          .. " | Flow: " .. string.format("%.1f", flow) .. "/min")
        if platform.fullLoad then print("    Wagon fully loaded") end
        if platform.fullUnload then print("    Wagon fully unloaded") end
        for _, inv in ipairs(platform.inventories) do
          print("    Buffer: " .. inv.fillPercent .. "% ("
            .. inv.itemCount .. "/" .. inv.capacity .. " items)")
        end
      end
    end
  end
end

return TrainMonitor