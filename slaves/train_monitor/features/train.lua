-- features/train.lua
-- Railroad network monitoring feature.
-- Scans the rail network periodically and outputs to screen (preferred) or console (fallback).

local trainMonitor = filesystem.doFile(DRIVE_PATH .. "/modules/train_monitor.lua")
local trainDisplay = filesystem.doFile(DRIVE_PATH .. "/modules/train_display.lua")

-- Register config schema
-- outputMode: "auto" (best available), "screen" (force specific screen), "console" (logs only)
CONFIG_MANAGER.register("train", {
  { key = "stationId",      label = "Station UUID",           type = "string" },
  { key = "scanInterval",   label = "Scan interval (sec)",    type = "number",  default = 30 },
  { key = "outputMode",     label = "Output (auto/screen/console)", type = "string", default = "auto" },
  { key = "screenId",       label = "Screen UUID (if mode=screen)", type = "string" },
  { key = "broadcastResults", label = "Broadcast via network", type = "boolean", default = false },
})

-- Register network component categories needed by this feature
REGISTRY.registerNetworkCategory("stations", "RailroadStation")
REGISTRY.registerNetworkCategory("cargoPlatforms", "TrainPlatformCargo")

-- Read config
local trainConfig = CONFIG_MANAGER.getSection("train")

-- Resolve station: config UUID > first auto-discovered station (resolved after discoverNetwork)
local function resolveStation()
  local configStationId = trainConfig.stationId
  if configStationId and configStationId ~= "" then
    return configStationId
  end
  local firstStation = REGISTRY.getFirst("stations")
  if firstStation then
    print("[TRAIN] Auto-discovered station: " .. tostring(firstStation.id))
    return firstStation.id
  end
  return nil
end

-- Resolve display output based on outputMode
local outputMode = trainConfig.outputMode or "auto"
local displayReady = false

if outputMode == "console" then
  print("[TRAIN] Output mode: console (forced)")

elseif outputMode == "screen" then
  -- Use a specifically configured screen UUID
  if trainConfig.screenId and trainConfig.screenId ~= "" then
    local targetScreen = component.proxy(trainConfig.screenId)
    if targetScreen then
      -- Need a spare GPU to drive this screen (prefer T2, fallback T1)
      local spareGpu = REGISTRY.pci.gpuT2[1] or REGISTRY.pci.gpuT1[1]
      if spareGpu then
        displayReady = trainDisplay.init(spareGpu, targetScreen)
      else
        print("[TRAIN] No spare GPU available to drive screen " .. trainConfig.screenId)
      end
    else
      print("[TRAIN] Screen not found: " .. trainConfig.screenId)
    end
  else
    print("[TRAIN] outputMode=screen but no Screen UUID configured")
  end

elseif outputMode == "auto" then
  -- Auto: try spare PCI GPU + spare PCI/network screen
  local autoGpu, autoScreen, autoGpuType = REGISTRY.getAvailableDisplay()
  if autoGpu and autoScreen then
    displayReady = trainDisplay.init(autoGpu, autoScreen)
    print("[TRAIN] Auto-selected display (GPU " .. autoGpuType .. ")")
  else
    local hasGpu = REGISTRY.pci.gpuT2[1] or REGISTRY.pci.gpuT1[1]
    if not hasGpu then
      print("[TRAIN] No spare GPU available - falling back to console")
    else
      print("[TRAIN] No spare screen available - falling back to console")
    end
  end
end

-- Network broadcasting: build a compact payload from scan results
local broadcastEnabled = trainConfig.broadcastResults == true

--- Build a lightweight summary suitable for network transmission.
-- Strips heavy/redundant fields to keep the serialized string small.
-- @param scanResult table - full scan result from trainMonitor.scan()
-- @return table - compact payload
local function buildNetworkPayload(scanResult)
  -- Pre-filter: only self-driving trains
  local selfDrivingList = {}
  for _, td in ipairs(scanResult.trains) do
    if td.isSelfDriving then table.insert(selfDrivingList, td) end
  end

  local trainSummaries = {}
  for _, td in ipairs(selfDrivingList) do
    -- Per-wagon fill percentages
    local wagonPcts = {}
    for _, wf in ipairs(td.wagonFills or {}) do
      for _, inv in ipairs(wf.inventories or {}) do
        table.insert(wagonPcts, math.floor(inv.fillPercent + 0.5))
      end
    end

    local summary = {
      name           = td.name,
      speed          = math.floor(td.speed * 10 + 0.5) / 10,
      maxSpeed       = td.maxSpeed,
      isMoving       = td.isMoving,
      isSelfDriving  = td.isSelfDriving,
      dockState      = td.dockState,
      dockStateLabel = td.dockStateLabel,
      vehicleCount   = td.vehicleCount,
      nextStation    = td.nextStationName,
      prevStation    = td.prevStationName,
      currentStop    = td.currentStop,
      totalStops     = td.totalStops,
      wagonFillPcts  = wagonPcts,
      error          = td.selfDrivingError ~= 0 and td.selfDrivingErrorLabel or nil,
    }

    -- Include trip stats if available (self-driving trains)
    if td.tripStats then
      summary.segmentEta   = td.tripStats.segment.eta
      summary.segmentAvg   = td.tripStats.segment.averageDuration
      summary.roundTripEta = td.tripStats.roundTrip.eta
      summary.roundTripAvg = td.tripStats.roundTrip.averageDuration
      summary.slowdowns    = td.tripStats.slowdownCount
    end

    table.insert(trainSummaries, summary)
  end

  return {
    globalStats = scanResult.globalStats,
    trains      = trainSummaries,
  }
end

-- Periodic scan function
local scanInterval = trainConfig.scanInterval or 30
local stationId = nil

local function performScan()
  -- Lazy-resolve station (network discovery may happen after feature loading)
  if not stationId then
    stationId = resolveStation()
    if not stationId then
      return -- Still no station, skip this tick
    end
  end

  local scanResult = trainMonitor.scan(stationId, REGISTRY.getCategory("cargoPlatforms"))
  if scanResult then
    if displayReady then
      trainDisplay.render(scanResult)
    else
      trainMonitor.printReport(scanResult)
    end

    -- Broadcast compact results over the network bus
    if broadcastEnabled and NETWORK_BUS then
      local payload = buildNetworkPayload(scanResult)
      NETWORK_BUS.publish("train_states", payload)
    end
  end
end


-- Register periodic scan as a managed async task (auto-restarts after game reload)
TASK_MANAGER.register("train_scan", {
  interval = scanInterval,
  factory = function()
    return async(function()
      while true do
        TASK_MANAGER.heartbeat("train_scan")
        performScan()
        sleep(scanInterval)
      end
    end)
  end,
})

local modeStr = displayReady and "screen" or "console"
if broadcastEnabled then
  modeStr = modeStr .. "+network"
end
print("[TRAIN] Monitoring active - scanning every " .. scanInterval .. "s (" .. modeStr .. ")")