-- modules/rail_scanner.lua
-- Scans railroad infrastructure elements (signals, switches, track connections)
-- connected to this slave's FicsIt network.
-- Reports their state (signal aspects, switch positions, track data) and
-- publishes it to the network bus for the train_monitor to aggregate.

local RailScanner = {}

-- ============================================================================
-- Signal aspect / validation labels (shared with train_monitor)
-- ============================================================================

local SIGNAL_ASPECTS = {
  [0] = "Unknown",
  [1] = "Clear",
  [2] = "Stop",
  [3] = "Dock",
}

local BLOCK_VALIDATION = {
  [0] = "Unknown",
  [1] = "OK",
  [2] = "No Exit Signal",
  [3] = "Contains Loop",
  [4] = "Mixed Entry Signals",
}

-- ============================================================================
-- Discovery
-- ============================================================================

local discoveredSignals = {}
local discoveredSwitches = {}

--- Discover all signals and switches accessible from the component network.
-- @param proxiesByCategory table - from REGISTRY, keyed by category name
function RailScanner.discover(proxiesByCategory)
  discoveredSignals = {}
  discoveredSwitches = {}

  local signalProxies = proxiesByCategory["rail_signals"] or {}
  for _, proxy in ipairs(signalProxies) do
    table.insert(discoveredSignals, {
      id = tostring(proxy),
      proxy = proxy,
      nick = proxy.nick or "",
    })
  end

  local switchProxies = proxiesByCategory["rail_switches"] or {}
  for _, proxy in ipairs(switchProxies) do
    table.insert(discoveredSwitches, {
      id = tostring(proxy),
      proxy = proxy,
      nick = proxy.nick or "",
    })
  end

  print("[RAIL_SCAN] Discovered " .. #discoveredSignals .. " signals, ".. #discoveredSwitches .. " switches")
end

-- ============================================================================
-- Scanning
-- ============================================================================

--- Collect state of a single signal.
local function scanSignal(sigInfo)
  local proxy = sigInfo.proxy
  local data = {
    id = sigInfo.id,
    nick = sigInfo.nick,
    aspect = 0,
    aspectLabel = "Unknown",
    blockValidation = 0,
    blockValidationLabel = "Unknown",
    isBiDirectional = false,
    isPathSignal = false,
    hasObservedBlock = false,
    location = nil,
  }

  local ok
  ok, data.aspect = pcall(function() return proxy.aspect end)
  if ok then
    data.aspectLabel = SIGNAL_ASPECTS[data.aspect] or "Unknown"
  end

  ok, data.blockValidation = pcall(function() return proxy.blockValidation end)
  if ok then
    data.blockValidationLabel = BLOCK_VALIDATION[data.blockValidation] or "Unknown"
  end

  pcall(function() data.isBiDirectional = proxy.isBiDirectional end)
  pcall(function() data.isPathSignal = proxy.isPathSignal end)
  pcall(function() data.hasObservedBlock = proxy.hasObservedBlock end)

  local connOk, guardedConns = pcall(proxy.getGuardedConnnections, proxy)
  if connOk and guardedConns and #guardedConns > 0 then
    local locOk, loc = pcall(function() return guardedConns[1].connectorLocation end)
    if locOk and loc then
      data.location = { x = loc.x, y = loc.y, z = loc.z }
    end
  end

  if data.hasObservedBlock then
    local blockOk, block = pcall(proxy.getObservedBlock, proxy)
    if blockOk and block then
      local isOccOk, isOccupied = pcall(function() return block.isOccupied end)
      data.blockOccupied = isOccOk and isOccupied or false
    end
  end

  return data
end

--- Euclidean distance between two {x,y,z} locations.
local function vecDistance(a, b)
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end


--- Switches locked by our code via setSwitchPosition (enforced every scan).
--- FIN's native forceSwitchPosition crashes (assertion in AFIRSubsystem::UpdateRailroadSwitch),
--- so we emulate it with periodic re-application of setSwitchPosition.
local lockedSwitches = {} -- switchId → position (or nil)


--- Collect state of a single switch.
local function scanSwitch(swInfo)
  local proxy = swInfo.proxy
  local data = {
    id = swInfo.id,
    nick = swInfo.nick,
    position = 0,
    numPositions = 0,
    location = nil,
    isLocked = lockedSwitches[swInfo.id] ~= nil,
    lockedPos = lockedSwitches[swInfo.id],
  }

  local posOk, pos = pcall(proxy.switchPosition, proxy)
  if posOk then data.position = pos end

  local connOk, conns = pcall(proxy.getControlledConnections, proxy)
  if connOk and conns then
    data.numPositions = #conns

    if #conns > 0 then
      local locOk, loc = pcall(function() return conns[1].connectorLocation end)
      if locOk and loc then
        data.location = { x = loc.x, y = loc.y, z = loc.z }
      end

      data.connections = {}
      for i, conn in ipairs(conns) do
        local connData = { index = i - 1 }

        local trackOk, track = pcall(conn.getTrack, conn)
        if trackOk and track then
          local lenOk, len = pcall(function() return track.length end)
          connData.trackLength = (lenOk and len and len > 0) and len or 0
          connData.trackId = tostring(track)
        end

        local oppOk, opposite = pcall(conn.getOpposite, conn)
        if oppOk and opposite then
          if (connData.trackLength or 0) == 0 then
            local oppLocOk, oppLoc = pcall(function() return opposite.connectorLocation end)
            if oppLocOk and oppLoc and data.location then
              connData.trackLength = vecDistance(data.location, oppLoc)
            end
          end

          local oppLocOk2, oppLoc2 = pcall(function() return opposite.connectorLocation end)
          if oppLocOk2 and oppLoc2 then
            connData.endLocation = { x = oppLoc2.x, y = oppLoc2.y, z = oppLoc2.z }
          end

          local fSigOk, fSig = pcall(conn.getFacingSignal, conn)
          local tSigOk, tSig = pcall(conn.getTrailingSignal, conn)
          local oppFSigOk, oppFSig = pcall(opposite.getFacingSignal, opposite)
          local oppTSigOk, oppTSig = pcall(opposite.getTrailingSignal, opposite)

          local hasSigThisEnd  = (fSigOk and fSig ~= nil) or (tSigOk and tSig ~= nil)
          local hasSigOtherEnd = (oppFSigOk and oppFSig ~= nil) or (oppTSigOk and oppTSig ~= nil)

          if hasSigThisEnd and hasSigOtherEnd then
            connData.direction = "bidirectional"
          elseif hasSigThisEnd then
            connData.direction = "forward"
          elseif hasSigOtherEnd then
            connData.direction = "reverse"
          else
            connData.direction = "unknown"
          end
        else
          connData.direction = "unknown"
        end

        table.insert(data.connections, connData)
      end
    end
  end

  return data
end

-- ============================================================================
-- Track collection: Territory BFS
-- Each rail_controller walks outward from its own signals/switches and fills
-- its "territory", stopping when it reaches equipment owned by a different
-- controller. This dynamically partitions the network: controllers placed
-- close together share a tight boundary, while sparse controllers cover the
-- long stretches between them. Map-side dedup (drawnTrackIds) handles the
-- small overlap at boundaries.
-- ============================================================================

--- Compute Hermite interpolation waypoints between two connection endpoints.
--- Uses connectorLocation + connectorNormal to approximate the track curve.
local function hermiteWaypoints(startLoc, startNorm, endLoc, endNorm, trackLen, numPts)
  if not startLoc or not endLoc then return nil end
  numPts = numPts or 4
  if numPts < 1 then return nil end

  local sl = trackLen or vecDistance(startLoc, endLoc)
  if sl < 50 then return nil end

  local tension = sl * 0.4
  local t0x, t0y = (startNorm and startNorm.x or 0) * tension, (startNorm and startNorm.y or 0) * tension
  local t1x, t1y = (endNorm and endNorm.x or 0) * tension, (endNorm and endNorm.y or 0) * tension

  local waypoints = {}
  for i = 1, numPts do
    local t = i / (numPts + 1)
    local t2 = t * t
    local t3 = t2 * t
    local h00 = 2 * t3 - 3 * t2 + 1
    local h10 = t3 - 2 * t2 + t
    local h01 = -2 * t3 + 3 * t2
    local h11 = t3 - t2
    table.insert(waypoints, {
      x = h00 * startLoc.x + h10 * t0x + h01 * endLoc.x + h11 * t1x,
      y = h00 * startLoc.y + h10 * t0y + h01 * endLoc.y + h11 * t1y,
    })
  end
  return waypoints
end

--- Collect a single track segment from a connection pair (conn + its opposite).
local function collectTrackFromConn(conn, visitedTrackIds)
  local trackOk, track = pcall(conn.getTrack, conn)
  if not trackOk or not track then return nil end
  local trackId = tostring(track)
  if visitedTrackIds[trackId] then return nil end
  visitedTrackIds[trackId] = true

  local locOk, loc = pcall(function() return conn.connectorLocation end)
  local normOk, norm = pcall(function() return conn.connectorNormal end)
  local oppOk, opp = pcall(conn.getOpposite, conn)
  if not locOk or not loc or not oppOk or not opp then return nil end

  local oppLocOk, oppLoc = pcall(function() return opp.connectorLocation end)
  local oppNormOk, oppNorm = pcall(function() return opp.connectorNormal end)
  if not oppLocOk or not oppLoc then return nil end

  local lenOk, trackLen = pcall(function() return track.length end)
  local tLen = (lenOk and trackLen and trackLen > 0) and trackLen or vecDistance(loc, oppLoc)
  local numPts = math.min(math.max(math.floor(tLen / 800), 2), 6)

  return {
    trackId = trackId,
    startLocation = { x = loc.x, y = loc.y, z = loc.z },
    endLocation = { x = oppLoc.x, y = oppLoc.y, z = oppLoc.z },
    trackLength = tLen,
    waypoints = hermiteWaypoints(
      loc, normOk and norm or nil,
      oppLoc, oppNormOk and oppNorm or nil,
      tLen, numPts),
  }
end

--- Check whether a RailroadTrackConnection has a signal or switch that this
--- controller does NOT own. Used as boundary detection for territory BFS:
--- foreign equipment marks the edge of another controller's territory.
local function connectionHasForeignEquipment(conn, ownSignalIds, ownSwitchIds)
  local fOk, fSig = pcall(conn.getFacingSignal, conn)
  if fOk and fSig and not ownSignalIds[tostring(fSig)] then return true end
  local tOk, tSig = pcall(conn.getTrailingSignal, conn)
  if tOk and tSig and not ownSignalIds[tostring(tSig)] then return true end
  local swOk, swCtrl = pcall(conn.getSwitchControl, conn)
  if swOk and swCtrl and not ownSwitchIds[tostring(swCtrl)] then return true end
  return false
end

--- BFS from own equipment, collecting every track until a foreign boundary.
--- Each controller "fills" the rails between its own signals/switches and the
--- nearest equipment belonging to another controller. Dead-ends and long
--- stretches with no intermediate equipment are naturally covered.
local function collectTerritoryTracks()
  local segments = {}
  local visitedTrackIds = {}
  local queue = {}

  local ownSignalIds = {}
  for _, sig in ipairs(discoveredSignals) do ownSignalIds[sig.id] = true end
  local ownSwitchIds = {}
  for _, sw in ipairs(discoveredSwitches) do ownSwitchIds[sw.id] = true end

  -- Seed from own signals (both directions per guarded connection)
  for _, sig in ipairs(discoveredSignals) do
    local ok, conns = pcall(sig.proxy.getGuardedConnnections, sig.proxy)
    if ok and conns then
      for _, conn in ipairs(conns) do
        table.insert(queue, conn)
        local oppOk, opp = pcall(conn.getOpposite, conn)
        if oppOk and opp then table.insert(queue, opp) end
      end
    end
  end

  -- Seed from own switches (both directions per controlled connection)
  for _, sw in ipairs(discoveredSwitches) do
    local ok, conns = pcall(sw.proxy.getControlledConnections, sw.proxy)
    if ok and conns then
      for _, conn in ipairs(conns) do
        table.insert(queue, conn)
        local oppOk, opp = pcall(conn.getOpposite, conn)
        if oppOk and opp then table.insert(queue, opp) end
      end
    end
  end

  local MAX_ITERATIONS = 4000
  local iter = 0

  while #queue > 0 and iter < MAX_ITERATIONS do
    iter = iter + 1
    local conn = table.remove(queue, 1)

    local seg = collectTrackFromConn(conn, visitedTrackIds)
    if seg then
      table.insert(segments, seg)
    end

    -- Walk from the far end of this track toward the next segment
    local oppOk, opp = pcall(conn.getOpposite, conn)
    if oppOk and opp then
      if not connectionHasForeignEquipment(opp, ownSignalIds, ownSwitchIds) then
        local function enqueueIfNew(c)
          local ok, t = pcall(c.getTrack, c)
          if ok and t and not visitedTrackIds[tostring(t)] then
            table.insert(queue, c)
          end
        end

        -- Primary: getNext follows active path (reliable on all connections)
        local nextOk, nxt = pcall(opp.getNext, opp)
        if nextOk and nxt then enqueueIfNew(nxt) end

        -- Supplement: getConnections reveals alternative switch branches
        local connsOk, nextConns = pcall(opp.getConnections, opp)
        if connsOk and nextConns then
          for _, alt in ipairs(nextConns) do enqueueIfNew(alt) end
        end
      end
    end
  end

  if iter >= MAX_ITERATIONS then
    print("[RAIL_SCAN] Territory BFS hit iteration limit (" .. MAX_ITERATIONS .. ")")
  end

  return segments
end

--- Perform a full scan of all discovered rail elements.
function RailScanner.scan()
  local signals = {}
  for _, sigInfo in ipairs(discoveredSignals) do
    local ok, data = pcall(scanSignal, sigInfo)
    if ok then
      table.insert(signals, data)
    else
      print("[RAIL_SCAN] Error scanning signal: " .. tostring(data))
    end
  end

  local switches = {}
  for _, swInfo in ipairs(discoveredSwitches) do
    local ok, data = pcall(scanSwitch, swInfo)
    if ok then
      table.insert(switches, data)
    else
      print("[RAIL_SCAN] Error scanning switch: " .. tostring(data))
    end
  end

  local tracks = collectTerritoryTracks()

  RailScanner.enforceLockedSwitches()

  return {
    signals = signals,
    switches = switches,
    tracks = tracks,
    timestamp = computer.millis(),
    signalCount = #signals,
    switchCount = #switches,
    trackCount = #tracks,
  }
end

-- ============================================================================
-- Control operations
-- ============================================================================

function RailScanner.toggleSwitch(switchId)
  for _, swInfo in ipairs(discoveredSwitches) do
    if swInfo.id == switchId then
      local connOk, conns = pcall(swInfo.proxy.getControlledConnections, swInfo.proxy)
      if connOk and conns and #conns > 0 then
        local mainConn = conns[1]
        local posOk, currentPos = pcall(mainConn.getSwitchPosition, mainConn)
        local numPos = #conns
        if posOk and numPos > 0 then
          local nextPos = (currentPos + 1) % numPos
          local setOk, err = pcall(mainConn.setSwitchPosition, mainConn, nextPos)
          if setOk then
            print("[RAIL_SCAN] Toggled switch " .. switchId .. " → pos " .. nextPos)
            return true
          else
            print("[RAIL_SCAN] Failed to toggle: " .. tostring(err))
            return false
          end
        end
      end
      return false
    end
  end
  print("[RAIL_SCAN] Switch not found: " .. switchId)
  return false
end

function RailScanner.setSwitchPosition(switchId, position)
  for _, swInfo in ipairs(discoveredSwitches) do
    if swInfo.id == switchId then
      local connOk, conns = pcall(swInfo.proxy.getControlledConnections, swInfo.proxy)
      if connOk and conns and #conns > 0 then
        local mainConn = conns[1]
        local setOk, err = pcall(mainConn.setSwitchPosition, mainConn, position)
        if setOk then
          print("[RAIL_SCAN] Set switch " .. switchId .. " to position " .. position)
          return true
        else
          print("[RAIL_SCAN] Failed to set position: " .. tostring(err))
          return false
        end
      end
      return false
    end
  end
  return false
end

--- Lock or release a switch position.
--- position >= 0 → lock at that position (re-applied every scan cycle).
--- position < 0  → release the lock.
function RailScanner.forceSwitchPosition(switchId, position)
  if position >= 0 then
    lockedSwitches[switchId] = math.floor(position)
    RailScanner.setSwitchPosition(switchId, math.floor(position))
    print("[RAIL_SCAN] Locked switch " .. switchId .. " at position " .. math.floor(position))
    return true
  else
    lockedSwitches[switchId] = nil
    print("[RAIL_SCAN] Released switch lock " .. switchId)
    return true
  end
end

--- Re-apply all locked switch positions. Called from scan() every cycle.
function RailScanner.enforceLockedSwitches()
  for switchId, pos in pairs(lockedSwitches) do
    RailScanner.setSwitchPosition(switchId, pos)
  end
end

function RailScanner.getLockedSwitches()
  return lockedSwitches
end

-- ============================================================================
-- Forced route management
-- ============================================================================

local activeForces = {}

function RailScanner.applyForcedRoute(routeData)
  if not routeData or not routeData.route then return end
  for _, sw in ipairs(routeData.route) do
    RailScanner.forceSwitchPosition(sw.switchId, sw.position)
    activeForces[sw.switchId] = routeData.trainId
  end
end

function RailScanner.releaseForcedRoute(trainId)
  local toRelease = {}
  for switchId, owner in pairs(activeForces) do
    if owner == trainId then
      table.insert(toRelease, switchId)
    end
  end
  for _, switchId in ipairs(toRelease) do
    RailScanner.forceSwitchPosition(switchId, -1)
    activeForces[switchId] = nil
  end
end

-- ============================================================================
-- Network payload builders
-- ============================================================================

function RailScanner.buildPayload(scanResult)
  local signals = {}
  for _, s in ipairs(scanResult.signals) do
    table.insert(signals, {
      id = s.id,
      nick = s.nick,
      aspect = s.aspect,
      aspectLabel = s.aspectLabel,
      blockOccupied = s.blockOccupied,
      isBiDirectional = s.isBiDirectional,
      isPathSignal = s.isPathSignal,
      location = s.location,
    })
  end

  local switches = {}
  for _, s in ipairs(scanResult.switches) do
    local conns = {}
    for _, c in ipairs(s.connections or {}) do
      table.insert(conns, {
        index = c.index,
        trackId = c.trackId,
        trackLength = c.trackLength,
        endLocation = c.endLocation,
        direction = c.direction,
      })
    end
    table.insert(switches, {
      id = s.id,
      nick = s.nick,
      position = s.position,
      numPositions = s.numPositions,
      location = s.location,
      connections = conns,
    })
  end

  return {
    signals = signals,
    switches = switches,
    tracks = scanResult.tracks or {},
    signalCount = #signals,
    switchCount = #switches,
    trackCount = #(scanResult.tracks or {}),
  }
end

return RailScanner
