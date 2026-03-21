-- modules/train_display.lua
-- Renders train monitoring data on a GPU T1 or GPU T2 screen.
--
-- GPU compatibility:
--   GPU T1 uses character-mode: setText, fill, setForeground, setBackground, setSize
--   GPU T2 uses vector-mode: drawText, drawRect, drawLines (no setSize/setText/fill)
--   A wrapper layer auto-detects the GPU type and emulates the T1 character API
--   on T2 using drawText (monospace) + drawRect, so all rendering code stays uniform.
--
-- Display modes (cycled via footer click):
--   "table"    - Tabular list of all trains with status, speed, fill, trip stats
--   "stations" - Station-centric view with platforms, flow, load/unload
--   "timetable"- Timetable editor: set stops, rename trains, toggle autopilot
--
-- Console fallback for headless operation.

local TrainDisplay = {}

-- Forward declaration for click handler
local handleClick

-- Screen dimensions (logical character grid)
local W = 150
local H = 75

-- GPU type flag (set explicitly at init by caller)
local isGpuT1 = true

-- T2 character emulation parameters (pixels per character cell)
local CHAR_W = 9
local CHAR_H = 14
local FONT_SIZE = 12

-- ============================================================================
-- GPU Wrapper: provides a uniform T1-style API regardless of GPU type.
-- On T1: thin passthrough (no wrapping needed).
-- On T2: emulates setText/fill/setForeground/setBackground using drawText/drawRect.
-- The GPU type is provided explicitly by the caller to avoid probing missing
-- properties (which triggers deprecation warnings on FicsIt-Networks objects).
-- ============================================================================

local function createT2Wrapper(rawGpu)
  local wrapper = {}
  local fgColor = { r = 1.0, g = 1.0, b = 1.0, a = 1.0 }
  local bgColor = { r = 0.05, g = 0.05, b = 0.1, a = 1.0 }

  -- Passthrough methods
  function wrapper:bindScreen(screen)   return rawGpu:bindScreen(screen) end
  function wrapper:flush()              return rawGpu:flush() end
  function wrapper:getScreen()          return rawGpu:getScreen() end

  -- setSize: no-op on T2 (character grid is virtual)
  function wrapper:setSize(w, h) end

  -- getSize: return the virtual character grid dimensions
  function wrapper:getSize() return W, H end

  -- setForeground: store color for next draw calls
  function wrapper:setForeground(r, g, b, a)
    fgColor = { r = r, g = g, b = b, a = a or 1.0 }
  end

  -- setBackground: store color for next draw calls
  function wrapper:setBackground(r, g, b, a)
    bgColor = { r = r, g = g, b = b, a = a or 1.0 }
  end

  -- setText: draw text at character position using drawText with monospace
  function wrapper:setText(x, y, str)
    if not str or str == "" then return end
    local px = x * CHAR_W
    local py = y * CHAR_H
    rawGpu:drawText({ x = px, y = py }, str, FONT_SIZE, fgColor, true)
  end

  -- fill: draw a filled rectangle at character position
  function wrapper:fill(x, y, dx, dy, str)
    local px = x * CHAR_W
    local py = y * CHAR_H
    local pw = dx * CHAR_W
    local ph = dy * CHAR_H

    -- Draw background rectangle
    rawGpu:drawRect({ x = px, y = py }, { x = pw, y = ph }, bgColor, "", 0)

    -- If a fill character is provided, tile it as text
    if str and str ~= " " and str ~= "" then
      local fillChar = str:sub(1, 1)
      local line = string.rep(fillChar, dx)
      for row = 0, dy - 1 do
        rawGpu:drawText(
          { x = px, y = py + row * CHAR_H },
          line, FONT_SIZE, fgColor, true
        )
      end
    end
  end

  return wrapper
end

-- Helper: convert T2 mouse pixel coords to T1 character coords
local function pixelToChar(px, py)
  return math.floor(px / CHAR_W), math.floor(py / CHAR_H)
end

-- Color palette
local COLORS = {
  bg          = { 0.05, 0.05, 0.1, 1.0 },
  title       = { 0.2, 0.7, 1.0, 1.0 },
  text        = { 1.0, 1.0, 1.0, 1.0 },
  label       = { 0.6, 0.6, 0.6, 1.0 },
  dim         = { 0.4, 0.4, 0.4, 1.0 },
  separator   = { 0.3, 0.3, 0.4, 1.0 },
  trainName   = { 0.4, 0.8, 1.0, 1.0 },
  moving      = { 0.3, 1.0, 0.4, 1.0 },
  docked      = { 1.0, 0.8, 0.2, 1.0 },
  idle        = { 0.5, 0.5, 0.5, 1.0 },
  error       = { 1.0, 0.3, 0.3, 1.0 },
  good        = { 0.3, 1.0, 0.4, 1.0 },
  warning     = { 1.0, 0.8, 0.2, 1.0 },
  fillEmpty   = { 0.3, 0.3, 0.3, 1.0 },
  fillLow     = { 1.0, 0.3, 0.3, 1.0 },
  fillMid     = { 1.0, 0.8, 0.2, 1.0 },
  fillHigh    = { 0.3, 1.0, 0.4, 1.0 },
  fillFull    = { 0.2, 0.7, 1.0, 1.0 },
  tripLabel   = { 0.7, 0.5, 1.0, 1.0 },
  eta         = { 1.0, 0.6, 0.2, 1.0 },
  flow        = { 0.2, 1.0, 0.8, 1.0 },
  platform    = { 0.8, 0.6, 1.0, 1.0 },
  button      = { 0.15, 0.15, 0.25, 1.0 },
  buttonText  = { 0.8, 0.9, 1.0, 1.0 },
  buttonDim   = { 0.4, 0.5, 0.6, 1.0 },
  stationHdr  = { 0.6, 0.8, 1.0, 1.0 },
  selected    = { 1.0, 1.0, 0.3, 1.0 },
  autopilot   = { 0.3, 0.8, 1.0, 1.0 },
}

