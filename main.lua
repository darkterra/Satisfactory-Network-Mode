-- main.lua - Application Entry Point
-- DRIVE_PATH is set by the bootloader (MasterEEPROM)
-- GPU and SCREEN globals are optionally set by the bootloader (GPU T1 + Screen for config UI)
print("[MAIN] System started on " .. DRIVE_PATH)

-- Clean slate: detach all listeners and flush stale events from previous session
event.ignoreAll()
event.clear()

-- Load and initialize the configuration manager
CONFIG_MANAGER = filesystem.doFile(DRIVE_PATH .. "/lib/config_manager.lua")
CONFIG_MANAGER.load(DRIVE_PATH .. "/config.lua")

-- Auto-discover all PCI devices (GPU T1, GPU T2, Screens)
REGISTRY = filesystem.doFile(DRIVE_PATH .. "/lib/component_registry.lua")
REGISTRY.discoverPCI()

-- Load the task manager (watchdog for async tasks across game reloads)
TASK_MANAGER = filesystem.doFile(DRIVE_PATH .. "/lib/task_manager.lua")

-- Generic signal dispatch table.
-- Features register handlers: SIGNAL_HANDLERS["SignalName"] = { handler1, handler2, ... }
-- The event loop captures every signal and forwards it to registered handlers.
SIGNAL_HANDLERS = SIGNAL_HANDLERS or {}

-- Synchronous tick handlers called every game tick from the main loop.
-- Features register callbacks: table.insert(TICK_HANDLERS, function() ... end)
-- Unlike async tasks, these run inline and never yield the computer.
TICK_HANDLERS = TICK_HANDLERS or {}

-- Discover feature files and register enable/disable config for each
local coreFeatureFiles = filesystem.children(DRIVE_PATH .. "/coreFeatures/")
if not coreFeatureFiles or #coreFeatureFiles == 0 then
  computer.panic("[MAIN] No core features found in /coreFeatures")
end
local businessFeatureFiles = filesystem.children(DRIVE_PATH .. "/features/")
if not businessFeatureFiles or #businessFeatureFiles == 0 then
  computer.panic("[MAIN] No features found in /features")
end

local featureSchemaFields = {}
local featureNames = {}

local function prepareLoadingFiles(folderPath, featureFiles)
  for _, featureFile in ipairs(featureFiles) do
    local featurePath = folderPath .. "/" .. featureFile
    if filesystem.exists(featurePath) and filesystem.isFile(featurePath) then
      local featureName = featureFile:match("^(.+)%.lua$") or featureFile
      table.insert(featureNames, { name = featureName, path = featurePath })
      table.insert(featureSchemaFields, {
        key = featureName,
        label = featureName .. " (enabled)",
        type = "boolean",
        default = true,
      })
    end
  end
end

prepareLoadingFiles(DRIVE_PATH .. "/coreFeatures", coreFeatureFiles)
prepareLoadingFiles(DRIVE_PATH .. "/features", businessFeatureFiles)

CONFIG_MANAGER.register("features", featureSchemaFields)

-- Load each enabled feature (features may register network categories + async tasks)
for _, entry in ipairs(featureNames) do
  local isEnabled = CONFIG_MANAGER.get("features", entry.name)
  if isEnabled == false then
    print("[MAIN] Feature '" .. entry.name .. "' is disabled, skipping")
  else
    print("[MAIN] Loading feature: " .. entry.name)
    local featureSuccess, featureError = pcall(filesystem.doFile, entry.path)
    if not featureSuccess then
      print("[MAIN] Feature '" .. entry.name .. "' failed: " .. tostring(featureError))
    end
  end
end

-- Discover network components registered by features
REGISTRY.discoverNetwork()

-- Start config UI on the internal screen (if GPU and Screen are available)
if not GPU then
  computer.panic("[MAIN] No GPU available - cannot start config UI")
end

local configUI = filesystem.doFile(DRIVE_PATH .. "/lib/config_ui.lua")
if not configUI or not configUI.initialize then
  computer.panic("[MAIN] No config UI module found - expected /lib/config_ui.lua with initialize() function")
end

configUI.initialize()

        
local function removeRecursive(path)
  if not filesystem.exists(path) then return end
  if filesystem.isFile(path) then
    filesystem.remove(path)
    return
  end
  local children = filesystem.children(path)
  if children then
    for _, child in ipairs(children) do
      removeRecursive(path .. "/" .. child)
    end
  end
  filesystem.remove(path)
