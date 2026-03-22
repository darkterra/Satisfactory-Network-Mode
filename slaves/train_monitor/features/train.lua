-- features/train.lua
-- Railroad network monitoring and control feature.
-- Scans the rail network periodically, renders to screen or console,
-- and provides control capabilities (timetable, autopilot, forced routing).
-- Integrates with rail_controller slaves for signal/switch data.

local trainMonitor = filesystem.doFile(DRIVE_PATH .. "/modules/train_monitor.lua")
local trainDisplay = filesystem.doFile(DRIVE_PATH .. "/modules/train_display.lua")
local trainController = filesystem.doFile(DRIVE_PATH .. "/modules/train_controller.lua")

-- Optionally load GPU T2 map display
local trainMap = nil
local mapLoaded, mapModule = pcall(filesystem.doFile, DRIVE_PATH .. "/modules/train_map.lua")
if mapLoaded then trainMap = mapModule end

-- Render dirty flag — set by data changes, cleared after render
local renderDirty = true

-- ============================================================================
-- Configuration
-- ============================================================================

CONFIG_MANAGER.register("train", {
  { key = "stationId",        label = "Station UUID",                  type = "string" },
  { key = "scanInterval",     label = "Scan interval (sec)",           type = "number",  default = 30 },
  { key = "outputMode",       label = "Output (auto/screen/console)",  type = "string",  default = "auto" },
  { key = "displayGpuType",   label = "Display GPU type (T1/T2)",      type = "string",  default = "T1" },
  { key = "screenId",         label = "Screen UUID (if mode=screen)",  type = "string" },
  { key = "mapScreenId",      label = "Map screen UUID (GPU T2)",      type = "string" },
  { key = "mapWidth",         label = "Map resolution width (px)",     type = "number",  default = 2700 },
  { key = "mapHeight",        label = "Map resolution height (px)",    type = "number",  default = 2400 },
  { key = "broadcastResults", label = "Broadcast via network",         type = "boolean", default = false },
  { key = "enableControl",    label = "Enable train control",          type = "boolean", default = true },
})

-- Network component categories
REGISTRY.registerNetworkCategory("stations", "RailroadStation")
REGISTRY.registerNetworkCategory("cargoPlatforms", "TrainPlatformCargo")

local trainConfig = CONFIG_MANAGER.getSection("train")

-- ============================================================================
-- Station resolution
-- ============================================================================

local function resolveStation()
  local configStationId = trainConfig.stationId
  if configStationId and configStationId ~= "" then return configStationId end
  local first = REGISTRY.getFirst("stations")
  if first then
    print("[TRAIN] Auto-discovered station: " .. tostring(first.id))
    return first.id
  end
  return nil
end

-- ============================================================================
-- Display resolution
-- ============================================================================

local outputMode = trainConfig.outputMode or "auto"
local displayGpuType = trainConfig.displayGpuType or "T1"
local displayReady = false
local mapReady = false

-- Main display
if outputMode == "console" then
  print("[TRAIN] Output mode: console")
elseif outputMode == "screen" then
  if trainConfig.screenId and trainConfig.screenId ~= "" then
    local autoGpu, autoScreen, autoGpuType = REGISTRY.getAvailableDisplay(displayGpuType, trainConfig.screenId)
    if autoGpu and autoScreen then
      displayReady = trainDisplay.init(autoGpu, autoScreen, {
        gpuType = autoGpuType,
        controller = trainController,
      })
    else
      print("[TRAIN] No GPU " .. displayGpuType .. " or screen for screenId " .. trainConfig.screenId)
    end
  else
    print("[TRAIN] outputMode=screen but no screenId")
  end
elseif outputMode == "auto" then
  local autoGpu, autoScreen, autoGpuType = REGISTRY.getAvailableDisplay(displayGpuType)
  if autoGpu and autoScreen then
    displayReady = trainDisplay.init(autoGpu, autoScreen, {
      gpuType = autoGpuType,
      controller = trainController,
    })
    print("[TRAIN] Auto-display (GPU " .. autoGpuType .. ")")
  else
    print("[TRAIN] No display available - console fallback")
  end
end