-- Display state
local state = {
  gpu = nil,
  screen = nil,
  enabled = false,
  displayMode = "table",
}

local DISPLAY_MODES = { "table", "stations", "timetable" }

-- Sort modes for table view
local SORT_MODES = {
  { key = "name",   label = "Name" },
  { key = "wagons", label = "Cars" },
  { key = "fill",   label = "Fill%" },
  { key = "speed",  label = "Speed" },
  { key = "status", label = "Status" },
  { key = "segEta", label = "SegETA" },
  { key = "rtEta",  label = "RtETA" },
  { key = "rtAvg",  label = "RtAvg" },
  { key = "slow",   label = "Slow" },
}
local sortState = {
  mode = "name",
  ascending = true,
}

-- Pagination
local currentPage = 1
local totalPages = 1

-- Footer click zones: { x1, x2, action }
local footerButtons = {}

-- Table mode click zones
local tableClickZones = {}
local sortHeaderRow = nil
local sortButtons = {}

-- Timetable mode state
local ttState = {
  selectedTrainIdx = nil,
  selectedTrainId = nil,
}

-- Timetable click zones
local ttClickZones = {}

-- Station mode click zones
local stationClickZones = {}

-- Filter: show all trains or only self-driving
local showAllTrains = false

-- Last scan + controller references
local lastScanResult = nil
local controllerRef = nil

-- Track peak speed per train for abnormal stop detection
local trainPeakSpeeds = {}

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the train display.
-- @param gpu     userdata - raw GPU proxy (T1 or T2)
-- @param screen  userdata - screen proxy
-- @param options table    - { gpuType = "T1"|"T2", controller = trainController }
function TrainDisplay.init(gpu, screen, options)
  if not gpu or not screen then
    print("[TRAIN_DSP] No GPU/Screen - console fallback")
    state.enabled = false
    return false
  end

  options = options or {}
  controllerRef = options.controller or nil

  -- GPU type must be provided by the caller (avoids probing missing properties)
  local gpuType = options.gpuType or "T1"
  isGpuT1 = (gpuType == "T1")

  -- Wrap GPU T2 to provide T1-compatible character-mode API
  local wrappedGpu = isGpuT1 and gpu or createT2Wrapper(gpu)
  state.gpu = wrappedGpu
  state.rawGpu = gpu
  state.screen = screen

  wrappedGpu:bindScreen(screen)
  wrappedGpu:setSize(W, H)
  state.enabled = true

  event.listen(gpu)
  if SIGNAL_HANDLERS then
    SIGNAL_HANDLERS["OnMouseDown"] = SIGNAL_HANDLERS["OnMouseDown"] or {}
    table.insert(SIGNAL_HANDLERS["OnMouseDown"], function(signal, sender, ...)
      if sender == state.rawGpu then
        if isGpuT1 then
          -- T1: OnMouseDown(x, y, btn) - integer character coords
          local x, y, btn = ...
          handleClick(x, y, btn)
        else
          -- T2: OnMouseDown(position, modifiers) - position is Vector2D in pixels
          local position, modifiers = ...
          local cx, cy = pixelToChar(position.x, position.y)
          handleClick(cx, cy, modifiers)
        end
      end
    end)
  end

  if not isGpuT1 then
    print("[TRAIN_DSP] GPU T2 - using character emulation layer")
  end
  print("[TRAIN_DSP] Initialized (" .. W .. "x" .. H .. ") on GPU " .. gpuType)
  return true
end

function TrainDisplay.isEnabled()
  return state.enabled
end

-- ============================================================================
-- Drawing helpers
-- ============================================================================

local function txt(col, row, text, color)
  if row < 0 or row >= H then return end
  state.gpu:setForeground(table.unpack(color or COLORS.text))
  state.gpu:setText(col, row, text)
end

local function drawSeparator(row)
  if row < 0 or row >= H then return end
  state.gpu:setForeground(table.unpack(COLORS.separator))
  state.gpu:fill(0, row, W, 1, "-")
end

