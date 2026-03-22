-- modules/train_map.lua
-- Renders a railroad network map on a GPU T2 screen with full interactivity.

local TrainMap = {}

local SCREEN_W = 2700
local SCREEN_H = 2400
local MARGIN = 40
local CONTENT_W = SCREEN_W - 2 * MARGIN
local CONTENT_H = SCREEN_H - 2 * MARGIN

local C = {
  bg          = { r = 0.04, g = 0.04, b = 0.08, a = 1.0 },
  track       = { r = 0.4,  g = 0.4,  b = 0.5,  a = 1.0 },
  trackActive = { r = 0.6,  g = 0.7,  b = 0.8,  a = 1.0 },
  trackFallback = { r = 0.25, g = 0.25, b = 0.35, a = 0.6 },
  station     = { r = 0.2,  g = 0.6,  b = 1.0,  a = 1.0 },
  stationBg   = { r = 0.1,  g = 0.15, b = 0.25, a = 0.9 },
  storageBg   = { r = 0.2,  g = 0.12, b = 0.08, a = 0.9 },
  signalClear = { r = 0.2,  g = 1.0,  b = 0.3,  a = 1.0 },
  signalStop  = { r = 1.0,  g = 0.2,  b = 0.2,  a = 1.0 },
  signalDock  = { r = 1.0,  g = 0.8,  b = 0.2,  a = 1.0 },
  signalUnk   = { r = 0.5,  g = 0.5,  b = 0.5,  a = 1.0 },
  switchNorm  = { r = 0.8,  g = 0.8,  b = 0.3,  a = 1.0 },
  switchForce = { r = 1.0,  g = 0.4,  b = 0.1,  a = 1.0 },
  trainIcon   = { r = 0.3,  g = 1.0,  b = 0.5,  a = 1.0 },
  trainLabel  = { r = 1.0,  g = 1.0,  b = 1.0,  a = 1.0 },
  text        = { r = 0.8,  g = 0.8,  b = 0.8,  a = 1.0 },
  dim         = { r = 0.4,  g = 0.4,  b = 0.4,  a = 1.0 },
  loading     = { r = 0.2,  g = 1.0,  b = 0.8,  a = 1.0 },
  unloading   = { r = 1.0,  g = 0.6,  b = 0.2,  a = 1.0 },
  arrow       = { r = 0.5,  g = 0.6,  b = 0.7,  a = 0.8 },
  length      = { r = 0.5,  g = 0.5,  b = 0.6,  a = 0.7 },
  selected    = { r = 1.0,  g = 1.0,  b = 0.2,  a = 1.0 },
  panelBg     = { r = 0.08, g = 0.08, b = 0.14, a = 0.95 },
  panelBorder = { r = 0.3,  g = 0.4,  b = 0.6,  a = 1.0 },
  buttonBg    = { r = 0.15, g = 0.2,  b = 0.3,  a = 0.9 },
  buttonText  = { r = 0.9,  g = 0.9,  b = 1.0,  a = 1.0 },
  priority    = { r = 1.0,  g = 0.3,  b = 0.8,  a = 1.0 },
  noReverse   = { r = 0.3,  g = 0.8,  b = 1.0,  a = 1.0 },
  ttEdit      = { r = 0.0,  g = 0.8,  b = 0.4,  a = 1.0 },
  ttEditBg    = { r = 0.05, g = 0.15, b = 0.1,  a = 0.9 },
}

local function rgba(c) return { c.r, c.g, c.b, c.a } end

-- Display state
local state = {
  gpu = nil, screen = nil, enabled = false,
  offsetX = 0, offsetY = 0, zoom = 1.0,
  controller = nil, lastScanResult = nil,
}

local mapClickZones = {}
local panelButtons = {}

-- Selection
local selection = {
  type = nil, data = nil, controller = nil,
}

-- Persistent train flags (keyed by trainId)
local trainFlags = {}   -- trainId → { priority=bool, noReverse=bool }

-- Storage zone stations (keyed by station id)
local storageZones = {} -- stationId → true

-- Timetable editor state
local ttEditor = {
  active = false,
  trainId = nil,
  trainName = nil,
  stops = {},  -- ordered { stationName, stationId }
}

-- Forced route editor state
local routeEditor = {
  active = false,
  trainId = nil,
  trainName = nil,
  switches = {},  -- ordered { switchId, position, controllerId }
}

-- ============================================================================
-- State persistence (storage zones, train flags)
-- ============================================================================

local statePath = nil

local function saveState()
  if not statePath then return end
  local ok, err = pcall(function()
    local f = filesystem.open(statePath, "w")
    if not f then return end
    f:write("return {\n")
    f:write("  trainFlags = {\n")
    for id, flags in pairs(trainFlags) do
      f:write("    [" .. string.format("%q", id) .. "] = {")
      f:write(" priority = " .. tostring(flags.priority or false))
      f:write(", noReverse = " .. tostring(flags.noReverse or false))
      f:write(" },\n")
    end
    f:write("  },\n")
    f:write("  storageZones = {\n")
    for id, _ in pairs(storageZones) do
      f:write("    [" .. string.format("%q", id) .. "] = true,\n")
    end
    f:write("  },\n")
    f:write("}\n")
    f:close()
  end)
  if not ok then
    print("[TRAIN_MAP] Failed to save state: " .. tostring(err))
  end
end

local function loadState()
  if not statePath then return end
  if not filesystem.exists(statePath) then return end
  local ok, data = pcall(filesystem.doFile, statePath)
  if ok and type(data) == "table" then
    trainFlags = data.trainFlags or {}
    storageZones = data.storageZones or {}
  end
end

-- ============================================================================
-- Initialization
-- ============================================================================

function TrainMap.init(gpu, screen, options)
  if not gpu or not screen then
    print("[TRAIN_MAP] No GPU T2/Screen - map disabled")
    return false
  end
  options = options or {}
  SCREEN_W = options.screenWidth or SCREEN_W
  SCREEN_H = options.screenHeight or SCREEN_H
  CONTENT_W = SCREEN_W - 2 * MARGIN
  CONTENT_H = SCREEN_H - 2 * MARGIN

  local drivePath = options.drivePath or DRIVE_PATH
  if drivePath then
    statePath = drivePath .. "/train_map_state.lua"
    loadState()
  end

  state.gpu = gpu
  state.screen = screen
  gpu:bindScreen(screen)
  state.enabled = true

  event.listen(gpu)
  event.registerListener(
    event.filter{event = "OnMouseDown", sender = gpu},
    function(e, sender, position, modifiers)
      if position then
        TrainMap.handleClick(position.x, position.y, modifiers)
      end
    end
  )

  print("[TRAIN_MAP] Map display initialized (" .. SCREEN_W .. "x" .. SCREEN_H .. ")")
  return true
