-- modules/master_display.lua
-- Fleet dashboard for the Master computer.
-- Renders slave fleet status on a GPU T1 screen (PCI or network).
-- Supports interactive mouse clicks for reboot/update actions.

local MasterDisplay = {}

-- Screen dimensions
local W = 125
local H = 50

-- Color palette
local COLORS = {
  bg       = { 0.05, 0.05, 0.1, 1.0 },
  title    = { 0.2, 0.7, 1.0, 1.0 },
  text     = { 0.8, 0.8, 0.8, 1.0 },
  dim      = { 0.5, 0.5, 0.5, 1.0 },
  typeName = { 1.0, 0.8, 0.2, 1.0 },
  online   = { 0.3, 1.0, 0.4, 1.0 },
  degraded = { 1.0, 0.6, 0.2, 1.0 },
  offline  = { 1.0, 0.3, 0.3, 1.0 },
  prov     = { 0.4, 0.7, 1.0, 1.0 },
  updating = { 0.8, 0.5, 1.0, 1.0 },
  error    = { 1.0, 0.2, 0.2, 1.0 },
  btn      = { 0.15, 0.35, 0.6, 1.0 },
  btnText  = { 1.0, 1.0, 1.0, 1.0 },
  btnDanger = { 0.7, 0.1, 0.1, 1.0 },
  btnGit   = { 0.1, 0.5, 0.2, 1.0 },
  separator = { 0.3, 0.3, 0.4, 1.0 },
  colHead  = { 0.6, 0.6, 0.6, 1.0 },
}

-- Display state
local state = {
  gpu = nil,
  screen = nil,
  fleet = {},
  types = {},
  queueLen = 0,
  isTransferring = false,
}

-- Self-update state
local updaterAvailable = false
local updaterState = nil

-- Current version string
local currentVersion = nil

-- Modal state for type selection (nil when no modal is shown)
-- { cardId, identity, slaveType, types }
local modal = nil

-- Clickable buttons rebuilt on each render
local buttons = {}

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the display.
-- @param gpu proxy - GPU T1 device
-- @param screen proxy - Screen device (PCI or network)
function MasterDisplay.init(gpu, screen)
  state.gpu = gpu
  state.screen = screen
  gpu:bindScreen(screen)
  gpu:setSize(W, H)
  print("[MASTER_DISPLAY] Display bound (" .. W .. "x" .. H .. ")")
end

--- Get the GPU for event registration.
-- @return proxy
function MasterDisplay.getGPU()
  return state.gpu
end

-- ============================================================================
-- Data update
-- ============================================================================

--- Update the fleet data for rendering.
-- @param fleet table - cardId -> slave info
-- @param types table - array of known type names
-- @param queueLen number - pending queue length
-- @param isTransferring boolean - whether a transfer is active
function MasterDisplay.setData(fleet, types, queueLen, isTransferring)
  state.fleet = fleet
  state.types = types
  state.queueLen = queueLen or 0
  state.isTransferring = isTransferring or false
end

--- Update self-updater state for display.
-- @param available boolean - whether InternetCard is present
-- @param uState table - updater state from MasterUpdater.getState()
function MasterDisplay.setUpdaterState(available, uState)
  updaterAvailable = available
  updaterState = uState
end

--- Set the current version string for display.
-- @param ver string|nil - semver version string
function MasterDisplay.setVersion(ver)
  currentVersion = ver
end

--- Open the type selection modal for a reset operation.
-- @param cardId string - target slave NetworkCard UUID
-- @param identity string - current slave identity
-- @param currentType string - current slave type
-- @param types table - array of available type names
function MasterDisplay.openModal(cardId, identity, currentType, types)
  modal = {
    cardId = cardId,
    identity = identity or "?",
    currentType = currentType or "?",
    types = types or {},
  }
end

--- Close the type selection modal.
function MasterDisplay.closeModal()
  modal = nil
end

--- Check if the modal is currently open.
-- @return boolean
function MasterDisplay.isModalOpen()
  return modal ~= nil
