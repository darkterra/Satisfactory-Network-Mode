-- modules/master_provisioner.lua
-- Handles the bootstrap protocol for slave provisioning.
-- Manages the slave fleet registry, file collection, transfer queue,
-- and protocol messaging on bootstrap port 1 / reboot port 2.

local MasterProvisioner = {}

-- Reserved ports matching SlaveEEPROM
local PORT_BOOTSTRAP = 1
local PORT_REBOOT    = 2

-- Max characters per network message payload (conservative for NetworkCard)
local CHUNK_SIZE = 2000

-- How many send operations per event-loop tick (non-blocking pacing)
local OPS_PER_TICK = 10

-- Internal state
local card = nil
local drivePath = nil
local slavesDir = "slaves"

-- Fleet registry: cardId -> slave info
local fleet = {}

-- Provisioning queue: array of { cardId, slaveType, identity }
local queue = {}

-- Active transfer state (nil when idle)
-- { cardId, files, fileIndex, chunkIndex, totalChunks }
local transferState = nil

-- ============================================================================
-- Filesystem helpers
-- ============================================================================

--- Read an entire file and return its content.
-- @param path string - absolute path
-- @return string or nil
local function readFile(path)
  local f = filesystem.open(path, "r")
  if not f then return nil end
  local content = f:read(9999999)
  f:close()
  return content or ""
end

--- Recursively collect all file relative paths under a directory.
-- @param basePath string - root directory to scan
-- @param relPrefix string|nil - current relative prefix
-- @param result table|nil - accumulator
-- @return table - array of relative path strings
local function collectFilesRecursive(basePath, relPrefix, result)
  result = result or {}
  local children = filesystem.children(basePath)
  if not children then return result end
  for _, name in ipairs(children) do
    local fullPath = basePath .. "/" .. name
    local relPath = relPrefix and (relPrefix .. "/" .. name) or name
    if filesystem.isFile(fullPath) then
      table.insert(result, relPath)
    else
      collectFilesRecursive(fullPath, relPath, result)
    end
  end
  return result