end

-- Register EEPROM reboot handler for Slave computers.
-- The SlaveEEPROM keeps a dedicated reboot port always open so the Master
-- can remotely restart any Slave at any time (even during normal operation).
if EEPROM_RESERVED_PORTS and EEPROM_RESERVED_PORTS.reboot and NETWORK_CARD then
  local rebootPort = EEPROM_RESERVED_PORTS.reboot
  SIGNAL_HANDLERS["NetworkMessage"] = SIGNAL_HANDLERS["NetworkMessage"] or {}
  table.insert(SIGNAL_HANDLERS["NetworkMessage"], function(signal, comp, sender, port, ...)
    if port == rebootPort then
      local args = { ... }
      if args[1] == "reboot" then
        print("[MAIN] Remote reboot command received - resetting")
        computer.reset()
      elseif args[1] == "reboot_for_update" then
        print("[MAIN] Update reboot - removing main.lua for reprovisioning")
        if filesystem.exists(DRIVE_PATH .. "/main.lua") then
          filesystem.remove(DRIVE_PATH .. "/main.lua")
        end
        computer.reset()
      elseif args[1] == "reset_reprovision" then
        -- Reset and re-specialize: wipe all files, write config.lua
        -- with the new type (sent by Master) and current identity, then reboot.
        -- SlaveEEPROM will auto-skip to S_REQUEST (file request) state.
        local newType = args[2] or "unknown"
        print("[MAIN] RESET_REPROVISION -> new type: " .. newType)
        -- Read current identity before wiping
        local currentIdentity = "unknown"
        if CONFIG_MANAGER then
          local slaveCfg = CONFIG_MANAGER.getSection("slave")
          if slaveCfg and slaveCfg.identity then
            currentIdentity = slaveCfg.identity
          elseif CONFIG_MANAGER.get("network", "identity") then
            currentIdentity = CONFIG_MANAGER.get("network", "identity")
          end
        end

        local entries = filesystem.children(DRIVE_PATH)
        if entries then
          for _, entry in ipairs(entries) do
            removeRecursive(DRIVE_PATH .. "/" .. entry)
          end
        end

        -- Write minimal config so SlaveEEPROM skips UI and requests files immediately
        local f = filesystem.open(DRIVE_PATH .. "/config.lua", "w")
        if f then
          f:write("return {\n")
          f:write("  slave = {\n")
          f:write('    type = "' .. newType .. '",\n')
          f:write('    identity = "' .. currentIdentity .. '",\n')
          f:write("  },\n")
          f:write("}\n")
          f:close()
          
          CONFIG_MANAGER.save()
        end
        print("[MAIN] Files wiped, config written (type=" .. newType .. ", identity=" .. currentIdentity .. ") - rebooting")
        computer.reset()
      end
    end
  end)
  print("[MAIN] EEPROM reboot handler registered on port " .. rebootPort)
end

-- Start the event loop
-- Processes events, runs futures/tasks, and yields when idle
-- Periodically checks task health and restarts stale tasks (survives game reloads)
print("[MAIN] Entering event loop")
local lastTaskCheck = 0
local now = computer.millis()
while true do
  -- Drain all pending signals this tick (avoids 1-event-per-tick bottleneck)
  local signalData = { event.pull(0) }
  while signalData[1] do
    -- DEBUG: log all incoming signals (remove once networking is confirmed)
    local handlers = SIGNAL_HANDLERS[signalData[1]]

    if handlers then
      for _, handler in ipairs(handlers) do
        local ok, err = pcall(handler, table.unpack(signalData))
        if not ok then
          print("[MAIN] Signal handler error (" .. tostring(signalData[1]) .. "): " .. tostring(err))
        end
      end
    end

    signalData = { event.pull(0) }
  end

  -- Run synchronous tick handlers (features like master use these)
  for _, handler in ipairs(TICK_HANDLERS) do
    local ok, err = pcall(handler)
    if not ok then
      print("[MAIN] Tick handler error: " .. tostring(err))
    end
  end

  -- Poll async futures (for features that use sleep()-based coroutines)
  future.run()

  -- Task health check every 5 seconds
  now = computer.millis()
  if now - lastTaskCheck > 5000 then
    TASK_MANAGER.check()
    lastTaskCheck = now
  end

  computer.skip()
end