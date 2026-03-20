-- modules/fluid_display.lua
-- Renders fluid network data on a GPU T1 screen.
--
-- Display modes (cycled via footer click):
--   "table"    - Tabular list of all elements with flow, fill, state
--   "topology" - 2D grid layout grouped by pipe network ID, ASCII schematic
--
-- Click behavior:
--   Table mode:   click on an element row to toggle it on/off
--   Topology mode: click on an element node to toggle it on/off
--
-- Console fallback for headless operation.

local FluidDisplay = {}

-- Forward declaration for click handler
local handleClick

-- Screen dimensions (GPU T1 character mode)
local W = 125
local H = 50

-- Color palette
local COLORS = {
  bg          = { 0.05, 0.05, 0.1, 1.0 },
  title       = { 0.2, 0.7, 1.0, 1.0 },
  text        = { 1.0, 1.0, 1.0, 1.0 },
  label       = { 0.6, 0.6, 0.6, 1.0 },
  dim         = { 0.4, 0.4, 0.4, 1.0 },
  separator   = { 0.3, 0.3, 0.4, 1.0 },
  groupName   = { 1.0, 0.8, 0.2, 1.0 },
  elemName    = { 0.4, 0.8, 1.0, 1.0 },
  pumpColor   = { 0.3, 0.7, 1.0, 1.0 },
  reservColor = { 0.4, 1.0, 0.6, 1.0 },
  valveColor  = { 1.0, 0.6, 0.3, 1.0 },
  extractColor= { 0.8, 0.5, 1.0, 1.0 },
  active      = { 0.3, 1.0, 0.4, 1.0 },
  inactive    = { 1.0, 0.3, 0.3, 1.0 },
  fillEmpty   = { 0.3, 0.3, 0.3, 1.0 },
  fillLow     = { 1.0, 0.3, 0.3, 1.0 },
  fillMid     = { 1.0, 0.8, 0.2, 1.0 },
  fillHigh    = { 0.3, 1.0, 0.4, 1.0 },
  fillFull    = { 0.2, 0.7, 1.0, 1.0 },
  flowPos     = { 0.3, 0.8, 1.0, 1.0 },
  flowNeg     = { 1.0, 0.5, 0.2, 1.0 },
  nodeBorder  = { 0.4, 0.5, 0.6, 1.0 },
  nodeActive  = { 0.15, 0.2, 0.15, 1.0 },
  nodeInactive= { 0.2, 0.1, 0.1, 1.0 },
  pipeLine    = { 0.3, 0.4, 0.5, 1.0 },
  prodHigh    = { 0.3, 1.0, 0.4, 1.0 },
  prodMid     = { 1.0, 0.8, 0.2, 1.0 },
  prodLow     = { 1.0, 0.3, 0.3, 1.0 },
  button      = { 0.15, 0.15, 0.25, 1.0 },
  buttonText  = { 0.8, 0.9, 1.0, 1.0 },
  buttonDim   = { 0.4, 0.5, 0.6, 1.0 },
  networkHdr  = { 0.6, 0.8, 1.0, 1.0 },
}

-- Display state
local state = {
  gpu = nil,
  screen = nil,
  enabled = false,
  displayMode = "table", -- "table", "topology", or "rules"
}

local DISPLAY_MODES = { "table", "topology", "rules" }

-- Sort modes for table view
local SORT_MODES = { "alpha", "fill_asc", "fill_desc", "type" }
local SORT_LABELS = { alpha = "A-Z", fill_asc = "Fill+", fill_desc = "Fill-", type = "Type" }
local currentSortIdx = 1

-- Pagination
local currentPage = 1
local totalPages = 1

-- Footer click zones: { x1, x2, action }
local footerButtons = {}

-- Table mode click zones: { y, element }
local tableClickZones = {}

-- Topology mode click zones: { x1, y1, x2, y2, element }
local topoClickZones = {}

-- Rules mode click zones: { y, action, ruleId }
local rulesClickZones = {}

-- Topology edit mode
local editState = {
  active = false,
  editTool = "move",       -- "move" or "link"
  selectedNodeId = nil,
  selectedNetId = nil,
  netList = {},
  netIdx = 1,
  modified = false,
}
local topoEditZones = {}
local EDIT_GRID_COLS = 6
local EDIT_GRID_ROWS = 7

-- Last scan + controller + rules + topology reference
local lastScanResult = nil
local controllerRef = nil
local rulesRef = nil  -- reference to FluidRules module
local topologyRef = nil -- reference to FluidTopology module

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the display.
-- @param gpu GPU T1 proxy
-- @param screen Screen proxy
-- @param options table - { displayMode, controller }
-- @return boolean
function FluidDisplay.init(gpu, screen, options)
  if not gpu or not screen then
    print("[FLUID_DSP] No GPU/Screen - console fallback")
    state.enabled = false
    return false
  end

  state.gpu = gpu
  state.screen = screen

  options = options or {}
  local dm = options.displayMode or "table"
  if dm == "table" or dm == "topology" then
    state.displayMode = dm
  else
    state.displayMode = "table"
  end
  controllerRef = options.controller or nil
  rulesRef = options.rules or nil
  topologyRef = options.topology or nil

  gpu:bindScreen(screen)
  gpu:setSize(W, H)
  state.enabled = true

  event.listen(gpu)
  if SIGNAL_HANDLERS then
    SIGNAL_HANDLERS["OnMouseDown"] = SIGNAL_HANDLERS["OnMouseDown"] or {}
    table.insert(SIGNAL_HANDLERS["OnMouseDown"], function(signal, sender, x, y, btn)
      if sender == state.gpu then
        handleClick(x, y, btn)
      end
    end)
  end

  print("[FLUID_DSP] Initialized (" .. W .. "x" .. H .. ", mode: " .. state.displayMode .. ")")
  return true
end

function FluidDisplay.isEnabled()
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
  if percent < 50 then return COLORS.fillMid end
  if percent < 90 then return COLORS.fillHigh end
  return COLORS.fillFull
end

local function getTypeColor(elemType)
  if elemType == "pump" then return COLORS.pumpColor end
  if elemType == "reservoir" then return COLORS.reservColor end
  if elemType == "valve" then return COLORS.valveColor end
  if elemType == "extractor" then return COLORS.extractColor end
  return COLORS.text
end

local function getTypeIcon(elemType)
  if elemType == "pump" then return "P" end
  if elemType == "reservoir" then return "T" end -- Tank
  if elemType == "valve" then return "V" end
  if elemType == "extractor" then return "E" end
  return "?"
end

local function getTypeLabel(elemType)
  if elemType == "pump" then return "Pump" end
  if elemType == "reservoir" then return "Tank" end
  if elemType == "valve" then return "Valve" end
  if elemType == "extractor" then return "Extr" end
  return "???"
end

--- Format a flow value from m3/s (API) to m3/min (game units).
local function formatFlow(val)
  if not val or val == 0 then return "0" end
  local perMin = val * 60
  if math.abs(perMin) >= 100 then
    return string.format("%.0f", perMin)
  elseif math.abs(perMin) >= 10 then
    return string.format("%.1f", perMin)
  end
  return string.format("%.2f", perMin)
