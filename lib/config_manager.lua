-- lib/config_manager.lua
-- Manages configuration: schema registration, load/save from disk, value access.

local ConfigManager = {
  schemas = {},     -- { sectionName = { fields } }
  values = {},      -- { sectionName = { key = value } }
  configPath = nil, -- file path for persistence
}

--- Serialize a Lua value to a writable string representation.
local function serialize(value, indent)
  indent = indent or ""
  local nextIndent = indent .. "  "
  local valueType = type(value)
  if valueType == "string" then
    return string.format("%q", value)
  elseif valueType == "number" or valueType == "boolean" then
    return tostring(value)
  elseif valueType == "table" then
    local parts = {}
    for key, val in pairs(value) do
      local keyStr
      if type(key) == "string" then
        if key:match("^[%a_][%w_]*$") then
          keyStr = key
        else
          keyStr = "[" .. string.format("%q", key) .. "]"
        end
      else
        keyStr = "[" .. tostring(key) .. "]"
      end
      table.insert(parts, nextIndent .. keyStr .. " = " .. serialize(val, nextIndent))
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  return "nil"
end

--- Register a config section with its field definitions.
-- @param sectionName string - unique section identifier
-- @param fields table - array of { key, label, type ("string"|"number"), default? }
function ConfigManager.register(sectionName, fields)
  ConfigManager.schemas[sectionName] = fields
  if not ConfigManager.values[sectionName] then
    ConfigManager.values[sectionName] = {}
  end
  -- Apply defaults for missing values
  for _, field in ipairs(fields) do
    if ConfigManager.values[sectionName][field.key] == nil and field.default ~= nil then
      ConfigManager.values[sectionName][field.key] = field.default
    end
  end
end

--- Load config values from a Lua file on disk.
function ConfigManager.load(filePath)
  ConfigManager.configPath = filePath
  if filesystem.exists(filePath) and filesystem.isFile(filePath) then
    local success, loaded = pcall(filesystem.doFile, filePath)
    if success and type(loaded) == "table" then
      ConfigManager.values = loaded
      print("[CONFIG] Loaded from " .. filePath)
      return true
    else
      print("[CONFIG] Failed to parse " .. filePath)
    end
  else
    print("[CONFIG] No config file found, using defaults")
  end
  return false
end

--- Build a complete values table with all registered schema keys present.
local function buildCompleteValues()
  local completeValues = {}
  for sectionName, fields in pairs(ConfigManager.schemas) do
    completeValues[sectionName] = {}
    -- Copy existing values
    if ConfigManager.values[sectionName] then
      for key, val in pairs(ConfigManager.values[sectionName]) do
        completeValues[sectionName][key] = val
      end
    end
    -- Ensure every schema key exists (empty string for strings, 0 for numbers, false for booleans)
    for _, field in ipairs(fields) do
      if completeValues[sectionName][field.key] == nil then
        if field.default ~= nil then
          completeValues[sectionName][field.key] = field.default
        elseif field.type == "number" then
          completeValues[sectionName][field.key] = 0
        elseif field.type == "boolean" then
          completeValues[sectionName][field.key] = false
        else
          completeValues[sectionName][field.key] = ""
        end
      end
    end
  end
  -- Preserve the "slave" section which has no schema but was injected
  -- by the provisioner. It must survive save cycles.
  if ConfigManager.values.slave and not completeValues.slave then
    completeValues.slave = ConfigManager.values.slave
  end
  return completeValues
end

--- Save current config values to disk.
function ConfigManager.save()
  if not ConfigManager.configPath then
    print("[CONFIG] No config path set")
    return false
  end
  local file = filesystem.open(ConfigManager.configPath, "w")
  if not file then
    print("[CONFIG] Failed to open file for writing")
    return false
  end
  local completeValues = buildCompleteValues()
  file:write("return " .. serialize(completeValues))
  file:close()
  print("[CONFIG] Saved to " .. ConfigManager.configPath)
  return true
end

--- Get all values for a section as a table.
function ConfigManager.getSection(sectionName)
  return ConfigManager.values[sectionName] or {}
end

--- Get a single config value.
function ConfigManager.get(sectionName, key)
  local section = ConfigManager.values[sectionName]
  if section then
    return section[key]
  end
  return nil
end

--- Set a single config value.
-- Automatically clamps number values to min/max if defined in the schema.
function ConfigManager.set(sectionName, key, value)
  if not ConfigManager.values[sectionName] then
    ConfigManager.values[sectionName] = {}
  end
  -- Validate min/max constraints from schema
  local fields = ConfigManager.schemas[sectionName]
  if fields then
    for _, field in ipairs(fields) do
      if field.key == key and field.type == "number" and type(value) == "number" then
        if field.min and value < field.min then value = field.min end
        if field.max and value > field.max then value = field.max end
        break
      end
    end
  end
  ConfigManager.values[sectionName][key] = value
end

return ConfigManager