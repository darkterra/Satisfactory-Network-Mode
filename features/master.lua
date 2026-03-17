-- features/master.lua
-- Master fleet management feature.
-- Orchestrates slave provisioning, fleet monitoring, and interactive dashboard.
-- Uses deferred initialization to ensure network_bus is ready before opening ports.
--
-- Dependencies:
--   modules/master_provisioner.lua - bootstrap protocol, file transfer, fleet registry
--   modules/master_display.lua    - GPU T1 fleet dashboard with mouse interaction

local provisioner = filesystem.doFile(DRIVE_PATH .. "/modules/master_provisioner.lua")
local display = filesystem.doFile(DRIVE_PATH .. "/modules/master_display.lua")
local updater = filesystem.doFile(DRIVE_PATH .. "/modules/master_updater.lua")

-- Register config schema
CONFIG_MANAGER.register("master", {
  { key = "slavesDir",  label = "Slaves code directory",  type = "string", default = "slaves" },
  { key = "githubRepo", label = "GitHub repo (owner/repo)", type = "string", default = "" },
  { key = "githubBranch", label = "GitHub branch",         type = "string", default = "main" },
  { key = "githubSubPath", label = "Repo sub-path (optional)", type = "string", default = "" },
})

-- Register screen category so network-attached displays can be discovered
REGISTRY.registerNetworkCategory("screens", "Build_Screen_C")

-- State flags
local provisionerReady = false
local updaterReady = false
local displayReady = false
local displayInputReady = false

-- ============================================================================
-- Bootstrap protocol handler (registered immediately, guarded by flag)
-- ============================================================================

SIGNAL_HANDLERS["NetworkMessage"] = SIGNAL_HANDLERS["NetworkMessage"] or {}
table.insert(SIGNAL_HANDLERS["NetworkMessage"], function(signal, comp, sender, port, ...)
  -- Only handle bootstrap port messages
  if port ~= 1 then return end
  if not provisionerReady then
    print("[MASTER] Bootstrap msg IGNORED (provisioner not ready): port=" .. tostring(port))
    return
  end
  local args = { ... }
  print("[MASTER] Bootstrap msg from " .. tostring(sender) .. " port=" .. tostring(port) .. " type=" .. tostring(args[1]))
  provisioner.handleBootstrapMessage(sender, port, args[1], args[2], args[3], args[4], args[5])
end)

-- ============================================================================
-- Deferred initialization (runs after all features + network discovery)
-- ============================================================================

--- Initialize the provisioner (after network_bus has done its closeAll + port setup).
local function initProvisioner()
  local card = REGISTRY.pci.networkCards[1]
  if not card then
    print("[MASTER] No NetworkCard found - provisioner disabled")
    return false
  end

  local masterConfig = CONFIG_MANAGER.getSection("master")
  local slavesDir = masterConfig.slavesDir or "slaves"

  local ok = provisioner.init(card, DRIVE_PATH, slavesDir)
  if not ok then return false end

  -- Subscribe to heartbeat from running slaves (via network bus)
  if NETWORK_BUS then
    NETWORK_BUS.registerChannel("slave_heartbeat")
    NETWORK_BUS.subscribe("slave_heartbeat", function(senderCardId, senderIdentity, payload)
      if payload and payload.type then
        provisioner.onSlaveHeartbeat(senderCardId, payload.type, payload.identity or senderIdentity)
      end
    end)
    print("[MASTER] Subscribed to slave_heartbeat channel")
  else
    print("[MASTER] WARNING: NETWORK_BUS not available - no live slave tracking")
  end

  provisionerReady = true
  print("[MASTER] Provisioner ready")
  return true
end

--- Initialize the self-updater with the InternetCard.
local function initUpdater()
  local iCard = REGISTRY.pci.internetCards[1]
  if not iCard then
    print("[MASTER] No InternetCard found - self-update disabled")
    return false
  end
  local ok = updater.init(iCard, DRIVE_PATH)
  if not ok then return false end
  updaterReady = true
  print("[MASTER] Self-updater ready (InternetCard detected)")
  return true
end

--- Try to bind the fleet dashboard to a spare display.
-- The dashboard uses GPU T1 character-mode API; a T2 GPU would crash.
local function tryInitDisplay()
  if displayReady then
    return true
  end

  -- Find a spare screen (PCI first, then network)
  local screen = REGISTRY.pci.screens[1]
  if not screen then
    local netScreens = REGISTRY.network["screens"] or {}
    if #netScreens > 0 then screen = netScreens[1] end
  end
  if not screen then
    print("[MASTER] No spare screen available for fleet dashboard")
    return false
  end

  -- Use a spare PCI GPU T1 (separate from config UI)
  local gpu = REGISTRY.pci.gpuT1[1]
  if gpu then
    display.init(gpu, screen)
    displayReady = true
    print("[MASTER] Fleet dashboard on spare GPU T1 + spare screen")
    return true
  end

  print("[MASTER] No GPU T1 available for fleet dashboard")
  return false
end

