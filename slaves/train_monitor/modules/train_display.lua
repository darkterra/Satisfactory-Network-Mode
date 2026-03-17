-- modules/train_display.lua
-- Renders train monitoring data on a GPU T1 screen.
-- Falls back to console output if no GPU/screen is available.

local TrainDisplay = {}

-- Color palette for the train dashboard
local COLORS = {
  background   = { 0.05, 0.05, 0.1, 1.0 },
  title        = { 0.2, 0.7, 1.0, 1.0 },
  label        = { 0.6, 0.6, 0.6, 1.0 },
  value        = { 1.0, 1.0, 1.0, 1.0 },
  good         = { 0.3, 1.0, 0.4, 1.0 },
  warning      = { 1.0, 0.8, 0.2, 1.0 },
  error        = { 1.0, 0.3, 0.3, 1.0 },
  separator    = { 0.3, 0.3, 0.4, 1.0 },
  trainName    = { 0.4, 0.8, 1.0, 1.0 },
  moving       = { 0.3, 1.0, 0.4, 1.0 },
  docked       = { 1.0, 0.8, 0.2, 1.0 },
  idle         = { 0.5, 0.5, 0.5, 1.0 },
  fillEmpty    = { 0.3, 0.3, 0.3, 1.0 },
  fillLow      = { 1.0, 0.3, 0.3, 1.0 },
  fillMid      = { 1.0, 0.8, 0.2, 1.0 },
  fillHigh     = { 0.3, 1.0, 0.4, 1.0 },
  fillFull     = { 0.2, 0.7, 1.0, 1.0 },
  tripLabel    = { 0.7, 0.5, 1.0, 1.0 },
  eta          = { 1.0, 0.6, 0.2, 1.0 },
  flow         = { 0.2, 1.0, 0.8, 1.0 },
  platform     = { 0.8, 0.6, 1.0, 1.0 },
}

local displayState = {
  gpu = nil,
  screen = nil,
  width = 150,
  height = 75,
  enabled = false,
  scrollOffset = 0,
}

-- Track peak speed per train (km/h) for abnormal stop detection
local trainPeakSpeeds = {}

-- ============================================================================
-- Interactive sort system
-- ============================================================================

local SORT_MODES = {
  { key = "name",    label = "Name" },
  { key = "wagons",  label = "Cars" },
  { key = "fill",    label = "Fill%" },
  { key = "speed",   label = "Speed" },
  { key = "status",  label = "Status" },
  { key = "segEta",  label = "SegETA" },
  { key = "rtEta",   label = "RtETA" },
  { key = "rtAvg",   label = "RtAvg" },
  { key = "slow",    label = "Slow" },
}

local sortState = {
  mode = "name",
  ascending = true,
  headerRow = nil,
  buttons = {},
}

--- Compute average fill percentage across all wagon inventories.
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

--- Get numeric priority for status sorting (lower = docked/idle first).
local function getStatusPriority(trainData)
  if trainData.isDocked then return 0 end
  if not trainData.isMoving then return 1 end
  return 2
end

--- Safely extract a numeric value for trip-stat based sorting.
local function getTripSortValue(trainData, path)
  local ts = trainData.tripStats
  if not ts then return 999999 end
  if path == "segEta" then return ts.segment.eta or 999999 end
  if path == "rtEta" then return ts.roundTrip.eta or 999999 end
  if path == "rtAvg" then return ts.roundTrip.averageDuration or 999999 end
  if path == "slow" then return ts.slowdownCount or 0 end
  return 999999
end

--- Sort a trains list in-place based on current sortState.
local function sortTrains(trains)
  local mode = sortState.mode
  local asc = sortState.ascending
  table.sort(trains, function(a, b)
    local va, vb
    if mode == "name" then
      va, vb = a.name:lower(), b.name:lower()
    elseif mode == "wagons" then
      va, vb = a.vehicleCount, b.vehicleCount
    elseif mode == "fill" then
      va, vb = getAvgFill(a), getAvgFill(b)
    elseif mode == "speed" then
      va, vb = a.speed, b.speed
    elseif mode == "status" then
      va, vb = getStatusPriority(a), getStatusPriority(b)
    else
      va = getTripSortValue(a, mode)
      vb = getTripSortValue(b, mode)
    end
    if asc then return va < vb end
    return va > vb
  end)
