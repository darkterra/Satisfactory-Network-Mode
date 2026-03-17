-- lib/config_ui.lua
-- Text-based configuration UI rendered on the computer's internal screen.
-- Requires GPU and SCREEN globals to be set by the bootloader.

if not GPU or not SCREEN then
  print("[CONFIG_UI] No GPU or Screen Driver detected - config UI disabled")
  return
end

-- Screen dimensions
local SCREEN_WIDTH  = 100
local SCREEN_HEIGHT = 40

GPU:setSize(SCREEN_WIDTH, SCREEN_HEIGHT)

-- Color palette (R, G, B, A)
local COLORS = {
  background      = { 0.1, 0.1, 0.15, 1.0 },
  text            = { 0.8, 0.8, 0.8, 1.0 },
  header          = { 0.2, 0.7, 1.0, 1.0 },
  sectionTitle    = { 1.0, 0.8, 0.2, 1.0 },
  selectedRow     = { 0.15, 0.15, 0.3, 1.0 },
  value           = { 0.6, 1.0, 0.6, 1.0 },
  editingValue    = { 1.0, 1.0, 0.5, 1.0 },
  statusBar       = { 0.5, 0.5, 0.5, 1.0 },
  actionButton    = { 0.3, 0.9, 0.5, 1.0 },
}

-- Key codes (charCode from OnKeyDown 'c' parameter)
local KEY = {
  ENTER     = 13,
  ESCAPE    = 27,
  BACKSPACE = 8,
}

-- Key codes (keyCode from OnKeyDown 'code' parameter, Windows VK codes)
local KEYCODE = {
  ARROW_UP   = 38,
  ARROW_DOWN = 40,
  ARROW_LEFT = 37,
  ARROW_RIGHT = 39,
  ENTER      = 13,
  ESCAPE     = 27,
  BACKSPACE  = 8,
  KEY_V      = 86,
}

-- Modifier bit-field ('btn' parameter)
local MODIFIER = {
  CTRL  = 4,
  SHIFT = 8,
  ALT   = 16,
}

-- UI State
local uiState = {
  items          = {},   -- flat list of navigable items
  selectedIndex  = 1,
  editMode       = false,
  editBuffer     = "",
  statusMessage  = "",
  scrollOffset   = 0,
}

-- ============================================================
-- Item List Builder
-- ============================================================

--- Build the flat navigable item list from registered config schemas.
local function buildItemList()
  uiState.items = {}
  for sectionName, fields in pairs(CONFIG_MANAGER.schemas) do
    table.insert(uiState.items, {
      type = "section",
      label = "[" .. sectionName .. "]",
    })
    for _, field in ipairs(fields) do
      table.insert(uiState.items, {
        type = "field",
        sectionName = sectionName,
        field = field,
        label = field.label,
      })
    end
  end
  table.insert(uiState.items, {
    type = "action",
    label = "[ SAVE CONFIG ]",
    action = "save",
  })
end

-- ============================================================
-- Rendering
-- ============================================================