--- Wire mouse clicks from the dashboard GPU to action handlers.
local function setupDisplayInput()
  if displayInputReady or not displayReady then return end
  local dgpu = display.getGPU()
  if not dgpu then return end

  event.listen(dgpu)

  SIGNAL_HANDLERS["OnMouseDown"] = SIGNAL_HANDLERS["OnMouseDown"] or {}
  table.insert(SIGNAL_HANDLERS["OnMouseDown"], function(signal, sender, x, y, btn)
    if sender ~= dgpu then return end
    local action = display.handleClick(x, y)
    if not action then return end

    if action.action == "update_one" then
      provisioner.sendUpdateReboot(action.cardId)
      print("[MASTER] Update initiated: " .. (action.cardId or "?"))

    elseif action.action == "reboot_one" then
      provisioner.sendReboot(action.cardId)
      print("[MASTER] Reboot sent: " .. (action.cardId or "?"))

    elseif action.action == "update_type" then
      local fleet = provisioner.getFleet()
      local count = 0
      for cardId, slave in pairs(fleet) do
        if slave.type == action.slaveType and slave.state ~= "provisioning" and slave.state ~= "updating" then
          provisioner.sendUpdateReboot(cardId)
          count = count + 1
        end
      end
      print("[MASTER] Update all '" .. action.slaveType .. "': " .. count .. " slaves")

    elseif action.action == "reboot_type" then
      local fleet = provisioner.getFleet()
      local count = 0
      for cardId, slave in pairs(fleet) do
        if slave.type == action.slaveType then
          provisioner.sendReboot(cardId)
          count = count + 1
        end
      end
      print("[MASTER] Reboot all '" .. action.slaveType .. "': " .. count .. " slaves")

    elseif action.action == "reset_one" then
      -- Open type selection modal instead of sending immediately
      local fleet = provisioner.getFleet()
      local slave = fleet[action.cardId]
      local types = provisioner.getSlaveTypes()
      local identity = slave and slave.identity or "?"
      local currentType = slave and slave.type or action.slaveType or "?"
      display.openModal(action.cardId, identity, currentType, types)
      print("[MASTER] Reset modal opened for: " .. identity .. " (" .. currentType .. ")")

    elseif action.action == "modal_select" then
      -- User picked a new type in the modal -> send reset+reprovision
      provisioner.sendResetReprovision(action.cardId, action.newType)
      display.closeModal()
      print("[MASTER] Reset+Reprovision: " .. (action.cardId or "?") .. " -> type '" .. (action.newType or "?") .. "'")

    elseif action.action == "modal_cancel" then
      display.closeModal()
      print("[MASTER] Reset cancelled")

    elseif action.action == "self_update" then
      -- Start GitHub self-update
      if not updaterReady then
        print("[MASTER] Self-update unavailable (no InternetCard)")
        return
      end
      if updater.isRunning() then
        print("[MASTER] Self-update already in progress")
        return
      end
      local masterConfig = CONFIG_MANAGER.getSection("master")
      local repo = masterConfig.githubRepo or ""
      local branch = masterConfig.githubBranch or "main"
      local subPath = masterConfig.githubSubPath or ""
      if repo == "" then
        print("[MASTER] Self-update: no GitHub repo configured")
        return
      end
      print("[MASTER] Self-update started: " .. repo .. " (" .. branch .. ")")
      -- Run async so HTTP requests don't block the event loop
      future.addTask(async(function()
        local ok = updater.run(repo, branch, subPath ~= "" and subPath or nil)
        if ok then
          print("[MASTER] Self-update finished successfully")
        else
          print("[MASTER] Self-update finished with errors")
        end
      end))
    end
  end)

  displayInputReady = true
  print("[MASTER] Dashboard mouse input wired")
end

-- ============================================================================
-- Tick handler (called every game tick from main loop, synchronous)
-- ============================================================================

local lastDisplayUpdate = 0

table.insert(TICK_HANDLERS, function()
  -- Deferred provisioner init (first tick only, after network_bus.init has run)
  if not provisionerReady then
    initProvisioner()
    return -- wait next tick for everything else
  end

  -- Deferred updater init (once)
  if not updaterReady then
    initUpdater()
  end

  -- Process transfer queue every tick (fast file delivery)
  provisioner.processQueue()

  -- Display refresh every ~1 second
  local now = computer.millis()
  if now - lastDisplayUpdate > 1000 then
    -- Try to find a display if we don't have one yet
    if not displayReady then
      if tryInitDisplay() then
        setupDisplayInput()
      end
    end

    -- Update fleet states (offline detection)
    provisioner.updateStates()

    -- Render dashboard
    if displayReady then
      local fleet = provisioner.getFleet()
      local types = provisioner.getSlaveTypes()
      display.setData(fleet, types, provisioner.getQueueLength(), provisioner.isTransferring())
      display.setUpdaterState(updaterReady, updater.getState())
      display.setVersion(updater.getVersion())
      display.render()
    end

    lastDisplayUpdate = now
  end
end)

print("[MASTER] Fleet management feature loaded")