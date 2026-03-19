-- modules/master_updater.lua
-- Self-update module for the Master computer.
-- Downloads the latest code from a GitHub repository using FINInternetCard.
-- Files are fetched via the GitHub raw content API and written to disk.
--
-- Requires: FINInternetCard PCI device, filesystem globals.

local MasterUpdater = {}

-- Internal state
local internetCard = nil
local drivePath = nil

-- Cached version string (read from VERSION file on disk)
local cachedVersion = nil

-- Update progress tracking
local updateState = {
  running = false,
  step = "",       -- current step description
  progress = 0,    -- files downloaded so far
  total = 0,       -- total files to download
  errors = {},     -- array of error strings
  done = false,    -- true when finished (success or failure)
  success = false, -- true only on full success
}

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the updater.
-- @param card proxy - FINInternetCard PCI device
-- @param basePath string - DRIVE_PATH for writing files
-- @return boolean success
function MasterUpdater.init(card, basePath)
  if not card then
    print("[UPDATER] No InternetCard provided")
    return false
  end
  internetCard = card
  drivePath = basePath

  -- Try to read cached version from disk
  local versionPath = drivePath .. "/VERSION"
  if filesystem.exists(versionPath) then
    local file = filesystem.open(versionPath, "r")
    if file then
      local content = file:read(256)
      file:close()
      if content then
        cachedVersion = content:match("^%s*(.-)%s*$") -- trim whitespace
        print("[UPDATER] Current version: " .. cachedVersion)
      end
    end
  end

  print("[UPDATER] Initialized")
  return true
end

--- Check whether an InternetCard is available.
-- @return boolean
function MasterUpdater.isAvailable()
  return internetCard ~= nil
end

-- ============================================================================
-- HTTP helpers
-- ============================================================================

--- Perform a synchronous HTTP GET request.
-- Blocks the current coroutine until the response arrives.
-- @param url string - full URL
-- @return number code, string body (or nil, string error)
local function httpGet(url)
  local ok, fut = pcall(internetCard.request, internetCard, url, "GET", "", "User-Agent", "FicsIt-Master/1.0")
  if not ok then
    return nil, "request failed: " .. tostring(fut)
  end
  local code, body = fut:await()
  return code, body
end

-- ============================================================================
-- Minimal JSON parser (GitHub API responses)
-- ============================================================================

