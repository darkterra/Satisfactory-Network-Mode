-- modules/network_bus.lua
-- Generic message bus over FicsIt-Networks NetworkCard.
-- Provides channel-based pub/sub, targeted send, broadcast, and
-- simple table serialization (since NetworkCard only carries primitives).
--
-- Channels are mapped to port numbers (offset by a configurable base port).
-- Each channel can have multiple handlers subscribed.
--
-- Usage:
--   local bus = filesystem.doFile(DRIVE_PATH .. "/modules/network_bus.lua")
--   bus.init(networkCard, { basePort = 100, identity = "TrainPC" })
--   bus.subscribe("train_data", function(sender, payload) ... end)
--   bus.publish("train_data", { speed = 42, name = "Express" })
--   bus.sendTo(targetCardUUID, "train_data", { speed = 42 })

local NetworkBus = {}

-- Internal state
local card = nil
local config = {
  basePort = 100,   -- Starting port number (discovery channel lives here)
  identity = "unknown", -- Human-readable name for this computer
  portRange = 899,  -- Range of ports for channels (basePort+1 .. basePort+portRange)
}

-- Channel registry: channelName -> { port, handlers[] }
local channels = {}

-- Port -> channel name reverse lookup
local portToChannel = {}

-- ============================================================================
-- Deterministic port hashing
-- ============================================================================

--- DJB2 string hash for deterministic channel -> port mapping.
-- Same channel name always produces the same port on every computer.
-- @param str string - channel name
-- @return number - hash value (positive integer)
local function djb2Hash(str)
  local hash = 5381
  for i = 1, #str do
    hash = ((hash * 33) + string.byte(str, i)) % 0x7FFFFFFF
  end
  return hash
end

--- Compute the deterministic port for a channel name.
-- "discovery" always maps to basePort. All others map to basePort+1 .. basePort+portRange.
-- @param channelName string
-- @return number
local function channelToPort(channelName)
  if channelName == "discovery" then
    return config.basePort
  elseif channelName == "slave_heartbeat" then
    return config.basePort + 1
  end
  return config.basePort + 1 + (djb2Hash(channelName) % config.portRange)
end

-- ============================================================================
-- Serialization helpers (tables <-> string, since NetworkCard only sends primitives)
-- ============================================================================

--- Serialize a Lua value to a string representation.
-- Supports: nil, boolean, number, string, flat/nested tables (no functions/userdata).
-- @param value any
-- @return string
local function serialize(value)
  local valueType = type(value)
  if value == nil then
    return "nil"
  elseif valueType == "boolean" then
    return value and "true" or "false"
  elseif valueType == "number" then
    return tostring(value)
  elseif valueType == "string" then
    -- Escape backslashes and quotes
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
  elseif valueType == "table" then
    local parts = {}
    -- Check if array-like (consecutive integer keys from 1)
    local isArray = true
    local maxIndex = 0
    for key, _ in pairs(value) do
      if type(key) == "number" and key == math.floor(key) and key > 0 then
        if key > maxIndex then maxIndex = key end
      else
        isArray = false
        break
      end
    end
    if isArray and maxIndex == #value then
      for index = 1, #value do
        table.insert(parts, serialize(value[index]))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for key, val in pairs(value) do
        table.insert(parts, serialize(tostring(key)) .. ":" .. serialize(val))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "nil"
end

--- Deserialize a string back into a Lua value.
-- @param str string
-- @return any value, number nextPosition
local function deserializeAt(str, pos)
  pos = pos or 1
  -- Skip whitespace
  while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end

  if pos > #str then return nil, pos end

  local char = str:sub(pos, pos)

  -- nil
  if str:sub(pos, pos + 2) == "nil" then
    return nil, pos + 3
  end

  -- boolean
  if str:sub(pos, pos + 3) == "true" then
    return true, pos + 4
  end
  if str:sub(pos, pos + 4) == "false" then
    return false, pos + 5
  end

  -- number
  if char:match("[%d%.%-]") then
    local numStr = str:match("^([%-]?%d+%.?%d*)", pos)
    if numStr then
      return tonumber(numStr), pos + #numStr
    end
  end

  -- string
  if char == '"' then
    local result = {}
    pos = pos + 1
    while pos <= #str do
      local currentChar = str:sub(pos, pos)
      if currentChar == '\\' and pos + 1 <= #str then
        table.insert(result, str:sub(pos + 1, pos + 1))
        pos = pos + 2
      elseif currentChar == '"' then
        return table.concat(result), pos + 1
      else
        table.insert(result, currentChar)
        pos = pos + 1
      end
    end
    return table.concat(result), pos
  end

  -- array
  if char == '[' then
    local arr = {}
    pos = pos + 1
    while pos <= #str do
      while pos <= #str and str:sub(pos, pos):match("[%s,]") do pos = pos + 1 end
      if str:sub(pos, pos) == ']' then return arr, pos + 1 end
      local val
      val, pos = deserializeAt(str, pos)
      table.insert(arr, val)
    end
    return arr, pos
  end

  -- table/object
  if char == '{' then
    local tbl = {}
    pos = pos + 1
    while pos <= #str do
      while pos <= #str and str:sub(pos, pos):match("[%s,]") do pos = pos + 1 end
      if str:sub(pos, pos) == '}' then return tbl, pos + 1 end
      local key
      key, pos = deserializeAt(str, pos)
      -- Skip colon
      while pos <= #str and str:sub(pos, pos):match("[%s:]") do pos = pos + 1 end
      local val
      val, pos = deserializeAt(str, pos)
      if key ~= nil then tbl[key] = val end
    end
    return tbl, pos
  end

  -- Unknown - skip character
  return nil, pos + 1
end