end

--- Draw a fill bar.
local function drawFillBar(col, row, barWidth, percent)
  if row < 0 or row >= H then return barWidth + 2 end
  local gpu = state.gpu
  local filled = math.floor(barWidth * math.min(percent or 0, 100) / 100)
  local empty = barWidth - filled

  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col, row, "[")

  gpu:setForeground(table.unpack(getFillColor(percent or 0)))
  gpu:setText(col + 1, row, string.rep("#", filled))

  gpu:setForeground(table.unpack(COLORS.fillEmpty))
  gpu:setText(col + 1 + filled, row, string.rep("-", empty))

  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col + 1 + barWidth, row, "]")

  local pctText = string.format("%5.1f%%", percent or 0)
  gpu:setForeground(table.unpack(getFillColor(percent or 0)))
  gpu:setText(col + barWidth + 2, row, pctText)

  return col + barWidth + 2 + #pctText
end

-- ============================================================================
-- Table mode rendering
-- ============================================================================

--- Sort elements within each group for table display.
local function sortGroupElements(elements)
  local sorted = {}
  for i, e in ipairs(elements) do sorted[i] = e end
  local mode = SORT_MODES[currentSortIdx]
  if mode == "fill_asc" then
    table.sort(sorted, function(a, b)
      return (a.fillPercent or 0) < (b.fillPercent or 0)
    end)
  elseif mode == "fill_desc" then
    table.sort(sorted, function(a, b)
      return (a.fillPercent or 0) > (b.fillPercent or 0)
    end)
  elseif mode == "type" then
    local order = { pump = 1, reservoir = 2, valve = 3, extractor = 4 }
    table.sort(sorted, function(a, b)
      local oa = order[a.elementType] or 5
      local ob = order[b.elementType] or 5
      if oa ~= ob then return oa < ob end
      return (a.elementName or "") < (b.elementName or "")
    end)
  else -- alpha
    table.sort(sorted, function(a, b)
      return (a.elementName or "") < (b.elementName or "")
    end)
  end
  return sorted
end

--- Get a sorted copy of groupOrder based on current sort mode.
-- @param scanResult table
-- @return table - sorted array of group names
local function sortedGroupOrder(scanResult)
  local order = {}
  for _, name in ipairs(scanResult.groupOrder) do
    table.insert(order, name)
  end
  local sortMode = SORT_MODES[currentSortIdx]
  if sortMode == "fill_asc" then
    table.sort(order, function(a, b)
      local ga, gb = scanResult.groups[a], scanResult.groups[b]
      return (ga and ga.avgFillPercent or 0) < (gb and gb.avgFillPercent or 0)
    end)
  elseif sortMode == "fill_desc" then
    table.sort(order, function(a, b)
      local ga, gb = scanResult.groups[a], scanResult.groups[b]
      return (ga and ga.avgFillPercent or 0) > (gb and gb.avgFillPercent or 0)
    end)
  end
  -- alpha and type: groups stay in discovery order (alpha sorted elements inside)
  return order
end

