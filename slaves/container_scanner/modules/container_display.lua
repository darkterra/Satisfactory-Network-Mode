-- modules/container_display.lua
-- Renders container inventory data on a GPU T1 screen.
-- Supports display modes cycled via click: "both" (overview+detail) and "compact".
-- Click-based pagination and sort cycling on footer buttons.
-- Falls back to console output if no GPU/screen is available.

local ContainerDisplay = {}

-- Screen dimensions (GPU T1 character mode)
local W = 125
local H = 50

-- Color palette
local COLORS = {
  bg         = { 0.05, 0.05, 0.1, 1.0 },
  title      = { 0.2, 0.7, 1.0, 1.0 },
  text       = { 1.0, 1.0, 1.0, 1.0 },
  label      = { 0.6, 0.6, 0.6, 1.0 },
  dim        = { 0.4, 0.4, 0.4, 1.0 },
  separator  = { 0.3, 0.3, 0.4, 1.0 },
  groupName  = { 1.0, 0.8, 0.2, 1.0 },
  contName   = { 0.4, 0.8, 1.0, 1.0 },
  good       = { 0.3, 1.0, 0.4, 1.0 },
  warning    = { 1.0, 0.8, 0.2, 1.0 },
  error      = { 1.0, 0.3, 0.3, 1.0 },
  fillEmpty  = { 0.3, 0.3, 0.3, 1.0 },
  fillLow    = { 1.0, 0.3, 0.3, 1.0 },
  fillMid    = { 1.0, 0.8, 0.2, 1.0 },
  fillHigh   = { 0.3, 1.0, 0.4, 1.0 },
  fillFull   = { 0.2, 0.7, 1.0, 1.0 },
  itemName   = { 0.8, 0.8, 0.6, 1.0 },
  count      = { 0.9, 0.9, 0.9, 1.0 },
  button     = { 0.15, 0.15, 0.25, 1.0 },
  buttonText = { 0.8, 0.9, 1.0, 1.0 },
  buttonDim  = { 0.4, 0.5, 0.6, 1.0 },
}

-- Display state
local state = {
  gpu = nil,
  screen = nil,
  enabled = false,
  displayMode = "both", -- "both", "overview", "detail", or "compact" (cycled via click)
  compactPrefixStrip = "",
  defaultGroupName = "default",
}

-- Available display modes (cycled via click)
local DISPLAY_MODES = { "both", "overview", "detail", "compact" }

-- Sort modes for detail view
local SORT_MODES = { "alpha", "fill_asc", "fill_desc" }
local SORT_LABELS = { alpha = "A-Z", fill_asc = "Fill+", fill_desc = "Fill-" }
local currentSortIdx = 1

-- Pagination state (for detail section)
local currentPage = 1
local totalPages = 1
local pageSize = 0 -- computed at render time based on available rows

-- Footer click-zone definitions (populated at render time)
-- Each entry: { x1, x2, action }
local footerButtons = {}

-- Last scan result reference (for re-sorting without re-scan)
local lastScanResult = nil

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the display with a GPU and screen.
-- @param gpu GPU T1 proxy
-- @param screen Screen proxy (PCI or network)
-- @param displayMode string - initial display mode ("both" or "compact")
-- @return boolean success
function ContainerDisplay.init(gpu, screen, options)
  if not gpu or not screen then
    print("[CONT_DSP] No GPU/Screen - using console fallback")
    state.enabled = false
    return false
  end

  state.gpu = gpu
  state.screen = screen

  options = options or {}
  local dm = options.displayMode or "both"
  if dm == "overview" or dm == "detail" or dm == "compact" or dm == "both" then
    state.displayMode = dm
  else
    state.displayMode = "both"
  end
  state.compactPrefixStrip = options.compactPrefixStrip or ""
  state.defaultGroupName = options.defaultGroupName or "default"

  gpu:bindScreen(screen)
  gpu:setSize(W, H)
  state.enabled = true

  -- Listen for mouse events (click-based navigation)
  event.listen(gpu)
  if SIGNAL_HANDLERS then
    SIGNAL_HANDLERS["OnMouseDown"] = SIGNAL_HANDLERS["OnMouseDown"] or {}
    table.insert(SIGNAL_HANDLERS["OnMouseDown"], function(signal, sender, x, y, btn)
      if sender == state.gpu then
        handleClick(x, y, btn)
      end
    end)
  end

  print("[CONT_DSP] Display initialized (" .. W .. "x" .. H .. ", mode: " .. state.displayMode .. ")")
  return true