-- Map display (GPU T2) - separate screen
if trainMap and trainConfig.mapScreenId and trainConfig.mapScreenId ~= "" then
  local mapGpu, mapScreen, _ = REGISTRY.getAvailableDisplay("T2", trainConfig.mapScreenId)
  if mapGpu and mapScreen then
    mapReady = trainMap.init(mapGpu, mapScreen, {
      screenWidth = trainConfig.mapWidth or 1920,
      screenHeight = trainConfig.mapHeight or 1080,
      drivePath = DRIVE_PATH,
    })
    print("[TRAIN] Map display initialized (GPU T2, " .. (trainConfig.mapWidth or 1920) .. "x" .. (trainConfig.mapHeight or 1080) .. ")")
  else
    print("[TRAIN] No GPU T2 or screen for map")
  end
end

-- ============================================================================
-- Controller initialization
-- ============================================================================

local controlEnabled = trainConfig.enableControl ~= false
if controlEnabled then
  trainController.init({ networkBus = NETWORK_BUS })
  if mapReady and trainMap.setController then
    trainMap.setController(trainController)
  end
  print("[TRAIN] Control mode enabled")
end

-- ============================================================================
-- Rail controller data aggregation
-- Receives rail_states from remote rail_controller slaves
-- ============================================================================

local railStates = {}

if NETWORK_BUS then
  NETWORK_BUS.registerChannel("rail_states")
  NETWORK_BUS.subscribe("rail_states", function(senderCardId, senderIdentity, data)
    if not data then
      return
    end
    
    local key = data.identity or senderIdentity or senderCardId
    if key then
      local existing = railStates[key] or {}
      existing.lastUpdate = computer.millis()
      existing.signals = data.signals or {}
      existing.switches = data.switches or {}
      if data.tracks then
        existing.tracks = data.tracks
      elseif not existing.tracks then
        existing.tracks = {}
      end
      railStates[key] = existing
      renderDirty = true
    end
  end)
end

-- ============================================================================
-- Network broadcasting
-- ============================================================================

local broadcastEnabled = trainConfig.broadcastResults == true

local function buildNetworkPayload(scanResult)
  local selfDriving = {}
  for _, td in ipairs(scanResult.trains) do
    if td.isSelfDriving then table.insert(selfDriving, td) end
  end

  local trainSummaries = {}
  for _, td in ipairs(selfDriving) do
    local wagonPcts = {}
    for _, wf in ipairs(td.wagonFills or {}) do
      for _, inv in ipairs(wf.inventories or {}) do
        table.insert(wagonPcts, math.floor(inv.fillPercent + 0.5))
      end
    end

    local summary = {
      name = td.name,
      speed = math.floor(td.speed * 10 + 0.5) / 10,
      maxSpeed = td.maxSpeed,
      isMoving = td.isMoving,
      isSelfDriving = td.isSelfDriving,
      dockState = td.dockState,
      dockStateLabel = td.dockStateLabel,
      vehicleCount = td.vehicleCount,
      nextStation = td.nextStationName,
      prevStation = td.prevStationName,
      currentStop = td.currentStop,
      totalStops = td.totalStops,
      wagonFillPcts = wagonPcts,
      error = td.selfDrivingError ~= 0 and td.selfDrivingErrorLabel or nil,
    }

    if td.tripStats then
      summary.segmentEta = td.tripStats.segment.eta
      summary.segmentAvg = td.tripStats.segment.averageDuration
      summary.roundTripEta = td.tripStats.roundTrip.eta
      summary.roundTripAvg = td.tripStats.roundTrip.averageDuration
      summary.slowdowns = td.tripStats.slowdownCount
    end

    table.insert(trainSummaries, summary)
  end

  return {
    globalStats = scanResult.globalStats,
    trains = trainSummaries,
  }
end

-- Station summary for network broadcast
local function buildStationPayload(scanResult)
  if not scanResult.stations then return nil end
  local result = {}
  for _, st in ipairs(scanResult.stations) do
    local plats = {}
    for _, p in ipairs(st.platforms or {}) do
      if p.isCargo then
        table.insert(plats, {
          isInLoadMode = p.isInLoadMode,
          inputFlow = p.inputFlow,
          outputFlow = p.outputFlow,
        })
      end
    end
    table.insert(result, {
      name = st.name,
      platforms = plats,
    })
  end
  return result
end

-- ============================================================================
-- Network bus commands
-- ============================================================================