--- Render the entire screen.
local function render()
  -- Clear screen
  GPU:setBackground(table.unpack(COLORS.background))
  GPU:fill(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, " ")

  -- Header
  GPU:setForeground(table.unpack(COLORS.header))
  local headerText = "--- CONFIGURATION ---"
  GPU:setText(math.floor((SCREEN_WIDTH - #headerText) / 2), 0, headerText)

  -- Content area
  local contentStartRow = 2
  local contentHeight = SCREEN_HEIGHT - 4

  -- Adjust scroll so selected item is always visible
  if uiState.selectedIndex - uiState.scrollOffset > contentHeight then
    uiState.scrollOffset = uiState.selectedIndex - contentHeight
  elseif uiState.selectedIndex - uiState.scrollOffset < 1 then
    uiState.scrollOffset = uiState.selectedIndex - 1
  end

  for displayRow = 1, contentHeight do
    local itemIndex = displayRow + uiState.scrollOffset
    local item = uiState.items[itemIndex]
    if not item then break end

    local rowY = contentStartRow + displayRow - 1
    local isSelected = (itemIndex == uiState.selectedIndex)

    -- Highlight selected row
    if isSelected then
      GPU:setBackground(table.unpack(COLORS.selectedRow))
      GPU:fill(0, rowY, SCREEN_WIDTH, 1, " ")
    else
      GPU:setBackground(table.unpack(COLORS.background))
    end

    if item.type == "section" then
      GPU:setForeground(table.unpack(COLORS.sectionTitle))
      GPU:setText(1, rowY, item.label)

    elseif item.type == "field" then
      GPU:setForeground(table.unpack(COLORS.text))
      local fieldLabel = "  " .. item.label .. ": "
      GPU:setText(0, rowY, fieldLabel)

      -- Display value
      local displayValue
      if isSelected and uiState.editMode then
        GPU:setForeground(table.unpack(COLORS.editingValue))
        displayValue = uiState.editBuffer .. "_"
      else
        GPU:setForeground(table.unpack(COLORS.value))
        displayValue = tostring(CONFIG_MANAGER.get(item.sectionName, item.field.key) or "")
      end
      -- Truncate if too long
      local maxLen = SCREEN_WIDTH - #fieldLabel - 1
      if #displayValue > maxLen then
        displayValue = displayValue:sub(1, maxLen - 3) .. "..."
      end
      GPU:setText(#fieldLabel, rowY, displayValue)

      -- Show range hint for fields with min/max constraints
      if not (isSelected and uiState.editMode) and (item.field.min or item.field.max) then
        local rangeStr = " ("
        if item.field.min then rangeStr = rangeStr .. tostring(item.field.min) end
        rangeStr = rangeStr .. "-"
        if item.field.max then rangeStr = rangeStr .. tostring(item.field.max) end
        rangeStr = rangeStr .. ")"
        GPU:setForeground(table.unpack(COLORS.statusBar))
        GPU:setText(#fieldLabel + #displayValue, rowY, rangeStr)
      end

    elseif item.type == "action" then
      GPU:setForeground(table.unpack(COLORS.actionButton))
      GPU:setText(1, rowY, item.label)
    end
  end

  -- Status bar
  GPU:setBackground(table.unpack(COLORS.background))
  GPU:setForeground(table.unpack(COLORS.statusBar))
  local helpText
  if uiState.editMode then
    helpText = "Type value + Enter | Esc to cancel"
  else
    helpText = "Arrows: navigate | Enter: edit/action"
  end
  GPU:setText(0, SCREEN_HEIGHT - 1, helpText)

  -- Status message
  if uiState.statusMessage ~= "" then
    GPU:setForeground(table.unpack(COLORS.header))
    GPU:setText(0, SCREEN_HEIGHT - 2, uiState.statusMessage)
  end

  GPU:flush()
end

-- ============================================================
-- Navigation & Editing
-- ============================================================

local function navigateUp()
  if uiState.selectedIndex > 1 then
    uiState.selectedIndex = uiState.selectedIndex - 1
    -- Skip section headers
    if uiState.items[uiState.selectedIndex].type == "section" then
      if uiState.selectedIndex > 1 then
        uiState.selectedIndex = uiState.selectedIndex - 1
      else
        uiState.selectedIndex = uiState.selectedIndex + 1
      end
    end
  end
end

local function navigateDown()
  if uiState.selectedIndex < #uiState.items then
    uiState.selectedIndex = uiState.selectedIndex + 1
    if uiState.items[uiState.selectedIndex].type == "section" then
      if uiState.selectedIndex < #uiState.items then
        uiState.selectedIndex = uiState.selectedIndex + 1
      end
    end
  end
end

local function enterEditMode()
  local item = uiState.items[uiState.selectedIndex]
  if not item then return end

  if item.type == "field" then
    -- Boolean fields: toggle directly without entering edit mode
    if item.field.type == "boolean" then
      local currentValue = CONFIG_MANAGER.get(item.sectionName, item.field.key)
      local newValue = not currentValue
      CONFIG_MANAGER.set(item.sectionName, item.field.key, newValue)
      uiState.statusMessage = item.label .. " = " .. tostring(newValue)
    else
      uiState.editMode = true
      local currentValue = CONFIG_MANAGER.get(item.sectionName, item.field.key)
      uiState.editBuffer = tostring(currentValue or "")
      uiState.statusMessage = ""
    end

  elseif item.type == "action" and item.action == "save" then
    CONFIG_MANAGER.save()
    uiState.statusMessage = "Config saved! Reboot to apply changes."
  end
end

local function confirmEdit()
  local item = uiState.items[uiState.selectedIndex]
  if item and item.type == "field" then
    local value = uiState.editBuffer
    if item.field.type == "number" then
      value = tonumber(value) or 0
      -- Clamp to min/max and show feedback
      if item.field.min and value < item.field.min then
        value = item.field.min
        uiState.statusMessage = item.label .. " clamped to min: " .. item.field.min
      elseif item.field.max and value > item.field.max then
        value = item.field.max
        uiState.statusMessage = item.label .. " clamped to max: " .. item.field.max
      else
        uiState.statusMessage = item.label .. " updated"
      end
    else
      uiState.statusMessage = item.label .. " updated"
    end
    CONFIG_MANAGER.set(item.sectionName, item.field.key, value)
  end
  uiState.editMode = false
  uiState.editBuffer = ""
end

local function cancelEdit()
  uiState.editMode = false
  uiState.editBuffer = ""
  uiState.statusMessage = ""
end

-- ============================================================
-- Event Listeners
-- ============================================================

event.listen(GPU)

-- Keyboard navigation and special keys
local keyDownFilter = event.filter({ sender = GPU, event = "OnKeyDown" })
event.registerListener(keyDownFilter, function(eventName, sender, charCode, keyCode, buttonField)
  local hasCtrl = (buttonField and buttonField >= MODIFIER.CTRL) and (math.floor(buttonField / MODIFIER.CTRL) % 2 == 1)
  local handled = false

  if uiState.editMode then
    if charCode == KEY.ENTER or keyCode == KEYCODE.ENTER then
      confirmEdit()
      handled = true
    elseif charCode == KEY.ESCAPE or keyCode == KEYCODE.ESCAPE then
      cancelEdit()
      handled = true
    elseif charCode == KEY.BACKSPACE or keyCode == KEYCODE.BACKSPACE then
      if #uiState.editBuffer > 0 then
        uiState.editBuffer = uiState.editBuffer:sub(1, -2)
      end
      handled = true
    elseif hasCtrl and keyCode == KEYCODE.KEY_V then
      -- GPU T1 has no clipboard API - show a hint
      uiState.statusMessage = "Paste unavailable. Edit config.lua directly for UUIDs."
      handled = true
    end
  else
    if keyCode == KEYCODE.ARROW_UP then
      navigateUp()
      handled = true
    elseif keyCode == KEYCODE.ARROW_DOWN then
      navigateDown()
      handled = true
    elseif charCode == KEY.ENTER or keyCode == KEYCODE.ENTER then
      enterEditMode()
      handled = true
    end
  end

  if handled then
    render()
  end
end)

-- Text input for edit mode
local keyCharFilter = event.filter({ sender = GPU, event = "OnKeyChar" })
event.registerListener(keyCharFilter, function(eventName, sender, character, buttonField)
  if not uiState.editMode then return end

  local charByte = string.byte(character, 1)

  if charByte and charByte >= 32 then
    -- Only append printable characters
    uiState.editBuffer = uiState.editBuffer .. character
    render()
  end
  -- Silently ignore other control characters
end)

-- ============================================================
-- Initialization
-- ============================================================

--- Rebuild and render. Called by main.lua after all features have registered.
local function initialize()
  buildItemList()
  -- Select first non-section item
  for index, item in ipairs(uiState.items) do
    if item.type ~= "section" then
      uiState.selectedIndex = index
      break
    end
  end
  render()
  print("[CONFIG_UI] Screen UI ready")
end

return { initialize = initialize }