end

-- ============================================================================
-- Rendering helpers
-- ============================================================================

local function cls()
  state.gpu:setBackground(table.unpack(COLORS.bg))
  state.gpu:fill(0, 0, W, H, " ")
end

local function txt(x, y, s, color)
  if y >= H then return end
  state.gpu:setForeground(table.unpack(color or COLORS.text))
  state.gpu:setText(x, y, s)
end

local function drawSeparator(y)
  txt(0, y, string.rep("-", W), COLORS.separator)
end

--- Draw a clickable button and register its hit zone.
-- @param x number - column
-- @param y number - row
-- @param label string - button text (e.g. "[UPD]")
-- @param action table - action descriptor for handleClick
local function drawButton(x, y, label, action, bgColor)
  if y >= H then return end
  state.gpu:setBackground(table.unpack(bgColor or COLORS.btn))
  state.gpu:setForeground(table.unpack(COLORS.btnText))
  state.gpu:setText(x, y, label)
  state.gpu:setBackground(table.unpack(COLORS.bg))

  table.insert(buttons, {
    x1 = x,
    x2 = x + #label,
    y = y,
    args = action,
  })
end

--- Get the color for a given slave state.
local function stateColor(s)
  if s == "online" then return COLORS.online
  elseif s == "degraded" then return COLORS.degraded
  elseif s == "offline" then return COLORS.offline
  elseif s == "provisioning" then return COLORS.prov
  elseif s == "updating" then return COLORS.updating
  elseif s == "provisioned" then return COLORS.prov
  elseif s == "error" then return COLORS.error
  end
  return COLORS.dim
end

--- Format elapsed time since a timestamp.
local function formatElapsed(timestamp)
  if not timestamp then return "never" end
  local elapsed = (computer.millis() - timestamp) / 1000
  if elapsed < 5 then return "just now" end
  if elapsed < 60 then return math.floor(elapsed) .. "s ago" end
  if elapsed < 3600 then return math.floor(elapsed / 60) .. "m ago" end
  return math.floor(elapsed / 3600) .. "h ago"
end