--- Decode a JSON string into a Lua table.
-- Supports: objects, arrays, strings, numbers, booleans, null.
-- Deliberately minimal — handles the GitHub tree API response format.
local function jsonDecode(str)
  local pos = 1
  local function skipWhitespace()
    while pos <= #str do
      local ch = str:sub(pos, pos)
      if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
        pos = pos + 1
      else
        break
      end
    end
  end

  local parseValue -- forward declaration

  local function parseString()
    -- pos should be on the opening quote
    pos = pos + 1 -- skip "
    local parts = {}
    while pos <= #str do
      local ch = str:sub(pos, pos)
      if ch == '"' then
        pos = pos + 1
        return table.concat(parts)
      elseif ch == '\\' then
        pos = pos + 1
        local esc = str:sub(pos, pos)
        if esc == '"' then table.insert(parts, '"')
        elseif esc == '\\' then table.insert(parts, '\\')
        elseif esc == '/' then table.insert(parts, '/')
        elseif esc == 'n' then table.insert(parts, '\n')
        elseif esc == 'r' then table.insert(parts, '\r')
        elseif esc == 't' then table.insert(parts, '\t')
        elseif esc == 'u' then
          -- Skip 4 hex digits (simplified: insert placeholder)
          pos = pos + 4
          table.insert(parts, "?")
        else
          table.insert(parts, esc)
        end
        pos = pos + 1
      else
        table.insert(parts, ch)
        pos = pos + 1
      end
    end
    return table.concat(parts)
  end

  local function parseNumber()
    local startPos = pos
    if str:sub(pos, pos) == '-' then pos = pos + 1 end
    while pos <= #str and str:sub(pos, pos):match("[%d%.eE%+%-]") do
      pos = pos + 1
    end
    return tonumber(str:sub(startPos, pos - 1))
  end

  local function parseObject()
    pos = pos + 1 -- skip {
    local obj = {}
    skipWhitespace()
    if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
    while pos <= #str do
      skipWhitespace()
      local key = parseString()
      skipWhitespace()
      pos = pos + 1 -- skip :
      skipWhitespace()
      obj[key] = parseValue()
      skipWhitespace()
      if str:sub(pos, pos) == ',' then
        pos = pos + 1
      elseif str:sub(pos, pos) == '}' then
        pos = pos + 1
        return obj
      end
    end
    return obj
  end

  local function parseArray()
    pos = pos + 1 -- skip [
    local arr = {}
    skipWhitespace()
    if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
    while pos <= #str do
      skipWhitespace()
      table.insert(arr, parseValue())
      skipWhitespace()
      if str:sub(pos, pos) == ',' then
        pos = pos + 1
      elseif str:sub(pos, pos) == ']' then
        pos = pos + 1
        return arr
      end
    end
    return arr
  end

  parseValue = function()
    skipWhitespace()
    local ch = str:sub(pos, pos)
    if ch == '"' then return parseString()
    elseif ch == '{' then return parseObject()
    elseif ch == '[' then return parseArray()
    elseif ch == 't' then pos = pos + 4; return true
    elseif ch == 'f' then pos = pos + 5; return false
    elseif ch == 'n' then pos = pos + 4; return nil
    else return parseNumber()
    end
  end

  return parseValue()
end

-- ============================================================================
-- Filesystem helpers
-- ============================================================================

-- Set of files to never delete during a wipe.
local PROTECTED_FILES = { ["config.lua"] = true }

--- Recursively delete all files and directories except protected ones.
-- @param dirPath string - absolute path to the directory to wipe
-- @param relPrefix string - relative prefix for protection matching ("" at root)
local function wipeDirectory(dirPath, relPrefix)
  local children = filesystem.children(dirPath)
  if not children then return end

  for _, name in ipairs(children) do
    local absPath = dirPath .. "/" .. name
    local relPath = (relPrefix == "") and name or (relPrefix .. "/" .. name)

    if PROTECTED_FILES[relPath] then
      print("[UPDATER] Protected, skipping: " .. relPath)
    elseif filesystem.isDir(absPath) then
      -- Recurse into subdirectory first
      wipeDirectory(absPath, relPath)
      -- Remove the directory if it is now empty
      local remaining = filesystem.children(absPath)
      if not remaining or #remaining == 0 then
        filesystem.remove(absPath)
      end
    else
      filesystem.remove(absPath)
    end
  end
end

--- Ensure all parent directories of a path exist.
-- @param filePath string - relative path like "lib/config_manager.lua"
local function ensureDirectories(filePath)
  local parts = {}
  for part in filePath:gmatch("([^/]+)") do
    table.insert(parts, part)
  end
  -- Remove the filename (last part)
  table.remove(parts)
  -- Create each directory level
  local current = drivePath
  for _, dir in ipairs(parts) do
    current = current .. "/" .. dir
    if not filesystem.exists(current) then
      filesystem.createDir(current)
    end
  end
end

--- Write content to a file, creating parent directories as needed.
-- @param relPath string - relative path from drive root
-- @param content string - file content
-- @return boolean success
local function writeFile(relPath, content)
  ensureDirectories(relPath)
  local fullPath = drivePath .. "/" .. relPath
  local f = filesystem.open(fullPath, "w")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  return true
end

-- ============================================================================
-- Update logic
-- ============================================================================

--- Get the current update state.
-- @return table { running, step, progress, total, errors, done, success }
function MasterUpdater.getState()
  return updateState
end

--- Check if an update is currently running.
-- @return boolean
function MasterUpdater.isRunning()
  return updateState.running
end

--- Start a self-update from the configured GitHub repository.
-- This is an async operation — call from within an async(function() ... end).
-- @param repoUrl string - "owner/repo" format (e.g. "DarkTerra/Phoenix-Master")
-- @param branch string - branch name (e.g. "main")
-- @param subPath string|nil - optional subdirectory prefix in the repo (e.g. "src")
-- @return boolean success
function MasterUpdater.run(repoUrl, branch, subPath)
  if updateState.running then
    print("[UPDATER] Update already in progress")
    return false
  end

  -- Reset state
  updateState = {
    running = true,
    step = "Fetching file tree...",
    progress = 0,
    total = 0,
    errors = {},
    done = false,
    success = false,
  }

  print("[UPDATER] Starting update from " .. repoUrl .. " branch=" .. branch)

  -- Step 1: Fetch the repository tree via GitHub API
  local treeUrl = "https://api.github.com/repos/" .. repoUrl .. "/git/trees/" .. branch .. "?recursive=1"
  local code, body = httpGet(treeUrl)

  if not code or code ~= 200 then
    local errMsg = "Failed to fetch tree: HTTP " .. tostring(code)
    print("[UPDATER] " .. errMsg)
    table.insert(updateState.errors, errMsg)
    updateState.step = "ERROR: " .. errMsg
    updateState.done = true
    updateState.running = false
    return false
  end

  -- Step 2: Parse the tree and filter to blobs (files) only
  local tree = jsonDecode(body)
  if not tree or not tree.tree then
    local errMsg = "Invalid tree response"
    print("[UPDATER] " .. errMsg)
    table.insert(updateState.errors, errMsg)
    updateState.step = "ERROR: " .. errMsg
    updateState.done = true
    updateState.running = false
    return false
  end

  -- Filter: only blobs, optionally under subPath prefix
  local files = {}
  local prefix = subPath and (subPath .. "/") or ""
  local prefixLen = #prefix
  for _, entry in ipairs(tree.tree) do
    if entry.type == "blob" then
      local path = entry.path
      if prefix == "" then
        table.insert(files, path)
      elseif path:sub(1, prefixLen) == prefix then
        -- Strip the subPath prefix so files land at the drive root
        table.insert(files, path:sub(prefixLen + 1))
      end
    end
  end

  -- Filter out protected files (config.lua)
  local filtered = {}
  for _, path in ipairs(files) do
    if not PROTECTED_FILES[path] then
      table.insert(filtered, path)
    else
      print("[UPDATER] Skipping protected file: " .. path)
    end
  end
  files = filtered

  -- Step 2b: Wipe existing files (except config.lua) before downloading
  updateState.step = "Cleaning old files..."
  print("[UPDATER] Wiping existing files (except config.lua)...")
  wipeDirectory(drivePath, "")
  print("[UPDATER] Wipe complete")

  updateState.total = #files
  updateState.step = "Downloading " .. #files .. " files..."
  print("[UPDATER] Tree parsed: " .. #files .. " files to download")

  if #files == 0 then
    local errMsg = "No files found in repository"
    if subPath then errMsg = errMsg .. " (subPath: " .. subPath .. ")" end
    print("[UPDATER] " .. errMsg)
    table.insert(updateState.errors, errMsg)
    updateState.step = "ERROR: " .. errMsg
    updateState.done = true
    updateState.running = false
    return false
  end

  -- Step 3: Download each file and write to disk
  local rawBase = "https://raw.githubusercontent.com/" .. repoUrl .. "/" .. branch .. "/"
  local successCount = 0

  for i, relPath in ipairs(files) do
    -- Build the raw URL (use full repo path, not stripped path)
    local rawUrl
    if prefix == "" then
      rawUrl = rawBase .. relPath
    else
      rawUrl = rawBase .. prefix .. relPath
    end

    updateState.step = "(" .. i .. "/" .. #files .. ") " .. relPath
    updateState.progress = i

    local fCode, fBody = httpGet(rawUrl)
    if fCode and fCode == 200 and fBody then
      local ok = writeFile(relPath, fBody)
      if ok then
        successCount = successCount + 1
      else
        local errMsg = "Write failed: " .. relPath
        print("[UPDATER] " .. errMsg)
        table.insert(updateState.errors, errMsg)
      end
    else
      local errMsg = "HTTP " .. tostring(fCode) .. ": " .. relPath
      print("[UPDATER] " .. errMsg)
      table.insert(updateState.errors, errMsg)
    end
  end

  -- Step 4: Read VERSION file if it was downloaded
  local versionPath = drivePath .. "/VERSION"
  if filesystem.exists(versionPath) then
    local file = filesystem.open(versionPath, "r")
    if file then
      local content = file:read(256)
      file:close()
      if content then
        cachedVersion = content:match("^%s*(.-)%s*$")
        print("[UPDATER] Updated version: " .. cachedVersion)
      end
    end
  end

  -- Step 5: Report results
  local allOk = successCount == #files
  updateState.success = allOk
  updateState.done = true
  updateState.running = false

  if allOk then
    updateState.step = "Update complete (" .. successCount .. " files)"
    print("[UPDATER] Update complete: " .. successCount .. "/" .. #files .. " files written")
  else
    updateState.step = "Partial update: " .. successCount .. "/" .. #files .. " (" .. #updateState.errors .. " errors)"
    print("[UPDATER] Partial update: " .. successCount .. "/" .. #files .. " files, " .. #updateState.errors .. " errors")
  end

  return allOk
end

--- Get the current version string (from VERSION file).
-- @return string|nil - semver string or nil if not available
function MasterUpdater.getVersion()
  return cachedVersion
end

return MasterUpdater