local function getFillColor(percent)
  if percent <= 0 then return COLORS.fillEmpty end
  if percent < 25 then return COLORS.fillLow end
  if percent < 75 then return COLORS.fillMid end
  if percent < 100 then return COLORS.fillHigh end
  return COLORS.fillFull
end

local function getStateColor(trainData)
  if trainData.selfDrivingError ~= 0 then return COLORS.error
  elseif trainData.isMoving then return COLORS.moving
  elseif trainData.isDocked then return COLORS.docked
  else return COLORS.idle end
end

local function formatSpeed(speed)
  return string.format("%.1f km/h", math.abs(speed) * 0.036)
end

local function formatMass(mass)
  if mass >= 1000 then return string.format("%.1f t", mass / 1000) end
  return string.format("%.0f kg", mass)
end

local function formatDuration(seconds)
  if not seconds then return "--" end
  seconds = math.floor(seconds)
  if seconds >= 3600 then
    return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  elseif seconds >= 60 then
    return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60)
  end
  return string.format("%ds", seconds)
end

local function drawFillBar(col, row, barWidth, percent, suffix)
  if row < 0 or row >= H then return barWidth + 2 end
  local gpu = state.gpu
  local innerWidth = barWidth - 2
  local filled = math.floor(innerWidth * math.min(percent or 0, 100) / 100)
  local empty = innerWidth - filled

  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col, row, "[")
  gpu:setForeground(table.unpack(getFillColor(percent or 0)))
  gpu:setText(col + 1, row, string.rep("#", filled))
  gpu:setForeground(table.unpack(COLORS.fillEmpty))
  gpu:setText(col + 1 + filled, row, string.rep("-", empty))
  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col + 1 + innerWidth, row, "]")

  local drawn = barWidth
  if suffix then
    gpu:setForeground(table.unpack(getFillColor(percent or 0)))
    gpu:setText(col + barWidth + 1, row, suffix)
    drawn = barWidth + 1 + #suffix
  end
  return drawn
end

local function getAvgFill(trainData)
  if not trainData.wagonFills or #trainData.wagonFills == 0 then return 0 end
  local total, count = 0, 0
  for _, wf in ipairs(trainData.wagonFills) do
    for _, inv in ipairs(wf.inventories) do
      total = total + inv.fillPercent
      count = count + 1
    end
  end
  return count > 0 and (total / count) or 0
end

-- ============================================================================
-- Overview stats bar (shared across modes)
-- ============================================================================