end

function TrainMap.isEnabled() return state.enabled end

function TrainMap.setController(controller) state.controller = controller end

-- ============================================================================
-- Coordinate projection
-- ============================================================================

local function expandBounds(minX, maxX, minY, maxY, x, y)
  if x < minX then minX = x end
  if x > maxX then maxX = x end
  if y < minY then minY = y end
  if y > maxY then maxY = y end
  return minX, maxX, minY, maxY, true
end

local function buildWorldBounds(scanResult)
  local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
  local hasPoints = false

  if scanResult.stations then
    for _, st in ipairs(scanResult.stations) do
      if st.location then
        minX, maxX, minY, maxY, hasPoints = expandBounds(minX, maxX, minY, maxY, st.location.x or 0, st.location.y or 0)
      end
    end
  end
  if scanResult.trains then
    for _, td in ipairs(scanResult.trains) do
      if td.worldLocation then
        minX, maxX, minY, maxY, hasPoints = expandBounds(minX, maxX, minY, maxY, td.worldLocation.x or 0, td.worldLocation.y or 0)
      end
    end
  end
  if scanResult.railStates then
    for _, rs in pairs(scanResult.railStates) do
      for _, sig in ipairs(rs.signals or {}) do
        if sig.location then
          minX, maxX, minY, maxY, hasPoints = expandBounds(minX, maxX, minY, maxY, sig.location.x or 0, sig.location.y or 0)
        end
      end
      for _, sw in ipairs(rs.switches or {}) do
        if sw.location then
          minX, maxX, minY, maxY, hasPoints = expandBounds(minX, maxX, minY, maxY, sw.location.x or 0, sw.location.y or 0)
        end
      end
      for _, seg in ipairs(rs.tracks or {}) do
        if seg.startLocation then
          minX, maxX, minY, maxY, hasPoints = expandBounds(minX, maxX, minY, maxY, seg.startLocation.x or 0, seg.startLocation.y or 0)
        end
        if seg.endLocation then
          minX, maxX, minY, maxY, hasPoints = expandBounds(minX, maxX, minY, maxY, seg.endLocation.x or 0, seg.endLocation.y or 0)
        end
        for _, wp in ipairs(seg.waypoints or {}) do
          minX, maxX, minY, maxY, hasPoints = expandBounds(minX, maxX, minY, maxY, wp.x or 0, wp.y or 0)
        end
      end
    end
  end

  if not hasPoints then return { minX = 0, maxX = 1000, minY = 0, maxY = 1000 } end
  local padX = math.max((maxX - minX) * 0.1, 500)
  local padY = math.max((maxY - minY) * 0.1, 500)
  return { minX = minX - padX, maxX = maxX + padX, minY = minY - padY, maxY = maxY + padY }
end

local function worldToScreen(bounds, wx, wy)
  local sx = MARGIN + ((wx - bounds.minX) / (bounds.maxX - bounds.minX)) * CONTENT_W
  local sy = MARGIN + ((wy - bounds.minY) / (bounds.maxY - bounds.minY)) * CONTENT_H
  return sx, sy
end

-- ============================================================================
-- Drawing helpers
-- ============================================================================

local function drawLine(gpu, x1, y1, x2, y2, thickness, color)
  gpu:drawLines({ { x = x1, y = y1 }, { x = x2, y = y2 } }, thickness, color)
end

local function drawCircle(gpu, cx, cy, radius, color)
  gpu:drawRect({ x = cx - radius, y = cy - radius }, { x = radius * 2, y = radius * 2 }, color, "", 0)
end

local function drawLabel(gpu, x, y, text, size, color, mono)
  gpu:drawText({ x = x, y = y }, text, size or 12, color, mono or true)
end

local function drawPolyline(gpu, points, thickness, color)
  if #points < 2 then return end
  for i = 1, #points - 1 do
    drawLine(gpu, points[i].x, points[i].y, points[i + 1].x, points[i + 1].y, thickness, color)
  end
end

--- Draw a button in the selection panel. ctx.py is advanced automatically.
--- ctx = { pX, pW, py, btnH }
local function drawPanelButton(gpu, ctx, label, action, color, actionData)
  gpu:drawRect({ x = ctx.pX + 6, y = ctx.py }, { x = ctx.pW - 12, y = ctx.btnH }, rgba(C.buttonBg), "", 0)
  drawLabel(gpu, ctx.pX + 12, ctx.py + 4, label, 11, color or rgba(C.buttonText), true)
  table.insert(panelButtons, { x = ctx.pX + 6, y = ctx.py, w = ctx.pW - 12, h = ctx.btnH, action = action, actionData = actionData })
  ctx.py = ctx.py + ctx.btnH + 4
end

local function buildSegmentPolyline(bounds, startLoc, endLoc, waypoints)
  local pts = {}
  if startLoc then
    local sx, sy = worldToScreen(bounds, startLoc.x, startLoc.y)
    table.insert(pts, { x = sx, y = sy })
  end
  if waypoints then
    for _, wp in ipairs(waypoints) do
      local wx, wy = worldToScreen(bounds, wp.x, wp.y)
      table.insert(pts, { x = wx, y = wy })
    end
  end
  if endLoc then
    local ex, ey = worldToScreen(bounds, endLoc.x, endLoc.y)
    table.insert(pts, { x = ex, y = ey })
  end
  return pts
end

local function drawArrow(gpu, x1, y1, x2, y2, color)
  local dx = x2 - x1
  local dy = y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  local mx = (x1 + x2) / 2
  local my = (y1 + y2) / 2
  local ux = dx / len
  local uy = dy / len
  local arrowLen = 8
  local arrowW = 4
  local tipX = mx + ux * arrowLen
  local tipY = my + uy * arrowLen
  gpu:drawLines({
    { x = mx - uy * arrowW, y = my + ux * arrowW },
    { x = tipX, y = tipY },
    { x = mx + uy * arrowW, y = my - ux * arrowW },
  }, 2, color)
end

-- ============================================================================
-- Main render
-- ============================================================================