end

--- Check if screen rendering is available.
-- @return boolean
function ContainerDisplay.isEnabled()
  return state.enabled
end

-- ============================================================================
-- Drawing helpers
-- ============================================================================

--- Write text at a position with a foreground color.
local function txt(col, row, text, color)
  if row < 0 or row >= H then return end
  state.gpu:setForeground(table.unpack(color or COLORS.text))
  state.gpu:setText(col, row, text)
end

--- Draw a horizontal separator line.
local function drawSeparator(row)
  if row < 0 or row >= H then return end
  state.gpu:setForeground(table.unpack(COLORS.separator))
  state.gpu:fill(0, row, W, 1, "-")
end

--- Get the fill color based on percentage.
local function getFillColor(percent)
  if percent <= 0 then return COLORS.fillEmpty end
  if percent < 25 then return COLORS.fillLow end
  if percent < 50 then return COLORS.fillMid end
  if percent < 90 then return COLORS.fillHigh end
  return COLORS.fillFull
end

--- Format a large number for compact display.
local function formatCount(n)
  if not n then return "0" end
  if n >= 1000000 then
    return string.format("%.1fM", n / 1000000)
  elseif n >= 1000 then
    return string.format("%.1fK", n / 1000)
  end
  return tostring(n)
end

--- Draw a fill bar with percentage text.
-- @param col number - starting column
-- @param row number - row
-- @param barWidth number - width of the bar body (excluding brackets)
-- @param percent number - fill percentage (0-100)
-- @return number - total characters drawn
local function drawFillBar(col, row, barWidth, percent)
  if row < 0 or row >= H then return barWidth + 2 end
  local gpu = state.gpu
  local filled = math.floor(barWidth * math.min(percent, 100) / 100)
  local empty = barWidth - filled

  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col, row, "[")

  gpu:setForeground(table.unpack(getFillColor(percent)))
  gpu:setText(col + 1, row, string.rep("#", filled))

  gpu:setForeground(table.unpack(COLORS.fillEmpty))
  gpu:setText(col + 1 + filled, row, string.rep("-", empty))

  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col + 1 + barWidth, row, "]")

  -- Percentage text after bar
  local pctText = string.format("%5.1f%%", percent)
  gpu:setForeground(table.unpack(getFillColor(percent)))
  gpu:setText(col + barWidth + 2, row, pctText)

  return col + barWidth + 2 + #pctText
end