if NETWORK_BUS then
  NETWORK_BUS.registerChannel("train_commands")
  NETWORK_BUS.registerChannel("train_states")
  NETWORK_BUS.registerChannel("train_status")
  NETWORK_BUS.registerChannel("train_stations")
  NETWORK_BUS.registerChannel("rail_commands")

  local lastScanForCmds = nil

  NETWORK_BUS.subscribe("train_commands", function(senderCardId, senderIdentity, cmd)
    if not cmd then return end
    local myIdentity = CONFIG_MANAGER.get("slave", "identity") or ""
    if cmd.targetIdentity and cmd.targetIdentity ~= myIdentity then return end

    if cmd.action == "rescan" then
      print("[TRAIN] Remote rescan requested by " .. tostring(senderIdentity))
    elseif controlEnabled then
      trainController.handleCommand(cmd, lastScanForCmds)
    end
  end)

  -- Store latest scan for command handling
  local origPerformScan = nil
  -- Will be set after performScan is defined
end

-- ============================================================================
-- Periodic scan
-- ============================================================================

local scanInterval = trainConfig.scanInterval or 30
local stationId = nil
local lastScanResult = nil

--- Collect fresh data from the game engine (heavy: TrackGraph queries, proxy calls).
local function performScan()
  if not stationId then
    stationId = resolveStation()
    if not stationId then
      print("[TRAIN] No station found - please configure stationId or ensure a station is registered")
      return
    end
  end

  local scanResult = trainMonitor.scan(stationId, REGISTRY.getCategory("cargoPlatforms"))
  if not scanResult then
    print("[TRAIN] Scan failed - no data returned")
    return
  end

  lastScanResult = scanResult
  renderDirty = true

  if controlEnabled and scanResult.rawTrainProxies then
    trainController.updateProxyCache(scanResult.rawTrainProxies)
  end

  scanResult.railStates = railStates

  trainMonitor.tagDeadEndStations(scanResult.stations, railStates)

  if controlEnabled and trainMap then
    local flags = trainMap.getTrainFlags()
    if flags and next(flags) then
      trainController.enforceFlags(scanResult, flags)
    end
  end

  if broadcastEnabled and NETWORK_BUS then
    local payload = buildNetworkPayload(scanResult)
    NETWORK_BUS.publish("train_states", payload)
    local stationPayload = buildStationPayload(scanResult)
    if stationPayload then
      NETWORK_BUS.publish("train_stations", stationPayload)
    end
  end
end

--- Render displays using the latest scan data (skips if nothing changed).
local function performRender(force)
  if not lastScanResult then return end
  if not force and not renderDirty then return end
  renderDirty = false
  lastScanResult.railStates = railStates

  if displayReady then
    trainDisplay.render(lastScanResult)
  else
    trainMonitor.printReport(lastScanResult)
  end

  if mapReady and trainMap then
    trainMap.render(lastScanResult)
  end
end

--- Mark display as needing refresh (called from click handlers, rail_state updates, etc.)
local function markDirty()
  renderDirty = true
end

-- Expose markDirty so train_map.immediateRefresh can trigger it
if trainMap then
  trainMap.markDirty = markDirty
end

-- ============================================================================
-- Task registration
-- ============================================================================

local RENDER_POLL_INTERVAL = 0.5
local scanIntervalMs = scanInterval * 1000

TASK_MANAGER.register("train_monitor", {
  interval = 120,
  factory = function()
    return async(function()
      if NETWORK_BUS then
        NETWORK_BUS.publish("rail_commands", { action = "request_topology" })
      end

      local nextScanAt = 0
      while true do
        TASK_MANAGER.heartbeat("train_monitor")
        local now = computer.millis()

        if now >= nextScanAt then
          local sOk, sErr = pcall(performScan)
          if not sOk then print("[TRAIN] Scan error: " .. tostring(sErr)) end
          local rOk, rErr = pcall(performRender, true)
          if not rOk then print("[TRAIN] Render error: " .. tostring(rErr)) end
          nextScanAt = computer.millis() + scanIntervalMs
        elseif renderDirty then
          local rOk, rErr = pcall(performRender)
          if not rOk then print("[TRAIN] Render error: " .. tostring(rErr)) end
        end

        sleep(RENDER_POLL_INTERVAL)
      end
    end)
  end,
})

local modeStr = displayReady and "screen" or "console"
if mapReady then modeStr = modeStr .. "+map" end
if broadcastEnabled then modeStr = modeStr .. "+network" end
if controlEnabled then modeStr = modeStr .. "+control" end
print("[TRAIN] Monitoring active - every " .. scanInterval .. "s (" .. modeStr .. ")")