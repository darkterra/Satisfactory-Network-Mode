-- features/network.lua
-- Inter-computer communication feature via NetworkCard.
-- Provides a global NETWORK_BUS that other features can use to send/receive messages.

NETWORK_BUS = filesystem.doFile(DRIVE_PATH .. "/lib/network_bus.lua")

-- Register config schema
CONFIG_MANAGER.register("network", {
  { key = "basePort",  label = "Base port",       type = "number", default = 100, min = 4, max = 999 },
  { key = "portRange", label = "Port range",      type = "number", default = 899, min = 50, max = 9000 },
  { key = "identity",  label = "Computer name",   type = "string", default = "PC-1" },
})

-- Read config
local netConfig = CONFIG_MANAGER.getSection("network")

-- Resolve NetworkCard from PCI discovery
local networkCard = REGISTRY.pci.networkCards[1]
if not networkCard then
  print("[NETWORK] No NetworkCard found in PCI slots - feature disabled")
  return
end

-- Initialize the bus
local basePort = netConfig.basePort or 100
local portRange = netConfig.portRange or 899
local identity = netConfig.identity or "Generic-PC-Slave"

local success = NETWORK_BUS.init(networkCard, {
  basePort = basePort,
  portRange = portRange,
  identity = identity,
})

if not success then
  print("[NETWORK] Failed to initialize network bus")
  return
end

-- Print the local card UUID (needed by other computers to target this one)
local cardId = NETWORK_BUS.getCardId()
print("[NETWORK] Card UUID: " .. (cardId or "unknown"))
print("[NETWORK] Identity: " .. identity .. " | Base port: " .. basePort .. " | Port range: " .. portRange)

-- Register a heartbeat/discovery channel by default
-- Other computers can ping this channel to discover peers
NETWORK_BUS.registerChannel("discovery")
NETWORK_BUS.subscribe("discovery", function(senderCardId, senderIdentity, payload)
  if payload and payload.type == "ping" then
    -- Respond with our identity
    NETWORK_BUS.sendTo(senderCardId, "discovery", {
      type = "pong",
      identity = identity,
      cardId = cardId,
    })
    print("[NETWORK] Ping from " .. senderIdentity .. " (" .. senderCardId .. ") - pong sent")
  elseif payload and payload.type == "pong" then
    print("[NETWORK] Discovered peer: " .. (payload.identity or "?") .. " (" .. senderCardId .. ")")
  end
end)

-- Register signal handler in the main event loop's dispatch table.
-- This guarantees every NetworkMessage is captured (no race with event.pull).
if SIGNAL_HANDLERS then
  SIGNAL_HANDLERS["NetworkMessage"] = SIGNAL_HANDLERS["NetworkMessage"] or {}
  table.insert(SIGNAL_HANDLERS["NetworkMessage"], function(signal, comp, sender, port, ...)
    local args = { ... }
    local senderIdentity = args[1]     -- arg1: identity string
    local serializedPayload = args[2]  -- arg2: serialized data
    NETWORK_BUS.handleMessage(sender, port, senderIdentity, serializedPayload)
  end)
  print("[NETWORK] Signal handler registered - ready for inter-computer communication")
else
  print("[NETWORK] WARNING: SIGNAL_HANDLERS not available - upgrade main.lua")
end

-- Optional: Slave heartbeat for running slave computers.
-- When this computer has a slave config section, periodically broadcast
-- status so the Master can track the fleet. No-op on non-slave computers.
local slaveConfig = CONFIG_MANAGER.getSection("slave")
if slaveConfig and slaveConfig.type then
  NETWORK_BUS.registerChannel("slave_heartbeat")
  TASK_MANAGER.register("slave_heartbeat", {
    interval = 15,
    factory = function()
      return async(function()
        while true do
          NETWORK_BUS.publish("slave_heartbeat", {
            type = slaveConfig.type,
            identity = slaveConfig.identity or identity,
            cardId = cardId,
          })
          TASK_MANAGER.heartbeat("slave_heartbeat")
          sleep(10)
        end
      end)
    end,
  })
  print("[NETWORK] Slave heartbeat active (type: " .. slaveConfig.type .. ")")
end