local function renderOverview(scanResult, startRow)
  local row = startRow
  local s = scanResult.globalStats

  txt(1, row, "NETWORK OVERVIEW", COLORS.title)
  txt(18, row, "  [" .. state.displayMode .. "]", COLORS.dim)
  row = row + 1

  local statsLine = string.format(
    "  Trains:%d  Vehicles:%d  Self-Drv:%d  Moving:%d  Docked:%d  Idle:%d",
    s.totalTrains, s.totalVehicles, s.trainsSelfDriving,
    s.trainsMoving, s.trainsDocked, s.trainsIdle)
  txt(0, row, statsLine, COLORS.text)
  if s.trainsWithErrors > 0 then
    local errText = "  Errors:" .. s.trainsWithErrors
    txt(#statsLine + 1, row, errText, COLORS.error)
  end
  row = row + 1

  local line2 = string.format("  Payload:%s  Mass:%s  Avg:%s  Max:%s",
    formatMass(s.totalPayload), formatMass(s.totalMass),
    formatSpeed(s.averageSpeed), formatSpeed(s.maxSpeedObserved))
  txt(0, row, line2, COLORS.label)
  row = row + 1

  -- Rail controller summary
  if scanResult.railStates then
    local ctrlCount, sigCount, swCount = 0, 0, 0
    for _, rs in pairs(scanResult.railStates) do
      ctrlCount = ctrlCount + 1
      sigCount = sigCount + #(rs.signals or {})
      swCount = swCount + #(rs.switches or {})
    end
    if ctrlCount > 0 then
      local railLine = string.format("  RailCtrl:%d  Signals:%d  Switches:%d",
        ctrlCount, sigCount, swCount)
      txt(0, row, railLine, COLORS.dim)
      row = row + 1
    end
  end

  drawSeparator(row)
  row = row + 1
  return row
end

-- ============================================================================
-- Table mode rendering
-- ============================================================================

local function getStatusPriority(td)
  if td.isDocked then return 0 end
  if not td.isMoving then return 1 end
  return 2
end

local function getTripSortValue(td, path)
  local ts = td.tripStats
  if not ts then return 999999 end
  if path == "segEta" then return ts.segment.eta or 999999 end
  if path == "rtEta" then return ts.roundTrip.eta or 999999 end
  if path == "rtAvg" then return ts.roundTrip.averageDuration or 999999 end
  if path == "slow" then return ts.slowdownCount or 0 end
  return 999999
end

local function sortTrains(trains)
  local mode = sortState.mode
  local asc = sortState.ascending
  table.sort(trains, function(a, b)
    local va, vb
    if mode == "name" then va, vb = a.name:lower(), b.name:lower()
    elseif mode == "wagons" then va, vb = a.vehicleCount, b.vehicleCount
    elseif mode == "fill" then va, vb = getAvgFill(a), getAvgFill(b)
    elseif mode == "speed" then va, vb = a.speed, b.speed
    elseif mode == "status" then va, vb = getStatusPriority(a), getStatusPriority(b)
    else va = getTripSortValue(a, mode); vb = getTripSortValue(b, mode) end
    if asc then return va < vb end
    return va > vb
  end)
end

local function drawSortHeader(row)
  sortHeaderRow = row
  sortButtons = {}
  txt(1, row, "Sort:", COLORS.label)
  local col = 7
  for _, mode in ipairs(SORT_MODES) do
    local isActive = sortState.mode == mode.key
    local label = mode.label
    if isActive then label = label .. (sortState.ascending and "^" or "v") end
    table.insert(sortButtons, { key = mode.key, col = col, endCol = col + #label })
    txt(col, row, label, isActive and COLORS.title or COLORS.dim)
    col = col + #label + 2
  end
  -- Filter toggle at the end
  local filterLabel = showAllTrains and "[All]" or "[Auto]"
  txt(col + 2, row, filterLabel, COLORS.buttonText)
  table.insert(sortButtons, { key = "_filter", col = col + 2, endCol = col + 2 + #filterLabel })
end

local function renderTable(scanResult, startRow)
  tableClickZones = {}
  local row = startRow

  drawSortHeader(row)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  -- Filter trains
  local displayTrains = {}
  for _, td in ipairs(scanResult.trains) do
    if showAllTrains or td.isSelfDriving then
      table.insert(displayTrains, td)
    end
  end
  sortTrains(displayTrains)

  -- Pagination: each train takes 4-6 rows
  local contentRows = H - row - 1
  local rowsPerTrain = 4
  local trainsPerPage = math.max(1, math.floor(contentRows / rowsPerTrain))
  totalPages = math.max(1, math.ceil(#displayTrains / trainsPerPage))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end

  local startIdx = (currentPage - 1) * trainsPerPage + 1
  local endIdx = math.min(startIdx + trainsPerPage - 1, #displayTrains)

  for i = startIdx, endIdx do
    if row >= H - 2 then break end
    local td = displayTrains[i]
    local stateColor = getStateColor(td)
    local stateName = td.dockStateLabel
    if td.selfDrivingError ~= 0 then
      stateName = "ERR:" .. td.selfDrivingErrorLabel
    end

    local trainName = td.name
    if #trainName > 24 then trainName = trainName:sub(1, 21) .. "..." end

    local nextStop = td.nextStationName or "-"
    if #nextStop > 22 then nextStop = nextStop:sub(1, 19) .. "..." end

    -- Line 1: Name | State | Speed | Route
    txt(1, row, string.format("%-24s", trainName), COLORS.trainName)
    txt(26, row, string.format("%-16s", stateName), stateColor)

    -- Abnormal stop blink
    local speedKmh = math.abs(td.speed) * 0.036
    local peakKey = td.trainId or td.name
    trainPeakSpeeds[peakKey] = trainPeakSpeeds[peakKey] or 0
    if speedKmh > trainPeakSpeeds[peakKey] then trainPeakSpeeds[peakKey] = speedKmh end
    if td.dockState ~= 0 then trainPeakSpeeds[peakKey] = 0 end

    local isAbnormal = speedKmh < 0.1 and td.dockState == 0 and trainPeakSpeeds[peakKey] > 25
    if isAbnormal then
      local blinkOn = math.floor(computer.millis() / 500) % 2 == 0
      txt(43, row, string.format("%10s", formatSpeed(td.speed)), blinkOn and COLORS.error or COLORS.bg)
    else
      txt(43, row, string.format("%10s", formatSpeed(td.speed)), COLORS.text)
    end

    -- Route segment
    if td.dockState == 0 and td.isMoving and td.prevStationName then
      local dep = td.prevStationName
      local dest = nextStop
      if #dep > 14 then dep = dep:sub(1, 12) .. ".." end
      if #dest > 14 then dest = dest:sub(1, 12) .. ".." end
      txt(55, row, dep, COLORS.label)
      txt(55 + #dep, row, " > ", COLORS.moving)
      txt(55 + #dep + 3, row, dest, COLORS.text)
    else
      txt(55, row, "-> " .. string.format("%-22s", nextStop), COLORS.label)
    end

    -- Stops indicator
    if td.totalStops and td.totalStops > 0 then
      local curStop = td.currentStop and (td.currentStop + 1) or "-"
      txt(92, row, "[" .. curStop .. "/" .. td.totalStops .. "]", COLORS.label)
    end

    -- Trip stats on line 1
    if td.isSelfDriving and td.tripStats then
      local trip = td.tripStats
      local tc = 100
      if trip.segment.averageDuration then
        txt(tc, row, "Seg:", COLORS.tripLabel)
        txt(tc + 4, row, string.format("%-8s", formatDuration(trip.segment.averageDuration)), COLORS.text)
        tc = tc + 13
      end
      if trip.segment.eta then
        txt(tc, row, "ETA:", COLORS.tripLabel)
        txt(tc + 4, row, string.format("%-8s", formatDuration(trip.segment.eta)), COLORS.eta)
        tc = tc + 13
      end
      local slowColor = (trip.slowdownCount or 0) > 0 and COLORS.warning or COLORS.good
      txt(tc, row, "Slw:", COLORS.tripLabel)
      txt(tc + 4, row, tostring(trip.slowdownCount or 0), slowColor)
    end

    if td.selfDrivingError ~= 0 then
      txt(130, row, "[!] " .. td.selfDrivingErrorLabel, COLORS.error)
    end

    table.insert(tableClickZones, { y = row, trainData = td })
    row = row + 1
    if row >= H - 2 then break end

    -- Line 2: Cars | Payload | Mass | Route stats
    txt(3, row, "Cars:", COLORS.label)
    txt(8, row, string.format("%-3s", td.vehicleCount), COLORS.text)
    txt(13, row, "Payload:", COLORS.label)
    txt(21, row, string.format("%-9s", formatMass(td.totalPayload)), COLORS.text)
    txt(32, row, "Mass:", COLORS.label)
    txt(37, row, string.format("%-9s", formatMass(td.totalMass)), COLORS.text)

    if td.isSelfDriving and td.tripStats then
      local rt = td.tripStats.roundTrip
      if rt.averageDuration or rt.eta then
        local rtCol = 50
        txt(rtCol, row, "Route:", COLORS.tripLabel)
        rtCol = rtCol + 7
        if rt.averageDuration then
          txt(rtCol, row, "Avg:", COLORS.label)
          txt(rtCol + 4, row, string.format("%-8s", formatDuration(rt.averageDuration)), COLORS.text)
          rtCol = rtCol + 13
        end
        if rt.eta then
          txt(rtCol, row, "ETA:", COLORS.label)
          txt(rtCol + 4, row, string.format("%-8s", formatDuration(rt.eta)), COLORS.eta)
        end
      end
    end

    -- Autopilot indicator for non-self-driving trains
    if not td.isSelfDriving then
      if td.isPlayerDriven then
        txt(50, row, "[PLAYER DRIVEN]", COLORS.warning)
      else
        txt(50, row, "[MANUAL]", COLORS.dim)
      end
    end

    row = row + 1
    if row >= H - 2 then break end

    -- Line 3: Wagon fill bars
    if td.wagonFills and #td.wagonFills > 0 then
      txt(3, row, "Wagons:", COLORS.label)
      local wCol = 11
      for _, wf in ipairs(td.wagonFills) do
        for _, inv in ipairs(wf.inventories) do
          if wCol + 16 > W then break end
          local pctText = string.format("%3.0f%%", inv.fillPercent)
          local drawn = drawFillBar(wCol, row, 10, inv.fillPercent, pctText)
          wCol = wCol + drawn + 2
        end
      end
      row = row + 1
      if row >= H - 2 then break end
    end

    -- Line 4: Docking details (when docked)
    if td.dockingDetails and td.dockingDetails.platforms then
      for pIdx, plat in ipairs(td.dockingDetails.platforms) do
        if row >= H - 2 then break end
        local dInFlow = plat.inputFlow or 0
        local dOutFlow = plat.outputFlow or 0
        local dActive = dInFlow > 0 or dOutFlow > 0
        local mode = dActive and (plat.isInLoadMode and "LOADING" or "UNLOADING") or "IDLE"
        local modeColor = dActive and (plat.isInLoadMode and COLORS.flow or COLORS.eta) or COLORS.idle
        local flowVal = plat.isInLoadMode and dInFlow or dOutFlow
        txt(3, row, "Dock#" .. pIdx .. ":", COLORS.platform)
        txt(12, row, string.format("%-10s", mode), modeColor)
        txt(23, row, "Flow:", COLORS.label)
        txt(28, row, string.format("%.1f/min", flowVal), COLORS.flow)
        if plat.fullLoad then txt(42, row, "[FULL-LD]", COLORS.fillFull) end
        if plat.fullUnload then txt(52, row, "[FULL-UL]", COLORS.fillFull) end
        row = row + 1
      end
    end

    -- Train separator
    if i < endIdx and row < H - 2 then
      state.gpu:setForeground(table.unpack(COLORS.separator))
      state.gpu:fill(2, row, W - 4, 1, ".")
      row = row + 1
    end
  end

  return row
end

-- ============================================================================
-- Stations mode rendering
-- ============================================================================

local function renderStations(scanResult, startRow)
  stationClickZones = {}
  local row = startRow

  -- Collect station data from timetable stops and docking info
  local stations = {}
  local stationMap = {}

  for _, td in ipairs(scanResult.trains) do
    -- Collect stations from timetable
    if td.timetableStops then
      for _, name in pairs(td.timetableStops) do
        if not stationMap[name] then
          stationMap[name] = {
            name = name,
            trainsScheduled = 0,
            trainsDocked = 0,
            platforms = {},
          }
          table.insert(stations, stationMap[name])
        end
        stationMap[name].trainsScheduled = stationMap[name].trainsScheduled + 1
      end
    end

    -- Track docked trains at their current station
    if td.isDocked and td.nextStationName then
      local stName = td.prevStationName or td.nextStationName
      if stationMap[stName] then
        stationMap[stName].trainsDocked = stationMap[stName].trainsDocked + 1
      end
    end

    -- Collect platform data from docked trains
    if td.dockingDetails and td.dockingDetails.platforms then
      local stName = td.prevStationName or td.nextStationName or "Unknown"
      if stationMap[stName] then
        for _, plat in ipairs(td.dockingDetails.platforms) do
          table.insert(stationMap[stName].platforms, {
            trainName = td.name,
            isInLoadMode = plat.isInLoadMode,
            inputFlow = plat.inputFlow,
            outputFlow = plat.outputFlow,
            fullLoad = plat.fullLoad,
            fullUnload = plat.fullUnload,
            inventories = plat.inventories,
          })
        end
      end
    end
  end

  table.sort(stations, function(a, b) return a.name < b.name end)

  -- Column headers
  txt(1, row, string.format("%-25s", "Station"), COLORS.dim)
  txt(27, row, string.format("%-10s", "Scheduled"), COLORS.dim)
  txt(38, row, string.format("%-8s", "Docked"), COLORS.dim)
  txt(47, row, string.format("%-40s", "Active Platforms"), COLORS.dim)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  -- Pagination
  local contentRows = H - row - 1
  totalPages = math.max(1, math.ceil(#stations / contentRows))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end
  local startIdx = (currentPage - 1) * contentRows + 1
  local endIdx = math.min(startIdx + contentRows - 1, #stations)

  for i = startIdx, endIdx do
    if row >= H - 2 then break end
    local st = stations[i]

    local name = st.name
    if #name > 24 then name = name:sub(1, 22) .. ".." end
    txt(1, row, string.format("%-25s", name), COLORS.stationHdr)
    txt(27, row, string.format("%-10s", st.trainsScheduled), COLORS.text)

    local dockedColor = st.trainsDocked > 0 and COLORS.docked or COLORS.dim
    txt(38, row, string.format("%-8s", st.trainsDocked), dockedColor)

    -- Show active platform info inline
    if #st.platforms > 0 then
      local platCol = 47
      for _, plat in ipairs(st.platforms) do
        if platCol + 30 > W then break end
        local sInFlow = plat.inputFlow or 0
        local sOutFlow = plat.outputFlow or 0
        local sActive = sInFlow > 0 or sOutFlow > 0
        local mode = sActive and (plat.isInLoadMode and "LD" or "UL") or "--"
        local modeColor = sActive and (plat.isInLoadMode and COLORS.flow or COLORS.eta) or COLORS.idle
        local flowVal = plat.isInLoadMode and sInFlow or sOutFlow
        local confMode = plat.isInLoadMode and "Load" or "Unload"

        txt(platCol, row, "[", COLORS.dim)
        txt(platCol + 1, row, mode, modeColor)
        txt(platCol + 3, row, " " .. confMode, COLORS.label)
        txt(platCol + 3 + 1 + #confMode, row, string.format(" %.0f/m", flowVal), COLORS.flow)
        local endCol = platCol + 3 + 1 + #confMode + string.len(string.format(" %.0f/m", flowVal))
        txt(endCol, row, "]", COLORS.dim)
        platCol = endCol + 2
      end
    end

    table.insert(stationClickZones, { y = row, station = st })
    row = row + 1
  end

  return row
end

-- ============================================================================
-- Timetable mode rendering
-- ============================================================================

local function renderTimetable(scanResult, startRow)
  ttClickZones = {}
  local row = startRow

  -- Header
  txt(1, row, "TRAIN CONTROL", COLORS.title)
  row = row + 1

  -- Column headers
  txt(1, row, string.format("%-24s", "Train"), COLORS.dim)
  txt(26, row, string.format("%-12s", "Autopilot"), COLORS.dim)
  txt(39, row, string.format("%-8s", "Stops"), COLORS.dim)
  txt(48, row, string.format("%-30s", "Timetable Route"), COLORS.dim)
  txt(80, row, string.format("%-10s", "Speed"), COLORS.dim)
  txt(92, row, string.format("%-10s", "Status"), COLORS.dim)
  txt(104, row, string.format("%-20s", "Actions"), COLORS.dim)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  -- All trains (not filtered)
  local allTrains = {}
  for _, td in ipairs(scanResult.trains) do
    table.insert(allTrains, td)
  end
  table.sort(allTrains, function(a, b) return a.name < b.name end)

  -- Pagination
  local contentRows = H - row - 1
  totalPages = math.max(1, math.ceil(#allTrains / contentRows))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end
  local startIdx = (currentPage - 1) * contentRows + 1
  local endIdx = math.min(startIdx + contentRows - 1, #allTrains)

  for i = startIdx, endIdx do
    if row >= H - 2 then break end
    local td = allTrains[i]
    local isSelected = ttState.selectedTrainId == td.trainId

    -- Name
    local name = td.name
    if #name > 23 then name = name:sub(1, 21) .. ".." end
    local nameColor = isSelected and COLORS.selected or COLORS.trainName
    txt(1, row, string.format("%-24s", name), nameColor)

    -- Autopilot status
    local autoLabel = td.isSelfDriving and " ON " or "OFF "
    local autoColor = td.isSelfDriving and COLORS.good or COLORS.error
    txt(26, row, "[", COLORS.dim)
    txt(27, row, autoLabel, autoColor)
    txt(27 + #autoLabel, row, "]", COLORS.dim)
    table.insert(ttClickZones, {
      y = row, x1 = 26, x2 = 27 + #autoLabel,
      action = "toggle_autopilot", trainData = td
    })

    -- Stops count
    local stopsStr = td.hasTimeTable and tostring(td.totalStops) or "none"
    txt(39, row, string.format("%-8s", stopsStr), td.hasTimeTable and COLORS.text or COLORS.dim)

    -- Timetable route summary
    if td.timetableStops and td.totalStops > 0 then
      local route = ""
      for stopIdx = 0, math.min(td.totalStops - 1, 3) do
        local sName = td.timetableStops[stopIdx] or "?"
        if #sName > 8 then sName = sName:sub(1, 7) .. "." end
        if stopIdx > 0 then route = route .. ">" end
        route = route .. sName
      end
      if td.totalStops > 4 then route = route .. ">..." end
      if #route > 29 then route = route:sub(1, 27) .. ".." end
      txt(48, row, string.format("%-30s", route), COLORS.label)
    else
      txt(48, row, string.format("%-30s", "- no timetable -"), COLORS.dim)
    end

    -- Speed
    txt(80, row, string.format("%-10s", formatSpeed(td.speed)), COLORS.text)

    -- Status
    local stateColor = getStateColor(td)
    local stLabel = td.dockStateLabel
    if #stLabel > 10 then stLabel = stLabel:sub(1, 9) .. "." end
    txt(92, row, string.format("%-10s", stLabel), stateColor)

    -- Action buttons
    local actCol = 104
    if isSelected then
      txt(actCol, row, "[Rename]", COLORS.buttonText)
      table.insert(ttClickZones, {
        y = row, x1 = actCol, x2 = actCol + 7,
        action = "rename", trainData = td
      })
      actCol = actCol + 9

      txt(actCol, row, "[ClearTT]", COLORS.buttonText)
      table.insert(ttClickZones, {
        y = row, x1 = actCol, x2 = actCol + 8,
        action = "clear_timetable", trainData = td
      })
      actCol = actCol + 10

      txt(actCol, row, "[Dock]", COLORS.buttonText)
      table.insert(ttClickZones, {
        y = row, x1 = actCol, x2 = actCol + 5,
        action = "dock", trainData = td
      })
    end

    -- Row click to select train
    table.insert(ttClickZones, {
      y = row, x1 = 1, x2 = 25,
      action = "select_train", trainData = td, trainIdx = i
    })

    row = row + 1
  end

  return row
end

-- ============================================================================
-- Footer
-- ============================================================================

local function renderFooter(scanResult, footerRow)
  footerButtons = {}
  local gpu = state.gpu

  gpu:setBackground(0.08, 0.08, 0.15, 1.0)
  gpu:fill(0, footerRow, W, 1, " ")
  gpu:setBackground(table.unpack(COLORS.bg))

  local x = 1

  -- [< Prev]
  local prevLabel = "[<Prev]"
  local prevColor = currentPage > 1 and COLORS.buttonText or COLORS.buttonDim
  txt(x, footerRow, prevLabel, prevColor)
  table.insert(footerButtons, { x1 = x, x2 = x + #prevLabel - 1, action = "prev_page" })
  x = x + #prevLabel + 1

  -- Page X/Y
  local pageText = currentPage .. "/" .. totalPages
  txt(x, footerRow, pageText, COLORS.text)
  x = x + #pageText + 1

  -- [Next>]
  local nextLabel = "[Next>]"
  local nextColor = currentPage < totalPages and COLORS.buttonText or COLORS.buttonDim
  txt(x, footerRow, nextLabel, nextColor)
  table.insert(footerButtons, { x1 = x, x2 = x + #nextLabel - 1, action = "next_page" })
  x = x + #nextLabel + 3

  -- [Mode]
  local modeLabel = "[Mode:" .. state.displayMode .. "]"
  txt(x, footerRow, modeLabel, COLORS.buttonText)
  table.insert(footerButtons, { x1 = x, x2 = x + #modeLabel - 1, action = "cycle_mode" })
  x = x + #modeLabel + 2

  -- Mode-specific buttons
  if state.displayMode == "table" then
    -- Sort label is in the sort header, not footer
  elseif state.displayMode == "timetable" then
    if ttState.selectedTrainId then
      local deselLabel = "[Deselect]"
      txt(x, footerRow, deselLabel, COLORS.buttonText)
      table.insert(footerButtons, { x1 = x, x2 = x + #deselLabel - 1, action = "tt_deselect" })
      x = x + #deselLabel + 2
    end
  end

  -- Right-aligned: train count + timestamp
  local totalSec = math.floor((computer.millis() or 0) / 1000)
  local hh = math.floor(totalSec / 3600) % 24
  local mm = math.floor(totalSec / 60) % 60
  local ss = totalSec % 60
  local timeStr = string.format("%02d:%02d:%02d", hh, mm, ss)

  local s = scanResult.globalStats
  local infoText = s.totalTrains .. " trains/" .. s.totalVehicles .. " vehicles"
  local rightText = infoText .. "  " .. timeStr
  txt(W - #rightText - 1, footerRow, infoText, COLORS.dim)
  txt(W - #timeStr - 1, footerRow, timeStr, COLORS.text)
end

-- ============================================================================
-- Click handling
-- ============================================================================

handleClick = function(x, y, btn)
  local footerRow = H - 1

  -- Footer check
  if y == footerRow then
    for _, button in ipairs(footerButtons) do
      if x >= button.x1 and x <= button.x2 then
        if button.action == "prev_page" then
          if currentPage > 1 then currentPage = currentPage - 1 end
        elseif button.action == "next_page" then
          if currentPage < totalPages then currentPage = currentPage + 1 end
        elseif button.action == "cycle_mode" then
          local idx = 1
          for i, m in ipairs(DISPLAY_MODES) do
            if m == state.displayMode then idx = i; break end
          end
          idx = (idx % #DISPLAY_MODES) + 1
          state.displayMode = DISPLAY_MODES[idx]
          currentPage = 1
          ttState.selectedTrainIdx = nil
          ttState.selectedTrainId = nil
        elseif button.action == "tt_deselect" then
          ttState.selectedTrainIdx = nil
          ttState.selectedTrainId = nil
        end
        if lastScanResult then TrainDisplay.render(lastScanResult) end
        return
      end
    end
    return
  end

  -- Table mode: sort header click
  if state.displayMode == "table" then
    if sortHeaderRow and y == sortHeaderRow then
      for _, btn_item in ipairs(sortButtons) do
        if x >= btn_item.col and x < btn_item.endCol then
          if btn_item.key == "_filter" then
            showAllTrains = not showAllTrains
          elseif sortState.mode == btn_item.key then
            sortState.ascending = not sortState.ascending
          else
            sortState.mode = btn_item.key
            sortState.ascending = true
          end
          if lastScanResult then TrainDisplay.render(lastScanResult) end
          return
        end
      end
    end
  end

  -- Timetable mode: click zones
  if state.displayMode == "timetable" then
    for _, zone in ipairs(ttClickZones) do
      if y == zone.y and x >= zone.x1 and x <= zone.x2 then
        if zone.action == "select_train" then
          if ttState.selectedTrainId == zone.trainData.trainId then
            ttState.selectedTrainIdx = nil
            ttState.selectedTrainId = nil
          else
            ttState.selectedTrainIdx = zone.trainIdx
            ttState.selectedTrainId = zone.trainData.trainId
          end
        elseif zone.action == "toggle_autopilot" then
          if controllerRef and controllerRef.toggleAutopilot then
            controllerRef.toggleAutopilot(zone.trainData)
          end
        elseif zone.action == "clear_timetable" then
          if controllerRef and controllerRef.clearTimetable then
            controllerRef.clearTimetable(zone.trainData)
          end
        elseif zone.action == "dock" then
          if controllerRef and controllerRef.dockTrain then
            controllerRef.dockTrain(zone.trainData)
          end
        end
        if lastScanResult then TrainDisplay.render(lastScanResult) end
        return
      end
    end
  end
end

-- ============================================================================
-- Main render
-- ============================================================================

function TrainDisplay.render(scanResult)
  if not state.enabled then return end
  if not scanResult then return end

  lastScanResult = scanResult
  local gpu = state.gpu
  local row = 0

  gpu:setBackground(table.unpack(COLORS.bg))
  gpu:fill(0, 0, W, H, " ")

  local titleText = "=== RAILROAD NETWORK MONITOR ==="
  txt(math.floor((W - #titleText) / 2), row, titleText, COLORS.title)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  row = renderOverview(scanResult, row)

  if state.displayMode == "stations" then
    renderStations(scanResult, row)
  elseif state.displayMode == "timetable" then
    renderTimetable(scanResult, row)
  else
    renderTable(scanResult, row)
  end

  renderFooter(scanResult, H - 1)
  gpu:flush()
end

-- ============================================================================
-- Console fallback (delegated to train_monitor.printReport)
-- ============================================================================

return TrainDisplay