function TrainMap.render(scanResult)
  if not state.enabled then return end
  if not scanResult then return end
  state.lastScanResult = scanResult

  local gpu = state.gpu
  mapClickZones = {}
  panelButtons = {}

  -- Refresh selection.data from current scanResult so panel always shows live values
  if selection.type and selection.data then
    local found = false
    if selection.type == "train" and scanResult.trains then
      for _, td in ipairs(scanResult.trains) do
        if td.trainId == selection.data.trainId then
          selection.data = td; found = true; break
        end
      end
    elseif selection.type == "station" and scanResult.stations then
      for _, st in ipairs(scanResult.stations) do
        if st.id == selection.data.id then
          selection.data = st; found = true; break
        end
      end
    elseif (selection.type == "signal" or selection.type == "switch") and scanResult.railStates then
      for ctrlId, ctrlData in pairs(scanResult.railStates) do
        local list = selection.type == "signal" and (ctrlData.signals or {}) or (ctrlData.switches or {})
        for _, elem in ipairs(list) do
          if elem.id == selection.data.id then
            selection.data = elem; selection.controller = ctrlId; found = true; break
          end
        end
        if found then break end
      end
    end
    if not found then
      selection.type = nil; selection.data = nil; selection.controller = nil
    end
  end

  local bounds = buildWorldBounds(scanResult)

  gpu:drawRect({ x = 0, y = 0 }, { x = SCREEN_W, y = SCREEN_H }, rgba(C.bg), "", 0)
  local titleText = "RAILROAD NETWORK MAP"
  local titleColor = rgba(C.station)
  if ttEditor.active then
    titleText = "TIMETABLE EDITOR: " .. (ttEditor.trainName or "")
    titleColor = rgba(C.ttEdit)
  elseif routeEditor.active then
    titleText = "FORCED ROUTE: " .. (routeEditor.trainName or "")
    titleColor = rgba(C.switchForce)
  end
  drawLabel(gpu, MARGIN, 10, titleText, 18, titleColor, true)

  -- Build active switch trackId lookup for highlighting
  local activeTrackIds = {}
  if scanResult.railStates then
    for _, rs in pairs(scanResult.railStates) do
      for _, sw in ipairs(rs.switches or {}) do
        if sw.connections then
          for _, conn in ipairs(sw.connections) do
            if conn.trackId and conn.index == sw.position then
              activeTrackIds[conn.trackId] = true
            end
          end
        end
      end
    end
  end

  -- ======================================================================
  -- 1. Draw ALL track segments from rail_controller BFS walk
  -- ======================================================================

  local hasRailData = false
  local drawnTrackIds = {}
  if scanResult.railStates then
    for _, ctrlData in pairs(scanResult.railStates) do
      for _, seg in ipairs(ctrlData.tracks or {}) do
        if seg.startLocation and seg.endLocation then
          local tid = seg.trackId
          if not tid or not drawnTrackIds[tid] then
            if tid then drawnTrackIds[tid] = true end
            hasRailData = true
            local pts = buildSegmentPolyline(bounds, seg.startLocation, seg.endLocation, seg.waypoints)
            local isActive = tid and activeTrackIds[tid]
            local segColor = isActive and rgba(C.trackActive) or rgba(C.track)
            local thick = isActive and 3 or 2
            drawPolyline(gpu, pts, thick, segColor)
          end
        end
      end
    end
  end

  -- Fallback: topology edges when no rail_controller
  if not hasRailData and scanResult.topologyEdges then
    for _, edge in ipairs(scanResult.topologyEdges) do
      local x1, y1 = worldToScreen(bounds, edge.fromLocation.x, edge.fromLocation.y)
      local x2, y2 = worldToScreen(bounds, edge.toLocation.x, edge.toLocation.y)
      drawLine(gpu, x1, y1, x2, y2, 2, rgba(C.trackFallback))
      drawArrow(gpu, x1, y1, x2, y2, rgba(C.arrow))
    end
  end

  -- ======================================================================
  -- 2. Draw rail element icons (signals, switches)
  -- ======================================================================

  if scanResult.railStates then
    for ctrlIdentity, ctrlData in pairs(scanResult.railStates) do
      for _, sig in ipairs(ctrlData.signals or {}) do
        if sig.location then
          local sx, sy = worldToScreen(bounds, sig.location.x, sig.location.y)
          local sigColor
          if sig.aspect == 1 then sigColor = rgba(C.signalClear)
          elseif sig.aspect == 2 then sigColor = rgba(C.signalStop)
          elseif sig.aspect == 3 then sigColor = rgba(C.signalDock)
          else sigColor = rgba(C.signalUnk) end

          local isSelected = selection.type == "signal" and selection.data and selection.data.id == sig.id
          local r = isSelected and 8 or 5
          drawCircle(gpu, sx, sy, r, isSelected and rgba(C.selected) or sigColor)

          table.insert(mapClickZones, {
            x = sx - 10, y = sy - 10, w = 20, h = 20,
            type = "signal", data = sig, controller = ctrlIdentity,
          })
        end
      end

      for _, sw in ipairs(ctrlData.switches or {}) do
        if sw.location then
          local sx, sy = worldToScreen(bounds, sw.location.x, sw.location.y)
          local isSelected = selection.type == "switch" and selection.data and selection.data.id == sw.id
          local swColor = isSelected and rgba(C.selected) or rgba(C.switchNorm)
          local sz = isSelected and 8 or 6
          gpu:drawRect({ x = sx - sz, y = sy - sz }, { x = sz * 2, y = sz * 2 }, swColor, "", 45)

          table.insert(mapClickZones, {
            x = sx - 12, y = sy - 12, w = 24, h = 24,
            type = "switch", data = sw, controller = ctrlIdentity,
          })
        end
      end
    end
  end

  -- ======================================================================
  -- 3. Draw stations
  -- ======================================================================

  if scanResult.stations then
    for _, st in ipairs(scanResult.stations) do
      if st.location then
        local sx, sy = worldToScreen(bounds, st.location.x, st.location.y)
        local isSelected = selection.type == "station" and selection.data and selection.data.id == st.id
        local isStorage = storageZones[st.id] ~= nil
        local isTtTarget = false
        if ttEditor.active then
          for _, s in ipairs(ttEditor.stops) do
            if s.stationId == st.id then isTtTarget = true; break end
          end
        end

        local boxW = 160
        local cargoCount = 0
        for _, plat in ipairs(st.platforms or {}) do
          if plat.isCargo then cargoCount = cargoCount + 1 end
        end
        local boxH = 24 + cargoCount * 14
        local boxX = sx - boxW / 2
        local boxY = sy - 12

        if isSelected then
          gpu:drawRect({ x = boxX - 2, y = boxY - 2 }, { x = boxW + 4, y = boxH + 4 }, rgba(C.selected), "", 0)
        elseif isTtTarget then
          gpu:drawRect({ x = boxX - 2, y = boxY - 2 }, { x = boxW + 4, y = boxH + 4 }, rgba(C.ttEdit), "", 0)
        end

        local bgColor = isStorage and rgba(C.storageBg) or rgba(C.stationBg)
        gpu:drawRect({ x = boxX, y = boxY }, { x = boxW, y = boxH }, bgColor, "", 0)

        local name = st.name
        if #name > 20 then name = name:sub(1, 18) .. ".." end
        local nameColor = isStorage and rgba(C.unloading) or rgba(C.station)
        local prefix = ""
        if isStorage then prefix = "[S] " end
        if st.isDeadEnd then prefix = prefix .. "[D] " end
        drawLabel(gpu, boxX + 4, boxY + 2, prefix .. name, 12, nameColor, true)

        local pRow = boxY + 18
        for pIdx, plat in ipairs(st.platforms or {}) do
          if plat.isCargo then
            local mode = plat.isInLoadMode and "Load" or "Unload"
            local modeColor = plat.isInLoadMode and rgba(C.loading) or rgba(C.unloading)
            local inFlow = plat.inputFlow or 0
            local outFlow = plat.outputFlow or 0
            local isActive = inFlow > 0 or outFlow > 0
            local statusStr = isActive and (plat.isInLoadMode and "LD" or "UL") or "--"
            local flowVal = plat.isInLoadMode and inFlow or outFlow
            drawLabel(gpu, boxX + 6, pRow,
              "P" .. pIdx .. ":" .. mode .. " [" .. statusStr .. "] " .. string.format("%.0f/m", flowVal),
              9, modeColor, true)
            pRow = pRow + 14
          end
        end

        table.insert(mapClickZones, {
          x = boxX, y = boxY, w = boxW, h = boxH,
          type = "station", data = st,
        })
      end
    end
  end

  -- ======================================================================
  -- 4. Draw trains
  -- ======================================================================

  if scanResult.trains then
    for _, td in ipairs(scanResult.trains) do
      local sx, sy
      if td.worldLocation then sx, sy = worldToScreen(bounds, td.worldLocation.x, td.worldLocation.y) end

      if sx and sy then
        local isSelected = selection.type == "train" and selection.data and selection.data.trainId == td.trainId
        local flags = trainFlags[td.trainId] or {}
        local trainColor = td.isSelfDriving and rgba(C.trainIcon) or rgba(C.signalDock)
        if td.selfDrivingError and td.selfDrivingError ~= 0 then trainColor = rgba(C.signalStop) end

        local iconSize = isSelected and 8 or 6
        if isSelected then
          gpu:drawRect({ x = sx - iconSize - 2, y = sy - iconSize - 2 }, { x = (iconSize + 2) * 2, y = (iconSize + 2) * 2 }, rgba(C.selected), "", 0)
        end
        gpu:drawRect({ x = sx - iconSize, y = sy - iconSize }, { x = iconSize * 2, y = iconSize * 2 }, trainColor, "", 0)

        -- Badges
        local badgeX = sx - iconSize - 8
        if flags.priority then drawCircle(gpu, badgeX, sy - 4, 3, rgba(C.priority)); badgeX = badgeX - 8 end
        if flags.noReverse then drawCircle(gpu, badgeX, sy - 4, 3, rgba(C.noReverse)) end

        local pausedSet = state.controller and state.controller.getPausedByPriority and state.controller.getPausedByPriority() or {}
        local isPaused = pausedSet[td.trainId]

        local name = td.name
        if #name > 16 then name = name:sub(1, 14) .. ".." end
        drawLabel(gpu, sx + 10, sy - 8, name, 11, isPaused and rgba(C.signalStop) or rgba(C.trainLabel), true)
        drawLabel(gpu, sx + 10, sy + 4, string.format("%.0f km/h", math.abs(td.speed or 0) * 0.036), 9, rgba(C.dim), true)

        if isPaused then
          drawLabel(gpu, sx + 10, sy + 16, "PAUSED (Priority)", 8, rgba(C.signalStop), true)
        elseif td.isDocked then
          drawLabel(gpu, sx + 10, sy + 16, "DOCKED: " .. (td.dockStateLabel or ""), 8, rgba(C.loading), true)
        end

        drawLabel(gpu, sx + 10, sy + 28, (td.locomotiveCount or 0) .. "L " .. (td.freightCarCount or 0) .. "W", 8, rgba(C.dim), true)

        table.insert(mapClickZones, { x = sx - 10, y = sy - 10, w = 20, h = 20, type = "train", data = td })
      end
    end
  end

  -- ======================================================================
  -- 5. Stats overlay
  -- ======================================================================

  local statsY = MARGIN + 34
  local stationCount = scanResult.stations and #scanResult.stations or 0
  local trainCount = scanResult.trains and #scanResult.trains or 0
  local railCtrlCount, sigCount, swCount, trkCount = 0, 0, 0, 0
  if scanResult.railStates then
    for _, rs in pairs(scanResult.railStates) do
      railCtrlCount = railCtrlCount + 1
      sigCount = sigCount + #(rs.signals or {})
      swCount = swCount + #(rs.switches or {})
      trkCount = trkCount + #(rs.tracks or {})
    end
  end

  drawLabel(gpu, MARGIN, statsY, trainCount .. " trains  " .. stationCount .. " stations  " .. trkCount .. " tracks", 11, rgba(C.text), true)
  if railCtrlCount > 0 then
    drawLabel(gpu, MARGIN, statsY + 14, railCtrlCount .. " rail ctrl  " .. sigCount .. " signals  " .. swCount .. " switches", 11, rgba(C.text), true)
  else
    drawLabel(gpu, MARGIN, statsY + 14, "No rail_controller connected", 10, rgba(C.dim), true)
  end

  -- ======================================================================
  -- 5b. Train navigation bar
  -- ======================================================================

  if trainCount > 0 and not ttEditor.active and not routeEditor.active then
    local navY = statsY + 32
    local navBtnW = 70
    local navBtnH = 18

    gpu:drawRect({ x = MARGIN, y = navY - 2 }, { x = navBtnW, y = navBtnH }, rgba(C.buttonBg), "", 0)
    drawLabel(gpu, MARGIN + 8, navY, "[< Prev]", 11, rgba(C.buttonText), true)
    table.insert(panelButtons, { x = MARGIN, y = navY - 2, w = navBtnW, h = navBtnH, action = "nav_prev_train" })

    local nameX = MARGIN + navBtnW + 10
    local navTrainName = "No train selected"
    local navTrainColor = rgba(C.dim)
    if selection.type == "train" and selection.data then
      navTrainName = selection.data.name or "?"
      navTrainColor = rgba(C.trainLabel)
    end
    if #navTrainName > 28 then navTrainName = navTrainName:sub(1, 26) .. ".." end
    drawLabel(gpu, nameX, navY, "Train: " .. navTrainName, 11, navTrainColor, true)

    local nextBtnX = nameX + 260
    gpu:drawRect({ x = nextBtnX, y = navY - 2 }, { x = navBtnW, y = navBtnH }, rgba(C.buttonBg), "", 0)
    drawLabel(gpu, nextBtnX + 8, navY, "[Next >]", 11, rgba(C.buttonText), true)
    table.insert(panelButtons, { x = nextBtnX, y = navY - 2, w = navBtnW, h = navBtnH, action = "nav_next_train" })

    if selection.type == "train" then
      local deselX = nextBtnX + navBtnW + 10
      gpu:drawRect({ x = deselX, y = navY - 2 }, { x = 80, y = navBtnH }, rgba(C.buttonBg), "", 0)
      drawLabel(gpu, deselX + 6, navY, "[Deselect]", 10, rgba(C.dim), true)
      table.insert(panelButtons, { x = deselX, y = navY - 2, w = 80, h = navBtnH, action = "nav_deselect" })
    end
  end

  -- ======================================================================
  -- 6. Timetable editor sidebar (left, when active)
  -- ======================================================================

  if ttEditor.active then
    local ttX = MARGIN
    local ttY = MARGIN + 70
    local ttW = 240
    local lineH = 16
    local btnH = 22

    gpu:drawRect({ x = ttX, y = ttY }, { x = ttW, y = 20 + #ttEditor.stops * lineH + btnH * 2 + 20 }, rgba(C.ttEditBg), "", 0)
    gpu:drawRect({ x = ttX, y = ttY }, { x = ttW, y = 2 }, rgba(C.ttEdit), "", 0)

    local py = ttY + 4
    drawLabel(gpu, ttX + 6, py, "Stops (" .. #ttEditor.stops .. "):", 11, rgba(C.ttEdit), true)
    py = py + lineH + 2

    for i, s in ipairs(ttEditor.stops) do
      drawLabel(gpu, ttX + 10, py, i .. ". " .. s.stationName, 10, rgba(C.text), true)

      -- Remove button for each stop
      local rmX = ttX + ttW - 26
      gpu:drawRect({ x = rmX, y = py - 1 }, { x = 20, y = 14 }, rgba(C.signalStop), "", 0)
      drawLabel(gpu, rmX + 5, py, "X", 10, rgba(C.trainLabel), true)
      table.insert(panelButtons, { x = rmX, y = py - 1, w = 20, h = 14, action = "tt_remove_stop", actionData = i })
      py = py + lineH
    end

    py = py + 6
    gpu:drawRect({ x = ttX + 6, y = py }, { x = ttW - 12, y = btnH }, rgba(C.buttonBg), "", 0)
    drawLabel(gpu, ttX + 12, py + 4, "[ Apply Timetable ]", 11, rgba(C.ttEdit), true)
    table.insert(panelButtons, { x = ttX + 6, y = py, w = ttW - 12, h = btnH, action = "tt_apply" })
    py = py + btnH + 4

    gpu:drawRect({ x = ttX + 6, y = py }, { x = ttW - 12, y = btnH }, rgba(C.buttonBg), "", 0)
    drawLabel(gpu, ttX + 12, py + 4, "[ Cancel ]", 11, rgba(C.signalStop), true)
    table.insert(panelButtons, { x = ttX + 6, y = py, w = ttW - 12, h = btnH, action = "tt_cancel" })

    drawLabel(gpu, ttX + 6, py + btnH + 6, "Click stations to add stops", 8, rgba(C.dim), true)
  end

  -- ======================================================================
  -- 6b. Forced route editor sidebar (left, when active)
  -- ======================================================================

  if routeEditor.active then
    local reX = MARGIN
    local reY = MARGIN + 70
    local reW = 260
    local lineH = 16
    local btnH = 22

    gpu:drawRect({ x = reX, y = reY }, { x = reW, y = 20 + #routeEditor.switches * lineH + btnH * 2 + 20 }, rgba(C.ttEditBg), "", 0)
    gpu:drawRect({ x = reX, y = reY }, { x = reW, y = 2 }, rgba(C.switchForce), "", 0)

    local py = reY + 4
    drawLabel(gpu, reX + 6, py, "Switches (" .. #routeEditor.switches .. "):", 11, rgba(C.switchForce), true)
    py = py + lineH + 2

    for i, sw in ipairs(routeEditor.switches) do
      drawLabel(gpu, reX + 10, py, i .. ". " .. (sw.switchId or "?"):sub(-8) .. " → pos " .. sw.position, 10, rgba(C.text), true)
      local rmX = reX + reW - 26
      gpu:drawRect({ x = rmX, y = py - 1 }, { x = 20, y = 14 }, rgba(C.signalStop), "", 0)
      drawLabel(gpu, rmX + 5, py, "X", 10, rgba(C.trainLabel), true)
      table.insert(panelButtons, { x = rmX, y = py - 1, w = 20, h = 14, action = "route_remove", actionData = i })
      py = py + lineH
    end

    py = py + 6
    gpu:drawRect({ x = reX + 6, y = py }, { x = reW - 12, y = btnH }, rgba(C.buttonBg), "", 0)
    drawLabel(gpu, reX + 12, py + 4, "[ Apply Forced Route ]", 11, rgba(C.switchForce), true)
    table.insert(panelButtons, { x = reX + 6, y = py, w = reW - 12, h = btnH, action = "route_apply" })
    py = py + btnH + 4

    gpu:drawRect({ x = reX + 6, y = py }, { x = reW - 12, y = btnH }, rgba(C.buttonBg), "", 0)
    drawLabel(gpu, reX + 12, py + 4, "[ Cancel ]", 11, rgba(C.signalStop), true)
    table.insert(panelButtons, { x = reX + 6, y = py, w = reW - 12, h = btnH, action = "route_cancel" })

    drawLabel(gpu, reX + 6, py + btnH + 6, "Click switches to add to route", 8, rgba(C.dim), true)
  end

  -- ======================================================================
  -- 7. Selection info panel (right side)
  -- ======================================================================

  if selection.type and selection.data then
    local pW = 290
    local pX = SCREEN_W - MARGIN - pW
    local pY = MARGIN + 60
    local lineH = 16
    local btnH = 24

    -- Pre-calculate panel height based on content type
    local pH = 160
    local d_tmp = selection.data
    if selection.type == "train" then
      pH = 320
    elseif selection.type == "station" then
      pH = 120
      local platLines = 0
      for _, plat in ipairs(d_tmp.platforms or {}) do
        if plat.isCargo then
          platLines = platLines + 3
          if plat.inventories then platLines = platLines + #plat.inventories end
        else
          platLines = platLines + 1
        end
      end
      pH = pH + platLines * lineH + btnH + 40
    elseif selection.type == "switch" then
      pH = 160 + ((d_tmp.numPositions or 0) + 1) * (btnH + 4) + 20
    elseif selection.type == "signal" then
      pH = 160
    end

    gpu:drawRect({ x = pX, y = pY }, { x = pW, y = pH }, rgba(C.panelBg), "", 0)
    gpu:drawRect({ x = pX, y = pY }, { x = pW, y = 2 }, rgba(C.panelBorder), "", 0)

    local py = pY + 6
    local d = selection.data
    local btnCtx = { pX = pX, pW = pW, py = 0, btnH = btnH }

    if selection.type == "train" then
      local flags = trainFlags[d.trainId] or {}
      drawLabel(gpu, pX + 6, py, "TRAIN: " .. (d.name or "?"), 13, rgba(C.trainLabel), true)
      py = py + lineH + 4
      drawLabel(gpu, pX + 6, py, "Speed: " .. string.format("%.0f km/h", math.abs(d.speed or 0) * 0.036), 10, rgba(C.text), true)
      py = py + lineH
      drawLabel(gpu, pX + 6, py, "Autopilot: " .. (d.isSelfDriving and "ON" or "OFF"), 10, d.isSelfDriving and rgba(C.signalClear) or rgba(C.signalStop), true)
      py = py + lineH
      drawLabel(gpu, pX + 6, py, "Status: " .. (d.dockStateLabel or (d.isMoving and "Moving" or "Idle")), 10, rgba(C.text), true)
      py = py + lineH
      drawLabel(gpu, pX + 6, py, "Wagons: " .. (d.locomotiveCount or 0) .. "L " .. (d.freightCarCount or 0) .. "W", 10, rgba(C.dim), true)
      py = py + lineH
      if d.nextStationName then
        drawLabel(gpu, pX + 6, py, "Next: " .. d.nextStationName, 10, rgba(C.station), true)
        py = py + lineH
      end
      if d.hasTimeTable then
        drawLabel(gpu, pX + 6, py, "Stops: " .. (d.currentStop or "?") .. "/" .. (d.totalStops or "?"), 10, rgba(C.dim), true)
        py = py + lineH
      end
      if flags.priority then
        drawLabel(gpu, pX + 6, py, "PRIORITY", 10, rgba(C.priority), true)
        py = py + lineH
      end
      if flags.noReverse then
        drawLabel(gpu, pX + 6, py, "NO-REVERSE", 10, rgba(C.noReverse), true)
        py = py + lineH
      end
      local pausedSet = state.controller and state.controller.getPausedByPriority and state.controller.getPausedByPriority() or {}
      if pausedSet[d.trainId] then
        drawLabel(gpu, pX + 6, py, "PAUSED (Priority yield)", 10, rgba(C.signalStop), true)
        py = py + lineH
      end
      py = py + 6

      btnCtx.py = py
      drawPanelButton(gpu, btnCtx, d.isSelfDriving and "[ Disable Autopilot ]" or "[ Enable Autopilot ]", "toggle_autopilot")
      drawPanelButton(gpu, btnCtx, "[ Edit Timetable ]", "edit_timetable")
      drawPanelButton(gpu, btnCtx, "[ Edit Forced Route ]", "edit_forced_route")
      drawPanelButton(gpu, btnCtx, "[ Clear Timetable ]", "clear_timetable")
      drawPanelButton(gpu, btnCtx, flags.priority and "[ Remove Priority ]" or "[ Set Priority ]", "toggle_priority")
      drawPanelButton(gpu, btnCtx, flags.noReverse and "[ Allow Reverse ]" or "[ Lock Direction ]", "toggle_no_reverse")
      drawPanelButton(gpu, btnCtx, "[ Send to Storage ]", "send_to_storage")
      py = btnCtx.py

    elseif selection.type == "station" then
      local isStorage = storageZones[d.id] ~= nil
      drawLabel(gpu, pX + 6, py, "STATION: " .. (d.name or "?"), 13, rgba(C.station), true)
      py = py + lineH + 4
      drawLabel(gpu, pX + 6, py, "Platforms: " .. (d.platformCount or 0), 10, rgba(C.text), true)
      py = py + lineH
      if isStorage then
        drawLabel(gpu, pX + 6, py, "STORAGE ZONE", 10, rgba(C.unloading), true)
        py = py + lineH
      end
      if d.isDeadEnd then
        drawLabel(gpu, pX + 6, py, "DEAD END (Turnaround)", 10, rgba(C.noReverse), true)
        py = py + lineH
      end
      for pIdx, plat in ipairs(d.platforms or {}) do
        if plat.isCargo then
          local mode = plat.isInLoadMode and "LOAD" or "UNLOAD"
          local modeColor = plat.isInLoadMode and rgba(C.loading) or rgba(C.unloading)
          drawLabel(gpu, pX + 10, py, "P" .. pIdx .. ": " .. mode, 10, modeColor, true)
          py = py + lineH
          local pInFlow = plat.inputFlow or 0
          local pOutFlow = plat.outputFlow or 0
          local pActive = pInFlow > 0 or pOutFlow > 0
          local statusStr = pActive and (plat.isInLoadMode and "Loading" or "Unloading") or "Idle"
          drawLabel(gpu, pX + 18, py, statusStr, 9, rgba(C.dim), true)
          py = py + lineH
          local inFlow = plat.inputFlow or 0
          local outFlow = plat.outputFlow or 0
          drawLabel(gpu, pX + 18, py, string.format("In:%.0f/m  Out:%.0f/m", inFlow, outFlow), 9, rgba(C.dim), true)
          py = py + lineH
          if plat.inventories then
            for invIdx, inv in ipairs(plat.inventories) do
              local usedSlots = 0
              for _, stack in ipairs(inv.stacks or {}) do
                if stack.count and stack.count > 0 then usedSlots = usedSlots + 1 end
              end
              drawLabel(gpu, pX + 22, py, "Inv" .. invIdx .. ": " .. usedSlots .. "/" .. (inv.size or 0) .. " slots", 8, rgba(C.dim), true)
              py = py + lineH
            end
          end
        else
          drawLabel(gpu, pX + 10, py, "P" .. pIdx .. ": Empty platform", 10, rgba(C.dim), true)
          py = py + lineH
        end
      end
      py = py + 6
      btnCtx.py = py
      drawPanelButton(gpu, btnCtx, isStorage and "[ Unmark Storage Zone ]" or "[ Mark as Storage Zone ]", "toggle_storage")
      py = btnCtx.py

    elseif selection.type == "switch" then
      drawLabel(gpu, pX + 6, py, "SWITCH", 13, rgba(C.switchNorm), true)
      py = py + lineH + 4
      drawLabel(gpu, pX + 6, py, "Position: " .. (d.position or 0) .. "/" .. (d.numPositions or 0), 10, rgba(C.text), true)
      py = py + lineH
      if d.nick and d.nick ~= "" then
        drawLabel(gpu, pX + 6, py, "Name: " .. d.nick, 10, rgba(C.dim), true)
        py = py + lineH
      end
      py = py + 6
      btnCtx.py = py
      drawPanelButton(gpu, btnCtx, "[ Toggle Position ]", "toggle_switch")
      if d.numPositions and d.numPositions > 0 then
        for ci = 0, d.numPositions - 1 do
          local label = "[ Force Pos " .. ci .. " ]"
          if ci == d.position then label = label .. " (current)" end
          drawPanelButton(gpu, btnCtx, label, "force_switch_pos", nil, ci)
        end
      end
      py = btnCtx.py

    elseif selection.type == "signal" then
      drawLabel(gpu, pX + 6, py, "SIGNAL: " .. (d.aspectLabel or "?"), 13,
        d.aspect == 1 and rgba(C.signalClear)
        or (d.aspect == 2 and rgba(C.signalStop) or rgba(C.signalDock)), true)
      py = py + lineH + 4
      drawLabel(gpu, pX + 6, py, "ID: " .. (d.id or "?"):sub(-8), 9, rgba(C.dim), true)
      py = py + lineH
      if d.nick and d.nick ~= "" then
        drawLabel(gpu, pX + 6, py, "Name: " .. d.nick, 10, rgba(C.dim), true)
        py = py + lineH
      end
      drawLabel(gpu, pX + 6, py, "Bidir: " .. (d.isBiDirectional and "Yes" or "No"), 10, rgba(C.text), true)
      py = py + lineH
      drawLabel(gpu, pX + 6, py, "Block: " .. (d.blockOccupied and "OCCUPIED" or "Clear"), 10,
        d.blockOccupied and rgba(C.signalStop) or rgba(C.signalClear), true)
    end

    drawLabel(gpu, pX + 6, pY + pH - 18, "Click empty area to deselect", 8, rgba(C.dim), true)
  end

  -- Timestamp
  local totalSec = math.floor((computer.millis() or 0) / 1000)
  local timeStr = string.format("%02d:%02d:%02d", math.floor(totalSec / 3600) % 24, math.floor(totalSec / 60) % 60, totalSec % 60)
  drawLabel(gpu, SCREEN_W - MARGIN - 80, SCREEN_H - MARGIN - 14, timeStr, 12, rgba(C.text), true)

  gpu:flush()
end

-- ============================================================================
-- Click handling with overlap cycling
-- ============================================================================

function TrainMap.handleClick(posX, posY, modifiers)
  -- Panel buttons first
  for _, btn in ipairs(panelButtons) do
    if posX >= btn.x and posX <= btn.x + btn.w and posY >= btn.y and posY <= btn.y + btn.h then
      TrainMap.executeAction(btn.action, btn.actionData)
      TrainMap.immediateRefresh()
      return
    end
  end

  -- Timetable editor: clicking a station adds it as a stop
  if ttEditor.active then
    for _, zone in ipairs(mapClickZones) do
      if zone.type == "station" and posX >= zone.x and posX <= zone.x + zone.w and posY >= zone.y and posY <= zone.y + zone.h then
        table.insert(ttEditor.stops, { stationName = zone.data.name, stationId = zone.data.id })
        TrainMap.immediateRefresh()
        return
      end
    end
  end

  -- Route editor: clicking a switch adds it with current+1 position (cycles through)
  if routeEditor.active then
    for _, zone in ipairs(mapClickZones) do
      if zone.type == "switch" and posX >= zone.x and posX <= zone.x + zone.w and posY >= zone.y and posY <= zone.y + zone.h then
        local nextPos = ((zone.data.position or 0) + 1) % math.max(zone.data.numPositions or 2, 2)
        table.insert(routeEditor.switches, {
          switchId = zone.data.id,
          position = nextPos,
          controllerId = zone.controller,
        })
        TrainMap.immediateRefresh()
        return
      end
    end
  end

  -- Collect all matching zones (supports overlapping elements)
  local matchingZones = {}
  for _, zone in ipairs(mapClickZones) do
    if posX >= zone.x and posX <= zone.x + zone.w and posY >= zone.y and posY <= zone.y + zone.h then
      table.insert(matchingZones, zone)
    end
  end

  if #matchingZones > 0 then
    local currentIdx = 0
    for i, zone in ipairs(matchingZones) do
      if selection.type == zone.type and selection.data then
        local sid = selection.data.id or selection.data.trainId
        local zid = zone.data.id or zone.data.trainId
        if sid and zid and sid == zid then
          currentIdx = i
          break
        end
      end
    end
    local nextIdx = (currentIdx % #matchingZones) + 1
    local zone = matchingZones[nextIdx]
    selection.type = zone.type
    selection.data = zone.data
    selection.controller = zone.controller
    TrainMap.immediateRefresh()
    return
  end

  -- Empty area: deselect
  selection.type = nil
  selection.data = nil
  selection.controller = nil
  TrainMap.immediateRefresh()
end

--- Signal that the display needs refreshing (render happens on next task poll).
function TrainMap.immediateRefresh()
  if TrainMap.markDirty then TrainMap.markDirty() end
end

-- ============================================================================
-- Action execution
-- ============================================================================

function TrainMap.executeAction(action, actionData)
  local d = selection.data
  local scan = state.lastScanResult

  -- Timetable editor actions (don't require selection)
  if action == "tt_apply" then
    if state.controller and ttEditor.trainId and scan then
      -- Resolve station names to proxies via scanResult
      local stationProxies = {}
      if scan.stations then
        for _, st in ipairs(scan.stations) do
          stationProxies[st.id] = st.proxy
        end
      end
      local stops = {}
      for _, s in ipairs(ttEditor.stops) do
        local proxy = stationProxies[s.stationId]
        if proxy then table.insert(stops, { station = proxy, ruleSet = {} }) end
      end
      if #stops > 0 then
        state.controller.handleCommand({ action = "clear_timetable", trainId = ttEditor.trainId }, scan)
        for i, stop in ipairs(stops) do
          state.controller.addStop({ trainId = ttEditor.trainId }, stop.station, i - 1, stop.ruleSet)
        end
        -- Remove STORED: prefix if present since the train now has a mission
        if scan and scan.trains then
          for _, td in ipairs(scan.trains) do
            if td.trainId == ttEditor.trainId and td.name and td.name:find("^STORED:") then
              local cleanName = td.name:gsub("^STORED:", "")
              state.controller.handleCommand({ action = "rename", trainId = ttEditor.trainId, name = cleanName }, scan)
              break
            end
          end
        end
      end
    end
    ttEditor.active = false
    return
  end
  if action == "tt_cancel" then
    ttEditor.active = false
    return
  end
  if action == "tt_remove_stop" and actionData then
    table.remove(ttEditor.stops, actionData)
    return
  end
  if action == "route_apply" then
    if state.controller and routeEditor.trainId and #routeEditor.switches > 0 then
      local route = {}
      for _, sw in ipairs(routeEditor.switches) do
        table.insert(route, { switchId = sw.switchId, position = sw.position })
      end
      state.controller.handleCommand({
        action = "set_forced_route",
        trainId = routeEditor.trainId,
        route = route,
      }, scan)
    end
    routeEditor.active = false
    return
  end
  if action == "route_cancel" then
    routeEditor.active = false
    return
  end
  if action == "route_remove" and actionData then
    table.remove(routeEditor.switches, actionData)
    return
  end

  -- Train navigation (no selection required)
  if action == "nav_next_train" or action == "nav_prev_train" then
    if scan and scan.trains and #scan.trains > 0 then
      local trains = scan.trains
      local currentIdx = 0
      if selection.type == "train" and selection.data then
        for i, td in ipairs(trains) do
          if td.trainId == selection.data.trainId then currentIdx = i; break end
        end
      end
      local nextIdx
      if action == "nav_next_train" then
        nextIdx = (currentIdx % #trains) + 1
      else
        nextIdx = currentIdx <= 1 and #trains or (currentIdx - 1)
      end
      selection.type = "train"
      selection.data = trains[nextIdx]
      selection.controller = nil
    end
    return
  end
  if action == "nav_deselect" then
    selection.type = nil
    selection.data = nil
    selection.controller = nil
    return
  end

  if not d then return end

  if action == "toggle_autopilot" and selection.type == "train" then
    if state.controller then
      state.controller.handleCommand({ action = "toggle_autopilot", trainId = d.trainId }, scan)
    end

  elseif action == "edit_timetable" and selection.type == "train" then
    ttEditor.active = true
    ttEditor.trainId = d.trainId
    ttEditor.trainName = d.name
    ttEditor.stops = {}
    if d.hasTimeTable and d.timetableStops and d.totalStops then
      for idx = 0, d.totalStops - 1 do
        local stopName = d.timetableStops[idx]
        if stopName and scan and scan.stations then
          for _, st in ipairs(scan.stations) do
            if st.name == stopName then
              table.insert(ttEditor.stops, { stationName = stopName, stationId = st.id })
              break
            end
          end
        end
      end
    end

  elseif action == "edit_forced_route" and selection.type == "train" then
    routeEditor.active = true
    routeEditor.trainId = d.trainId
    routeEditor.trainName = d.name
    routeEditor.switches = {}

  elseif action == "clear_timetable" and selection.type == "train" then
    if state.controller then
      state.controller.handleCommand({ action = "clear_timetable", trainId = d.trainId }, scan)
    end

  elseif action == "toggle_priority" and selection.type == "train" then
    trainFlags[d.trainId] = trainFlags[d.trainId] or {}
    trainFlags[d.trainId].priority = not trainFlags[d.trainId].priority
    saveState()

  elseif action == "toggle_no_reverse" and selection.type == "train" then
    trainFlags[d.trainId] = trainFlags[d.trainId] or {}
    trainFlags[d.trainId].noReverse = not trainFlags[d.trainId].noReverse
    saveState()

  elseif action == "send_to_storage" and selection.type == "train" then
    TrainMap.sendTrainToStorage(d)

  elseif action == "toggle_switch" and selection.type == "switch" then
    if state.controller then
      state.controller.handleCommand({
        action = "toggle_switch", switchId = d.id, targetIdentity = selection.controller,
      }, scan)
    end

  elseif action == "force_switch_pos" and selection.type == "switch" and actionData then
    if state.controller then
      state.controller.handleCommand({
        action = "force_switch", switchId = d.id, position = actionData, targetIdentity = selection.controller,
      }, scan)
    end

  elseif action == "toggle_storage" and selection.type == "station" then
    if storageZones[d.id] then
      storageZones[d.id] = nil
    else
      storageZones[d.id] = true
    end
    saveState()
  end
end

-- ============================================================================
-- Storage zone: send train to first available storage station
-- ============================================================================

function TrainMap.sendTrainToStorage(trainData)
  local scan = state.lastScanResult
  if not scan or not state.controller then return end

  -- Find first storage zone station
  local storageSt = nil
  if scan.stations then
    for _, st in ipairs(scan.stations) do
      if storageZones[st.id] then
        storageSt = st
        break
      end
    end
  end

  if not storageSt then
    print("[TRAIN_MAP] No storage zone defined")
    return
  end

  -- 1. Clear existing timetable
  state.controller.handleCommand({ action = "clear_timetable", trainId = trainData.trainId }, scan)

  -- 2. Add storage station as only stop
  if storageSt.proxy then
    state.controller.addStop({ trainId = trainData.trainId }, storageSt.proxy, 0, {})
  end

  -- 3. Enable autopilot so it drives there
  state.controller.handleCommand({ action = "set_autopilot", trainId = trainData.trainId, enabled = true }, scan)

  -- 4. Rename with storage prefix (only if not already prefixed)
  local baseName = (trainData.name or "Train"):gsub("^STORED:", "")
  state.controller.handleCommand({ action = "rename", trainId = trainData.trainId, name = "STORED:" .. baseName }, scan)

  print("[TRAIN_MAP] Sending " .. (trainData.name or "?") .. " to storage: " .. storageSt.name)
end

-- ============================================================================
-- Public accessors for priority/flags (used by features/train.lua)
-- ============================================================================

function TrainMap.getTrainFlags() return trainFlags end
function TrainMap.getStorageZones() return storageZones end

return TrainMap