end

--- Draw the interactive sort header row.
local function drawSortHeader(row)
  local gpu = displayState.gpu
  sortState.headerRow = row
  sortState.buttons = {}

  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(1, row, "Sort:")

  local col = 7
  for _, mode in ipairs(SORT_MODES) do
    local isActive = sortState.mode == mode.key
    local label = mode.label
    if isActive then
      label = label .. (sortState.ascending and "^" or "v")
    end

    table.insert(sortState.buttons, { key = mode.key, col = col, endCol = col + #label })

    if isActive then
      gpu:setForeground(table.unpack(COLORS.title))
    else
      gpu:setForeground(table.unpack(COLORS.separator))
    end
    gpu:setText(col, row, label)
    col = col + #label + 2
  end
end

--- Handle a mouse click: check if it hit a sort header button.
local function handleSortClick(x, y)
  if sortState.headerRow == nil or y ~= sortState.headerRow then return end
  for _, btn in ipairs(sortState.buttons) do
    if x >= btn.col and x < btn.endCol then
      if sortState.mode == btn.key then
        sortState.ascending = not sortState.ascending
      else
        sortState.mode = btn.key
        sortState.ascending = true
      end
      return
    end
  end
end

--- Initialize the display with a GPU and screen.
-- @param gpu GPU T1 proxy
-- @param screen Screen proxy (PCI or network)
function TrainDisplay.init(gpu, screen)
  if not gpu or not screen then
    print("[TRAIN_DSP] No GPU/Screen - using console fallback")
    displayState.enabled = false
    return false
  end

  displayState.gpu = gpu
  displayState.screen = screen
  gpu:bindScreen(screen)
  gpu:setSize(displayState.width, displayState.height)
  displayState.enabled = true

  -- Listen for mouse events on this GPU (for interactive sort header)
  event.listen(gpu)
  if SIGNAL_HANDLERS then
    SIGNAL_HANDLERS["OnMouseDown"] = SIGNAL_HANDLERS["OnMouseDown"] or {}
    table.insert(SIGNAL_HANDLERS["OnMouseDown"], function(signal, sender, x, y, btn)
      if sender == displayState.gpu then
        handleSortClick(x, y)
      end
    end)
  end

  print("[TRAIN_DSP] Display initialized (" .. displayState.width .. "x" .. displayState.height .. ")")
  return true
end

--- Check if screen rendering is available.
function TrainDisplay.isEnabled()
  return displayState.enabled
end

--- Helper to draw a horizontal separator line.
local function drawSeparator(row)
  local gpu = displayState.gpu
  gpu:setForeground(table.unpack(COLORS.separator))
  gpu:fill(0, row, displayState.width, 1, "-")
end

--- Helper to draw a label: value pair.
local function drawLabelValue(col, row, label, value, valueColor)
  local gpu = displayState.gpu
  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col, row, label)
  gpu:setForeground(table.unpack(valueColor or COLORS.value))
  gpu:setText(col + #label, row, tostring(value))
end

--- Get the appropriate color for a train state.
local function getStateColor(trainData)
  if trainData.selfDrivingError ~= 0 then
    return COLORS.error
  elseif trainData.isMoving then
    return COLORS.moving
  elseif trainData.isDocked then
    return COLORS.docked
  else
    return COLORS.idle
  end
end

--- Format speed value to km/h.
local function formatSpeed(speed)
  local kmh = math.abs(speed) * 0.036
  return string.format("%.1f km/h", kmh)
end

--- Format mass value.
local function formatMass(mass)
  if mass >= 1000 then
    return string.format("%.1f t", mass / 1000)
  end
  return string.format("%.0f kg", mass)
end

--- Format a time duration for display.
local function formatDuration(seconds)
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

--- Get the fill color based on percentage.
local function getFillColor(percent)
  if percent <= 0 then return COLORS.fillEmpty end
  if percent < 25 then return COLORS.fillLow end
  if percent < 75 then return COLORS.fillMid end
  if percent < 100 then return COLORS.fillHigh end
  return COLORS.fillFull
end

--- Draw a compact fill bar at the given position.
-- @param col number - column position
-- @param row number - row position
-- @param barWidth number - total width for the bar (including brackets)
-- @param percent number - fill percentage (0-100)
-- @param suffix string - optional text after the bar
-- @return number - total characters drawn
local function drawFillBar(col, row, barWidth, percent, suffix)
  local gpu = displayState.gpu
  local innerWidth = barWidth - 2 -- subtract [ and ]
  local filled = math.floor(innerWidth * math.min(percent, 100) / 100)
  local empty = innerWidth - filled

  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col, row, "[")

  gpu:setForeground(table.unpack(getFillColor(percent)))
  gpu:setText(col + 1, row, string.rep("#", filled))

  gpu:setForeground(table.unpack(COLORS.fillEmpty))
  gpu:setText(col + 1 + filled, row, string.rep("-", empty))

  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col + 1 + innerWidth, row, "]")

  local drawn = barWidth
  if suffix then
    gpu:setForeground(table.unpack(getFillColor(percent)))
    gpu:setText(col + barWidth + 1, row, suffix)
    drawn = barWidth + 1 + #suffix
  end
  return drawn