--- Flatten all elements into an ordered list respecting group order,
--- with group headers inserted. Returns flat list + bounds.
local function flattenByGroup(scanResult)
  local flat = {}    -- { entry, ... } where entry = element OR group header
  local bounds = {}  -- { { groupName, startIdx, endIdx }, ... }
  local gOrder = sortedGroupOrder(scanResult)

  for _, gName in ipairs(gOrder) do
    local g = scanResult.groups[gName]
    if g and #g.elements > 0 then
      -- Group header marker
      local startIdx = #flat + 1
      table.insert(flat, { isGroupHeader = true, group = g })
      -- Sorted elements
      local sorted = sortGroupElements(g.elements)
      for _, e in ipairs(sorted) do
        table.insert(flat, { isGroupHeader = false, element = e })
      end
      table.insert(bounds, { groupName = gName, startIdx = startIdx, endIdx = #flat })
    end
  end
  return flat, bounds
end

--- Render overview stats bar.
local function renderOverview(scanResult, startRow)
  local row = startRow
  local s = scanResult.globalStats

  txt(1, row, "OVERVIEW", COLORS.title)
  txt(10, row, "  [" .. state.displayMode .. "]", COLORS.dim)
  row = row + 1

  local statsLine = string.format(
    "  Pumps:%d  Tanks:%d  Valves:%d  Extr:%d  Networks:%d  Groups:%d",
    s.pumpCount, s.reservoirCount, s.valveCount, s.extractorCount,
    s.networkCount, s.groupCount)
  txt(0, row, statsLine, COLORS.text)
  if s.defaultGroupCount and s.defaultGroupCount > 0 then
    local defText = "  Default:" .. s.defaultGroupCount
    txt(#statsLine + 1, row, defText, COLORS.fillLow)
  end
  row = row + 1

  drawSeparator(row)
  row = row + 1

  return row
end

-- Column positions (0-based) — shared between header and data rows.
local COL = {
  NAME     = 3,   -- 21 chars (indented 2 under group header)
  TYPE     = 25,  --  5 chars
  FLUID    = 31,  -- 11 chars
  FILL     = 43,  -- 20 chars (bar or flow)
  FLOW_IN  = 64,  -- 11 chars
  FLOW_OUT = 76,  -- 11 chars
  STATE    = 88,  --  4 chars (ON/OFF)
  RATE     = 94,  --  7 chars (Rate %)
}

--- Get a color for a productivity percentage.
local function getProdColor(pct)
  if pct >= 80 then return COLORS.prodHigh end
  if pct >= 40 then return COLORS.prodMid end
  return COLORS.prodLow
end

--- Render the table mode (grouped by group name, like container_scanner).
local function renderTable(scanResult, startRow)
  tableClickZones = {}
  local row = startRow

  -- Column header – positions match COL constants above.
  txt(COL.NAME,     row, string.format("%-21s", "Name"),      COLORS.dim)
  txt(COL.TYPE,     row, string.format("%-5s",  "Type"),      COLORS.dim)
  txt(COL.FLUID,    row, string.format("%-11s", "Fluid"),     COLORS.dim)
  txt(COL.FILL,     row, string.format("%-20s", "Fill"),      COLORS.dim)
  txt(COL.FLOW_IN,  row, string.format("%11s",  "In m3/min"), COLORS.dim)
  txt(COL.FLOW_OUT, row, string.format("%11s", "Out m3/min"), COLORS.dim)
  txt(COL.STATE,    row, string.format("%-4s",  "State"),     COLORS.dim)
  txt(COL.RATE,     row, string.format("%-7s",  "Rate %"),    COLORS.dim)
  row = row + 1

  -- Available rows for content
  local contentRows = H - row - 1
  if contentRows < 1 then return row end

  -- Build flattened list with group headers
  local flat, bounds = flattenByGroup(scanResult)
  local totalItems = #flat

  -- Pagination
  totalPages = math.max(1, math.ceil(totalItems / contentRows))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end

  local startIdx = (currentPage - 1) * contentRows + 1
  local endIdx = math.min(startIdx + contentRows - 1, totalItems)

  for i = startIdx, endIdx do
    if row >= H - 1 then break end
    local entry = flat[i]

    if entry.isGroupHeader then
      -- Group header row
      local g = entry.group
      local gName = g.name
      if #gName > 20 then gName = gName:sub(1, 18) .. ".." end
      txt(1, row, gName, COLORS.groupName)
      local groupInfo = string.format("  %dx", g.elementCount)
      txt(1 + #gName, row, groupInfo, COLORS.dim)
      -- Fluid type for the group
      if g.fluidType then
        local fLabel = g.fluidType.name or "?"
        if #fLabel > 11 then fLabel = fLabel:sub(1, 9) .. ".." end
        txt(1 + #gName + #groupInfo + 1, row, fLabel, COLORS.label)
      end
      -- Group avg fill (if group has reservoirs)
      if g.totalCapacity and g.totalCapacity > 0 then
        local avgPct = math.min(g.avgFillPercent or 0, 100)
        local avgStr = string.format("  avg %.1f%%", avgPct)
        local xPos = 1 + #gName + #groupInfo + 14
        txt(xPos, row, avgStr, getFillColor(avgPct))
      end
      row = row + 1
    else
      -- Element data row
      local e = entry.element

      -- Name (truncated, already stripped of spaces by parseNick)
      local name = e.elementName or "?"
      if #name > 20 then name = name:sub(1, 18) .. ".." end

      -- Type
      local typeLabel = getTypeLabel(e.elementType)

      -- Fluid name
      local fluidName = e.fluidType and e.fluidType.name or "-"
      if #fluidName > 11 then fluidName = fluidName:sub(1, 9) .. ".." end

      -- Flow values (already converted to m3/min by formatFlow)
      local flowIn, flowOut = "0", "0"
      if e.elementType == "reservoir" then
        flowIn = formatFlow(e.flowFill)
        flowOut = formatFlow(e.flowDrain)
      elseif e.elementType == "pump" or e.elementType == "valve" then
        flowIn = formatFlow(e.flow)
        flowOut = "-"
      else
        local totalIn, totalOut = 0, 0
        for _, conn in ipairs(e.pipeConnections or {}) do
          totalIn = totalIn + (conn.fluidBoxFlowFill or 0)
          totalOut = totalOut + (conn.fluidBoxFlowDrain or 0)
        end
        flowIn = formatFlow(totalIn)
        flowOut = formatFlow(totalOut)
      end

      -- Draw the row
      txt(COL.NAME, row, string.format("%-21s", name), COLORS.elemName)
      txt(COL.TYPE, row, string.format("%-5s", typeLabel), getTypeColor(e.elementType))

      -- Fluid name with fluid color if available
      if e.fluidType and e.fluidType.color then
        local fc = e.fluidType.color
        state.gpu:setForeground(fc.r, fc.g, fc.b, fc.a or 1.0)
        state.gpu:setText(COL.FLUID, row, string.format("%-11s", fluidName))
      else
        txt(COL.FLUID, row, string.format("%-11s", fluidName), COLORS.dim)
      end

      -- Fill bar (reservoirs only — other types already show data in In/Out columns)
      if e.elementType == "reservoir" then
        drawFillBar(COL.FILL, row, 12, e.fillPercent or 0)
      end

      -- Flow in / out
      txt(COL.FLOW_IN,  row, string.format("%11s", flowIn),  COLORS.flowPos)
      txt(COL.FLOW_OUT, row, string.format("%11s", flowOut), COLORS.flowNeg)

      -- State + Rate: only for controllable elements
      if e.controllable then
        local stateStr = e.active and " ON" or "OFF"
        local stateColor = e.active and COLORS.active or COLORS.inactive
        txt(COL.STATE, row, stateStr, stateColor)

        if e.productivity ~= nil then
          local pct = (e.productivity or 0) * 100
          txt(COL.RATE, row, string.format("%5.1f%%", pct), getProdColor(pct))
        end
      end

      -- Register click zone for this row
      table.insert(tableClickZones, { y = row, element = e })

      row = row + 1
    end
  end

  return row
end

-- ============================================================================
-- Topology mode rendering
-- ============================================================================

-- Node dimensions for topology
local NODE_W = 18  -- width of an element box
local NODE_H = 4   -- height of an element box
local NODE_GAP_X = 3 -- horizontal gap between nodes (for pipe lines)
local NODE_GAP_Y = 1 -- vertical gap between network rows
local NETWORK_HDR_H = 1 -- network header line

--- Draw a single element node box at (col, row).
local function drawNode(col, row, elem)
  if row + NODE_H > H - 1 then return end
  local gpu = state.gpu

  -- Background fill for node (neutral for non-controllable)
  local bgColor
  if elem.controllable then
    bgColor = elem.active and COLORS.nodeActive or COLORS.nodeInactive
  else
    bgColor = { 0.1, 0.1, 0.15, 1.0 } -- neutral blue-gray for passive elements
  end
  gpu:setBackground(table.unpack(bgColor))
  gpu:fill(col, row, NODE_W, NODE_H, " ")

  -- Border top
  local icon = "[" .. getTypeIcon(elem.elementType) .. "]"
  -- Name (strip after first space, same as container_scanner)
  local name = elem.elementName or "?"
  if #name > NODE_W - #icon - 3 then
    name = name:sub(1, NODE_W - #icon - 4) .. "."
  end
  gpu:setForeground(table.unpack(COLORS.nodeBorder))
  gpu:setText(col, row, "+")
  gpu:fill(col + 1, row, NODE_W - 2, 1, "-")
  gpu:setText(col + NODE_W - 1, row, "+")
  -- Type icon and name on top border
  gpu:setForeground(table.unpack(getTypeColor(elem.elementType)))
  gpu:setText(col + 1, row, icon)
  gpu:setForeground(table.unpack(COLORS.elemName))
  gpu:setText(col + 1 + #icon, row, name)

  -- Line 1: fluid name + state (state only for controllable elements)
  local fluidName = elem.fluidType and elem.fluidType.name or "---"
  if #fluidName > 10 then fluidName = fluidName:sub(1, 8) .. ".." end
  gpu:setForeground(table.unpack(COLORS.nodeBorder))
  gpu:setText(col, row + 1, "|")
  gpu:setText(col + NODE_W - 1, row + 1, "|")
  if elem.fluidType and elem.fluidType.color then
    local fc = elem.fluidType.color
    gpu:setForeground(fc.r, fc.g, fc.b, fc.a or 1.0)
  else
    gpu:setForeground(table.unpack(COLORS.dim))
  end
  gpu:setText(col + 1, row + 1, string.format("%-10s", fluidName))
  if elem.controllable then
    local stateStr = elem.active and "ON" or "OFF"
    gpu:setForeground(table.unpack(elem.active and COLORS.active or COLORS.inactive))
    gpu:setText(col + 12, row + 1, string.format("%5s", stateStr))
  end

  -- Productivity overlay for controllable factory machines (extractor only)
  if elem.controllable and elem.productivity ~= nil and elem.elementType == "extractor" then
    local pct = (elem.productivity or 0) * 100
    local prodStr = string.format("%.0f%%", pct)
    gpu:setForeground(table.unpack(getProdColor(pct)))
    gpu:setText(col + NODE_W - 1 - #prodStr - 1, row + 1, prodStr)
  end

  -- Line 2: fill bar (reservoir) or flow (pump/valve/extractor)
  gpu:setForeground(table.unpack(COLORS.nodeBorder))
  gpu:setText(col, row + 2, "|")
  gpu:setText(col + NODE_W - 1, row + 2, "|")
  if elem.elementType == "reservoir" then
    local pct = elem.fillPercent or 0
    local barW = 10
    local filled = math.floor(barW * math.min(pct, 100) / 100)
    gpu:setForeground(table.unpack(getFillColor(pct)))
    gpu:setText(col + 1, row + 2, string.rep("#", filled))
    gpu:setForeground(table.unpack(COLORS.fillEmpty))
    gpu:setText(col + 1 + filled, row + 2, string.rep("-", barW - filled))
    gpu:setForeground(table.unpack(getFillColor(pct)))
    gpu:setText(col + 12, row + 2, string.format("%4.0f%%", pct))
  else
    local flow = elem.flow or 0
    local flowStr = formatFlow(flow) .. " m3/min"
    gpu:setForeground(table.unpack(flow > 0 and COLORS.flowPos or COLORS.dim))
    gpu:setText(col + 1, row + 2, string.format("%-15s", ">" .. flowStr))
  end

  -- Border bottom
  gpu:setForeground(table.unpack(COLORS.nodeBorder))
  gpu:setText(col, row + 3, "+")
  gpu:fill(col + 1, row + 3, NODE_W - 2, 1, "-")
  gpu:setText(col + NODE_W - 1, row + 3, "+")

  -- Reset background
  gpu:setBackground(table.unpack(COLORS.bg))
end

--- Draw a routed pipe connection between two nodes with arrowhead at target.
-- Supports same-row (horizontal), same-column (vertical), and L-shaped (90° turn) routing.
-- The arrowhead lands at the center of the target node face nearest to the source.
-- @param fromGX number - source grid column
-- @param fromGY number - source grid row
-- @param toGX number - target grid column
-- @param toGY number - target grid row
-- @param baseRow number - pixel row offset for the grid
local function drawConnection(fromGX, fromGY, toGX, toGY, baseRow)
  local gpu = state.gpu
  if fromGX == toGX and fromGY == toGY then return end

  local fromNCol = fromGX * (NODE_W + NODE_GAP_X)
  local fromNRow = baseRow + fromGY * (NODE_H + NODE_GAP_Y)
  local toNCol = toGX * (NODE_W + NODE_GAP_X)
  local toNRow = baseRow + toGY * (NODE_H + NODE_GAP_Y)

  local fromMidRow = fromNRow + math.floor(NODE_H / 2)
  local toMidCol = toNCol + math.floor(NODE_W / 2)

  gpu:setForeground(table.unpack(COLORS.pipeLine))

  local dx = toGX - fromGX
  local dy = toGY - fromGY

  if dy == 0 then
    -- Same row: horizontal pipe, arrowhead on target face
    local pipeRow = fromMidRow
    if pipeRow < 0 or pipeRow >= H then return end
    if dx > 0 then
      local startC = fromNCol + NODE_W
      local arrowC = toNCol
      local gap = arrowC - startC
      if gap > 0 then
        gpu:setText(startC, pipeRow, string.rep("-", gap) .. ">")
      elseif gap == 0 then
        gpu:setText(arrowC, pipeRow, ">")
      end
    elseif dx < 0 then
      local arrowC = toNCol + NODE_W - 1
      local endC = fromNCol - 1
      local gap = endC - arrowC
      if gap > 0 then
        gpu:setText(arrowC, pipeRow, "<" .. string.rep("-", gap))
      elseif gap == 0 then
        gpu:setText(arrowC, pipeRow, "<")
      end
    end

  elseif dx == 0 then
    -- Same column: vertical pipe, arrowhead on target face
    local pipeCol = toMidCol
    if pipeCol < 0 or pipeCol >= W then return end
    if dy > 0 then
      local startR = fromNRow + NODE_H
      local arrowR = toNRow
      for r = startR, arrowR - 1 do
        if r >= 0 and r < H then gpu:setText(pipeCol, r, "|") end
      end
      if arrowR >= 0 and arrowR < H then
        gpu:setText(pipeCol, arrowR, "v")
      end
    else
      local arrowR = toNRow + NODE_H - 1
      local endR = fromNRow - 1
      if arrowR >= 0 and arrowR < H then
        gpu:setText(pipeCol, arrowR, "^")
      end
      for r = arrowR + 1, endR do
        if r >= 0 and r < H then gpu:setText(pipeCol, r, "|") end
      end
    end

  else
    -- L-shaped: horizontal from source face, turn 90°, vertical to target face
    local hRow = fromMidRow
    local turnCol = toMidCol

    -- Horizontal segment
    local hStart, hEnd
    if dx > 0 then
      hStart = fromNCol + NODE_W
      hEnd = turnCol
    else
      hStart = turnCol
      hEnd = fromNCol - 1
    end
    for c = hStart, hEnd do
      if c >= 0 and c < W and hRow >= 0 and hRow < H then
        gpu:setText(c, hRow, "-")
      end
    end

    -- Corner at turn point
    if turnCol >= 0 and turnCol < W and hRow >= 0 and hRow < H then
      gpu:setText(turnCol, hRow, "+")
    end

    -- Vertical segment with arrowhead on target face
    if dy > 0 then
      local vTop = hRow + 1
      local arrowR = toNRow
      for r = vTop, arrowR - 1 do
        if r >= 0 and r < H then gpu:setText(turnCol, r, "|") end
      end
      if arrowR >= 0 and arrowR < H then
        gpu:setText(turnCol, arrowR, "v")
      end
    else
      local arrowR = toNRow + NODE_H - 1
      local vBot = hRow - 1
      if arrowR >= 0 and arrowR < H then
        gpu:setText(turnCol, arrowR, "^")
      end
      for r = arrowR + 1, vBot do
        if r >= 0 and r < H then gpu:setText(turnCol, r, "|") end
      end
    end
  end
end

--- Render topology mode: elements placed on a 2D grid by network.
-- Uses the topology layout manager for custom positions when available,
-- falling back to auto-layout (left-to-right grid fill).
local function renderTopology(scanResult, startRow)
  topoClickZones = {}
  local row = startRow

  -- ========== EDIT MODE ==========
  if editState.active then
    topoEditZones = {}
    if #editState.netList == 0 then
      txt(1, row, "No networks available to edit.", COLORS.dim)
      return row + 1
    end
    local netIdx = math.max(1, math.min(editState.netIdx, #editState.netList))
    local net = editState.netList[netIdx]
    local netKey = tostring(net.id)
    local fluidLabel = net.data.fluidType and net.data.fluidType.name or "Unknown"
    txt(1, row, "Edit: Network #" .. tostring(net.id) .. " [" .. fluidLabel .. "]  (" .. #net.data.elements .. " el)  Net " .. netIdx .. "/" .. #editState.netList, COLORS.networkHdr)
    row = row + 1
    if editState.editTool == "link" then
      if editState.selectedNodeId then
        local selName = "?"
        for _, e in ipairs(net.data.elements) do
          if e.id == editState.selectedNodeId then selName = e.elementName or "?"; break end
        end
        txt(1, row, "[LINK] Selected: " .. selName .. "  | Click another node to toggle connection", COLORS.buttonText)
      else
        txt(1, row, "[LINK] Click a node to start, then click another to add/remove connection", COLORS.dim)
      end
    else
      if editState.selectedNodeId then
        local selName = "?"
        for _, e in ipairs(net.data.elements) do
          if e.id == editState.selectedNodeId then selName = e.elementName or "?"; break end
        end
        txt(1, row, "[MOVE] Selected: " .. selName .. "  | Click empty cell to move, or another node", COLORS.buttonText)
      else
        txt(1, row, "[MOVE] Click a node to select, then click an empty cell to place it", COLORS.dim)
      end
    end
    row = row + 1
    local topoLayout = topologyRef and topologyRef.getLayout(scanResult) or nil
    local netLayoutNodes = {}
    if topoLayout and topoLayout.grid and topoLayout.grid[netKey] then
      for _, node in ipairs(topoLayout.grid[netKey].nodes or {}) do
        netLayoutNodes[node.elementId] = node
      end
    end
    local elemById = {}
    for _, e in ipairs(net.data.elements) do elemById[e.id] = e end
    local occupied = {}
    for elemId, node in pairs(netLayoutNodes) do
      occupied[node.gridX .. "," .. node.gridY] = elemId
    end
    local gridStartRow = row
    for gy = 0, EDIT_GRID_ROWS - 1 do
      for gx = 0, EDIT_GRID_COLS - 1 do
        local cellCol = gx * (NODE_W + NODE_GAP_X)
        local cellRow = gridStartRow + gy * (NODE_H + NODE_GAP_Y)
        if cellRow + NODE_H <= H - 2 then
          local cellKey = gx .. "," .. gy
          local elemId = occupied[cellKey]
          if elemId and elemById[elemId] then
            drawNode(cellCol, cellRow, elemById[elemId])
            if editState.selectedNodeId == elemId then
              state.gpu:setForeground(1.0, 1.0, 0.3, 1.0)
              state.gpu:setText(cellCol, cellRow, ">" .. string.rep("=", NODE_W - 2) .. "<")
              state.gpu:setText(cellCol, cellRow + NODE_H - 1, ">" .. string.rep("=", NODE_W - 2) .. "<")
              state.gpu:setBackground(table.unpack(COLORS.bg))
            end
            table.insert(topoEditZones, {
              x1 = cellCol, y1 = cellRow,
              x2 = cellCol + NODE_W - 1, y2 = cellRow + NODE_H - 1,
              gridX = gx, gridY = gy, netId = netKey, elementId = elemId,
            })
          else
            state.gpu:setForeground(0.2, 0.2, 0.3, 1.0)
            state.gpu:setText(cellCol, cellRow, "+" .. string.rep(".", NODE_W - 2) .. "+")
            for dy = 1, NODE_H - 2 do
              state.gpu:setText(cellCol, cellRow + dy, ":")
              state.gpu:fill(cellCol + 1, cellRow + dy, NODE_W - 2, 1, " ")
              state.gpu:setText(cellCol + NODE_W - 1, cellRow + dy, ":")
            end
            state.gpu:setText(cellCol, cellRow + NODE_H - 1, "+" .. string.rep(".", NODE_W - 2) .. "+")
            table.insert(topoEditZones, {
              x1 = cellCol, y1 = cellRow,
              x2 = cellCol + NODE_W - 1, y2 = cellRow + NODE_H - 1,
              gridX = gx, gridY = gy, netId = netKey, elementId = nil,
            })
          end
        end
      end
    end

    -- Draw connection arrows between connected nodes in edit mode
    local connections = {}
    if topoLayout and topoLayout.grid and topoLayout.grid[netKey] then
      connections = topoLayout.grid[netKey].connections or {}
    end
    for _, conn in ipairs(connections) do
      local fromNode = netLayoutNodes[conn.from]
      local toNode = netLayoutNodes[conn.to]
      if fromNode and toNode then
        drawConnection(fromNode.gridX, fromNode.gridY, toNode.gridX, toNode.gridY, gridStartRow)
      end
    end

    return gridStartRow + EDIT_GRID_ROWS * (NODE_H + NODE_GAP_Y)
  end
  -- ========== END EDIT MODE ==========

  -- Build element lookup by ID for layout-based rendering
  local elemById = {}
  for _, e in ipairs(scanResult.elements) do
    elemById[e.id] = e
  end

  -- Get custom layout if topology manager is available
  local topoLayout = topologyRef and topologyRef.getLayout(scanResult) or nil

  -- Show layout status hint
  if topoLayout and topologyRef then
    local hint = topologyRef.isAutoGenerated() and "(auto-layout)" or "(custom)"
    txt(W - #hint - 1, startRow - 1, hint, COLORS.dim)
  end

  -- Build list of networks sorted by ID
  local netList = {}
  for nid, netData in pairs(scanResult.networks) do
    table.insert(netList, { id = nid, data = netData })
  end
  table.sort(netList, function(a, b) return a.id < b.id end)

  -- Also include elements not in any network (networkIDs empty)
  local orphans = {}
  for _, e in ipairs(scanResult.elements) do
    if not e.networkIDs or #e.networkIDs == 0 then
      table.insert(orphans, e)
    end
  end

  -- Calculate rows needed per network
  -- Each network: 1 header + ceil(elements / nodesPerRow) * (NODE_H + NODE_GAP_Y)
  local nodesPerRow = math.floor((W + NODE_GAP_X) / (NODE_W + NODE_GAP_X))
  if nodesPerRow < 1 then nodesPerRow = 1 end

  local contentRows = H - row - 1 -- leave 1 for footer

  -- Build "pages": each page contains as many networks as fit vertically
  local pages = {}
  local pageNets = {}
  local usedRows = 0

  local function addNetwork(entry)
    local elemCount = #entry.data.elements
    local netRows = NETWORK_HDR_H +
      math.ceil(elemCount / nodesPerRow) * (NODE_H + NODE_GAP_Y)
    if usedRows + netRows > contentRows and #pageNets > 0 then
      table.insert(pages, pageNets)
      pageNets = {}
      usedRows = 0
    end
    table.insert(pageNets, entry)
    usedRows = usedRows + netRows
  end

  for _, net in ipairs(netList) do
    addNetwork(net)
  end
  if #orphans > 0 then
    addNetwork({ id = 0, data = { elements = orphans, fluidType = nil } })
  end
  if #pageNets > 0 then
    table.insert(pages, pageNets)
  end

  totalPages = math.max(1, #pages)
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end

  local currentNets = pages[currentPage] or {}

  -- Render each network on the current page
  for _, net in ipairs(currentNets) do
    if row >= H - 1 then break end

    -- Network header
    local fluidLabel = net.data.fluidType and net.data.fluidType.name or "Unknown"
    local hdrText = "Network #" .. tostring(net.id)
    if net.id == 0 then hdrText = "Unconnected" end
    hdrText = hdrText .. "  [" .. fluidLabel .. "]  (" .. #net.data.elements .. " elements)"
    txt(1, row, hdrText, COLORS.networkHdr)
    row = row + 1

    -- Check for custom layout for this network
    local netLayoutNodes = nil
    local netLayoutConns = nil
    if topoLayout and topoLayout.grid then
      local netKey = tostring(net.id)
      local netLayout = topoLayout.grid[netKey]
      if netLayout then
        netLayoutNodes = {}
        for _, node in ipairs(netLayout.nodes or {}) do
          netLayoutNodes[node.elementId] = node
        end
        netLayoutConns = netLayout.connections or {}
      end
    end

    if netLayoutNodes then
      -- Custom layout: place nodes at their stored grid positions
      -- Find grid bounds
      local maxGX, maxGY = 0, 0
      for _, node in pairs(netLayoutNodes) do
        if node.gridX > maxGX then maxGX = node.gridX end
        if node.gridY > maxGY then maxGY = node.gridY end
      end

      local baseRow = row
      for _, elem in ipairs(net.data.elements) do
        local node = netLayoutNodes[elem.id]
        if node then
          local nCol = node.gridX * (NODE_W + NODE_GAP_X)
          local nRow = baseRow + node.gridY * (NODE_H + NODE_GAP_Y)
          if nRow + NODE_H <= H - 1 then
            drawNode(nCol, nRow, elem)
            table.insert(topoClickZones, {
              x1 = nCol, y1 = nRow,
              x2 = nCol + NODE_W - 1, y2 = nRow + NODE_H - 1,
              element = elem,
            })
          end
        end
      end

      -- Draw connections
      for _, conn in ipairs(netLayoutConns) do
        local fromNode = netLayoutNodes[conn.from]
        local toNode = netLayoutNodes[conn.to]
        if fromNode and toNode then
          drawConnection(fromNode.gridX, fromNode.gridY, toNode.gridX, toNode.gridY, baseRow)
        end
      end

      -- Advance row past the grid
      row = baseRow + (maxGY + 1) * (NODE_H + NODE_GAP_Y)
    else
      -- Fallback: sequential left-to-right auto-layout
      local col = 0
      local colIdx = 0
      for i, elem in ipairs(net.data.elements) do
        if row + NODE_H > H - 1 then break end

        drawNode(col, row, elem)

        table.insert(topoClickZones, {
          x1 = col, y1 = row,
          x2 = col + NODE_W - 1, y2 = row + NODE_H - 1,
          element = elem,
        })

        colIdx = colIdx + 1

        if i < #net.data.elements and colIdx < nodesPerRow then
          local pipeRow = row + math.floor(NODE_H / 2)
          if pipeRow >= 0 and pipeRow < H - 1 then
            gpu:setForeground(table.unpack(COLORS.pipeLine))
            gpu:setText(col + NODE_W, pipeRow, string.rep("-", NODE_GAP_X - 1) .. ">")
          end
        end

        if colIdx >= nodesPerRow then
          colIdx = 0
          col = 0
          row = row + NODE_H + NODE_GAP_Y
        else
          col = col + NODE_W + NODE_GAP_X
        end
      end

      if colIdx > 0 then
        row = row + NODE_H + NODE_GAP_Y
      end
    end
  end

  return row
end

-- ============================================================================
-- Rules mode rendering
-- ============================================================================

-- Colors for rules display
local RULE_COLORS = {
  enabled   = { 0.3, 1.0, 0.4, 1.0 },
  disabled  = { 0.5, 0.5, 0.5, 1.0 },
  triggerOk = { 0.3, 0.8, 1.0, 1.0 },
  triggerHi = { 1.0, 0.8, 0.2, 1.0 },
  action    = { 1.0, 0.6, 0.3, 1.0 },
  ruleId    = { 0.6, 0.6, 0.8, 1.0 },
  stateIdle = { 0.5, 0.5, 0.5, 1.0 },
  stateBelow= { 0.3, 1.0, 0.4, 1.0 },
  stateAbove= { 1.0, 0.3, 0.3, 1.0 },
  btnToggle = { 0.8, 0.9, 1.0, 1.0 },
  btnDelete = { 1.0, 0.4, 0.4, 1.0 },
}

--- Helper: find element name by ID from last scan.
local function elemNameById(scanResult, elemId)
  if not scanResult then return elemId or "?" end
  for _, e in ipairs(scanResult.elements) do
    if e.id == elemId then return e.elementName or elemId end
  end
  return elemId or "?"
end

--- Render the rules list display mode.
local function renderRules(scanResult, startRow)
  rulesClickZones = {}
  local row = startRow

  txt(1, row, "AUTOMATION RULES", COLORS.title)
  row = row + 1

  -- Column headers
  txt(1,  row, string.format("%-3s",  ""),       COLORS.dim)
  txt(5,  row, string.format("%-20s", "Rule"),    COLORS.dim)
  txt(26, row, string.format("%-7s",  "State"),   COLORS.dim)
  txt(34, row, string.format("%-30s", "Triggers"),COLORS.dim)
  txt(65, row, string.format("%-25s", "Targets"), COLORS.dim)
  txt(91, row, string.format("%-7s",  "Logic"),   COLORS.dim)
  txt(99, row, string.format("%-10s", "Actions"), COLORS.dim)
  row = row + 1

  drawSeparator(row)
  row = row + 1

  if not rulesRef then
    txt(3, row, "Rules engine not loaded.", COLORS.dim)
    return row + 1
  end

  local allRules = rulesRef.getAll()

  if #allRules == 0 then
    txt(3, row, "No rules defined. Use network bus 'fluid_commands' with", COLORS.dim)
    row = row + 1
    txt(3, row, "action='rule_create' to add rules, or configure via central UI.", COLORS.dim)
    return row + 1
  end

  -- Pagination
  local contentRows = H - row - 2
  local rowsPerRule = 1 -- compact: 1 row per rule (expandable later)
  local totalItems = #allRules
  totalPages = math.max(1, math.ceil(totalItems / contentRows))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end

  local startIdx = (currentPage - 1) * contentRows + 1
  local endIdx = math.min(startIdx + contentRows - 1, totalItems)

  for i = startIdx, endIdx do
    if row >= H - 2 then break end
    local rule = allRules[i]

    -- Enabled indicator
    local enabledStr = rule.enabled and "[v]" or "[ ]"
    local enabledColor = rule.enabled and RULE_COLORS.enabled or RULE_COLORS.disabled
    txt(1, row, enabledStr, enabledColor)
    table.insert(rulesClickZones, { y = row, action = "toggle_rule", ruleId = rule.id, x1 = 1, x2 = 3 })

    -- Rule name
    local rName = rule.name or rule.id
    if #rName > 19 then rName = rName:sub(1, 17) .. ".." end
    txt(5, row, string.format("%-20s", rName), COLORS.text)

    -- State
    local stateStr = rule.state or "idle"
    local stateColor = RULE_COLORS.stateIdle
    if stateStr == "below" then stateColor = RULE_COLORS.stateBelow
    elseif stateStr == "above" then stateColor = RULE_COLORS.stateAbove end
    txt(26, row, string.format("%-7s", stateStr), stateColor)

    -- Triggers summary (compact)
    local trigSum = ""
    for j, trig in ipairs(rule.triggers) do
      local eName = elemNameById(scanResult, trig.elementId)
      if #eName > 8 then eName = eName:sub(1, 7) .. "." end
      local trigPart = eName .. "." .. (trig.property or "?"):sub(1, 4)
      trigPart = trigPart .. "[" .. tostring(trig.min or 0) .. "-" .. tostring(trig.max or 100) .. "]"
      if j > 1 then trigSum = trigSum .. ", " end
      trigSum = trigSum .. trigPart
    end
    if #trigSum > 29 then trigSum = trigSum:sub(1, 27) .. ".." end
    txt(34, row, string.format("%-30s", trigSum), RULE_COLORS.triggerOk)

    -- Targets summary
    local targSum = ""
    for j, targ in ipairs(rule.targets) do
      local eName = elemNameById(scanResult, targ.elementId)
      if #eName > 10 then eName = eName:sub(1, 9) .. "." end
      if j > 1 then targSum = targSum .. ", " end
      targSum = targSum .. eName
    end
    if #targSum > 24 then targSum = targSum:sub(1, 22) .. ".." end
    txt(65, row, string.format("%-25s", targSum), RULE_COLORS.action)

    -- Logic mode
    txt(91, row, string.format("%-7s", rule.logic or "any"), COLORS.dim)

    -- Delete button
    txt(99, row, "[del]", RULE_COLORS.btnDelete)
    table.insert(rulesClickZones, { y = row, action = "delete_rule", ruleId = rule.id, x1 = 99, x2 = 103 })

    row = row + 1
  end

  -- Summary footer line
  if row < H - 2 then
    row = row + 1
    local activeCount = 0
    for _, r in ipairs(allRules) do
      if r.enabled then activeCount = activeCount + 1 end
    end
    txt(1, row, string.format("Total: %d rules (%d active)", #allRules, activeCount), COLORS.dim)
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

  -- [Mode] (always first for consistent position)
  local modeLabel = "[Mode:" .. state.displayMode .. "]"
  txt(x, footerRow, modeLabel, COLORS.buttonText)
  table.insert(footerButtons, { x1 = x, x2 = x + #modeLabel - 1, action = "cycle_mode" })
  x = x + #modeLabel + 2

  -- [Sort] (table mode only)
  if state.displayMode == "table" then
    local sortLabel = "[Sort:" .. (SORT_LABELS[SORT_MODES[currentSortIdx]] or "A-Z") .. "]"
    txt(x, footerRow, sortLabel, COLORS.buttonText)
    table.insert(footerButtons, { x1 = x, x2 = x + #sortLabel - 1, action = "cycle_sort" })
    x = x + #sortLabel + 3
  end

  -- Topology edit mode buttons
  if state.displayMode == "topology" then
    if editState.active then
      local netNavLabel = "[<Net]"
      local netNavColor = editState.netIdx > 1 and COLORS.buttonText or COLORS.buttonDim
      txt(x, footerRow, netNavLabel, netNavColor)
      table.insert(footerButtons, { x1 = x, x2 = x + #netNavLabel - 1, action = "topo_prev_net" })
      x = x + #netNavLabel + 1
      local netFwdLabel = "[Net>]"
      local netFwdColor = editState.netIdx < #editState.netList and COLORS.buttonText or COLORS.buttonDim
      txt(x, footerRow, netFwdLabel, netFwdColor)
      table.insert(footerButtons, { x1 = x, x2 = x + #netFwdLabel - 1, action = "topo_next_net" })
      x = x + #netFwdLabel + 2
      -- [Move]/[Link] tool toggle
      local toolLabel = editState.editTool == "link" and "[Link]" or "[Move]"
      local toolColor = editState.editTool == "link" and { 0.5, 0.7, 1.0, 1.0 } or COLORS.buttonText
      txt(x, footerRow, toolLabel, toolColor)
      table.insert(footerButtons, { x1 = x, x2 = x + #toolLabel - 1, action = "topo_toggle_tool" })
      x = x + #toolLabel + 2
      local saveLabel = "[Save]"
      txt(x, footerRow, saveLabel, editState.modified and COLORS.active or COLORS.buttonDim)
      table.insert(footerButtons, { x1 = x, x2 = x + #saveLabel - 1, action = "topo_save" })
      x = x + #saveLabel + 1
      local cancelLabel = "[Cancel]"
      txt(x, footerRow, cancelLabel, COLORS.buttonText)
      table.insert(footerButtons, { x1 = x, x2 = x + #cancelLabel - 1, action = "topo_cancel" })
    else
      local editLabel = "[Edit]"
      txt(x, footerRow, editLabel, COLORS.buttonText)
      table.insert(footerButtons, { x1 = x, x2 = x + #editLabel - 1, action = "topo_edit" })
    end
  end

  -- Right-aligned: element count + timestamp
  local totalSec = math.floor((scanResult.timestamp or 0) / 1000)
  local hh = math.floor(totalSec / 3600) % 24
  local mm = math.floor(totalSec / 60) % 60
  local ss = totalSec % 60
  local timeStr = string.format("%02d:%02d:%02d", hh, mm, ss)

  local s = scanResult.globalStats
  local infoText = s.totalElements .. "el/" .. s.networkCount .. "net"
  local rightText = infoText .. "  " .. timeStr
  txt(W - #rightText - 1, footerRow, infoText, COLORS.dim)
  txt(W - #timeStr - 1, footerRow, timeStr, COLORS.text)
end

-- ============================================================================
-- Click handling
-- ============================================================================

handleClick = function(x, y, btn)
  -- Footer check
  local footerRow = H - 1
  if y == footerRow then
    for _, button in ipairs(footerButtons) do
      if x >= button.x1 and x <= button.x2 then
        if button.action == "prev_page" then
          if currentPage > 1 then currentPage = currentPage - 1 end
        elseif button.action == "next_page" then
          if currentPage < totalPages then currentPage = currentPage + 1 end
        elseif button.action == "cycle_sort" then
          currentSortIdx = (currentSortIdx % #SORT_MODES) + 1
          currentPage = 1
        elseif button.action == "cycle_mode" then
          local idx = 1
          for i, m in ipairs(DISPLAY_MODES) do
            if m == state.displayMode then idx = i; break end
          end
          idx = (idx % #DISPLAY_MODES) + 1
          state.displayMode = DISPLAY_MODES[idx]
          currentPage = 1
          editState.active = false
        elseif button.action == "topo_edit" then
          editState.active = true
          editState.editTool = "move"
          editState.selectedNodeId = nil
          editState.modified = false
          editState.netList = {}
          if lastScanResult then
            for nid, data in pairs(lastScanResult.networks) do
              table.insert(editState.netList, { id = nid, data = data })
            end
            table.sort(editState.netList, function(a, b) return a.id < b.id end)
          end
          editState.netIdx = 1
        elseif button.action == "topo_prev_net" then
          if editState.netIdx > 1 then editState.netIdx = editState.netIdx - 1 end
          editState.selectedNodeId = nil
        elseif button.action == "topo_next_net" then
          if editState.netIdx < #editState.netList then editState.netIdx = editState.netIdx + 1 end
          editState.selectedNodeId = nil
        elseif button.action == "topo_save" then
          if topologyRef and editState.modified then topologyRef.save() end
          editState.active = false
          editState.selectedNodeId = nil
          editState.modified = false
        elseif button.action == "topo_cancel" then
          if editState.modified and topologyRef then topologyRef.load() end
          editState.active = false
          editState.selectedNodeId = nil
          editState.modified = false
        elseif button.action == "topo_toggle_tool" then
          editState.editTool = editState.editTool == "move" and "link" or "move"
          editState.selectedNodeId = nil
        end
        if lastScanResult then
          FluidDisplay.render(lastScanResult)
        end
        return
      end
    end
    return
  end

  -- Table mode: click on element row to toggle
  if state.displayMode == "table" then
    for _, zone in ipairs(tableClickZones) do
      if y == zone.y and zone.element and zone.element.controllable then
        if controllerRef then
          controllerRef.toggle(zone.element)
          -- Re-render on next scan (immediate feedback via state change)
        end
        return
      end
    end
  end

  -- Topology mode
  if state.displayMode == "topology" then
    -- Edit mode: select/move/link nodes
    if editState.active then
      for _, zone in ipairs(topoEditZones) do
        if x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2 then
          if editState.editTool == "link" then
            -- Link mode: click two nodes to toggle connection
            if zone.elementId then
              if not editState.selectedNodeId then
                editState.selectedNodeId = zone.elementId
                editState.selectedNetId = zone.netId
              elseif editState.selectedNodeId == zone.elementId then
                editState.selectedNodeId = nil
              else
                -- Toggle connection between selected and clicked node
                if topologyRef then
                  local netId = editState.selectedNetId or zone.netId
                  local fromId = editState.selectedNodeId
                  local toId = zone.elementId
                  -- Check if connection exists (either direction)
                  local exists = false
                  local topoLayout = topologyRef.getLayout(lastScanResult)
                  if topoLayout and topoLayout.grid and topoLayout.grid[netId] then
                    for _, conn in ipairs(topoLayout.grid[netId].connections or {}) do
                      if (conn.from == fromId and conn.to == toId) or
                         (conn.from == toId and conn.to == fromId) then
                        exists = true
                        break
                      end
                    end
                  end
                  if exists then
                    topologyRef.removeConnection(netId, fromId, toId)
                    topologyRef.removeConnection(netId, toId, fromId)
                  else
                    topologyRef.addConnection(netId, fromId, toId)
                  end
                  editState.modified = true
                end
                editState.selectedNodeId = nil
              end
            end
          else
            -- Move mode: select node, then click empty cell to move
            if zone.elementId then
              if editState.selectedNodeId == zone.elementId then
                editState.selectedNodeId = nil
              else
                editState.selectedNodeId = zone.elementId
                editState.selectedNetId = zone.netId
              end
            else
              if editState.selectedNodeId and topologyRef then
                topologyRef.setNodePosition(
                  editState.selectedNetId or zone.netId,
                  editState.selectedNodeId,
                  zone.gridX, zone.gridY)
                editState.modified = true
                editState.selectedNodeId = nil
              end
            end
          end
          if lastScanResult then FluidDisplay.render(lastScanResult) end
          return
        end
      end
      return
    end
    -- Normal topology: click to toggle
    for _, zone in ipairs(topoClickZones) do
      if x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2 then
        if zone.element and zone.element.controllable and controllerRef then
          controllerRef.toggle(zone.element)
        end
        return
      end
    end
  end

  -- Rules mode: click on rule row buttons
  if state.displayMode == "rules" then
    for _, zone in ipairs(rulesClickZones) do
      if y == zone.y and x >= zone.x1 and x <= zone.x2 then
        if zone.action == "toggle_rule" and rulesRef then
          rulesRef.toggleEnabled(zone.ruleId)
        elseif zone.action == "delete_rule" and rulesRef then
          rulesRef.delete(zone.ruleId)
        end
        if lastScanResult then
          FluidDisplay.render(lastScanResult)
        end
        return
      end
    end
  end
end

-- ============================================================================
-- Console fallback
-- ============================================================================

function FluidDisplay.printReport(scanResult)
  local s = scanResult.globalStats
  print("--- FLUID NETWORK REPORT ---")
  print(string.format("Elements: %d  |  Pumps: %d  Tanks: %d  Valves: %d  Extr: %d  |  Networks: %d",
    s.totalElements, s.pumpCount, s.reservoirCount, s.valveCount, s.extractorCount, s.networkCount))
  print("")

  for _, gName in ipairs(scanResult.groupOrder) do
    local g = scanResult.groups[gName]
    if g then
      local fluid = g.fluidType and g.fluidType.name or "?"
      print(string.format("  [%s] %d elements, fluid: %s, active: %d/%d, fill: %.1f%%",
        g.name, g.elementCount, fluid, g.activeCount, g.elementCount, g.avgFillPercent))
      for _, e in ipairs(g.elements) do
        local state = e.active and "ON" or "OFF"
        local extra = ""
        if e.elementType == "reservoir" then
          extra = string.format("fill:%.1f%%  in:%.1f  out:%.1f m3/min",
            math.min(e.fillPercent or 0, 100), (e.flowFill or 0) * 60, (e.flowDrain or 0) * 60)
        elseif e.elementType == "pump" then
          extra = string.format("flow:%.1f  limit:%.1f m3/min", (e.flow or 0) * 60, (e.flowLimit or 0) * 60)
        end
        print(string.format("    %-16s %-6s %-4s  %s  %s",
          e.elementName, getTypeLabel(e.elementType), state,
          e.fluidType and e.fluidType.name or "-", extra))
      end
    end
  end
  print("----------------------------")
end

-- ============================================================================
-- Main render
-- ============================================================================

function FluidDisplay.render(scanResult)
  if not state.enabled then return end
  if not scanResult then return end

  lastScanResult = scanResult
  local gpu = state.gpu
  local row = 0

  gpu:setBackground(table.unpack(COLORS.bg))
  gpu:fill(0, 0, W, H, " ")

  local titleText = "=== FLUID NETWORK MONITOR ==="
  txt(math.floor((W - #titleText) / 2), row, titleText, COLORS.title)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  -- Overview stats
  row = renderOverview(scanResult, row)

  -- Mode-specific content
  if state.displayMode == "topology" then
    renderTopology(scanResult, row)
  elseif state.displayMode == "rules" then
    renderRules(scanResult, row)
  else
    renderTable(scanResult, row)
  end

  -- Footer
  renderFooter(scanResult, H - 1)

  gpu:flush()
end

return FluidDisplay