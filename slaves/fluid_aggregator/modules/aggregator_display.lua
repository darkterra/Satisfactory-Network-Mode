-- modules/aggregator_display.lua
-- Renders the aggregated fluid monitoring dashboard on a GPU T1 screen.
--
-- Display modes (cycled via footer click):
--   "overview"      - Compact fleet view of all fluid_monitor slaves
--   "slave_detail"  - Detailed element table for a selected slave
--   "rules_config"  - Click-based rules editor for slave automation
--
-- All interaction is click-based (external screens have no keyboard).

local AggDisplay = {}

-- Forward declarations
local handleClick

-- Screen dimensions (GPU T1)
local W = 125
local H = 50

-- ============================================================================
-- Color palette (consistent with fluid_display.lua)
-- ============================================================================

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
  online      = { 0.3, 1.0, 0.4, 1.0 },
  offline     = { 1.0, 0.3, 0.3, 1.0 },
  fillEmpty   = { 0.3, 0.3, 0.3, 1.0 },
  fillLow     = { 1.0, 0.3, 0.3, 1.0 },
  fillMid     = { 1.0, 0.8, 0.2, 1.0 },
  fillHigh    = { 0.3, 1.0, 0.4, 1.0 },
  fillFull    = { 0.2, 0.7, 1.0, 1.0 },
  flowPos     = { 0.3, 0.8, 1.0, 1.0 },
  flowNeg     = { 1.0, 0.5, 0.2, 1.0 },
  button      = { 0.15, 0.15, 0.25, 1.0 },
  buttonText  = { 0.8, 0.9, 1.0, 1.0 },
  buttonDim   = { 0.4, 0.5, 0.6, 1.0 },
  ruleEnabled = { 0.3, 1.0, 0.4, 1.0 },
  ruleDisabled= { 0.5, 0.5, 0.5, 1.0 },
  triggerOk   = { 0.3, 0.8, 1.0, 1.0 },
  actionColor = { 1.0, 0.6, 0.3, 1.0 },
  btnDelete   = { 1.0, 0.4, 0.4, 1.0 },
  prodHigh    = { 0.3, 1.0, 0.4, 1.0 },
  prodMid     = { 1.0, 0.8, 0.2, 1.0 },
  prodLow     = { 1.0, 0.3, 0.3, 1.0 },
  wizardBg    = { 0.08, 0.08, 0.15, 1.0 },
  wizardBorder= { 0.3, 0.5, 0.7, 1.0 },
  selected    = { 1.0, 1.0, 0.3, 1.0 },
}

-- ============================================================================
-- State
-- ============================================================================

local state = {
  gpu = nil,
  screen = nil,
  enabled = false,
  displayMode = "overview",
}

local DISPLAY_MODES = { "overview", "slave_detail", "rules_config" }

-- Sort modes for overview
local SORT_MODES = { "name", "elements", "fill", "active" }
local SORT_LABELS = { name = "Name", elements = "Elems", fill = "Fill%", active = "Active" }
local currentSortIdx = 1

-- Pagination
local currentPage = 1
local totalPages = 1

-- Click zones
local footerButtons = {}
local overviewClickZones = {}   -- { y, identity }
local detailClickZones = {}     -- { y, element, identity }
local rulesClickZones = {}      -- { y, x1, x2, action, ... }

-- Selected slave for detail/rules view
local selectedSlaveId = nil

-- References to collector module
local collectorRef = nil

-- ============================================================================
-- Rules wizard state
-- ============================================================================

local wizard = {
  active = false,
  step = 1,        -- 1=name+logic, 2=triggers, 3=thresholds, 4=targets+actions
  targetSlaveId = nil,
  ruleId = nil,    -- nil for create, set for edit
  name = "",
  logic = "any",
  triggers = {},   -- { { elementId, elementName, elementType, property, min, max }, ... }
  targets = {},    -- { { elementId, elementName, actionBelow, actionAbove }, ... }
  -- UI selection state
  triggerPage = 1,
  targetPage = 1,
  thresholdIdx = 1,
}
local wizardClickZones = {} -- { y, x1, x2, action, ... }

-- ============================================================================
-- Initialization
-- ============================================================================

function AggDisplay.init(gpu, screen, options)
  if not gpu or not screen then
    print("[AGG_DSP] No GPU/Screen - console fallback")
    state.enabled = false
    return false
  end

  state.gpu = gpu
  state.screen = screen
  options = options or {}
  collectorRef = options.collector or nil

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

  print("[AGG_DSP] Initialized (" .. W .. "x" .. H .. ")")
  return true
end

function AggDisplay.isEnabled()
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

local function getTypeLabel(elemType)
  if elemType == "pump" then return "Pump" end
  if elemType == "reservoir" then return "Tank" end
  if elemType == "valve" then return "Valve" end
  if elemType == "extractor" then return "Extr" end
  return "???"
end

local function formatFlow(val)
  if not val or val == 0 then return "0" end
  local perMin = val * 60
  if math.abs(perMin) >= 100 then return string.format("%.0f", perMin)
  elseif math.abs(perMin) >= 10 then return string.format("%.1f", perMin) end
  return string.format("%.2f", perMin)
end

local function formatTimeSince(ms)
  if not ms then return "???" end
  local now = computer.millis()
  local sec = math.floor((now - ms) / 1000)
  if sec < 60 then return sec .. "s" end
  local min = math.floor(sec / 60)
  if min < 60 then return min .. "m" .. (sec % 60) .. "s" end
  return math.floor(min / 60) .. "h" .. (min % 60) .. "m"
end

local function drawFillBar(col, row, barWidth, percent)
  if row < 0 or row >= H then return end
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
end

local function getProdColor(pct)
  if pct >= 80 then return COLORS.prodHigh end
  if pct >= 40 then return COLORS.prodMid end
  return COLORS.prodLow
end

-- ============================================================================
-- Overview mode: compact view of all fluid_monitor slaves
-- ============================================================================

local function sortSlaves(slaveList)
  local sorted = {}
  for i, s in ipairs(slaveList) do sorted[i] = s end
  local mode = SORT_MODES[currentSortIdx]
  if mode == "elements" then
    table.sort(sorted, function(a, b) return (a.elementCount or 0) > (b.elementCount or 0) end)
  elseif mode == "fill" then
    table.sort(sorted, function(a, b) return (a.avgFill or 0) > (b.avgFill or 0) end)
  elseif mode == "active" then
    table.sort(sorted, function(a, b) return (a.activeCount or 0) > (b.activeCount or 0) end)
  else -- name
    table.sort(sorted, function(a, b) return (a.identity or "") < (b.identity or "") end)
  end
  return sorted
end

