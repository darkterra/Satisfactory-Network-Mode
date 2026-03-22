-- modules/rail_scanner.lua
-- Scans railroad infrastructure elements (signals, switches, track connections)
-- connected to this slave's FicsIt network.
-- Reports their state (signal aspects, switch positions, track data) and
-- publishes it to the network bus for the train_monitor to aggregate.
--
-- Architecture:
--   scanTopology() — expensive BFS track walk + full element probe. Called at
--                    boot, on peer changes, and every N minutes.
--   scanStates()  — lightweight read of signal/switch dynamic state. Called
--                    every 1-2 seconds for live map updates.

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
local nbPrecedentDiscoveredSignals = 0
local nbPrecedentDiscoveredSwitches = 0

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

  if #discoveredSignals ~= nbPrecedentDiscoveredSignals or #discoveredSwitches ~= nbPrecedentDiscoveredSwitches then
    print("[RAIL_SCAN] Discovery found " .. #discoveredSignals .. " signals, ".. #discoveredSwitches .. " switches")
    
    nbPrecedentDiscoveredSignals = #discoveredSignals
    nbPrecedentDiscoveredSwitches = #discoveredSwitches
  end
end

-- ============================================================================
-- Topology cache — populated by scanTopology(), read by scanStates()
-- ============================================================================

local cachedSignalTopo = {}   -- sigId → full data from scanSignal
local cachedSwitchTopo = {}   -- swId → full data from scanSwitch
local cachedTracks = {}       -- array of track segments from BFS

-- ============================================================================
-- Signal scanning (full topology + state)
-- ============================================================================

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

-- ============================================================================
-- Signal state-only update (lightweight, no topology re-probe)
-- ============================================================================

local function updateSignalState(sigInfo)
  local data = cachedSignalTopo[sigInfo.id]
  if not data then return end

  local ok, aspect = pcall(function() return sigInfo.proxy.aspect end)
  if ok then
    data.aspect = aspect
    data.aspectLabel = SIGNAL_ASPECTS[aspect] or "Unknown"
  end

  local ok2, bv = pcall(function() return sigInfo.proxy.blockValidation end)
  if ok2 then
    data.blockValidation = bv
    data.blockValidationLabel = BLOCK_VALIDATION[bv] or "Unknown"
  end

  if data.hasObservedBlock then
    local blockOk, block = pcall(sigInfo.proxy.getObservedBlock, sigInfo.proxy)
    if blockOk and block then
      local isOccOk, isOccupied = pcall(function() return block.isOccupied end)
      data.blockOccupied = isOccOk and isOccupied or false
    end
  end
end

-- ============================================================================
-- Switch scanning
-- ============================================================================

local function vecDistance(a, b)
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local lockedSwitches = {} -- switchId → position (or nil)

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

  local posOk, pos = pcall(function() return proxy.switchPosition end)
  if posOk then data.position = pos end

  local connOk, conns = pcall(proxy.getControlledConnections, proxy)
  if connOk and conns then
    data.numPositions = #conns
    if #conns > 0 then
      local stemOk, stems = pcall(conns[1].getConnections, conns[1])
      if stemOk and stems and #stems > 0 then
        local brOk, branches = pcall(stems[1].getConnections, stems[1])
        if brOk and branches and #branches > data.numPositions then
          data.numPositions = #branches
        end
      end
    end

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
-- Switch state-only update (lightweight, no topology re-probe)
-- ============================================================================

local function updateSwitchState(swInfo)
  local data = cachedSwitchTopo[swInfo.id]
  if not data then return end

  local posOk, pos = pcall(function() return swInfo.proxy.switchPosition end)
  if posOk then data.position = pos end
  data.isLocked = lockedSwitches[swInfo.id] ~= nil
  data.lockedPos = lockedSwitches[swInfo.id]
end

-- ============================================================================
-- Track collection: Territory BFS
-- Functions are defined at module level (no closures per call).
-- ============================================================================

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

-- Equipment IDs confirmed as belonging to a specific peer controller
local confirmedPeerSignalIds = {}
local confirmedPeerSwitchIds = {}

function RailScanner.updatePeerEquipment(peerSignalIds, peerSwitchIds)
  confirmedPeerSignalIds = peerSignalIds or {}
  confirmedPeerSwitchIds = peerSwitchIds or {}
end

local function connectionHasForeignEquipment(conn, ownSignalIds, ownSwitchIds)
  if next(confirmedPeerSignalIds) == nil and next(confirmedPeerSwitchIds) == nil then
    return false
  end
  local fOk, fSig = pcall(conn.getFacingSignal, conn)
  if fOk and fSig then
    local sid = tostring(fSig)
    if not ownSignalIds[sid] and confirmedPeerSignalIds[sid] then return true end
  end
  local tOk, tSig = pcall(conn.getTrailingSignal, conn)
  if tOk and tSig then
    local sid = tostring(tSig)
    if not ownSignalIds[sid] and confirmedPeerSignalIds[sid] then return true end
  end
  local swOk, swCtrl = pcall(conn.getSwitchControl, conn)
  if swOk and swCtrl then
    local sid = tostring(swCtrl)
    if not ownSwitchIds[sid] and confirmedPeerSwitchIds[sid] then return true end
  end
  return false
end

--- BFS helper: enqueue a connection if its track hasn't been enqueued yet.
local function bfsEnqueue(ctx, conn)
  local tOk, t = pcall(conn.getTrack, conn)
  if tOk and t then
    local tid = tostring(t)
    if not ctx.enqueuedTrackIds[tid] then
      ctx.enqueuedTrackIds[tid] = true
      table.insert(ctx.queue, conn)
    end
  end
end

--- BFS helper: explore neighbours from a connection endpoint.
local function bfsExploreFrom(ctx, c)
  if not c then return end
  if connectionHasForeignEquipment(c, ctx.ownSignalIds, ctx.ownSwitchIds) then return end
  local nextOk, nxt = pcall(c.getNext, c)
  if nextOk and nxt then bfsEnqueue(ctx, nxt) end
  local connsOk, nextConns = pcall(c.getConnections, c)
  if connsOk and nextConns then
    for _, alt in ipairs(nextConns) do bfsEnqueue(ctx, alt) end
  end
end

local function collectTerritoryTracks()
  local ctx = {
    queue = {},
    enqueuedTrackIds = {},
    ownSignalIds = {},
    ownSwitchIds = {},
  }
  local segments = {}
  local visitedTrackIds = {}

  for _, sig in ipairs(discoveredSignals) do ctx.ownSignalIds[sig.id] = true end
  for _, sw in ipairs(discoveredSwitches) do ctx.ownSwitchIds[sw.id] = true end

  for _, sig in ipairs(discoveredSignals) do
    local ok, conns = pcall(sig.proxy.getGuardedConnnections, sig.proxy)
    if ok and conns then
      for _, conn in ipairs(conns) do bfsEnqueue(ctx, conn) end
    end
  end

  for _, sw in ipairs(discoveredSwitches) do
    local ok, conns = pcall(sw.proxy.getControlledConnections, sw.proxy)
    if ok and conns then
      for _, conn in ipairs(conns) do bfsEnqueue(ctx, conn) end
    end
  end

  local MAX_ITERATIONS = 8000
  local iter = 0

  while #ctx.queue > 0 and iter < MAX_ITERATIONS do
    iter = iter + 1
    local conn = table.remove(ctx.queue, 1)

    local seg = collectTrackFromConn(conn, visitedTrackIds)
    if seg then
      table.insert(segments, seg)

      bfsExploreFrom(ctx, conn)
      local oppOk, opp = pcall(conn.getOpposite, conn)
      if oppOk and opp then
        bfsExploreFrom(ctx, opp)
      end
    end
  end

  return segments
end

-- ============================================================================
-- Public scan API
-- ============================================================================

--- Full topology scan: probe every element + BFS for tracks.
--- Call at boot, on peer changes, and periodically (every few minutes).
function RailScanner.scanTopology()
  cachedSignalTopo = {}
  for _, sigInfo in ipairs(discoveredSignals) do
    local ok, data = pcall(scanSignal, sigInfo)
    if ok then cachedSignalTopo[sigInfo.id] = data end
  end

  cachedSwitchTopo = {}
  for _, swInfo in ipairs(discoveredSwitches) do
    local ok, data = pcall(scanSwitch, swInfo)
    if ok then cachedSwitchTopo[swInfo.id] = data end
  end

  cachedTracks = collectTerritoryTracks()

  RailScanner.enforceLockedSwitches()
end

--- Lightweight state scan: only read dynamic properties (aspect, position).
--- Call every 1-2 seconds for live updates.
function RailScanner.scanStates()
  for _, sigInfo in ipairs(discoveredSignals) do
    updateSignalState(sigInfo)
  end
  for _, swInfo in ipairs(discoveredSwitches) do
    updateSwitchState(swInfo)
  end
  RailScanner.enforceLockedSwitches()
end

--- Build a result table from cached data (same format as the old scan()).
function RailScanner.getResults()
  local signals = {}
  for _, sigInfo in ipairs(discoveredSignals) do
    local data = cachedSignalTopo[sigInfo.id]
    if data then table.insert(signals, data) end
  end
  local switches = {}
  for _, swInfo in ipairs(discoveredSwitches) do
    local data = cachedSwitchTopo[swInfo.id]
    if data then table.insert(switches, data) end
  end
  return {
    signals = signals,
    switches = switches,
    tracks = cachedTracks,
    timestamp = computer.millis(),
    signalCount = #signals,
    switchCount = #switches,
    trackCount = #cachedTracks,
  }
end

-- ============================================================================
-- Control operations
-- ============================================================================

function RailScanner.toggleSwitch(switchId)
  for _, swInfo in ipairs(discoveredSwitches) do
    if swInfo.id == switchId then
      local posOk, currentPos = pcall(function() return swInfo.proxy.switchPosition end)
      if not posOk or type(currentPos) ~= "number" then currentPos = 0 end

      local connOk, conns = pcall(swInfo.proxy.getControlledConnections, swInfo.proxy)
      if connOk and conns and #conns > 0 then
        local mainConn = conns[1]
        local nextPos = currentPos + 1
        local setOk, err = pcall(mainConn.setSwitchPosition, mainConn, nextPos)
        if not setOk then
          nextPos = 0
          setOk, err = pcall(mainConn.setSwitchPosition, mainConn, 0)
        end
        if setOk then return true end
      end
      return false
    end
  end
  return false
end

function RailScanner.setSwitchPosition(switchId, position)
  for _, swInfo in ipairs(discoveredSwitches) do
    if swInfo.id == switchId then
      local connOk, conns = pcall(swInfo.proxy.getControlledConnections, swInfo.proxy)
      if connOk and conns and #conns > 0 then
        local mainConn = conns[1]
        local setOk, err = pcall(mainConn.setSwitchPosition, mainConn, position)
        return setOk == true
      end
      return false
    end
  end
  return false
end

function RailScanner.forceSwitchPosition(switchId, position)
  if position >= 0 then
    lockedSwitches[switchId] = math.floor(position)
    RailScanner.setSwitchPosition(switchId, math.floor(position))
    return true
  else
    lockedSwitches[switchId] = nil
    return true
  end
end

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
-- Network payload builder
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