--- Deserialize a string into a Lua value.
-- @param str string
-- @return any
local function deserialize(str)
  if not str or str == "" then return nil end
  local value = deserializeAt(str, 1)
  return value
end

-- ============================================================================
-- Core API
-- ============================================================================

--- Initialize the network bus with a NetworkCard and configuration.
-- @param networkCard proxy - a NetworkCard PCI device
-- @param options table - { basePort = number, identity = string }
-- @return boolean success
function NetworkBus.init(networkCard, options)
  if not networkCard then
    print("[NET_BUS] No NetworkCard provided")
    return false
  end

  card = networkCard

  -- Clean slate: close any ports left open from a previous session
  card:closeAll()

  -- Re-open EEPROM reserved ports (e.g. reboot port on Slave computers)
  if EEPROM_RESERVED_PORTS then
    for _, reservedPort in pairs(EEPROM_RESERVED_PORTS) do
      card:open(reservedPort)
    end
  end

  if options then
    config.basePort = options.basePort or config.basePort
    config.identity = options.identity or config.identity
    config.portRange = options.portRange or config.portRange
  end

  -- Listen for incoming messages from this card
  event.listen(card)
  print("[NET_BUS] Initialized (identity: " .. config.identity .. ", basePort: " .. config.basePort .. ")")
  return true
end

--- Get the UUID of the local NetworkCard (for other computers to target us).
-- @return string or nil
function NetworkBus.getCardId()
  if not card then return nil end
  local success, cardId = pcall(function() return card.id end)
  return success and cardId or nil
end

--- Get the configured identity name.
-- @return string
function NetworkBus.getIdentity()
  return config.identity
end

--- Register a named channel and open its port for receiving.
-- Port is computed deterministically from the channel name (same on every computer).
-- @param channelName string - unique channel name
-- @return number port - the assigned port number
function NetworkBus.registerChannel(channelName)
  if channels[channelName] then
    return channels[channelName].port
  end

  local port = channelToPort(channelName)

  -- Handle hash collision: if another channel already occupies this port,
  -- offset until we find a free one (extremely rare)
  local existingChannel = portToChannel[port]
  if existingChannel and existingChannel ~= channelName then
    local original = port
    repeat
      port = port + 1
      if port > config.basePort + config.portRange then
        port = config.basePort + 1
      end
    until not portToChannel[port] or portToChannel[port] == channelName or port == original
    print("[NET_BUS] Hash collision for '" .. channelName .. "': " .. original .. " -> " .. port)
  end

  channels[channelName] = {
    port = port,
    handlers = {},
  }
  portToChannel[port] = channelName

  -- Open the port so we can receive on it
  card:open(port)
  print("[NET_BUS] Channel '" .. channelName .. "' -> port " .. port)
  return port
end

--- Subscribe a handler to a channel.
-- The handler receives: function(senderCardId, senderIdentity, payload)
-- @param channelName string
-- @param handler function
function NetworkBus.subscribe(channelName, handler)
  if not channels[channelName] then
    NetworkBus.registerChannel(channelName)
  end
  table.insert(channels[channelName].handlers, handler)
end

--- Unsubscribe all handlers from a channel.
-- @param channelName string
function NetworkBus.unsubscribe(channelName)
  if channels[channelName] then
    channels[channelName].handlers = {}
  end
end

--- Publish (broadcast) a message on a channel to all computers.
-- @param channelName string
-- @param payload any - will be serialized if it's a table
function NetworkBus.publish(channelName, payload)
  if not card then
    print("[NET_BUS] Not initialized")
    return
  end

  if not channels[channelName] then
    NetworkBus.registerChannel(channelName)
  end

  local port = channels[channelName].port
  local serialized = serialize(payload)
  card:broadcast(port, config.identity, serialized)
end

--- Send a message to a specific computer's NetworkCard.
-- @param targetCardId string - UUID of the target NetworkCard
-- @param channelName string
-- @param payload any - will be serialized if it's a table
function NetworkBus.sendTo(targetCardId, channelName, payload)
  if not card then
    print("[NET_BUS] Not initialized")
    return
  end

  if not channels[channelName] then
    NetworkBus.registerChannel(channelName)
  end

  local port = channels[channelName].port
  local serialized = serialize(payload)
  card:send(targetCardId, port, config.identity, serialized)
end

--- Process a single incoming NetworkMessage event.
-- Called by the listener task when a message arrives.
-- @param sender string - NetworkCard UUID of the sender
-- @param port number - port the message arrived on
-- @param senderIdentity string - human-readable name of the sender
-- @param serializedPayload string - serialized data
function NetworkBus.handleMessage(sender, port, senderIdentity, serializedPayload)
  local channelName = portToChannel[port]
  if not channelName then
    -- Message on an unregistered port, ignore
    return
  end

  local channel = channels[channelName]
  if not channel or #channel.handlers == 0 then
    return
  end

  local payload = deserialize(serializedPayload)

  for _, handler in ipairs(channel.handlers) do
    local success, err = pcall(handler, sender, senderIdentity or "unknown", payload)
    if not success then
      print("[NET_BUS] Handler error on '" .. channelName .. "': " .. tostring(err))
    end
  end
end

--- Get all registered channel names.
-- @return table - array of channel names
function NetworkBus.getChannels()
  local result = {}
  for name, _ in pairs(channels) do
    table.insert(result, name)
  end
  return result
end

--- Get the port number for a channel.
-- @param channelName string
-- @return number or nil
function NetworkBus.getPort(channelName)
  if channels[channelName] then
    return channels[channelName].port
  end
  return nil
end

--- Clean up: close all ports and stop listening.
function NetworkBus.shutdown()
  if card then
    card:closeAll()
    event.ignore(card)
    print("[NET_BUS] Shutdown - all ports closed")
  end
end

return NetworkBus