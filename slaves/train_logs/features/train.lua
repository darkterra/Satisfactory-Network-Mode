-- features/train_receiver.lua (sur l'Ordinateur B)
-- Reçoit les données train depuis un autre ordinateur via le réseau.

if not NETWORK_BUS then
  print("[TRAIN_RX] No NETWORK_BUS - need network feature enabled")
  return
end

print("[TRAIN_RX] Initializing train receiver feature...")
-- S'abonner au channel "train_states" (même nom que l'émetteur)
NETWORK_BUS.subscribe("train_states", function(senderCardId, senderIdentity, payload)
  if not payload then return end

  -- payload.globalStats contient les stats globales
  local gs = payload.globalStats
  print("=== Train States from " .. senderIdentity .. " ===")
  print("Trains: " .. gs.totalTrains ..
        " | Moving: " .. gs.trainsMoving ..
        " | Docked: " .. gs.trainsDocked ..
        " | AvgSpeed: " .. math.floor(gs.averageSpeed) .. " km/h")

  -- payload.trains contient le résumé par train
  for _, t in ipairs(payload.trains or {}) do
    print("  " .. t.name .. " | " .. t.dockStateLabel ..
          " | " .. t.speed .. " km/h" ..
          (t.nextStation and (" -> " .. t.nextStation) or ""))
  end
end)

print("[TRAIN_RX] Listening for train data broadcasts...")