--- Pad or truncate a string to a fixed width.
local function fixedWidth(s, w)
  s = s or ""
  if #s > w then return s:sub(1, w - 1) .. "." end
  return s .. string.rep(" ", w - #s)
end

-- ============================================================================
-- Main render
-- ============================================================================

--- Render the modal overlay for type selection.
local function renderModal()
  if not modal then return end

  local types = modal.types
  local boxW = 50
  local boxH = #types + 8
  if boxH > H - 4 then boxH = H - 4 end
  local boxX = math.floor((W - boxW) / 2)
  local boxY = math.floor((H - boxH) / 2)

  -- Draw box background
  state.gpu:setBackground(0.12, 0.12, 0.18, 1.0)
  state.gpu:fill(boxX, boxY, boxW, boxH, " ")

  -- Border (top/bottom)
  state.gpu:setForeground(table.unpack(COLORS.error))
  state.gpu:setText(boxX, boxY, string.rep("=", boxW))
  state.gpu:setText(boxX, boxY + boxH - 1, string.rep("=", boxW))

  -- Title
  local title = "RESET & RE-SPECIALIZE"
  state.gpu:setForeground(table.unpack(COLORS.error))
  state.gpu:setText(boxX + math.floor((boxW - #title) / 2), boxY + 1, title)

  -- Slave info
  state.gpu:setForeground(table.unpack(COLORS.text))
  state.gpu:setText(boxX + 2, boxY + 2, "Slave: " .. modal.identity)
  state.gpu:setForeground(table.unpack(COLORS.dim))
  state.gpu:setText(boxX + 2, boxY + 3, "Current type: " .. modal.currentType)

  -- Type list
  state.gpu:setForeground(table.unpack(COLORS.typeName))
  state.gpu:setText(boxX + 2, boxY + 4, "Select new type:")

  local maxVisible = boxH - 8
  for i = 1, math.min(#types, maxVisible) do
    local ty = types[i]
    local btnY = boxY + 5 + (i - 1)
    local label = "  " .. ty .. "  "
    local btnX = boxX + 4
    -- Highlight if same as current type
    if ty == modal.currentType then
      drawButton(btnX, btnY, label, { action = "modal_select", cardId = modal.cardId, newType = ty }, COLORS.btn)
      state.gpu:setForeground(table.unpack(COLORS.dim))
      state.gpu:setText(btnX + #label + 1, btnY, "(current)")
    else
      drawButton(btnX, btnY, label, { action = "modal_select", cardId = modal.cardId, newType = ty }, COLORS.btn)
    end
  end

  -- Cancel button
  local cancelLabel = "[ CANCEL ]"
  local cancelX = boxX + math.floor((boxW - #cancelLabel) / 2)
  local cancelY = boxY + boxH - 2
  drawButton(cancelX, cancelY, cancelLabel, { action = "modal_cancel" }, COLORS.btnDanger)

  state.gpu:setBackground(table.unpack(COLORS.bg))
end

--- Render the fleet dashboard.
function MasterDisplay.render()
  if not state.gpu then return end
  buttons = {}
  cls()

  -- Title
  local titleStr = "=== MASTER - FLEET DASHBOARD ==="
  local titleX = math.floor((W - #titleStr) / 2)
  txt(titleX, 0, titleStr, COLORS.title)

  -- Version (left of title)
  if currentVersion then
    local verStr = "v" .. currentVersion
    txt(titleX - #verStr - 2, 0, verStr, COLORS.dim)
  end

  -- Self-update button (top right)
  if updaterAvailable then
    if updaterState and updaterState.running then
      local prog = "[UPDATING " .. (updaterState.progress or 0) .. "/" .. (updaterState.total or "?") .. "]"
      txt(W - #prog - 1, 0, prog, COLORS.updating)
    else
      local updateLabel = "[SELF UPDATE]"
      drawButton(W - #updateLabel - 1, 0, updateLabel, { action = "self_update" }, COLORS.btnGit)
    end
  end

  -- Summary bar
  local typeCount = #state.types
  local slaveCount = 0
  local onlineCount = 0
  for _, slave in pairs(state.fleet) do
    slaveCount = slaveCount + 1
    if slave.state == "online" then onlineCount = onlineCount + 1 end
  end

  local summaryStr = "Types: " .. typeCount
    .. "  |  Slaves: " .. slaveCount
    .. "  |  Online: " .. onlineCount
    .. "  |  Queue: " .. state.queueLen
  if state.isTransferring then
    summaryStr = summaryStr .. "  |  TRANSFERRING"
  end
  txt(1, 1, summaryStr, COLORS.dim)

  drawSeparator(2)

  -- Group slaves by type
  -- Merge known types (from folders) with types discovered from fleet
  local allTypes = {}
  local typeSet = {}
  for _, t in ipairs(state.types) do
    table.insert(allTypes, t)
    typeSet[t] = true
  end
  for _, slave in pairs(state.fleet) do
    if slave.type and not typeSet[slave.type] then
      table.insert(allTypes, slave.type)
      typeSet[slave.type] = true
    end
  end
  table.sort(allTypes)

  -- Build grouped slave lists
  local groupedSlaves = {}
  for _, t in ipairs(allTypes) do
    groupedSlaves[t] = {}
  end
  for _, slave in pairs(state.fleet) do
    local t = slave.type or "unknown"
    if not groupedSlaves[t] then
      groupedSlaves[t] = {}
      table.insert(allTypes, t)
    end
    table.insert(groupedSlaves[t], slave)
  end

  -- Sort slaves within each group by identity
  for _, slaves in pairs(groupedSlaves) do
    table.sort(slaves, function(a, b)
      return (a.identity or "") < (b.identity or "")
    end)
  end

  -- Render groups
  local row = 3

  if #allTypes == 0 then
    txt(1, row, "No slave types found.", COLORS.dim)
    txt(1, row + 1, "Create subdirectories in /slaves/ to define types.", COLORS.dim)
    txt(1, row + 2, "Waiting for slave computers to broadcast...", COLORS.dim)
    state.gpu:flush()
    return
  end

  for _, typeName in ipairs(allTypes) do
    if row >= H - 2 then break end

    local slaves = groupedSlaves[typeName] or {}
    local hasFolder = typeSet[typeName]

    -- Type header row
    txt(1, row, "[" .. typeName .. "]", COLORS.typeName)
    txt(2 + #typeName + 2, row, "(" .. #slaves .. " slave" .. (#slaves ~= 1 and "s" or "") .. ")", COLORS.dim)
    if not hasFolder then
      txt(2 + #typeName + 2 + 15, row, "NO FOLDER", COLORS.error)
    end

    -- Type-level action buttons
    local updateAllLabel = "[UPDATE ALL]"
    local rebootAllLabel = "[REBOOT ALL]"
    drawButton(W - #rebootAllLabel - 1, row, rebootAllLabel, { action = "reboot_type", slaveType = typeName })
    drawButton(W - #rebootAllLabel - #updateAllLabel - 3, row, updateAllLabel, { action = "update_type", slaveType = typeName })
    row = row + 1

    if #slaves == 0 then
      txt(3, row, "No slaves of this type detected yet.", COLORS.dim)
      row = row + 2
    else
      -- Column headers
      txt(3, row, fixedWidth("Identity", 22), COLORS.colHead)
      txt(25, row, fixedWidth("State", 14), COLORS.colHead)
      txt(40, row, fixedWidth("Last Seen", 14), COLORS.colHead)
      txt(55, row, "Actions", COLORS.colHead)
      row = row + 1

      for _, slave in ipairs(slaves) do
        if row >= H - 1 then break end

        -- Identity
        txt(3, row, fixedWidth(slave.identity or "?", 22), COLORS.text)

        -- State
        txt(25, row, fixedWidth(slave.state or "?", 14), stateColor(slave.state))

        -- Last seen
        txt(40, row, fixedWidth(formatElapsed(slave.lastSeen), 14), COLORS.dim)

        -- Per-slave action buttons
        drawButton(55, row, "[UPD]", { action = "update_one", cardId = slave.cardId, slaveType = typeName })
        drawButton(61, row, "[RBT]", { action = "reboot_one", cardId = slave.cardId })
        drawButton(67, row, "[RST]", { action = "reset_one", cardId = slave.cardId, slaveType = typeName }, COLORS.btnDanger)

        row = row + 1
      end
      row = row + 1 -- blank between type groups
    end
  end

  -- Footer
  local footerLeft = "[UPD] Update  [RBT] Reboot  [RST] Factory Reset  |  [UPDATE ALL] / [REBOOT ALL] per type"
  txt(0, H - 1, footerLeft, COLORS.dim)
  -- Update status on footer line if relevant
  if updaterState and updaterState.done and not updaterState.running then
    local statusMsg = updaterState.success and "Self-update OK" or "Update errors: " .. #(updaterState.errors or {})
    local statusColor = updaterState.success and COLORS.online or COLORS.error
    txt(W - #statusMsg - 1, H - 1, statusMsg, statusColor)
  end

  state.gpu:flush()

  -- Overlay modal if active
  if modal then
    renderModal()
    state.gpu:flush()
  end
end

-- ============================================================================
-- Mouse interaction
-- ============================================================================

--- Handle a mouse click and return the action if a button was hit.
-- @param x number - character column
-- @param y number - character row
-- @return table or nil - action descriptor { action, cardId?, slaveType? }
function MasterDisplay.handleClick(x, y)
  for _, btn in ipairs(buttons) do
    if x >= btn.x1 and x < btn.x2 and y == btn.y then
      return btn.args
    end
  end
  return nil
end

return MasterDisplay