local function renderOverview(startRow)
  overviewClickZones = {}
  local row = startRow
  local allSlaves = collectorRef and collectorRef.getSlaves() or {}

  -- Header
  local onlineCount = 0
  for _, s in ipairs(allSlaves) do
    if s.state == "online" then onlineCount = onlineCount + 1 end
  end
  txt(1, row, "OVERVIEW", COLORS.title)
  txt(12, row, string.format("  %d monitor%s  (%d online)", #allSlaves, #allSlaves ~= 1 and "s" or "", onlineCount), COLORS.dim)
  row = row + 1

  -- Column headers
  --    #  Identity          Elems  Grps  P   T   V   E  Fill%        Active  LastSeen  Status
  txt(1,   row, "#",                  COLORS.dim)
  txt(4,   row, string.format("%-18s", "Identity"),     COLORS.dim)
  txt(23,  row, "Elems",              COLORS.dim)
  txt(30,  row, "Grps",               COLORS.dim)
  txt(36,  row, "P",                   COLORS.dim)
  txt(39,  row, "T",                   COLORS.dim)
  txt(42,  row, "V",                   COLORS.dim)
  txt(45,  row, "E",                   COLORS.dim)
  txt(49,  row, string.format("%-20s", "Avg Fill"),     COLORS.dim)
  txt(70,  row, "Active",              COLORS.dim)
  txt(78,  row, "Rules",               COLORS.dim)
  txt(85,  row, "Nets",                COLORS.dim)
  txt(91,  row, "Last Seen",           COLORS.dim)
  txt(105, row, "Status",              COLORS.dim)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  if #allSlaves == 0 then
    txt(3, row, "No fluid_monitors discovered yet. Waiting for broadcasts...", COLORS.dim)
    return row + 1
  end

  local sorted = sortSlaves(allSlaves)
  local contentRows = H - row - 2
  totalPages = math.max(1, math.ceil(#sorted / contentRows))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end
  local startIdx = (currentPage - 1) * contentRows + 1
  local endIdx = math.min(startIdx + contentRows - 1, #sorted)

  for i = startIdx, endIdx do
    if row >= H - 2 then break end
    local s = sorted[i]
    local idStr = s.identity or "?"
    if #idStr > 17 then idStr = idStr:sub(1, 15) .. ".." end

    txt(1, row, string.format("%2d", i), COLORS.dim)
    txt(4, row, string.format("%-18s", idStr), COLORS.elemName)
    txt(23, row, string.format("%4d", s.elementCount or 0), COLORS.text)
    txt(30, row, string.format("%3d", s.groupCount or 0), COLORS.text)
    txt(36, row, string.format("%2d", s.pumpCount or 0), COLORS.pumpColor)
    txt(39, row, string.format("%2d", s.reservoirCount or 0), COLORS.reservColor)
    txt(42, row, string.format("%2d", s.valveCount or 0), COLORS.valveColor)
    txt(45, row, string.format("%2d", s.extractorCount or 0), COLORS.extractColor)

    local avgFill = s.avgFill or 0
    if s.reservoirCount and s.reservoirCount > 0 then
      drawFillBar(49, row, 12, avgFill)
    else
      txt(49, row, "       -", COLORS.dim)
    end

    local activeRatio = string.format("%d/%d", s.activeCount or 0, s.elementCount or 0)
    txt(70, row, string.format("%-6s", activeRatio), COLORS.text)
    txt(78, row, string.format("%3d", s.ruleCount or 0), COLORS.dim)
    txt(85, row, string.format("%3d", s.networkCount or 0), COLORS.dim)
    txt(91, row, string.format("%-12s", formatTimeSince(s.lastSeen)), COLORS.dim)

    local statusStr = s.state == "online" and "ONLINE" or "OFFLINE"
    local statusColor = s.state == "online" and COLORS.online or COLORS.offline
    txt(105, row, statusStr, statusColor)

    table.insert(overviewClickZones, { y = row, identity = s.identity })
    row = row + 1
  end

  return row
end

-- ============================================================================
-- Slave detail mode: element table for selected slave
-- ============================================================================

local COL = {
  NAME     = 3,
  TYPE     = 25,
  FLUID    = 31,
  FILL     = 43,
  FLOW_IN  = 64,
  FLOW_OUT = 76,
  STATE    = 88,
  RATE     = 94,
}

local function renderSlaveDetail(startRow)
  detailClickZones = {}
  local row = startRow

  if not selectedSlaveId or not collectorRef then
    txt(3, row, "No slave selected.", COLORS.dim)
    return row + 1
  end

  local slaveData = collectorRef.getSlaveData(selectedSlaveId)
  if not slaveData then
    txt(3, row, "Slave '" .. selectedSlaveId .. "' not found.", COLORS.dim)
    return row + 1
  end

  -- Slave header
  local statusStr = slaveData.state == "online" and "ONLINE" or "OFFLINE"
  local statusColor = slaveData.state == "online" and COLORS.online or COLORS.offline
  txt(1, row, "SLAVE: ", COLORS.title)
  txt(8, row, selectedSlaveId, COLORS.elemName)
  txt(8 + #selectedSlaveId + 1, row, "(" .. (slaveData.elementCount or 0) .. " elements, " .. (slaveData.groupCount or 0) .. " groups)", COLORS.dim)
  txt(W - #statusStr - 12, row, statusStr, statusColor)
  local backLabel = "[< Back]"
  txt(W - #backLabel - 1, row, backLabel, COLORS.buttonText)
  table.insert(detailClickZones, { y = row, x1 = W - #backLabel - 1, x2 = W - 2, action = "back" })
  row = row + 1

  drawSeparator(row)
  row = row + 1

  local detail = slaveData.detail
  if not detail or not detail.elements or #detail.elements == 0 then
    txt(3, row, "Waiting for detail data from slave...", COLORS.dim)
    row = row + 1
    txt(3, row, "Last seen: " .. formatTimeSince(slaveData.lastSeen), COLORS.dim)
    return row + 1
  end

  -- Column headers
  txt(COL.NAME,     row, string.format("%-21s", "Name"),      COLORS.dim)
  txt(COL.TYPE,     row, string.format("%-5s",  "Type"),      COLORS.dim)
  txt(COL.FLUID,    row, string.format("%-11s", "Fluid"),     COLORS.dim)
  txt(COL.FILL,     row, string.format("%-20s", "Fill"),      COLORS.dim)
  txt(COL.FLOW_IN,  row, string.format("%11s",  "In m3/min"), COLORS.dim)
  txt(COL.FLOW_OUT, row, string.format("%11s", "Out m3/min"), COLORS.dim)
  txt(COL.STATE,    row, string.format("%-4s",  "State"),     COLORS.dim)
  txt(COL.RATE,     row, string.format("%-7s",  "Rate %"),    COLORS.dim)
  row = row + 1

  -- Build groups from detail elements
  local groups = {}
  local groupOrder = {}
  local groupSeen = {}
  for _, e in ipairs(detail.elements) do
    local gName = e.groupName or "default"
    if not groupSeen[gName] then
      groupSeen[gName] = true
      table.insert(groupOrder, gName)
      groups[gName] = { name = gName, elements = {}, fluidType = nil, elementCount = 0, avgFillPercent = 0, totalCapacity = 0, totalContent = 0 }
    end
    table.insert(groups[gName].elements, e)
    groups[gName].elementCount = groups[gName].elementCount + 1
    if not groups[gName].fluidType and e.fluidType then
      groups[gName].fluidType = e.fluidType
    end
    if e.elementType == "reservoir" and e.fillPercent then
      groups[gName].totalContent = groups[gName].totalContent + (e.fillPercent or 0)
      groups[gName].totalCapacity = groups[gName].totalCapacity + 100
    end
  end
  for _, gName in ipairs(groupOrder) do
    local g = groups[gName]
    if g.totalCapacity > 0 then
      g.avgFillPercent = g.totalContent / g.totalCapacity * 100
    end
  end

  -- Flatten with group headers
  local flat = {}
  for _, gName in ipairs(groupOrder) do
    local g = groups[gName]
    table.insert(flat, { isGroupHeader = true, group = g })
    for _, e in ipairs(g.elements) do
      table.insert(flat, { isGroupHeader = false, element = e })
    end
  end

  local contentRows = H - row - 2
  totalPages = math.max(1, math.ceil(#flat / contentRows))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end
  local startIdx = (currentPage - 1) * contentRows + 1
  local endIdx = math.min(startIdx + contentRows - 1, #flat)

  for i = startIdx, endIdx do
    if row >= H - 2 then break end
    local entry = flat[i]

    if entry.isGroupHeader then
      local g = entry.group
      local gName = g.name
      if #gName > 20 then gName = gName:sub(1, 18) .. ".." end
      txt(1, row, gName, COLORS.groupName)
      local groupInfo = string.format("  %dx", g.elementCount)
      txt(1 + #gName, row, groupInfo, COLORS.dim)
      if g.fluidType then
        txt(1 + #gName + #groupInfo + 1, row, tostring(g.fluidType), COLORS.label)
      end
      if g.totalCapacity > 0 then
        local avgStr = string.format("  avg %.1f%%", g.avgFillPercent)
        txt(1 + #gName + #groupInfo + 14, row, avgStr, getFillColor(g.avgFillPercent))
      end
      row = row + 1
    else
      local e = entry.element
      local name = e.elementName or "?"
      if #name > 20 then name = name:sub(1, 18) .. ".." end
      local typeLabel = getTypeLabel(e.elementType)
      local fluidName = e.fluidType or "-"
      if #fluidName > 11 then fluidName = fluidName:sub(1, 9) .. ".." end

      txt(COL.NAME, row, string.format("%-21s", name), COLORS.elemName)
      txt(COL.TYPE, row, string.format("%-5s", typeLabel), getTypeColor(e.elementType))
      txt(COL.FLUID, row, string.format("%-11s", fluidName), COLORS.dim)

      if e.elementType == "reservoir" and e.fillPercent then
        drawFillBar(COL.FILL, row, 12, e.fillPercent or 0)
      end

      local flowIn, flowOut = "0", "0"
      if e.elementType == "reservoir" then
        flowIn = formatFlow(e.flowFill)
        flowOut = formatFlow(e.flowDrain)
      elseif e.elementType == "pump" or e.elementType == "valve" then
        flowIn = formatFlow(e.flow)
        flowOut = "-"
      end
      txt(COL.FLOW_IN, row, string.format("%11s", flowIn), COLORS.flowPos)
      txt(COL.FLOW_OUT, row, string.format("%11s", flowOut), COLORS.flowNeg)

      if e.controllable then
        local stateStr = e.active and " ON" or "OFF"
        local stateColor = e.active and COLORS.active or COLORS.inactive
        txt(COL.STATE, row, stateStr, stateColor)
        if e.productivity then
          local pct = (e.productivity or 0) * 100
          txt(COL.RATE, row, string.format("%5.1f%%", pct), getProdColor(pct))
        end
      end

      table.insert(detailClickZones, { y = row, element = e, identity = selectedSlaveId })
      row = row + 1
    end
  end

  return row
end

-- ============================================================================
-- Rules config mode: click-based rules management
-- ============================================================================

-- Trigger property definitions
local TRIGGER_PROPS = {
  { key = "fillPercent",  label = "Fill%",   unit = "%",      types = { reservoir = true } },
  { key = "flow",         label = "Flow",    unit = "m3/min", types = { pump = true, valve = true } },
  { key = "flowFill",     label = "FlowIn",  unit = "m3/min", types = { reservoir = true } },
  { key = "flowDrain",    label = "FlowOut", unit = "m3/min", types = { reservoir = true } },
  { key = "productivity", label = "Prod%",   unit = "%",      types = { reservoir = true, extractor = true } },
}

local RULE_NAME_PRESETS = {
  "Auto Fill", "Auto Drain", "Overflow Guard", "Low Level Alert",
  "High Level Limit", "Flow Balance", "Pump Control", "Valve Control",
}

local function resetWizard()
  wizard.active = false
  wizard.step = 1
  wizard.ruleId = nil
  wizard.name = ""
  wizard.logic = "any"
  wizard.triggers = {}
  wizard.targets = {}
  wizard.triggerPage = 1
  wizard.targetPage = 1
  wizard.thresholdIdx = 1
end

--- Get available elements for the selected slave
local function getSlaveElements()
  if not collectorRef or not wizard.targetSlaveId then return {} end
  local s = collectorRef.getSlaveData(wizard.targetSlaveId)
  if not s or not s.detail or not s.detail.elements then return {} end
  return s.detail.elements
end

--- Get available controllable elements
local function getSlaveControllables()
  local elems = getSlaveElements()
  local result = {}
  for _, e in ipairs(elems) do
    if e.controllable then table.insert(result, e) end
  end
  return result
end

--- Check if an element is already in the triggers list
local function isTriggerSelected(elemId)
  for _, t in ipairs(wizard.triggers) do
    if t.elementId == elemId then return true end
  end
  return false
end

--- Check if an element is already in the targets list
local function isTargetSelected(elemId)
  for _, t in ipairs(wizard.targets) do
    if t.elementId == elemId then return true end
  end
  return false
end

--- Get default trigger property for element type
local function getDefaultTriggerProp(elemType)
  for _, p in ipairs(TRIGGER_PROPS) do
    if p.types[elemType] then return p.key end
  end
  return "fillPercent"
end

-- ============================================================================
-- Wizard rendering
-- ============================================================================

local function renderWizardFrame(title, row)
  local gpu = state.gpu
  local wx, wy, ww, wh = 5, 3, W - 10, H - 7
  gpu:setBackground(table.unpack(COLORS.wizardBg))
  gpu:fill(wx, wy, ww, wh, " ")
  gpu:setForeground(table.unpack(COLORS.wizardBorder))
  gpu:setText(wx, wy, "+" .. string.rep("=", ww - 2) .. "+")
  for dy = 1, wh - 2 do
    gpu:setText(wx, wy + dy, "|")
    gpu:setText(wx + ww - 1, wy + dy, "|")
  end
  gpu:setText(wx, wy + wh - 1, "+" .. string.rep("=", ww - 2) .. "+")
  gpu:setForeground(table.unpack(COLORS.title))
  gpu:setText(wx + 2, wy + 1, title .. "  (Step " .. wizard.step .. "/4)")
  gpu:setBackground(table.unpack(COLORS.bg))
  return wx + 2, wy + 3, ww - 4, wh - 5
end

local function renderWizardStep1(wx, wy, ww, wh)
  -- Name & Logic
  wizardClickZones = {}
  local row = wy
  local gpu = state.gpu

  gpu:setBackground(table.unpack(COLORS.wizardBg))

  txt(wx, row, "Rule Name:", COLORS.label)
  row = row + 1
  txt(wx + 2, row, "[" .. (wizard.name ~= "" and wizard.name or "Auto Rule") .. "]", COLORS.text)

  -- Name preset buttons
  row = row + 2
  txt(wx, row, "Quick names:", COLORS.dim)
  row = row + 1
  local bx = wx
  for i, preset in ipairs(RULE_NAME_PRESETS) do
    local label = "[" .. preset .. "]"
    if bx + #label > wx + ww then
      row = row + 1
      bx = wx
    end
    if row < wy + wh then
      local isSelected = (wizard.name == preset)
      txt(bx, row, label, isSelected and COLORS.selected or COLORS.buttonText)
      table.insert(wizardClickZones, { y = row, x1 = bx, x2 = bx + #label - 1, action = "wiz_name", value = preset })
      bx = bx + #label + 1
    end
  end

  row = row + 2
  txt(wx, row, "Logic mode:", COLORS.label)
  row = row + 1
  local anyLabel = wizard.logic == "any" and "[>ANY<]" or "[ ANY ]"
  local allLabel = wizard.logic == "all" and "[>ALL<]" or "[ ALL ]"
  txt(wx + 2, row, anyLabel, wizard.logic == "any" and COLORS.active or COLORS.buttonText)
  table.insert(wizardClickZones, { y = row, x1 = wx + 2, x2 = wx + 8, action = "wiz_logic", value = "any" })
  txt(wx + 12, row, allLabel, wizard.logic == "all" and COLORS.active or COLORS.buttonText)
  table.insert(wizardClickZones, { y = row, x1 = wx + 12, x2 = wx + 18, action = "wiz_logic", value = "all" })

  -- Navigation
  local navRow = wy + wh - 1
  local cancelLabel = "[Cancel]"
  txt(wx, navRow, cancelLabel, COLORS.buttonText)
  table.insert(wizardClickZones, { y = navRow, x1 = wx, x2 = wx + #cancelLabel - 1, action = "wiz_cancel" })
  local nextLabel = "[ Next > ]"
  txt(wx + ww - #nextLabel, navRow, nextLabel, COLORS.buttonText)
  table.insert(wizardClickZones, { y = navRow, x1 = wx + ww - #nextLabel, x2 = wx + ww - 1, action = "wiz_next" })

  gpu:setBackground(table.unpack(COLORS.bg))
end

local function renderWizardStep2(wx, wy, ww, wh)
  -- Select trigger elements
  wizardClickZones = {}
  local row = wy
  local gpu = state.gpu
  gpu:setBackground(table.unpack(COLORS.wizardBg))

  txt(wx, row, "Select TRIGGER elements (click to toggle):", COLORS.label)
  row = row + 1
  txt(wx, row, "Selected: " .. #wizard.triggers, COLORS.dim)
  row = row + 1

  local elems = getSlaveElements()
  local itemsPerPage = wh - 5
  local totalElems = #elems
  local totalElemPages = math.max(1, math.ceil(totalElems / itemsPerPage))
  if wizard.triggerPage > totalElemPages then wizard.triggerPage = totalElemPages end
  local startI = (wizard.triggerPage - 1) * itemsPerPage + 1
  local endI = math.min(startI + itemsPerPage - 1, totalElems)

  for i = startI, endI do
    if row >= wy + wh - 2 then break end
    local e = elems[i]
    local sel = isTriggerSelected(e.id)
    local prefix = sel and "[X]" or "[ ]"
    local label = prefix .. " " .. (e.elementName or "?") .. " (" .. getTypeLabel(e.elementType) .. ")"
    if e.fluidType then label = label .. " " .. e.fluidType end
    if #label > ww - 2 then label = label:sub(1, ww - 4) .. ".." end
    txt(wx, row, label, sel and COLORS.selected or COLORS.text)
    table.insert(wizardClickZones, { y = row, x1 = wx, x2 = wx + #label - 1, action = "wiz_toggle_trigger", elementId = e.id, elementName = e.elementName, elementType = e.elementType })
    row = row + 1
  end

  -- Page nav
  if totalElemPages > 1 then
    local pageInfo = "Page " .. wizard.triggerPage .. "/" .. totalElemPages
    txt(wx + ww - #pageInfo - 12, wy + wh - 2, pageInfo, COLORS.dim)
    txt(wx + ww - 10, wy + wh - 2, "[<]", wizard.triggerPage > 1 and COLORS.buttonText or COLORS.buttonDim)
    table.insert(wizardClickZones, { y = wy + wh - 2, x1 = wx + ww - 10, x2 = wx + ww - 8, action = "wiz_trig_prev" })
    txt(wx + ww - 6, wy + wh - 2, "[>]", wizard.triggerPage < totalElemPages and COLORS.buttonText or COLORS.buttonDim)
    table.insert(wizardClickZones, { y = wy + wh - 2, x1 = wx + ww - 6, x2 = wx + ww - 4, action = "wiz_trig_next" })
  end

  -- Navigation
  local navRow = wy + wh - 1
  txt(wx, navRow, "[Cancel]", COLORS.buttonText)
  table.insert(wizardClickZones, { y = navRow, x1 = wx, x2 = wx + 7, action = "wiz_cancel" })
  txt(wx + 10, navRow, "[< Back]", COLORS.buttonText)
  table.insert(wizardClickZones, { y = navRow, x1 = wx + 10, x2 = wx + 17, action = "wiz_back" })
  local nextLabel = "[ Next > ]"
  local nextColor = #wizard.triggers > 0 and COLORS.buttonText or COLORS.buttonDim
  txt(wx + ww - #nextLabel, navRow, nextLabel, nextColor)
  table.insert(wizardClickZones, { y = navRow, x1 = wx + ww - #nextLabel, x2 = wx + ww - 1, action = "wiz_next" })

  gpu:setBackground(table.unpack(COLORS.bg))
end

local function renderWizardStep3(wx, wy, ww, wh)
  -- Configure thresholds for each trigger
  wizardClickZones = {}
  local row = wy
  local gpu = state.gpu
  gpu:setBackground(table.unpack(COLORS.wizardBg))

  if #wizard.triggers == 0 then
    txt(wx, row, "No triggers selected. Go back and select triggers.", COLORS.dim)
    local navRow = wy + wh - 1
    txt(wx, navRow, "[Cancel]", COLORS.buttonText)
    table.insert(wizardClickZones, { y = navRow, x1 = wx, x2 = wx + 7, action = "wiz_cancel" })
    txt(wx + 10, navRow, "[< Back]", COLORS.buttonText)
    table.insert(wizardClickZones, { y = navRow, x1 = wx + 10, x2 = wx + 17, action = "wiz_back" })
    gpu:setBackground(table.unpack(COLORS.bg))
    return
  end

  local tidx = math.max(1, math.min(wizard.thresholdIdx, #wizard.triggers))
  local trig = wizard.triggers[tidx]

  txt(wx, row, "Configure Trigger " .. tidx .. "/" .. #wizard.triggers .. ":  " .. (trig.elementName or "?"), COLORS.label)
  row = row + 2

  -- Property selector
  txt(wx, row, "Property:", COLORS.dim)
  row = row + 1
  local px = wx
  for _, p in ipairs(TRIGGER_PROPS) do
    local label = "[" .. p.label .. "]"
    local isSel = (trig.property == p.key)
    txt(px, row, label, isSel and COLORS.selected or COLORS.buttonText)
    table.insert(wizardClickZones, { y = row, x1 = px, x2 = px + #label - 1, action = "wiz_prop", value = p.key, trigIdx = tidx })
    px = px + #label + 1
  end
  row = row + 2

  -- Min threshold
  txt(wx, row, "Min threshold:", COLORS.dim)
  row = row + 1
  local minVal = trig.min or 0
  local minLine = string.format("  [-10] [-5] [-1]  %5.0f  [+1] [+5] [+10]", minVal)
  txt(wx, row, minLine, COLORS.text)
  -- Click zones for min adjustments
  table.insert(wizardClickZones, { y = row, x1 = wx + 2, x2 = wx + 6, action = "wiz_min", delta = -10, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 8, x2 = wx + 11, action = "wiz_min", delta = -5, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 13, x2 = wx + 16, action = "wiz_min", delta = -1, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 25, x2 = wx + 28, action = "wiz_min", delta = 1, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 30, x2 = wx + 33, action = "wiz_min", delta = 5, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 35, x2 = wx + 39, action = "wiz_min", delta = 10, trigIdx = tidx })
  row = row + 2

  -- Max threshold
  txt(wx, row, "Max threshold:", COLORS.dim)
  row = row + 1
  local maxVal = trig.max or 100
  local maxLine = string.format("  [-10] [-5] [-1]  %5.0f  [+1] [+5] [+10]", maxVal)
  txt(wx, row, maxLine, COLORS.text)
  table.insert(wizardClickZones, { y = row, x1 = wx + 2, x2 = wx + 6, action = "wiz_max", delta = -10, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 8, x2 = wx + 11, action = "wiz_max", delta = -5, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 13, x2 = wx + 16, action = "wiz_max", delta = -1, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 25, x2 = wx + 28, action = "wiz_max", delta = 1, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 30, x2 = wx + 33, action = "wiz_max", delta = 5, trigIdx = tidx })
  table.insert(wizardClickZones, { y = row, x1 = wx + 35, x2 = wx + 39, action = "wiz_max", delta = 10, trigIdx = tidx })
  row = row + 2

  -- Trigger nav (prev/next trigger)
  if #wizard.triggers > 1 then
    txt(wx, row, "[< Prev Trigger]", tidx > 1 and COLORS.buttonText or COLORS.buttonDim)
    table.insert(wizardClickZones, { y = row, x1 = wx, x2 = wx + 15, action = "wiz_thr_prev" })
    txt(wx + 20, row, "[Next Trigger >]", tidx < #wizard.triggers and COLORS.buttonText or COLORS.buttonDim)
    table.insert(wizardClickZones, { y = row, x1 = wx + 20, x2 = wx + 35, action = "wiz_thr_next" })
  end

  -- Navigation
  local navRow = wy + wh - 1
  txt(wx, navRow, "[Cancel]", COLORS.buttonText)
  table.insert(wizardClickZones, { y = navRow, x1 = wx, x2 = wx + 7, action = "wiz_cancel" })
  txt(wx + 10, navRow, "[< Back]", COLORS.buttonText)
  table.insert(wizardClickZones, { y = navRow, x1 = wx + 10, x2 = wx + 17, action = "wiz_back" })
  local nextLabel = "[ Next > ]"
  txt(wx + ww - #nextLabel, navRow, nextLabel, COLORS.buttonText)
  table.insert(wizardClickZones, { y = navRow, x1 = wx + ww - #nextLabel, x2 = wx + ww - 1, action = "wiz_next" })

  gpu:setBackground(table.unpack(COLORS.bg))
end

local function renderWizardStep4(wx, wy, ww, wh)
  -- Select targets + actions + confirm
  wizardClickZones = {}
  local row = wy
  local gpu = state.gpu
  gpu:setBackground(table.unpack(COLORS.wizardBg))

  txt(wx, row, "Select TARGET elements and actions:", COLORS.label)
  row = row + 1
  txt(wx, row, "Selected: " .. #wizard.targets, COLORS.dim)
  row = row + 1

  local contElems = getSlaveControllables()
  local itemsPerPage = math.floor((wh - 7) / 2)
  local totalElems = #contElems
  local totalElemPages = math.max(1, math.ceil(totalElems / itemsPerPage))
  if wizard.targetPage > totalElemPages then wizard.targetPage = totalElemPages end
  local startI = (wizard.targetPage - 1) * itemsPerPage + 1
  local endI = math.min(startI + itemsPerPage - 1, totalElems)

  for i = startI, endI do
    if row >= wy + wh - 4 then break end
    local e = contElems[i]
    local sel = isTargetSelected(e.id)
    local prefix = sel and "[X]" or "[ ]"
    local label = prefix .. " " .. (e.elementName or "?") .. " (" .. getTypeLabel(e.elementType) .. ")"
    if #label > ww - 2 then label = label:sub(1, ww - 4) .. ".." end
    txt(wx, row, label, sel and COLORS.selected or COLORS.text)
    table.insert(wizardClickZones, { y = row, x1 = wx, x2 = wx + #label - 1, action = "wiz_toggle_target", elementId = e.id, elementName = e.elementName })
    row = row + 1

    -- If selected, show action selectors
    if sel then
      local targ = nil
      for _, t in ipairs(wizard.targets) do
        if t.elementId == e.id then targ = t; break end
      end
      if targ then
        local belowLabel = "Below: [" .. (targ.actionBelow or "enable") .. "]"
        local aboveLabel = "Above: [" .. (targ.actionAbove or "disable") .. "]"
        txt(wx + 4, row, belowLabel, COLORS.actionColor)
        table.insert(wizardClickZones, { y = row, x1 = wx + 4, x2 = wx + 4 + #belowLabel - 1, action = "wiz_cycle_below", elementId = e.id })
        txt(wx + 4 + #belowLabel + 3, row, aboveLabel, COLORS.actionColor)
        table.insert(wizardClickZones, { y = row, x1 = wx + 4 + #belowLabel + 3, x2 = wx + 4 + #belowLabel + 3 + #aboveLabel - 1, action = "wiz_cycle_above", elementId = e.id })
        row = row + 1
      end
    end
  end

  -- Page nav
  if totalElemPages > 1 then
    local pageInfo = "Page " .. wizard.targetPage .. "/" .. totalElemPages
    txt(wx + ww - #pageInfo - 12, wy + wh - 3, pageInfo, COLORS.dim)
    txt(wx + ww - 10, wy + wh - 3, "[<]", wizard.targetPage > 1 and COLORS.buttonText or COLORS.buttonDim)
    table.insert(wizardClickZones, { y = wy + wh - 3, x1 = wx + ww - 10, x2 = wx + ww - 8, action = "wiz_targ_prev" })
    txt(wx + ww - 6, wy + wh - 3, "[>]", wizard.targetPage < totalElemPages and COLORS.buttonText or COLORS.buttonDim)
    table.insert(wizardClickZones, { y = wy + wh - 3, x1 = wx + ww - 6, x2 = wx + ww - 4, action = "wiz_targ_next" })
  end

  -- Navigation + Create
  local navRow = wy + wh - 1
  txt(wx, navRow, "[Cancel]", COLORS.buttonText)
  table.insert(wizardClickZones, { y = navRow, x1 = wx, x2 = wx + 7, action = "wiz_cancel" })
  txt(wx + 10, navRow, "[< Back]", COLORS.buttonText)
  table.insert(wizardClickZones, { y = navRow, x1 = wx + 10, x2 = wx + 17, action = "wiz_back" })
  local createLabel = #wizard.targets > 0 and (wizard.ruleId and "[ Update ]" or "[ Create ]") or "[ -- ]"
  local createColor = #wizard.targets > 0 and COLORS.active or COLORS.buttonDim
  txt(wx + ww - #createLabel, navRow, createLabel, createColor)
  table.insert(wizardClickZones, { y = navRow, x1 = wx + ww - #createLabel, x2 = wx + ww - 1, action = "wiz_confirm" })

  gpu:setBackground(table.unpack(COLORS.bg))
end

local function renderWizard()
  local title = wizard.ruleId and "EDIT RULE" or "NEW RULE"
  local wx, wy, ww, wh = renderWizardFrame(title, 0)
  if wizard.step == 1 then
    renderWizardStep1(wx, wy, ww, wh)
  elseif wizard.step == 2 then
    renderWizardStep2(wx, wy, ww, wh)
  elseif wizard.step == 3 then
    renderWizardStep3(wx, wy, ww, wh)
  elseif wizard.step == 4 then
    renderWizardStep4(wx, wy, ww, wh)
  end
end

-- ============================================================================
-- Rules config main rendering
-- ============================================================================

local function renderRulesConfig(startRow)
  rulesClickZones = {}
  local row = startRow

  -- Slave selector tabs
  txt(1, row, "Monitor:", COLORS.label)
  local tabX = 10
  local allSlaves = collectorRef and collectorRef.getSlaves() or {}
  for _, s in ipairs(allSlaves) do
    local label = "[" .. (s.identity or "?") .. "]"
    if #label > 20 then label = "[" .. s.identity:sub(1, 16) .. "..]" end
    local isSel = (selectedSlaveId == s.identity)
    if tabX + #label > W - 15 then break end
    txt(tabX, row, label, isSel and COLORS.selected or COLORS.buttonText)
    table.insert(rulesClickZones, { y = row, x1 = tabX, x2 = tabX + #label - 1, action = "select_slave", identity = s.identity })
    tabX = tabX + #label + 1
  end

  local backLabel = "[< Back]"
  txt(W - #backLabel - 1, row, backLabel, COLORS.buttonText)
  table.insert(rulesClickZones, { y = row, x1 = W - #backLabel - 1, x2 = W - 2, action = "back" })
  row = row + 1
  drawSeparator(row)
  row = row + 1

  if not selectedSlaveId then
    txt(3, row, "Select a fluid_monitor above to manage its rules.", COLORS.dim)
    return row + 1
  end

  local slaveData = collectorRef and collectorRef.getSlaveData(selectedSlaveId)
  if not slaveData then
    txt(3, row, "Slave not found.", COLORS.dim)
    return row + 1
  end

  -- New rule button
  local newLabel = "[+ New Rule]"
  txt(1, row, newLabel, COLORS.buttonText)
  table.insert(rulesClickZones, { y = row, x1 = 1, x2 = #newLabel, action = "new_rule" })

  -- Refresh rules button
  local refreshLabel = "[Refresh]"
  txt(#newLabel + 3, row, refreshLabel, COLORS.buttonText)
  table.insert(rulesClickZones, { y = row, x1 = #newLabel + 3, x2 = #newLabel + 3 + #refreshLabel - 1, action = "refresh_rules" })
  row = row + 1

  -- Rules list header
  txt(1,  row, " ", COLORS.dim)
  txt(5,  row, string.format("%-20s", "Rule"), COLORS.dim)
  txt(26, row, string.format("%-5s", "On?"), COLORS.dim)
  txt(32, row, string.format("%-7s", "State"), COLORS.dim)
  txt(40, row, string.format("%-25s", "Triggers"), COLORS.dim)
  txt(66, row, string.format("%-20s", "Targets"), COLORS.dim)
  txt(87, row, string.format("%-5s", "Logic"), COLORS.dim)
  txt(93, row, "Actions", COLORS.dim)
  row = row + 1

  local rules = slaveData.rules or {}
  if #rules == 0 then
    txt(3, row, "No rules found. Click [+ New Rule] to create one, or [Refresh] to reload.", COLORS.dim)
    return row + 1
  end

  local contentRows = H - row - 2
  totalPages = math.max(1, math.ceil(#rules / contentRows))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end
  local startIdx = (currentPage - 1) * contentRows + 1
  local endIdx = math.min(startIdx + contentRows - 1, #rules)

  for i = startIdx, endIdx do
    if row >= H - 2 then break end
    local rule = rules[i]

    -- Toggle checkbox
    local chk = rule.enabled and "[v]" or "[ ]"
    local chkColor = rule.enabled and COLORS.ruleEnabled or COLORS.ruleDisabled
    txt(1, row, chk, chkColor)
    table.insert(rulesClickZones, { y = row, x1 = 1, x2 = 3, action = "toggle_rule", ruleId = rule.id })

    -- Name
    local rName = rule.name or rule.id
    if #rName > 19 then rName = rName:sub(1, 17) .. ".." end
    txt(5, row, string.format("%-20s", rName), COLORS.text)

    -- State
    local stateStr = rule.state or "idle"
    local stateColor = COLORS.dim
    if stateStr == "below" then stateColor = COLORS.active
    elseif stateStr == "above" then stateColor = COLORS.inactive end
    txt(32, row, string.format("%-7s", stateStr), stateColor)

    -- Triggers summary
    local trigSum = ""
    for j, trig in ipairs(rule.triggers or {}) do
      local tPart = (trig.elementId or "?"):sub(1, 8) .. "." .. (trig.property or "?"):sub(1, 4)
      tPart = tPart .. "[" .. tostring(trig.min or 0) .. "-" .. tostring(trig.max or 100) .. "]"
      if j > 1 then trigSum = trigSum .. "," end
      trigSum = trigSum .. tPart
    end
    if #trigSum > 24 then trigSum = trigSum:sub(1, 22) .. ".." end
    txt(40, row, string.format("%-25s", trigSum), COLORS.triggerOk)

    -- Targets summary
    local targSum = ""
    for j, targ in ipairs(rule.targets or {}) do
      local ePart = (targ.elementId or "?"):sub(1, 10)
      if j > 1 then targSum = targSum .. "," end
      targSum = targSum .. ePart
    end
    if #targSum > 19 then targSum = targSum:sub(1, 17) .. ".." end
    txt(66, row, string.format("%-20s", targSum), COLORS.actionColor)

    -- Logic
    txt(87, row, string.format("%-5s", rule.logic or "any"), COLORS.dim)

    -- Edit / Delete buttons
    txt(93, row, "[Edit]", COLORS.buttonText)
    table.insert(rulesClickZones, { y = row, x1 = 93, x2 = 98, action = "edit_rule", ruleId = rule.id, rule = rule })
    txt(100, row, "[Del]", COLORS.btnDelete)
    table.insert(rulesClickZones, { y = row, x1 = 100, x2 = 104, action = "delete_rule", ruleId = rule.id })

    row = row + 1
  end

  return row
end

-- ============================================================================
-- Footer
-- ============================================================================

local function renderFooter(footerRow)
  footerButtons = {}
  local gpu = state.gpu

  gpu:setBackground(0.08, 0.08, 0.15, 1.0)
  gpu:fill(0, footerRow, W, 1, " ")
  gpu:setBackground(table.unpack(COLORS.bg))

  local x = 1

  local prevLabel = "[<Prev]"
  local prevColor = currentPage > 1 and COLORS.buttonText or COLORS.buttonDim
  txt(x, footerRow, prevLabel, prevColor)
  table.insert(footerButtons, { x1 = x, x2 = x + #prevLabel - 1, action = "prev_page" })
  x = x + #prevLabel + 1

  local pageText = currentPage .. "/" .. totalPages
  txt(x, footerRow, pageText, COLORS.text)
  x = x + #pageText + 1

  local nextLabel = "[Next>]"
  local nextColor = currentPage < totalPages and COLORS.buttonText or COLORS.buttonDim
  txt(x, footerRow, nextLabel, nextColor)
  table.insert(footerButtons, { x1 = x, x2 = x + #nextLabel - 1, action = "next_page" })
  x = x + #nextLabel + 3

  -- Mode selector (always first for consistent position)
  local modeLabel = "[Mode:" .. state.displayMode .. "]"
  txt(x, footerRow, modeLabel, COLORS.buttonText)
  table.insert(footerButtons, { x1 = x, x2 = x + #modeLabel - 1, action = "cycle_mode" })
  x = x + #modeLabel + 2

  -- Sort (overview only)
  if state.displayMode == "overview" then
    local sortLabel = "[Sort:" .. (SORT_LABELS[SORT_MODES[currentSortIdx]] or "Name") .. "]"
    txt(x, footerRow, sortLabel, COLORS.buttonText)
    table.insert(footerButtons, { x1 = x, x2 = x + #sortLabel - 1, action = "cycle_sort" })
    x = x + #sortLabel + 3
  end

  -- Right: slave count + time
  local slaveCount = collectorRef and collectorRef.getSlaveCount() or 0
  local totalSec = math.floor((computer.millis() or 0) / 1000)
  local hh = math.floor(totalSec / 3600) % 24
  local mm = math.floor(totalSec / 60) % 60
  local ss = totalSec % 60
  local timeStr = string.format("%02d:%02d:%02d", hh, mm, ss)
  local infoText = slaveCount .. "mon"
  local rightText = infoText .. "  " .. timeStr
  txt(W - #rightText - 1, footerRow, infoText, COLORS.dim)
  txt(W - #timeStr - 1, footerRow, timeStr, COLORS.text)
end

-- ============================================================================
-- Click handling
-- ============================================================================

local function handleWizardClick(x, y)
  for _, zone in ipairs(wizardClickZones) do
    if y == zone.y and x >= zone.x1 and x <= zone.x2 then
      if zone.action == "wiz_cancel" then
        resetWizard()

      elseif zone.action == "wiz_next" then
        if wizard.step == 1 then
          if wizard.name == "" then wizard.name = "Auto Rule" end
          wizard.step = 2
        elseif wizard.step == 2 then
          if #wizard.triggers > 0 then wizard.step = 3; wizard.thresholdIdx = 1 end
        elseif wizard.step == 3 then
          wizard.step = 4
        end

      elseif zone.action == "wiz_back" then
        if wizard.step > 1 then wizard.step = wizard.step - 1 end

      elseif zone.action == "wiz_name" then
        wizard.name = zone.value or ""

      elseif zone.action == "wiz_logic" then
        wizard.logic = zone.value or "any"

      elseif zone.action == "wiz_toggle_trigger" then
        if isTriggerSelected(zone.elementId) then
          for i, t in ipairs(wizard.triggers) do
            if t.elementId == zone.elementId then table.remove(wizard.triggers, i); break end
          end
        else
          table.insert(wizard.triggers, {
            elementId = zone.elementId,
            elementName = zone.elementName,
            elementType = zone.elementType,
            property = getDefaultTriggerProp(zone.elementType),
            min = 20,
            max = 80,
          })
        end

      elseif zone.action == "wiz_trig_prev" then
        if wizard.triggerPage > 1 then wizard.triggerPage = wizard.triggerPage - 1 end

      elseif zone.action == "wiz_trig_next" then
        wizard.triggerPage = wizard.triggerPage + 1

      elseif zone.action == "wiz_prop" and zone.trigIdx then
        local trig = wizard.triggers[zone.trigIdx]
        if trig then trig.property = zone.value end

      elseif zone.action == "wiz_min" and zone.trigIdx then
        local trig = wizard.triggers[zone.trigIdx]
        if trig then trig.min = math.max(0, math.min(100, (trig.min or 0) + (zone.delta or 0))) end

      elseif zone.action == "wiz_max" and zone.trigIdx then
        local trig = wizard.triggers[zone.trigIdx]
        if trig then trig.max = math.max(0, math.min(100, (trig.max or 100) + (zone.delta or 0))) end

      elseif zone.action == "wiz_thr_prev" then
        if wizard.thresholdIdx > 1 then wizard.thresholdIdx = wizard.thresholdIdx - 1 end

      elseif zone.action == "wiz_thr_next" then
        if wizard.thresholdIdx < #wizard.triggers then wizard.thresholdIdx = wizard.thresholdIdx + 1 end

      elseif zone.action == "wiz_toggle_target" then
        if isTargetSelected(zone.elementId) then
          for i, t in ipairs(wizard.targets) do
            if t.elementId == zone.elementId then table.remove(wizard.targets, i); break end
          end
        else
          table.insert(wizard.targets, {
            elementId = zone.elementId,
            elementName = zone.elementName,
            actionBelow = "enable",
            actionAbove = "disable",
          })
        end

      elseif zone.action == "wiz_targ_prev" then
        if wizard.targetPage > 1 then wizard.targetPage = wizard.targetPage - 1 end

      elseif zone.action == "wiz_targ_next" then
        wizard.targetPage = wizard.targetPage + 1

      elseif zone.action == "wiz_cycle_below" then
        for _, t in ipairs(wizard.targets) do
          if t.elementId == zone.elementId then
            t.actionBelow = t.actionBelow == "enable" and "disable" or "enable"
            break
          end
        end

      elseif zone.action == "wiz_cycle_above" then
        for _, t in ipairs(wizard.targets) do
          if t.elementId == zone.elementId then
            t.actionAbove = t.actionAbove == "enable" and "disable" or "enable"
            break
          end
        end

      elseif zone.action == "wiz_confirm" then
        if #wizard.targets > 0 and #wizard.triggers > 0 and collectorRef then
          -- Build triggers for the command (strip UI-only fields)
          local cmdTriggers = {}
          for _, t in ipairs(wizard.triggers) do
            table.insert(cmdTriggers, {
              elementId = t.elementId,
              property = t.property,
              min = t.min,
              max = t.max,
            })
          end
          local cmdTargets = {}
          for _, t in ipairs(wizard.targets) do
            table.insert(cmdTargets, {
              elementId = t.elementId,
              actionBelow = t.actionBelow,
              actionAbove = t.actionAbove,
            })
          end
          if wizard.ruleId then
            -- Update existing rule
            collectorRef.sendCommand(wizard.targetSlaveId, {
              action = "rule_update",
              ruleId = wizard.ruleId,
              name = wizard.name,
              triggers = cmdTriggers,
              targets = cmdTargets,
              logic = wizard.logic,
            })
          else
            -- Create new rule
            collectorRef.sendCommand(wizard.targetSlaveId, {
              action = "rule_create",
              name = wizard.name,
              triggers = cmdTriggers,
              targets = cmdTargets,
              logic = wizard.logic,
              enabled = true,
            })
          end
          -- Request updated rules list after a short delay
          collectorRef.requestRuleList(wizard.targetSlaveId)
          resetWizard()
        end
      end

      AggDisplay.render()
      return true
    end
  end
  return false
end

handleClick = function(x, y, btn)
  -- Wizard intercepts all clicks when active
  if wizard.active then
    handleWizardClick(x, y)
    return
  end

  -- Footer
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
        end
        AggDisplay.render()
        return
      end
    end
    return
  end

  -- Overview: click on slave row to drill down
  if state.displayMode == "overview" then
    for _, zone in ipairs(overviewClickZones) do
      if y == zone.y then
        selectedSlaveId = zone.identity
        state.displayMode = "slave_detail"
        currentPage = 1
        AggDisplay.render()
        return
      end
    end
  end

  -- Slave detail mode
  if state.displayMode == "slave_detail" then
    -- Back button
    for _, zone in ipairs(detailClickZones) do
      if zone.action == "back" and y == zone.y and x >= zone.x1 and x <= zone.x2 then
        state.displayMode = "overview"
        currentPage = 1
        AggDisplay.render()
        return
      end
    end
    -- Click on controllable element to toggle
    for _, zone in ipairs(detailClickZones) do
      if y == zone.y and zone.element and zone.element.controllable and zone.identity and collectorRef then
        collectorRef.sendCommand(zone.identity, {
          action = "toggle",
          elementId = zone.element.id,
        })
        return
      end
    end
  end

  -- Rules config mode
  if state.displayMode == "rules_config" then
    for _, zone in ipairs(rulesClickZones) do
      if y == zone.y and x >= zone.x1 and x <= zone.x2 then
        if zone.action == "back" then
          state.displayMode = "overview"
          currentPage = 1
        elseif zone.action == "select_slave" then
          selectedSlaveId = zone.identity
          currentPage = 1
          -- Request rules for this slave
          if collectorRef then collectorRef.requestRuleList(zone.identity) end
        elseif zone.action == "new_rule" then
          resetWizard()
          wizard.active = true
          wizard.step = 1
          wizard.targetSlaveId = selectedSlaveId
        elseif zone.action == "refresh_rules" then
          if collectorRef and selectedSlaveId then
            collectorRef.requestRuleList(selectedSlaveId)
          end
        elseif zone.action == "toggle_rule" and zone.ruleId and collectorRef then
          collectorRef.sendCommand(selectedSlaveId, {
            action = "rule_toggle",
            ruleId = zone.ruleId,
          })
          -- Refresh after toggle
          collectorRef.requestRuleList(selectedSlaveId)
        elseif zone.action == "edit_rule" and zone.rule then
          resetWizard()
          wizard.active = true
          wizard.step = 1
          wizard.targetSlaveId = selectedSlaveId
          wizard.ruleId = zone.ruleId
          wizard.name = zone.rule.name or ""
          wizard.logic = zone.rule.logic or "any"
          -- Load triggers (add UI fields)
          wizard.triggers = {}
          for _, t in ipairs(zone.rule.triggers or {}) do
            table.insert(wizard.triggers, {
              elementId = t.elementId,
              elementName = t.elementId, -- best we have from the stored rule
              elementType = "unknown",
              property = t.property or "fillPercent",
              min = t.min or 0,
              max = t.max or 100,
            })
          end
          -- Load targets
          wizard.targets = {}
          for _, t in ipairs(zone.rule.targets or {}) do
            table.insert(wizard.targets, {
              elementId = t.elementId,
              elementName = t.elementId,
              actionBelow = t.actionBelow or "enable",
              actionAbove = t.actionAbove or "disable",
            })
          end
        elseif zone.action == "delete_rule" and zone.ruleId and collectorRef then
          collectorRef.sendCommand(selectedSlaveId, {
            action = "rule_delete",
            ruleId = zone.ruleId,
          })
          collectorRef.requestRuleList(selectedSlaveId)
        end
        AggDisplay.render()
        return
      end
    end
  end
end

-- ============================================================================
-- Console fallback
-- ============================================================================

function AggDisplay.printReport()
  if not collectorRef then
    print("[AGG_DSP] No collector available")
    return
  end
  local slaves = collectorRef.getSlaves()
  print("--- FLUID AGGREGATOR ---")
  print(string.format("%d fluid_monitor(s) discovered", #slaves))
  for _, s in ipairs(slaves) do
    print(string.format("  %-20s  %s  elems:%d  groups:%d  rules:%d  fill:%.1f%%",
      s.identity, s.state, s.elementCount or 0, s.groupCount or 0, s.ruleCount or 0, s.avgFill or 0))
  end
  print("------------------------")
end

-- ============================================================================
-- Main render
-- ============================================================================

function AggDisplay.render()
  if not state.enabled then return end

  local gpu = state.gpu
  local row = 0

  gpu:setBackground(table.unpack(COLORS.bg))
  gpu:fill(0, 0, W, H, " ")

  local titleText = "=== FLUID AGGREGATOR ==="
  txt(math.floor((W - #titleText) / 2), row, titleText, COLORS.title)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  if state.displayMode == "slave_detail" then
    renderSlaveDetail(row)
  elseif state.displayMode == "rules_config" then
    renderRulesConfig(row)
  else
    renderOverview(row)
  end

  -- Wizard overlay
  if wizard.active then
    renderWizard()
  end

  renderFooter(H - 1)
  gpu:flush()
end

return AggDisplay