end

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the provisioner.
-- @param networkCard proxy - NetworkCard PCI device
-- @param basePath string - DRIVE_PATH of the master computer
-- @param slavesDirName string|nil - subdirectory name for slave type folders
-- @return boolean success
function MasterProvisioner.init(networkCard, basePath, slavesDirName)
  if not networkCard then
    print("[PROVISIONER] No NetworkCard provided")
    return false
  end

  card = networkCard
  drivePath = basePath
  slavesDir = slavesDirName or "slaves"

  -- Open bootstrap port for slave requests
  card:open(PORT_BOOTSTRAP)
  print("[PROVISIONER] Bootstrap port " .. PORT_BOOTSTRAP .. " open")

  -- Validate and log slaves directory contents at init
  local slavesFullPath = drivePath .. "/" .. slavesDir
  if filesystem.exists(slavesFullPath) then
    local children = filesystem.children(slavesFullPath)
    if children and #children > 0 then
      local typeNames = {}
      for _, name in ipairs(children) do
        if not filesystem.isFile(slavesFullPath .. "/" .. name) then
          table.insert(typeNames, name)
        end
      end
      print("[PROVISIONER] Slave types found: " .. (#typeNames > 0 and table.concat(typeNames, ", ") or "(none - only files)"))
    else
      print("[PROVISIONER] WARNING: Slaves directory is empty: " .. slavesFullPath)
    end
  else
    print("[PROVISIONER] WARNING: Slaves directory not found: " .. slavesFullPath)
  end

  return true
end

--- Recover after a game reload.
-- Re-opens the bootstrap port (engine-side state lost on reload).
function MasterProvisioner.recover()
  if card then
    card:open(PORT_BOOTSTRAP)
    print("[PROVISIONER] Recover: bootstrap port " .. PORT_BOOTSTRAP .. " re-opened")
  end
end

-- ============================================================================
-- Fleet management
-- ============================================================================

--- Get the full fleet registry.
-- @return table - cardId -> slave info
function MasterProvisioner.getFleet()
  return fleet
end

--- Get list of valid slave types based on subdirectory names.
-- @return table - array of type name strings
function MasterProvisioner.getSlaveTypes()
  -- print("[PROVISIONER] Scanning for slave types in: " .. drivePath .. "/" .. slavesDir)
  
  local types = {}
  local dir = drivePath .. "/" .. slavesDir
  if not filesystem.exists(dir) then
    return types
  end
  local children = filesystem.children(dir)
  if not children then return types end
  for _, name in ipairs(children) do
    local fullPath = dir .. "/" .. name
    if not filesystem.isFile(fullPath) then
      table.insert(types, name)
    end
  end
  return types
end

--- Called when a running slave heartbeat is received.
-- @param cardId string - NetworkCard UUID of the slave
-- @param slaveType string - declared slave type
-- @param identity string - human-readable name
function MasterProvisioner.onSlaveHeartbeat(cardId, slaveType, identity)
  if not fleet[cardId] then
    fleet[cardId] = {
      cardId = cardId,
      type = slaveType,
      identity = identity or "unknown",
      state = "online",
      lastSeen = computer.millis(),
    }
  else
    fleet[cardId].type = slaveType
    fleet[cardId].identity = identity or fleet[cardId].identity
    fleet[cardId].state = "online"
    fleet[cardId].lastSeen = computer.millis()
  end
end

--- Mark slaves as offline if no heartbeat received recently.
function MasterProvisioner.updateStates()
  local now = computer.millis()
  for _, slave in pairs(fleet) do
    if slave.state == "online" and (now - slave.lastSeen) > 60000 then
      slave.state = "offline"
    end
  end
end

-- ============================================================================
-- File collection
-- ============================================================================

--- Build the complete file list to send to a slave of a given type.
-- Includes common files (main.lua, lib/, features/network.lua, modules/network_bus.lua)
-- plus type-specific files from slaves/<type>/.
-- A config.lua is generated with the slave's type and identity.
-- @param slaveType string
-- @param identity string
-- @return table - array of { relPath, content }
function MasterProvisioner.collectFilesForSlave(slaveType, identity)
  local files = {}

  -- Common files that every slave needs
  local commonFiles = {
    "main.lua",
    "lib/config_manager.lua",
    "lib/config_ui.lua",
    "lib/component_registry.lua",
    "lib/task_manager.lua",
    "features/network.lua",
    "modules/network_bus.lua",
  }

  for _, relPath in ipairs(commonFiles) do
    local content = readFile(drivePath .. "/" .. relPath)
    if content then
      table.insert(files, { relPath = relPath, content = content })
    else
      print("[PROVISIONER] WARNING: Common file missing: " .. relPath)
    end
  end

  -- Type-specific files from slaves/<type>/
  local typePath = drivePath .. "/" .. slavesDir .. "/" .. slaveType
  if filesystem.exists(typePath) then
    local typeFiles = collectFilesRecursive(typePath, nil)
    for _, relPath in ipairs(typeFiles) do
      local content = readFile(typePath .. "/" .. relPath)
      if content then
        table.insert(files, { relPath = relPath, content = content })
      end
    end
  else
    print("[PROVISIONER] WARNING: No type directory: " .. typePath)
  end

  -- Generate config.lua with slave identity and enabled features.
  -- Discover which features are present in the file list.
  local featureNames = {}
  for _, file in ipairs(files) do
    local name = file.relPath:match("^features/(.+)%.lua$")
    if name then
      table.insert(featureNames, name)
    end
  end
  local featureEntries = {}
  for _, name in ipairs(featureNames) do
    table.insert(featureEntries, "    " .. name .. " = true")
  end
  local configContent = "return {\n"
    .. "  features = {\n" .. table.concat(featureEntries, ",\n") .. "\n  },\n"
    .. "  network = {\n"
    .. "    basePort = 100,\n"
    .. "    identity = " .. string.format("%q", identity) .. "\n"
    .. "  },\n"
    .. "  slave = {\n"
    .. "    type = " .. string.format("%q", slaveType) .. ",\n"
    .. "    identity = " .. string.format("%q", identity) .. "\n"
    .. "  }\n"
    .. "}"
  table.insert(files, { relPath = "config.lua", content = configContent })

  print("[PROVISIONER] Collected " .. #files .. " files for type '" .. slaveType .. "' (identity: " .. identity .. ")")
  return files
end

-- ============================================================================
-- File transfer protocol
-- ============================================================================

--- Send a single part of the current transfer (one file or one chunk).
-- Returns true if work was done, false if transfer is complete.
local function sendNextPart()
  if not transferState then return false end

  local ts = transferState
  local file = ts.files[ts.fileIndex]

  if not file then
    -- All files sent: signal completion
    card:send(ts.cardId, PORT_BOOTSTRAP, "files_done")
    if fleet[ts.cardId] then
      fleet[ts.cardId].state = "provisioned"
      fleet[ts.cardId].provisionedAt = computer.millis()
    end
    print("[PROVISIONER] Transfer complete -> " .. (fleet[ts.cardId] and fleet[ts.cardId].identity or ts.cardId))
    transferState = nil
    return false
  end

  if not ts.chunkIndex then
    -- New file: decide single-message or chunked
    if #file.content <= CHUNK_SIZE then
      card:send(ts.cardId, PORT_BOOTSTRAP, "file", file.relPath, file.content)
      ts.fileIndex = ts.fileIndex + 1
      return true
    else
      ts.totalChunks = math.ceil(#file.content / CHUNK_SIZE)
      ts.chunkIndex = 1
    end
  end

  -- Send one chunk
  local startPos = (ts.chunkIndex - 1) * CHUNK_SIZE + 1
  local chunk = file.content:sub(startPos, startPos + CHUNK_SIZE - 1)
  card:send(ts.cardId, PORT_BOOTSTRAP, "file_chunk", file.relPath, chunk, tostring(ts.chunkIndex), tostring(ts.totalChunks))

  ts.chunkIndex = ts.chunkIndex + 1
  if ts.chunkIndex > ts.totalChunks then
    ts.chunkIndex = nil
    ts.fileIndex = ts.fileIndex + 1
  end
  return true
end

--- Process the provisioning queue. Call once per event-loop tick.
-- Sends up to OPS_PER_TICK file parts, or starts a new transfer.
function MasterProvisioner.processQueue()
  -- Continue active transfer
  if transferState then
    for _ = 1, OPS_PER_TICK do
      if not sendNextPart() then break end
    end
    return
  end

  -- Start next job from queue
  if #queue == 0 then return end
  local job = table.remove(queue, 1)

  local files = MasterProvisioner.collectFilesForSlave(job.slaveType, job.identity or "unknown")
  if #files == 0 then
    print("[PROVISIONER] No files for type: " .. job.slaveType)
    return
  end

  -- Announce transfer start
  card:send(job.cardId, PORT_BOOTSTRAP, "file_start", tostring(#files))

  -- Update fleet state
  if not fleet[job.cardId] then
    fleet[job.cardId] = {
      cardId = job.cardId,
      type = job.slaveType,
      identity = job.identity or "unknown",
      state = "provisioning",
      lastSeen = computer.millis(),
    }
  else
    fleet[job.cardId].state = "provisioning"
    fleet[job.cardId].lastSeen = computer.millis()
  end

  -- Begin transfer
  transferState = {
    cardId = job.cardId,
    files = files,
    fileIndex = 1,
    chunkIndex = nil,
    totalChunks = nil,
  }

  print("[PROVISIONER] Starting transfer: " .. #files .. " files -> " .. (job.identity or job.cardId))
end

-- ============================================================================
-- Reboot commands
-- ============================================================================

--- Send a simple reboot command to a slave.
-- @param targetCardId string
function MasterProvisioner.sendReboot(targetCardId)
  card:send(targetCardId, PORT_REBOOT, "reboot")
  print("[PROVISIONER] Reboot -> " .. targetCardId)
end

--- Send a reboot-for-update command (slave deletes main.lua, enters degraded mode).
-- @param targetCardId string
function MasterProvisioner.sendUpdateReboot(targetCardId)
  card:send(targetCardId, PORT_REBOOT, "reboot_for_update")
  if fleet[targetCardId] then
    fleet[targetCardId].state = "updating"
    fleet[targetCardId].lastSeen = computer.millis()
  end
  print("[PROVISIONER] Update reboot -> " .. targetCardId)
end

--- Send a full reset command (slave wipes all files, enters degraded mode).
-- The slave is removed from the fleet registry since it will be re-specialized.
-- @param targetCardId string
function MasterProvisioner.sendReset(targetCardId)
  card:send(targetCardId, PORT_REBOOT, "reset")
  if fleet[targetCardId] then
    print("[PROVISIONER] Reset -> " .. (fleet[targetCardId].identity or targetCardId) .. " (" .. (fleet[targetCardId].type or "?") .. ")")
    fleet[targetCardId] = nil
  else
    print("[PROVISIONER] Reset -> " .. targetCardId)
  end
end

--- Send a reset-and-reprovision command.
-- The slave wipes its files, writes a config.lua with the new type + its
-- current identity, then reboots into degraded mode which auto-requests
-- files from the Master.
-- @param targetCardId string
-- @param newType string - the new slave type to assign
function MasterProvisioner.sendResetReprovision(targetCardId, newType)
  card:send(targetCardId, PORT_REBOOT, "reset_reprovision", newType)
  if fleet[targetCardId] then
    print("[PROVISIONER] Reset+Reprovision -> " .. (fleet[targetCardId].identity or targetCardId)
      .. " (" .. (fleet[targetCardId].type or "?") .. " -> " .. newType .. ")")
    fleet[targetCardId].state = "updating"
    fleet[targetCardId].lastSeen = computer.millis()
  else
    print("[PROVISIONER] Reset+Reprovision -> " .. targetCardId .. " (new type: " .. newType .. ")")
  end
end

-- ============================================================================
-- Bootstrap protocol handler
-- ============================================================================

--- Handle an incoming message on the bootstrap port.
-- Called from the SIGNAL_HANDLERS dispatch in master.lua feature.
-- @param sender string - NetworkCard UUID of sender
-- @param port number - port number
-- @param msgType string - protocol message type
-- @param arg1..arg4 - additional arguments
function MasterProvisioner.handleBootstrapMessage(sender, port, msgType, arg1, arg2, arg3, arg4)
  if port ~= PORT_BOOTSTRAP then return end

  if msgType == "get_types" then
    -- Slave in degraded mode wants the list of valid types
    local types = MasterProvisioner.getSlaveTypes()
    local typesList = table.concat(types, ",")
    card:send(sender, PORT_BOOTSTRAP, "types_list", typesList)
    print("[PROVISIONER] Types request from " .. sender .. " -> [" .. typesList .. "]")

  elseif msgType == "request_files" then
    -- Slave in degraded mode requests provisioning
    local slaveType = arg1
    local identity = arg2
    -- arg3 = cardId (redundant with sender for targeted reply)

    -- Register/update fleet entry
    fleet[sender] = {
      cardId = sender,
      type = slaveType or "unknown",
      identity = identity or "unknown",
      state = "degraded",
      lastSeen = computer.millis(),
    }

    -- Deduplicate: skip if already queued or being transferred
    if transferState and transferState.cardId == sender then
      return
    end
    for _, job in ipairs(queue) do
      if job.cardId == sender then return end
    end

    -- Add to provisioning queue
    table.insert(queue, {
      cardId = sender,
      slaveType = slaveType or "unknown",
      identity = identity or "unknown",
    })
    print("[PROVISIONER] Queued: " .. (identity or "?") .. " (" .. (slaveType or "?") .. ")")
  end
end

-- ============================================================================
-- Status helpers
-- ============================================================================

--- Check if a file transfer is in progress.
-- @return boolean
function MasterProvisioner.isTransferring()
  return transferState ~= nil
end

--- Get the current provisioning queue length.
-- @return number
function MasterProvisioner.getQueueLength()
  return #queue
end

--- Get the cardId of the slave currently being provisioned.
-- @return string or nil
function MasterProvisioner.getActiveTransferTarget()
  return transferState and transferState.cardId or nil
end

return MasterProvisioner