--- Draw a label: value pair.
local function drawLabelValue(col, row, label, value, valueColor)
  if row < 0 or row >= H then return end
  local gpu = state.gpu
  gpu:setForeground(table.unpack(COLORS.label))
  gpu:setText(col, row, label)
  gpu:setForeground(table.unpack(valueColor or COLORS.text))
  gpu:setText(col + #label, row, tostring(value))
end

--- Handle mouse click events.
-- Checks footer button zones and triggers actions.
function handleClick(x, y, btn)
  local footerRow = H - 1
  if y ~= footerRow then return end

  for _, button in ipairs(footerButtons) do
    if x >= button.x1 and x <= button.x2 then
      if button.action == "prev_page" then
        if currentPage > 1 then
          currentPage = currentPage - 1
        end
      elseif button.action == "next_page" then
        if currentPage < totalPages then
          currentPage = currentPage + 1
        end
      elseif button.action == "cycle_sort" then
        currentSortIdx = (currentSortIdx % #SORT_MODES) + 1
        currentPage = 1
      elseif button.action == "cycle_mode" then
        local modeIdx = 1
        for i, m in ipairs(DISPLAY_MODES) do
          if m == state.displayMode then modeIdx = i; break end
        end
        modeIdx = (modeIdx % #DISPLAY_MODES) + 1
        state.displayMode = DISPLAY_MODES[modeIdx]
        currentPage = 1
      end
      -- Immediate re-render with last data
      if lastScanResult then
        ContainerDisplay.render(lastScanResult)
      end
      return
    end
  end
end

-- ============================================================================
-- Rendering
-- ============================================================================

--- Sort containers within groups based on current sort mode.
-- @param scanResult table
local function sortedContainers(scanResult)
  local sortMode = SORT_MODES[currentSortIdx]
  for _, groupName in ipairs(scanResult.groupOrder) do
    local group = scanResult.groups[groupName]
    if group and group.containers then
      local sorted = {}
      for i, c in ipairs(group.containers) do sorted[i] = c end
      if sortMode == "fill_asc" then
        table.sort(sorted, function(a, b) return a.totalFill < b.totalFill end)
      elseif sortMode == "fill_desc" then
        table.sort(sorted, function(a, b) return a.totalFill > b.totalFill end)
      else -- "alpha"
        table.sort(sorted, function(a, b) return a.name < b.name end)
      end
      group.containers = sorted
    end
  end
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
      return (ga and ga.avgFill or 0) < (gb and gb.avgFill or 0)
    end)
  elseif sortMode == "fill_desc" then
    table.sort(order, function(a, b)
      local ga, gb = scanResult.groups[a], scanResult.groups[b]
      return (ga and ga.avgFill or 0) > (gb and gb.avgFill or 0)
    end)
  end
  return order
end

--- Flatten all containers into a single ordered list respecting group order.
-- @param scanResult table
-- @return table flat, table bounds
local function flattenContainers(scanResult, gOrder)
  local flat = {}
  local bounds = {}
  for _, groupName in ipairs(gOrder or scanResult.groupOrder) do
    local group = scanResult.groups[groupName]
    if group then
      local startIdx = #flat + 1
      for _, c in ipairs(group.containers) do
        table.insert(flat, { container = c, groupName = groupName, group = group })
      end
      table.insert(bounds, { groupName = groupName, startIdx = startIdx, endIdx = #flat })
    end
  end
  return flat, bounds
end

-- ============================================================================
-- Rendering
-- ============================================================================

--- Render the overview section (global stats only, always shown).
-- @param scanResult table
-- @param startRow number
-- @return number - next available row
local function renderOverview(scanResult, startRow)
  local row = startRow
  local stats = scanResult.globalStats

  txt(1, row, "OVERVIEW", COLORS.title)
  local modeTag = "  [" .. state.displayMode .. "]"
  txt(10, row, modeTag, COLORS.dim)
  row = row + 1

  drawLabelValue(2, row, "Containers: ", tostring(stats.totalContainers), COLORS.text)
  drawLabelValue(24, row, "Items: ", formatCount(stats.totalItems), COLORS.text)
  drawLabelValue(44, row, "Slots: ", stats.slotsUsed .. "/" .. stats.totalSlots, COLORS.text)
  drawLabelValue(66, row, "Avg fill: ", string.format("%.1f%%", stats.avgFill), getFillColor(stats.avgFill))
  if stats.defaultGroupCount and stats.defaultGroupCount > 0 then
    drawLabelValue(88, row, "Default: ", tostring(stats.defaultGroupCount), COLORS.warning)
  end
  row = row + 1

  drawSeparator(row)
  row = row + 1

  return row
end

--- Render the detail section with click-based pagination.
-- Shows group headers with summaries + per-container lines, paginated.
-- @param scanResult table
-- @param startRow number
-- @return number - next available row
local function renderDetail(scanResult, startRow)
  local row = startRow

  local sortLabel = SORT_LABELS[SORT_MODES[currentSortIdx]] or "A-Z"
  txt(1, row, "DETAIL", COLORS.title)
  txt(10, row, "(sort: " .. sortLabel .. ")", COLORS.dim)
  row = row + 1

  local headerFormat = string.format("  %-20s %-18s %8s  %-8s  %s", "Container", "Fill", "Items", "Slots", "Top Item")
  txt(0, row, headerFormat, COLORS.dim)
  row = row + 1

  -- Available content rows (leave 1 for footer)
  local contentRows = H - row - 1
  if contentRows < 1 then return row end

  local flat, bounds = flattenContainers(scanResult, sortedGroupOrder(scanResult))
  local totalItems = #flat

  -- Compute page breaks accounting for group header rows
  local pages = {}
  local rowsUsed = 0
  local pageStart = 1

  for i, entry in ipairs(flat) do
    local needsGroupHeader = false
    for _, b in ipairs(bounds) do
      if b.startIdx == i then needsGroupHeader = true; break end
    end
    local rowCost = needsGroupHeader and 2 or 1
    if rowsUsed + rowCost > contentRows and rowsUsed > 0 then
      table.insert(pages, { startIdx = pageStart, endIdx = i - 1 })
      pageStart = i
      rowsUsed = rowCost
    else
      rowsUsed = rowsUsed + rowCost
    end
  end
  if pageStart <= totalItems then
    table.insert(pages, { startIdx = pageStart, endIdx = totalItems })
  end

  totalPages = math.max(1, #pages)
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end

  local page = pages[currentPage]
  if page then
    local lastGroup = nil
    for i = page.startIdx, page.endIdx do
      if row >= H - 1 then break end
      local entry = flat[i]
      local c = entry.container

      -- Group header with summary
      if entry.groupName ~= lastGroup then
        local g = entry.group
        txt(1, row, g.name, COLORS.groupName)
        local groupInfo = string.format("  %dx  avg %.1f%%", g.containerCount, g.avgFill)
        txt(1 + #g.name, row, groupInfo, COLORS.dim)
        -- Top item for group
        if #g.topItems > 0 then
          local topInfo = "  top: " .. g.topItems[1].name
          txt(1 + #g.name + #groupInfo, row, topInfo, COLORS.itemName)
        end
        row = row + 1
        if row >= H - 1 then break end
        lastGroup = entry.groupName
      end

      -- Container line
      local displayName = c.name:match("([^%s]+)") or c.name
      if #displayName > 18 then
        displayName = displayName:sub(1, 15) .. "..."
      end
      txt(2, row, string.format("%-18s", displayName), COLORS.contName)

      local nextCol = drawFillBar(21, row, 16, c.totalFill)

      txt(nextCol + 1, row, string.format("%8s", formatCount(c.totalItems)), COLORS.count)
      local slotsText = string.format("  %d/%d", c.slotsUsed or 0, c.totalSlots or 0)
      txt(nextCol + 10, row, slotsText, COLORS.dim)

      local topItemCol = nextCol + 11 + #slotsText
      if #c.topItems > 0 then
        local topItem = c.topItems[1].name
        if #topItem > 20 then topItem = topItem:sub(1, 17) .. "..." end
        txt(topItemCol, row, topItem, COLORS.itemName)

        if #c.topItems > 1 and topItemCol + #topItem + 2 < W - 15 then
          local second = ", " .. c.topItems[2].name
          if #second > 20 then second = second:sub(1, 17) .. "..." end
          txt(topItemCol + #topItem, row, second, COLORS.dim)
        end
      end

      row = row + 1
    end
  end

  return row
end

--- Render "both" mode: aggregation zone on top + detail zone below, paginated.
-- Each page shows N groups in both zones. The number of groups per page is
-- determined by the total space needed for aggregation rows + detail rows.
-- @param scanResult table
-- @param startRow number
-- @return number - next available row
local function renderBoth(scanResult, startRow)
  local row = startRow

  -- Get sorted group order
  local gOrder = sortedGroupOrder(scanResult)

  -- Available content rows (leave 1 for footer)
  local availableRows = H - row - 1
  if availableRows < 3 then return row end

  -- Compute pages: each page has aggregation rows + separator + detail rows
  -- For each group: 1 agg row + 1 detail header row + containerCount detail rows
  -- Plus 1 separator between zones per page
  local pages = {}
  local pageGroups = {}
  local usedRows = 1 -- 1 for separator between zones

  for _, groupName in ipairs(gOrder) do
    local group = scanResult.groups[groupName]
    if group then
      local cost = 1 + 1 + group.containerCount -- agg + detail header + containers
      if usedRows + cost > availableRows and #pageGroups > 0 then
        table.insert(pages, pageGroups)
        pageGroups = {}
        usedRows = 1 -- separator
      end
      table.insert(pageGroups, groupName)
      usedRows = usedRows + cost
    end
  end
  if #pageGroups > 0 then
    table.insert(pages, pageGroups)
  end

  totalPages = math.max(1, #pages)
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end

  local currentGroups = pages[currentPage] or {}

  -- === Aggregation zone ===
  for _, groupName in ipairs(currentGroups) do
    if row >= H - 1 then break end
    local group = scanResult.groups[groupName]
    if group then
      local gName = group.name
      if #gName > 20 then gName = gName:sub(1, 18) .. ".." end
      txt(1, row, string.format("%-20s", gName), COLORS.groupName)

      local info = string.format(" %3dx  avg ", group.containerCount)
      txt(22, row, info, COLORS.dim)

      local barCol = 22 + #info
      local nextCol = drawFillBar(barCol, row, 10, group.avgFill)

      if #group.topItems > 0 then
        local topName = group.topItems[1].name
        if #topName > 20 then topName = topName:sub(1, 17) .. "..." end
        txt(nextCol + 2, row, topName, COLORS.itemName)
      end

      row = row + 1
    end
  end

  -- Separator between aggregation and detail zones
  if row < H - 1 then
    drawSeparator(row)
    row = row + 1
  end

  -- === Detail zone ===
  for _, groupName in ipairs(currentGroups) do
    if row >= H - 1 then break end
    local group = scanResult.groups[groupName]
    if group then
      -- Group header
      txt(1, row, group.name, COLORS.groupName)
      local groupInfo = string.format("  %dx  avg %.1f%%", group.containerCount, group.avgFill)
      txt(1 + #group.name, row, groupInfo, COLORS.dim)
      row = row + 1

      -- Container lines
      for _, c in ipairs(group.containers) do
        if row >= H - 1 then break end

        local displayName = c.name:match("([^%s]+)") or c.name
        if #displayName > 18 then
          displayName = displayName:sub(1, 15) .. "..."
        end
        txt(2, row, string.format("%-18s", displayName), COLORS.contName)

        local nextCol = drawFillBar(21, row, 16, c.totalFill)

        txt(nextCol + 1, row, string.format("%8s", formatCount(c.totalItems)), COLORS.count)
        local slotsText = string.format("  %d/%d", c.slotsUsed or 0, c.totalSlots or 0)
        txt(nextCol + 10, row, slotsText, COLORS.dim)

        local topItemCol = nextCol + 11 + #slotsText
        if #c.topItems > 0 then
          local topItem = c.topItems[1].name
          if #topItem > 20 then topItem = topItem:sub(1, 17) .. "..." end
          txt(topItemCol, row, topItem, COLORS.itemName)
        end

        row = row + 1
      end
    end
  end

  return row
end

--- Render "overview" mode: paginated group summary list.
-- Shows one row per group with key stats.
-- @param scanResult table
-- @param startRow number
-- @return number - next available row
local function renderOverviewOnly(scanResult, startRow)
  local row = startRow

  local sortLabel = SORT_LABELS[SORT_MODES[currentSortIdx]] or "A-Z"
  txt(1, row, "GROUPS", COLORS.title)
  txt(10, row, "(sort: " .. sortLabel .. ")", COLORS.dim)
  row = row + 1

  -- Column header
  local headerFormat = string.format("  %-20s %5s  %-16s  %8s  %8s  %s",
    "Group", "Count", "Avg Fill", "Items", "Slots", "Top Item")
  txt(0, row, headerFormat, COLORS.dim)
  row = row + 1

  local gOrder = sortedGroupOrder(scanResult)

  -- Available content rows
  local contentRows = H - row - 1
  if contentRows < 1 then return row end

  totalPages = math.max(1, math.ceil(#gOrder / contentRows))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end

  local startIdx = (currentPage - 1) * contentRows + 1
  local endIdx = math.min(#gOrder, startIdx + contentRows - 1)

  for i = startIdx, endIdx do
    if row >= H - 1 then break end
    local groupName = gOrder[i]
    local group = scanResult.groups[groupName]
    if group then
      local gName = group.name
      if #gName > 20 then gName = gName:sub(1, 18) .. ".." end
      txt(1, row, string.format("%-20s", gName), COLORS.groupName)
      txt(22, row, string.format("%4dx", group.containerCount), COLORS.dim)

      local nextCol = drawFillBar(28, row, 10, group.avgFill)

      txt(nextCol + 2, row, string.format("%8s", formatCount(group.totalItems)), COLORS.count)
      local slotsText = string.format("  %d/%d", group.slotsUsed, group.totalSlots)
      txt(nextCol + 11, row, slotsText, COLORS.dim)

      local topCol = nextCol + 12 + #slotsText
      if #group.topItems > 0 then
        local topName = group.topItems[1].name
        if #topName > 20 then topName = topName:sub(1, 17) .. "..." end
        txt(topCol, row, topName, COLORS.itemName)
      end

      row = row + 1
    end
  end

  return row
end

--- Render compact mode (dense group cards, 3 per row).
-- @param scanResult table
-- @param startRow number
-- @return number - next available row
local function renderCompact(scanResult, startRow)
  local row = startRow

  local sortLabel = SORT_LABELS[SORT_MODES[currentSortIdx]] or "A-Z"
  txt(1, row, "COMPACT", COLORS.title)
  txt(11, row, "(sort: " .. sortLabel .. ")", COLORS.dim)
  row = row + 1

  local cardWidth = math.floor(W / 3)
  local cardsPerRow = 3
  local barWidth = 8

  -- Sort groups based on current sort mode
  local groups = {}
  for _, groupName in ipairs(scanResult.groupOrder) do
    local group = scanResult.groups[groupName]
    if group then table.insert(groups, group) end
  end
  local sortMode = SORT_MODES[currentSortIdx]
  if sortMode == "fill_asc" then
    table.sort(groups, function(a, b) return a.avgFill < b.avgFill end)
  elseif sortMode == "fill_desc" then
    table.sort(groups, function(a, b) return a.avgFill > b.avgFill end)
  end
  -- "alpha" keeps the original groupOrder (already alphabetical from scanner)

  local availableRows = H - row - 1 -- leave 1 for footer
  local cardsPerPage = cardsPerRow * availableRows
  totalPages = math.max(1, math.ceil(#groups / cardsPerPage))
  if currentPage > totalPages then currentPage = totalPages end
  if currentPage < 1 then currentPage = 1 end

  local startIdx = (currentPage - 1) * cardsPerPage + 1
  local endIdx = math.min(#groups, startIdx + cardsPerPage - 1)

  local col = 0
  local cardInRow = 0
  for i = startIdx, endIdx do
    if row >= H - 1 then break end
    local group = groups[i]

    local gName = group.name
    if state.compactPrefixStrip ~= "" and gName:sub(1, #state.compactPrefixStrip) == state.compactPrefixStrip then
      gName = gName:sub(#state.compactPrefixStrip + 1)
    end
    if #gName > 12 then gName = gName:sub(1, 10) .. ".." end
    txt(col, row, gName, COLORS.groupName)

    local cntText = string.format(" %dx", group.containerCount)
    txt(col + #gName, row, cntText, COLORS.dim)

    local topText = ""
    if #group.topItems > 0 then
      local topName = group.topItems[1].name
      if #topName > 8 then topName = topName:sub(1, 7) .. "." end
      topText = " " .. topName
    end
    local topCol = col + #gName + #cntText
    if #topText > 0 and topCol + #topText < col + cardWidth - barWidth - 8 then
      txt(topCol, row, topText, COLORS.itemName)
    end

    local barCol = col + cardWidth - barWidth - 8
    drawFillBar(barCol, row, barWidth, group.avgFill)

    cardInRow = cardInRow + 1
    if cardInRow >= cardsPerRow then
      cardInRow = 0
      col = 0
      row = row + 1
    else
      col = col + cardWidth
    end
  end

  if cardInRow > 0 then row = row + 1 end

  return row
end

--- Draw the footer bar with clickable buttons (single line).
-- @param scanResult table
-- @param footerRow number
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

  -- [Sort: X]
  local sortBtnLabel = "[Sort:" .. (SORT_LABELS[SORT_MODES[currentSortIdx]] or "A-Z") .. "]"
  txt(x, footerRow, sortBtnLabel, COLORS.buttonText)
  table.insert(footerButtons, { x1 = x, x2 = x + #sortBtnLabel - 1, action = "cycle_sort" })
  x = x + #sortBtnLabel + 3

  -- [Mode: X]
  local modeLabel = "[Mode:" .. state.displayMode .. "]"
  txt(x, footerRow, modeLabel, COLORS.buttonText)
  table.insert(footerButtons, { x1 = x, x2 = x + #modeLabel - 1, action = "cycle_mode" })

  -- Right-aligned: containers/groups + last update time
  local totalSec = math.floor((scanResult.timestamp or 0) / 1000)
  local hh = math.floor(totalSec / 3600) % 24
  local mm = math.floor(totalSec / 60) % 60
  local ss = totalSec % 60
  local timeStr = string.format("%02d:%02d:%02d", hh, mm, ss)

  local infoText = tostring(scanResult.globalStats.totalContainers) .. "c/"
    .. tostring(scanResult.globalStats.totalGroups) .. "g"
  local rightText = infoText .. "  " .. timeStr
  txt(W - #rightText - 1, footerRow, infoText, COLORS.dim)
  txt(W - #timeStr - 1, footerRow, timeStr, COLORS.text)
end

--- Print a console-friendly summary (fallback when no screen).
-- @param scanResult table
function ContainerDisplay.printReport(scanResult)
  local stats = scanResult.globalStats
  print("--- CONTAINER INVENTORY REPORT ---")
  print(string.format("Containers: %d  |  Items: %s  |  Slots: %d/%d  |  Avg fill: %.1f%%",
    stats.totalContainers, formatCount(stats.totalItems),
    stats.slotsUsed, stats.totalSlots, stats.avgFill))
  print("")

  for _, groupName in ipairs(scanResult.groupOrder) do
    local group = scanResult.groups[groupName]
    if group then
      print(string.format("  [%s] %d containers, avg %.1f%%, items: %s, slots: %d/%d",
        group.name, group.containerCount, group.avgFill,
        formatCount(group.totalItems), group.slotsUsed, group.totalSlots))
      for _, c in ipairs(group.containers) do
        local topItem = (#c.topItems > 0) and c.topItems[1].name or "-"
        print(string.format("    %-20s %5.1f%%  %s  %d/%d  %s",
          c.name, c.totalFill,
          formatCount(c.totalItems), c.slotsUsed, c.totalSlots, topItem))
      end
    end
  end
  print("----------------------------------")
end

--- Render the full container dashboard on the GPU screen.
-- @param scanResult table
function ContainerDisplay.render(scanResult)
  if not state.enabled then return end
  if not scanResult then return end

  sortedContainers(scanResult)
  lastScanResult = scanResult

  local gpu = state.gpu
  local row = 0

  gpu:setBackground(table.unpack(COLORS.bg))
  gpu:fill(0, 0, W, H, " ")

  local titleText = "=== CONTAINER INVENTORY MONITOR ==="
  txt(math.floor((W - #titleText) / 2), row, titleText, COLORS.title)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  -- Overview (global stats only, 3 rows)
  row = renderOverview(scanResult, row)

  -- Mode-specific content (has full remaining space for pagination)
  if state.displayMode == "compact" then
    renderCompact(scanResult, row)
  elseif state.displayMode == "overview" then
    renderOverviewOnly(scanResult, row)
  elseif state.displayMode == "detail" then
    renderDetail(scanResult, row)
  else -- "both"
    renderBoth(scanResult, row)
  end

  -- Footer (1 line at bottom)
  renderFooter(scanResult, H - 1)

  gpu:flush()
end

return ContainerDisplay