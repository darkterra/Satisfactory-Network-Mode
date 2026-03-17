-- modules/container_display.lua
-- Renders container inventory data on a GPU T1 screen.
-- Supports three display modes: overview, detail, and both.
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
}

-- Display state
local state = {
  gpu = nil,
  screen = nil,
  enabled = false,
  displayMode = "both", -- "overview", "detail", "both"
}

-- Scroll offset for detail view
local scrollOffset = 0
local maxScroll = 0

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the display with a GPU and screen.
-- @param gpu GPU T1 proxy
-- @param screen Screen proxy (PCI or network)
-- @param displayMode string - "overview", "detail", or "both"
-- @return boolean success
function ContainerDisplay.init(gpu, screen, displayMode)
  if not gpu or not screen then
    print("[CONT_DSP] No GPU/Screen - using console fallback")
    state.enabled = false
    return false
  end

  state.gpu = gpu
  state.screen = screen
  state.displayMode = displayMode or "both"

  gpu:bindScreen(screen)
  gpu:setSize(W, H)
  state.enabled = true

  -- Listen for mouse events (scrolling)
  event.listen(gpu)
  if SIGNAL_HANDLERS then
    SIGNAL_HANDLERS["OnMouseDown"] = SIGNAL_HANDLERS["OnMouseDown"] or {}
    table.insert(SIGNAL_HANDLERS["OnMouseDown"], function(signal, sender, x, y, btn)
      if sender == state.gpu then
        handleClick(x, y, btn)
      end
    end)
    SIGNAL_HANDLERS["OnMouseWheel"] = SIGNAL_HANDLERS["OnMouseWheel"] or {}
    table.insert(SIGNAL_HANDLERS["OnMouseWheel"], function(signal, sender, x, y, delta)
      if sender == state.gpu then
        scrollOffset = math.max(0, math.min(maxScroll, scrollOffset - delta * 3))
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
-- Currently supports scrolling via up/down clicks.
function handleClick(x, y, btn)
  -- Future: click-to-expand group, etc.
end

-- ============================================================================
-- Rendering
-- ============================================================================

--- Render the overview section.
-- Shows global stats and per-group summaries.
-- @param scanResult table - from ContainerScanner.scan()
-- @param startRow number - first available row
-- @return number - next available row after rendering
local function renderOverview(scanResult, startRow)
  local row = startRow
  local stats = scanResult.globalStats

  txt(1, row, "OVERVIEW", COLORS.title)
  row = row + 1

  -- Global stats line
  drawLabelValue(2, row, "Containers: ", tostring(stats.totalContainers), COLORS.text)
  drawLabelValue(24, row, "Items: ", formatCount(stats.totalItems), COLORS.text)
  drawLabelValue(44, row, "Slots: ", stats.slotsUsed .. "/" .. stats.totalSlots, COLORS.text)
  drawLabelValue(66, row, "Avg fill: ", string.format("%.1f%%", stats.avgFill), getFillColor(stats.avgFill))
  row = row + 1

  drawSeparator(row)
  row = row + 1

  -- Per-group summaries
  for _, groupName in ipairs(scanResult.groupOrder) do
    if row >= H - 2 then break end
    local group = scanResult.groups[groupName]
    if group then
      -- Group header: name + container count + fill bar
      txt(1, row, "GROUP: ", COLORS.label)
      txt(8, row, group.name, COLORS.groupName)
      local countText = " (" .. group.containerCount .. " containers)"
      txt(8 + #group.name, row, countText, COLORS.dim)

      -- Fill bar at fixed position
      drawFillBar(50, row, 20, group.avgFill)
      row = row + 1
      if row >= H - 2 then break end

      -- Items summary and top items on same line
      drawLabelValue(3, row, "Items: ", formatCount(group.totalItems), COLORS.text)
      drawLabelValue(22, row, "Slots: ", group.slotsUsed .. "/" .. group.totalSlots, COLORS.text)

      if #group.topItems > 0 then
        local topCol = 35
        txt(topCol, row, "Top: ", COLORS.label)
        topCol = topCol + 5
        for i, item in ipairs(group.topItems) do
          if topCol >= W - 20 then break end
          local itemText = item.name .. " (" .. formatCount(item.count) .. ")"
          if i < #group.topItems and topCol + #itemText + 2 < W then
            itemText = itemText .. ", "
          end
          txt(topCol, row, itemText, COLORS.itemName)
          topCol = topCol + #itemText
        end
      end
      row = row + 1

      -- Thin separator between groups
      if row < H - 2 then
        state.gpu:setForeground(table.unpack(COLORS.separator))
        state.gpu:fill(2, row, W - 4, 1, ".")
        row = row + 1
      end
    end
  end

  return row
end

--- Render the detail section.
-- Shows per-container breakdown within each group.
-- @param scanResult table - from ContainerScanner.scan()
-- @param startRow number - first available row
-- @return number - next available row after rendering
local function renderDetail(scanResult, startRow)
  local row = startRow
  local virtualRow = 0 -- tracks total content rows for scrolling

  txt(1, row, "DETAIL", COLORS.title)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  -- Column headers
  local headerFormat = string.format("      %-20s %-11s %7s %8s  %-8s  %s", "Container", "Bar", "Fill%", "Items", "Slots", "Top Item")
  txt(0, row, headerFormat, COLORS.dim)
  row = row + 1

  local contentStartRow = row
  local maxContentRows = H - row - 1 -- leave 1 row for footer

  for _, groupName in ipairs(scanResult.groupOrder) do
    local group = scanResult.groups[groupName]
    if not group then goto continueGroup end

    -- Group header
    if virtualRow >= scrollOffset and row < contentStartRow + maxContentRows then
      txt(1, row, group.name, COLORS.groupName)
      local groupInfo = string.format("  (%d containers, avg %.1f%%)", group.containerCount, group.avgFill)
      txt(1 + #group.name, row, groupInfo, COLORS.dim)
      row = row + 1
    end
    virtualRow = virtualRow + 1

    -- Per-container lines
    for _, c in ipairs(group.containers) do
      if virtualRow >= scrollOffset and row < contentStartRow + maxContentRows then
        -- Container name (truncated)
        local displayName = c.name:match("([^%s]+)")
        if #displayName > 18 then
          displayName = displayName:sub(1, 15) .. "..."
        end
        txt(2, row, string.format("%-18s", displayName), COLORS.contName)

        -- Fill bar
        local nextNumberColumn = drawFillBar(21, row, 16, c.totalFill)

        txt(nextNumberColumn + 2, row, string.format("%8s", formatCount(c.totalItems)), COLORS.count)
        txt(nextNumberColumn + 13, row, c.slotsUsed, COLORS.dim)
        txt(nextNumberColumn + 14, row, "/", COLORS.dim)
        txt(nextNumberColumn + 15, row, c.totalSlots, COLORS.dim)

        -- Top item
        local topItemCol = nextNumberColumn + 22
        if #c.topItems > 0 then
          local topItem = c.topItems[1].name
          if #topItem > 18 then topItem = topItem:sub(1, 18) .. "..." end
          txt(topItemCol, row, topItem, COLORS.itemName)

          -- Second item if space allows
          if #c.topItems > 1 and topItemCol + #topItem + 2 < W - 20 then
            local secondItem = ", " .. c.topItems[2].name
            if #secondItem > 20 then secondItem = secondItem:sub(1, 20) .. "..." end
            txt(topItemCol + #topItem, row, secondItem, COLORS.dim)

            -- Third item if space allows
            if #c.topItems > 2 and topItemCol + #topItem + #secondItem + 2 < W - 20 then
              local thirdItem = ", " .. c.topItems[3].name
              if #thirdItem > 20 then thirdItem = thirdItem:sub(1, 20) .. "..." end
              txt(topItemCol + #topItem + #secondItem, row, thirdItem, COLORS.dim)
            end
          end
        end

        row = row + 1
      end
      virtualRow = virtualRow + 1
    end

    -- Blank line between groups
    if virtualRow >= scrollOffset and row < contentStartRow + maxContentRows then
      row = row + 1
    end
    virtualRow = virtualRow + 1

    ::continueGroup::
  end

  -- Update max scroll value
  maxScroll = math.max(0, virtualRow - maxContentRows)

  return row
end

--- Print a console-friendly summary (fallback when no screen).
-- @param scanResult table - from ContainerScanner.scan()
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
-- @param scanResult table - from ContainerScanner.scan()
function ContainerDisplay.render(scanResult)
  if not state.enabled then return end
  if not scanResult then return end

  local gpu = state.gpu
  local row = 0

  -- Clear screen
  gpu:setBackground(table.unpack(COLORS.bg))
  gpu:fill(0, 0, W, H, " ")

  -- Title bar
  local titleText = "=== CONTAINER INVENTORY MONITOR ==="
  txt(math.floor((W - #titleText) / 2), row, titleText, COLORS.title)
  row = row + 1
  drawSeparator(row)
  row = row + 1

  -- Render based on display mode
  if state.displayMode == "overview" then
    renderOverview(scanResult, row)
  elseif state.displayMode == "detail" then
    renderDetail(scanResult, row)
  else -- "both"
    row = renderOverview(scanResult, row)
    if row < H - 5 then
      drawSeparator(row)
      row = row + 1
      renderDetail(scanResult, row)
    end
  end

  -- Footer
  local footerRow = H - 1
  local timeText = "Last scan: " .. string.format("%.0f", computer.millis() / 1000) .. "s uptime"
  txt(1, footerRow, timeText, COLORS.separator)
  local countText = tostring(scanResult.globalStats.totalContainers) .. " containers in "
    .. tostring(scanResult.globalStats.totalGroups) .. " groups"
  txt(W - #countText - 1, footerRow, countText, COLORS.dim)

  -- Scroll indicator
  if maxScroll > 0 then
    local scrollText = "Scroll: " .. scrollOffset .. "/" .. maxScroll
    txt(math.floor(W / 2) - math.floor(#scrollText / 2), footerRow, scrollText, COLORS.dim)
  end

  gpu:flush()
end

return ContainerDisplay