end

--- Render the full train dashboard on the GPU screen.
-- @param scanResult table - from TrainMonitor.scan()
function TrainDisplay.render(scanResult)
  if not displayState.enabled then return end
  if not scanResult then return end

  local gpu = displayState.gpu
  local stats = scanResult.globalStats
  local row = 0

  -- Clear screen
  gpu:setBackground(table.unpack(COLORS.background))
  gpu:fill(0, 0, displayState.width, displayState.height, " ")

  -- Title bar
  gpu:setForeground(table.unpack(COLORS.title))
  local titleText = "RAILROAD NETWORK MONITOR"
  gpu:setText(math.floor((displayState.width - #titleText) / 2), row, titleText)
  row = row + 1
  drawSeparator(row)
  row = row + 2

  -- Global stats - left column
  gpu:setForeground(table.unpack(COLORS.title))
  gpu:setText(1, row, "NETWORK OVERVIEW")
  row = row + 1

  drawLabelValue(2, row, "Trains: ", tostring(stats.totalTrains), COLORS.value)
  drawLabelValue(25, row, "Vehicles: ", tostring(stats.totalVehicles), COLORS.value)
  drawLabelValue(45, row, "Self-driving: ", tostring(stats.trainsSelfDriving), COLORS.value)
  row = row + 1

  drawLabelValue(2, row, "Moving: ", tostring(stats.trainsMoving), COLORS.moving)
  drawLabelValue(25, row, "Docked: ", tostring(stats.trainsDocked), COLORS.docked)
  drawLabelValue(45, row, "Idle: ", tostring(stats.trainsIdle), COLORS.idle)
  row = row + 1

  local errColor = stats.trainsWithErrors > 0 and COLORS.error or COLORS.good
  drawLabelValue(2, row, "Errors: ", tostring(stats.trainsWithErrors), errColor)
  row = row + 1

  drawLabelValue(2, row, "Total payload: ", formatMass(stats.totalPayload), COLORS.value)
  drawLabelValue(40, row, "Total mass: ", formatMass(stats.totalMass), COLORS.value)
  row = row + 1

  drawLabelValue(2, row, "Avg speed (auto): ", formatSpeed(stats.averageSpeed), COLORS.value)
  drawLabelValue(40, row, "Max observed: ", formatSpeed(stats.maxSpeedObserved), COLORS.value)
  row = row + 1

  drawLabelValue(2, row, "Avg speed (moving): ", formatSpeed(stats.averageMovingSpeed), COLORS.moving)
  row = row + 1

  drawSeparator(row)
  row = row + 1

  -- Interactive sort header
  drawSortHeader(row)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  -- Filter to self-driving trains only and sort
  local displayTrains = {}
  for _, td in ipairs(scanResult.trains) do
    if td.isSelfDriving then
      table.insert(displayTrains, td)
    end
  end
  sortTrains(displayTrains)

  -- Train detail blocks
  for trainIndex, trainData in ipairs(displayTrains) do
    if row >= displayState.height - 2 then break end

    local stateColor = getStateColor(trainData)
    local stateName = trainData.dockStateLabel
    if trainData.selfDrivingError ~= 0 then
      stateName = "ERR:" .. trainData.selfDrivingErrorLabel
    end

    local trainName = trainData.name
    if #trainName > 24 then
      trainName = trainName:sub(1, 21) .. "..."
    end

    local nextStop = trainData.nextStationName or "-"
    if #nextStop > 22 then
      nextStop = nextStop:sub(1, 19) .. "..."
    end

    -- Line 1: Train name | State | Speed | -> Next Stop
    gpu:setForeground(table.unpack(COLORS.trainName))
    gpu:setText(1, row, string.format("%-24s", trainName))

    gpu:setForeground(table.unpack(stateColor))
    gpu:setText(26, row, string.format("%-16s", stateName))

    -- Track peak speed for abnormal stop detection
    local speedKmh = math.abs(trainData.speed) * 0.036
    local peakKey = trainData.trainId or trainData.name
    if not trainPeakSpeeds[peakKey] then trainPeakSpeeds[peakKey] = 0 end
    if speedKmh > trainPeakSpeeds[peakKey] then
      trainPeakSpeeds[peakKey] = speedKmh
    end
    -- Reset peak when train docks normally
    if trainData.dockState ~= 0 then
      trainPeakSpeeds[peakKey] = 0
    end

    -- Blink speed red if stopped abnormally (speed 0, not docked, previously reached >25 km/h)
    local isAbnormalStop = speedKmh < 0.1 and trainData.dockState == 0
      and trainPeakSpeeds[peakKey] > 25
    if isAbnormalStop then
      local blinkOn = math.floor(computer.millis() / 500) % 2 == 0
      if blinkOn then
        gpu:setForeground(table.unpack(COLORS.error))
      else
        gpu:setForeground(table.unpack(COLORS.background))
      end
    else
      gpu:setForeground(table.unpack(COLORS.value))
    end
    gpu:setText(43, row, string.format("%10s", formatSpeed(trainData.speed)))

    -- Show route segment when in transit, or arrow to next stop otherwise
    if trainData.dockState == 0 and trainData.isMoving and trainData.prevStationName then
      local departure = trainData.prevStationName
      local dest = nextStop
      -- Fit within 32 chars: "departure > dest"
      local maxLen = 32
      local sepLen = 3
      local halfLen = math.floor((maxLen - sepLen) / 2)
      if #departure > halfLen then departure = departure:sub(1, halfLen - 2) .. ".." end
      if #dest > halfLen then dest = dest:sub(1, halfLen - 2) .. ".." end
      gpu:setForeground(table.unpack(COLORS.label))
      gpu:setText(55, row, departure)
      gpu:setForeground(table.unpack(COLORS.moving))
      gpu:setText(55 + #departure, row, " > ")
      gpu:setForeground(table.unpack(COLORS.value))
      gpu:setText(55 + #departure + 3, row, dest)
    else
      gpu:setForeground(table.unpack(COLORS.label))
      gpu:setText(55, row, "-> ")
      gpu:setForeground(table.unpack(COLORS.value))
      gpu:setText(58, row, string.format("%-22s", nextStop))
    end

    -- Total stops indicator before Seg
    if trainData.totalStops and trainData.totalStops > 0 then
      local currentStopDisplay = trainData.currentStop and (trainData.currentStop + 1) or "-"
      local stopsText = "[" .. currentStopDisplay .. "/" .. trainData.totalStops .. "]"
      gpu:setForeground(table.unpack(COLORS.label))
      gpu:setText(92, row, stopsText)
    end

    -- Seg / ETA / Slw at end of Line 1 (self-driving only)
    if trainData.isSelfDriving and trainData.tripStats then
      local trip = trainData.tripStats
      local tripCol = 100

      if trip.segment.averageDuration then
        gpu:setForeground(table.unpack(COLORS.tripLabel))
        gpu:setText(tripCol, row, "Seg:")
        gpu:setForeground(table.unpack(COLORS.value))
        gpu:setText(tripCol + 4, row, string.format("%-8s", formatDuration(trip.segment.averageDuration)))
        tripCol = tripCol + 13
      end

      if trip.segment.eta then
        gpu:setForeground(table.unpack(COLORS.tripLabel))
        gpu:setText(tripCol, row, "ETA:")
        gpu:setForeground(table.unpack(COLORS.eta))
        gpu:setText(tripCol + 4, row, string.format("%-8s", formatDuration(trip.segment.eta)))
        tripCol = tripCol + 13
      end

      local slowColor = trip.slowdownCount > 0 and COLORS.warning or COLORS.good
      gpu:setForeground(table.unpack(COLORS.tripLabel))
      gpu:setText(tripCol, row, "Slw:")
      gpu:setForeground(table.unpack(slowColor))
      gpu:setText(tripCol + 4, row, tostring(trip.slowdownCount))
    end

    if trainData.selfDrivingError ~= 0 then
      gpu:setForeground(table.unpack(COLORS.error))
      gpu:setText(82, row, "[!] " .. trainData.selfDrivingErrorLabel)
    end

    row = row + 1
    if row >= displayState.height - 2 then break end

    -- Line 2: Cars | Payload | Mass | Route stats (self-driving only)
    local col = 3
    gpu:setForeground(table.unpack(COLORS.label))
    gpu:setText(col, row, "Cars:")
    gpu:setForeground(table.unpack(COLORS.value))
    gpu:setText(col + 5, row, string.format("%-3s", tostring(trainData.vehicleCount)))
    col = col + 10

    gpu:setForeground(table.unpack(COLORS.label))
    gpu:setText(col, row, "Payload:")
    gpu:setForeground(table.unpack(COLORS.value))
    gpu:setText(col + 8, row, string.format("%-9s", formatMass(trainData.totalPayload)))
    col = col + 19

    gpu:setForeground(table.unpack(COLORS.label))
    gpu:setText(col, row, "Mass:")
    gpu:setForeground(table.unpack(COLORS.value))
    gpu:setText(col + 5, row, string.format("%-9s", formatMass(trainData.totalMass)))

    -- Route stats on same line (self-driving only)
    if trainData.isSelfDriving and trainData.tripStats then
      local roundTrip = trainData.tripStats.roundTrip
      if roundTrip.averageDuration or roundTrip.eta then
        local rtCol = 60
        gpu:setForeground(table.unpack(COLORS.tripLabel))
        gpu:setText(rtCol, row, "Route:")
        rtCol = rtCol + 7

        if roundTrip.averageDuration then
          gpu:setForeground(table.unpack(COLORS.label))
          gpu:setText(rtCol, row, "Avg:")
          gpu:setForeground(table.unpack(COLORS.value))
          gpu:setText(rtCol + 4, row, string.format("%-8s", formatDuration(roundTrip.averageDuration)))
          rtCol = rtCol + 13
        end

        if roundTrip.eta then
          gpu:setForeground(table.unpack(COLORS.label))
          gpu:setText(rtCol, row, "ETA:")
          gpu:setForeground(table.unpack(COLORS.eta))
          gpu:setText(rtCol + 4, row, string.format("%-8s", formatDuration(roundTrip.eta)))
          rtCol = rtCol + 13
        end
      end
    end

    row = row + 1
    if row >= displayState.height - 2 then break end

    -- Wagon fill bars on one line, item breakdown on the next
    if trainData.wagonFills and #trainData.wagonFills > 0 then
      gpu:setForeground(table.unpack(COLORS.label))
      gpu:setText(3, row, "Wagons:")
      local barWidth = 10
      local suffixLen = 4 -- "%3.0f%%" = 4 chars
      local barTotalWidth = barWidth + 1 + suffixLen -- bar + space + suffix
      local wagonPositions = {} -- remember column positions for item labels
      local wagonCol = 11
      for _, wagonFill in ipairs(trainData.wagonFills) do
        for _, inv in ipairs(wagonFill.inventories) do
          if wagonCol + barTotalWidth > displayState.width then break end
          local pctText = string.format("%3.0f%%", inv.fillPercent)
          local drawn = drawFillBar(wagonCol, row, barWidth, inv.fillPercent, pctText)
          table.insert(wagonPositions, { col = wagonCol, width = drawn, inv = inv })
          wagonCol = wagonCol + drawn + 2
        end
      end
      row = row + 1
      if row >= displayState.height - 2 then break end

      -- Item breakdown line: dominant item name + intra-wagon proportion per wagon
      gpu:setForeground(table.unpack(COLORS.label))
      gpu:setText(3, row, "Items: ")
      for _, pos in ipairs(wagonPositions) do
        local inv = pos.inv
        if inv.itemBreakdown and #inv.itemBreakdown > 0 then
          local top = inv.itemBreakdown[1]
          local maxLabelLen = pos.width -- fit within the bar column width
          local pctStr = tostring(top.percent) .. "%"
          -- Available space for name: total width - pctStr - 1 space
          local nameSpace = maxLabelLen - #pctStr - 1
          local itemName = top.name
          if nameSpace < 3 then
            -- Not enough room for name, just show percentage
            local label = pctStr
            if #label > maxLabelLen then label = label:sub(1, maxLabelLen) end
            gpu:setForeground(table.unpack(COLORS.value))
            gpu:setText(pos.col, row, label)
          else
            if #itemName > nameSpace then
              itemName = itemName:sub(1, nameSpace - 1) .. "."
            end
            local label = itemName .. " " .. pctStr
            gpu:setForeground(table.unpack(COLORS.value))
            gpu:setText(pos.col, row, label)
          end
        end
      end
      row = row + 1
      if row >= displayState.height - 2 then break end
    end

    -- Line 4: Docking details (only when docked with platforms)
    if trainData.dockingDetails and trainData.dockingDetails.platforms then
      for platformIndex, platform in ipairs(trainData.dockingDetails.platforms) do
        if row >= displayState.height - 2 then break end

        local mode = platform.isLoading and "LOADING" or (platform.isUnloading and "UNLOADING" or "IDLE")
        local modeColor = platform.isLoading and COLORS.flow or (platform.isUnloading and COLORS.eta or COLORS.idle)
        local flow = platform.isLoading and platform.inputFlow or platform.outputFlow

        gpu:setForeground(table.unpack(COLORS.platform))
        gpu:setText(3, row, "Dock#" .. platformIndex .. ":")

        gpu:setForeground(table.unpack(modeColor))
        gpu:setText(12, row, string.format("%-10s", mode))

        gpu:setForeground(table.unpack(COLORS.label))
        gpu:setText(23, row, "Flow:")
        gpu:setForeground(table.unpack(COLORS.flow))
        gpu:setText(28, row, string.format("%-10s", string.format("%.1f/min", flow)))

        -- Status flags
        local flagCol = 40
        if platform.fullLoad then
          gpu:setForeground(table.unpack(COLORS.fillFull))
          gpu:setText(flagCol, row, "[FULL-LD]")
          flagCol = flagCol + 10
        end
        if platform.fullUnload then
          gpu:setForeground(table.unpack(COLORS.fillFull))
          gpu:setText(flagCol, row, "[FULL-UL]")
          flagCol = flagCol + 10
        end

        -- Platform buffer fills
        if platform.inventories and #platform.inventories > 0 then
          gpu:setForeground(table.unpack(COLORS.label))
          gpu:setText(flagCol, row, "Buf:")
          local bufCol = flagCol + 4
          for _, inv in ipairs(platform.inventories) do
            if bufCol >= displayState.width - 16 then break end
            local pctText = string.format("%3.0f%%", inv.fillPercent)
            local drawn = drawFillBar(bufCol, row, 8, inv.fillPercent, pctText)
            bufCol = bufCol + drawn + 2
          end
        end

        row = row + 1
      end
    end

    -- Thin separator between trains
    if trainIndex < #displayTrains and row < displayState.height - 2 then
      gpu:setForeground(table.unpack(COLORS.separator))
      gpu:fill(2, row, displayState.width - 4, 1, ".")
      row = row + 1
    end
  end

  -- Footer
  gpu:setForeground(table.unpack(COLORS.separator))
  gpu:setText(1, displayState.height - 1,
    "Last update: " .. string.format("%.0f", computer.millis() / 1000) .. "s uptime")
  gpu:setForeground(table.unpack(COLORS.label))
  local countText = tostring(#displayTrains) .. "/" .. tostring(#scanResult.trains) .. " trains"
  gpu:setText(displayState.width - #countText - 1, displayState.height - 1, countText)

  gpu:flush()
end

return TrainDisplay