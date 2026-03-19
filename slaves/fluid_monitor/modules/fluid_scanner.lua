-- modules/fluid_scanner.lua
-- Discovers and scans fluid network elements (pumps, reservoirs, valves, extractors).
--
-- Each element is identified by its network nick using a separator convention:
--   nick = "GroupName:ElementName"
-- Groups are automatically derived from the nick prefix.
-- Elements without the separator fall into the default group.
--
-- Discovery is done by the feature file which passes pre-resolved proxies
-- keyed by element type. This module handles nick parsing, property reading,
-- pipe connection analysis, and data aggregation.

local FluidScanner = {}

-- Configuration
local config = {
  separator = ":",
  defaultGroup = "default",
  groupFilter = nil, -- nil = all, or array of allowed group names
}

-- Cached element references after discovery
-- { proxy, id, nick, groupName, elementName, elementType,
--   controllable, pipeConnectorCount }
local elements = {}

-- Group ordering (array of group names)
local groupOrder = {}

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the scanner with configuration options.
-- @param options table - { separator, defaultGroup, groupFilter }
function FluidScanner.init(options)
  if options then
    config.separator = options.separator or config.separator
    config.defaultGroup = options.defaultGroup or config.defaultGroup
    if options.groupFilter and options.groupFilter ~= "" then
      config.groupFilter = {}
      for name in options.groupFilter:gmatch("[^,]+") do
        local trimmed = name:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
          table.insert(config.groupFilter, trimmed)
        end
      end
      if #config.groupFilter == 0 then config.groupFilter = nil end
    end
  end
  print("[FLUID_SCN] Initialized (separator: '" .. config.separator .. "')")
end

-- ============================================================================
-- Discovery helpers
-- ============================================================================

--- Parse a nick into group name and element name.
-- After splitting on separator, the element name is further stripped to the
-- first word (before the first space). This matches container_scanner and
-- also supports the game's grouped nick-query syntax (e.g. "Group:Pump 1"
-- becomes elementName="Pump").
-- @param nick string - full nick from network component
-- @return string groupName, string elementName
local function parseNick(nick)
  local sep = config.separator
  local sepPos = nick:find(sep, 1, true)
  local groupName, rawName
  if sepPos and sepPos > 1 and sepPos < #nick then
    groupName = nick:sub(1, sepPos - 1)
    rawName   = nick:sub(sepPos + #sep)
  else
    groupName = config.defaultGroup
    rawName   = nick
  end
  -- Strip everything after the first space (query suffix)
  local elementName = rawName:match("([^%s]+)") or rawName
  return groupName, elementName
end

--- Check if a group name passes the optional filter.
-- @param groupName string
-- @return boolean
local function groupAllowed(groupName)
  if not config.groupFilter then return true end
  for _, allowed in ipairs(config.groupFilter) do
    if allowed == groupName then return true end
  end
  return false
end

--- Count pipe connectors on an actor.
-- @param proxy component proxy
-- @return number
local function countPipeConnectors(proxy)
  local ok, conns = pcall(function() return proxy:getPipeConnectors() end)
  if ok and conns then return #conns end
  return 0
end

--- Determine the element type label from the category key.
-- @param catKey string - e.g. "fluid_PipelinePump"
-- @return string - "pump", "reservoir", "valve", "extractor", or "unknown"
local function typeFromCategory(catKey)
  if catKey:find("PipelinePump") then return "pump" end
  if catKey:find("PipeReservoir") then return "reservoir" end
  if catKey:find("PipelineAttachment") or catKey:find("Valve") then return "valve" end
  if catKey:find("WaterPump") or catKey:find("ResourceExtractor") then return "extractor" end
  return "unknown"
end

-- ============================================================================
-- Discovery
-- ============================================================================

--- Discover fluid elements from proxies grouped by category.
-- @param proxiesByCategory table - { categoryKey = { proxy, ... }, ... }
-- @return number - total count of elements retained
function FluidScanner.discover(proxiesByCategory)
  elements = {}
  groupOrder = {}
  local groupSeen = {}
  local seenIds = {}

  if not proxiesByCategory then
    print("[FLUID_SCN] No proxies provided for discovery")
    return 0
  end

  -- Process categories in priority order: pumps first, then reservoirs,
  -- then extractors, then valves (so we can deduplicate valve category
  -- which may also find pumps since PipelinePump extends FGBuildablePipelineAttachment)
  local categoryKeys = {}
  for catKey, _ in pairs(proxiesByCategory) do
    table.insert(categoryKeys, catKey)
  end
  -- Sort: pumps > reservoirs > extractors > valves
  table.sort(categoryKeys, function(a, b)
    local order = { pump = 1, reservoir = 2, extractor = 3, valve = 4, unknown = 5 }
    return (order[typeFromCategory(a)] or 5) < (order[typeFromCategory(b)] or 5)
  end)

  for _, catKey in ipairs(categoryKeys) do
    local proxies = proxiesByCategory[catKey]
    local elementType = typeFromCategory(catKey)

    for _, proxy in ipairs(proxies) do
      local idOk, id = pcall(function() return proxy.id end)
      if idOk and id and not seenIds[id] then
        seenIds[id] = true

        local nickOk, nick = pcall(function() return proxy.nick end)
        nick = (nickOk and nick and nick ~= "") and nick or ("Unknown_" .. id:sub(1, 8))

        local groupName, elementName = parseNick(nick)

        if groupAllowed(groupName) then
          -- Determine controllability
          local controllable = false
          if elementType == "pump" then
            -- PipelinePump: control via userFlowLimit
            controllable = true
          elseif elementType == "extractor" then
            -- Factory children: control via standby
            controllable = true
          elseif elementType == "reservoir" then
            -- Reservoirs are passive tanks — standby has no effect
            controllable = false
          elseif elementType == "valve" then
            -- FGBuildablePipelineAttachment: try userFlowLimit at runtime
            local ok, _ = pcall(function() return proxy.userFlowLimit end)
            controllable = ok
          end

          table.insert(elements, {
            proxy = proxy,
            id = id,
            nick = nick,
            groupName = groupName,
            elementName = elementName,
            elementType = elementType,
            controllable = controllable,
            category = catKey,
            pipeConnectorCount = countPipeConnectors(proxy),
          })

          if not groupSeen[groupName] then
            groupSeen[groupName] = true
            table.insert(groupOrder, groupName)
          end
        end
      end
    end
  end

  print("[FLUID_SCN] Discovered " .. #elements .. " elements in " .. #groupOrder .. " groups")
  return #elements
end

-- ============================================================================
-- Scanning
-- ============================================================================

--- Read a numeric property safely, returning 0 on failure.
local function safeNum(proxy, prop)
  local ok, val = pcall(function() return proxy[prop] end)
  return (ok and type(val) == "number") and val or 0
end

--- Read a boolean property safely, returning false on failure.
local function safeBool(proxy, prop)
  local ok, val = pcall(function() return proxy[prop] end)
  return (ok and type(val) == "boolean") and val or false
end

-- Default color for unknown fluids.
local DEFAULT_FLUID_COLOR = { r = 0.5, g = 0.5, b = 1.0, a = 1.0 }

-- Known fluid colors keyed by internal fluid key.
local KNOWN_FLUID_COLORS = {
  Water           = { r = 0.2,  g = 0.5,  b = 1.0,  a = 1.0 },
  LiquidOil       = { r = 0.15, g = 0.1,  b = 0.05, a = 1.0 },
  HeavyOilResidue = { r = 0.4,  g = 0.2,  b = 0.1,  a = 1.0 },
  LiquidFuel      = { r = 1.0,  g = 0.6,  b = 0.1,  a = 1.0 },
  LiquidTurboFuel = { r = 1.0,  g = 0.3,  b = 0.2,  a = 1.0 },
  LiquidBiofuel   = { r = 0.5,  g = 0.8,  b = 0.2,  a = 1.0 },
  AluminaSolution = { r = 0.8,  g = 0.8,  b = 0.9,  a = 1.0 },
  SulfuricAcid    = { r = 0.8,  g = 0.8,  b = 0.2,  a = 1.0 },
  NitrogenGas     = { r = 0.6,  g = 0.9,  b = 1.0,  a = 1.0 },
  NitricAcid      = { r = 0.6,  g = 1.0,  b = 0.5,  a = 1.0 },
  DissolveSilica  = { r = 0.9,  g = 0.9,  b = 0.8,  a = 1.0 },
}

-- Human-friendly display names keyed by internal fluid key.
local FLUID_DISPLAY_NAMES = {
  Water           = "Water",
  LiquidOil       = "Crude Oil",
  HeavyOilResidue = "Heavy Oil",
  LiquidFuel      = "Fuel",
  LiquidTurboFuel = "Turbofuel",
  LiquidBiofuel   = "Biofuel",
  AluminaSolution = "Alumina",
  SulfuricAcid    = "Sulfuric",
  NitrogenGas     = "N2 Gas",
  NitricAcid      = "Nitric",
  DissolveSilica  = "Silica",
}

-- Satisfactory fluid descriptor class names (UE format).
-- Used for equality comparison with the `classes` global.
local FLUID_CLASS_ENTRIES = {
  { key = "Water",           descs = {"Desc_Water_C"} },
  { key = "LiquidOil",       descs = {"Desc_LiquidOil_C"} },
  { key = "HeavyOilResidue", descs = {"Desc_HeavyOilResidue_C"} },
  { key = "LiquidFuel",      descs = {"Desc_LiquidFuel_C"} },
  { key = "LiquidTurboFuel", descs = {"Desc_LiquidTurboFuel_C"} },
  { key = "LiquidBiofuel",   descs = {"Desc_LiquidBiofuel_C"} },
  { key = "AluminaSolution", descs = {"Desc_AluminaSolution_C"} },
  { key = "SulfuricAcid",    descs = {"Desc_SulfuricAcid_C"} },
  { key = "NitrogenGas",     descs = {"Desc_NitrogenGas_C"} },
  { key = "NitricAcid",      descs = {"Desc_NitricAcid_C"} },
  { key = "DissolveSilica",  descs = {"Desc_DissolveSilica_C"} },
}

-- Resolved class references from the `classes` global (built on first use).
local resolvedClassList = nil

--- Build the resolved class reference list from the `classes` global.
local function ensureClassRefs()
  if resolvedClassList then return end
  resolvedClassList = {}
  for _, entry in ipairs(FLUID_CLASS_ENTRIES) do
    for _, descName in ipairs(entry.descs) do
      local ok, ref = pcall(function() return classes[descName] end)
      if ok and ref then
        table.insert(resolvedClassList, { ref = ref, key = entry.key })
      end
    end
  end
  print("[FLUID_SCN] Loaded " .. #resolvedClassList .. "/" .. #FLUID_CLASS_ENTRIES
    .. " fluid class refs for identification")
end

--- Build a fluid type result table from a known fluid key.
local function makeFluidType(key)
  return {
    name = FLUID_DISPLAY_NAMES[key] or key:gsub("_", " "),
    key = key,
    color = KNOWN_FLUID_COLORS[key] or DEFAULT_FLUID_COLOR,
    form = 2, -- default: Liquid
  }
end

-- Debug log dedup: only log once per unique tostring value.
local fluidDebugLogged = {}

--- Identify the fluid type from a PipeReservoir (getFluidType) or
--- PipeConnection (getFluidDescriptor).
---
--- Access strategy (in order):
---   1. Equality comparison with known class refs from the `classes` global.
---   2. Pattern extraction from tostring ("Desc_XXX_C" anywhere).
---   3. nil  (caller should fall back to network propagation or type inference).
---
--- DOES NOT access .name / .fluidColor / .form on the returned reference.
--- Those properties are not available on Class<ItemType> / Trace<ItemType>
--- wrappers in the current FicsIt-Networks runtime and cause log warnings.
---
--- @return table|nil  { name, key, color, form }
local function readFluidType(proxy, method)
  local ok, fluidRef = pcall(function() return proxy[method](proxy) end)
  if not ok or not fluidRef then return nil end

  ensureClassRefs()

  -- Strategy 1: equality comparison with known class references.
  for _, entry in ipairs(resolvedClassList) do
    local eqOk, eq = pcall(function() return fluidRef == entry.ref end)
    if eqOk and eq then
      return makeFluidType(entry.key)
    end
  end

  -- Strategy 2: extract UE descriptor pattern from tostring.
  -- Handles formats like "Desc_Water_C", "Class<Desc_Water_C>", etc.
  local tsOk, ts = pcall(tostring, fluidRef)
  if tsOk and ts then
    local descKey = ts:match("Desc_(.+)_C")
    if descKey then
      return makeFluidType(descKey)
    end
  end

  -- One-time debug log per unique tostring value for diagnosis.
  local tsStr = tostring(ts or "nil")
  if not fluidDebugLogged[tsStr] then
    fluidDebugLogged[tsStr] = true
    print("[FLUID_SCN] WARN: Unknown fluid via " .. method
      .. " tostring='" .. tsStr .. "' (" .. #resolvedClassList .. " refs loaded)")
  end

  return nil
end

--- Read pipe connections for an element and gather flow/network data.
-- @param proxy component proxy
-- @return table - { connections = {}, networkIDs = {}, fluidType = nil }
local function readPipeConnections(proxy)
  local result = { connections = {}, networkIDs = {}, fluidType = nil }
  local netSeen = {}

  local ok, conns = pcall(function() return proxy:getPipeConnectors() end)
  if not ok or not conns then return result end

  for _, conn in ipairs(conns) do
    local connData = {
      isConnected = safeBool(conn, "isConnected"),
      fluidBoxContent = safeNum(conn, "fluidBoxContent"),
      fluidBoxHeight = safeNum(conn, "fluidBoxHeight"),
      fluidBoxFlowThrough = safeNum(conn, "fluidBoxFlowThrough"),
      fluidBoxFlowFill = safeNum(conn, "fluidBoxFlowFill"),
      fluidBoxFlowDrain = safeNum(conn, "fluidBoxFlowDrain"),
      fluidBoxFlowLimit = safeNum(conn, "fluidBoxFlowLimit"),
      networkID = safeNum(conn, "networkID"),
    }

    -- Track unique network IDs
    local nid = connData.networkID
    if nid ~= 0 and not netSeen[nid] then
      netSeen[nid] = true
      table.insert(result.networkIDs, nid)
    end

    -- Try to get fluid type from connection
    if not result.fluidType then
      result.fluidType = readFluidType(conn, "getFluidDescriptor")
    end

    table.insert(result.connections, connData)
  end

  return result
end

-- Last scan result cache (for remote state queries)
local lastScanResultCache = nil

--- Perform a full scan of all discovered elements.
-- @return table - complete scan result (elements, groups, networks, stats)
function FluidScanner.scan()
  if #elements == 0 then return nil end

  local scanResult = {
    elements = {},
    groups = {},
    networks = {},
    groupOrder = {},
    globalStats = {
      totalElements = 0,
      pumpCount = 0,
      reservoirCount = 0,
      valveCount = 0,
      extractorCount = 0,
      networkCount = 0,
      groupCount = 0,
      defaultGroupCount = 0,
      defaultGroupName = config.defaultGroup,
    },
    timestamp = computer.millis(),
  }

  local allNetworkIDs = {}
  local groupData = {}

  for _, elem in ipairs(elements) do
    local proxy = elem.proxy

    -- Read pipe connections (flow data, network IDs, fluid type)
    local pipeData = readPipeConnections(proxy)

    -- Build the element scan record
    local record = {
      id = elem.id,
      nick = elem.nick,
      groupName = elem.groupName,
      elementName = elem.elementName,
      elementType = elem.elementType,
      controllable = elem.controllable,
      pipeConnections = pipeData.connections,
      networkIDs = pipeData.networkIDs,
      fluidType = nil,
      -- Location for topology placement
      location = nil,
    }

    -- Read location
    local locOk, loc = pcall(function() return proxy.location end)
    if locOk and loc then
      record.location = { x = loc.x or 0, y = loc.y or 0, z = loc.z or 0 }
    end

    -- Element-type-specific properties
    if elem.elementType == "pump" then
      record.flow = safeNum(proxy, "flow")
      record.flowLimit = safeNum(proxy, "flowLimit")
      record.userFlowLimit = safeNum(proxy, "userFlowLimit")
      record.defaultFlowLimit = safeNum(proxy, "defaultFlowLimit")
      record.maxHeadlift = safeNum(proxy, "maxHeadlift")
      record.designedHeadlift = safeNum(proxy, "designedHeadlift")
      record.indicatorHeadlift = safeNum(proxy, "indicatorHeadlift")
      -- Pump active if userFlowLimit != 0
      record.active = (record.userFlowLimit ~= 0)
      scanResult.globalStats.pumpCount = scanResult.globalStats.pumpCount + 1

    elseif elem.elementType == "reservoir" then
      record.fluidContent = safeNum(proxy, "fluidContent")
      record.maxFluidContent = safeNum(proxy, "maxFluidContent")
      record.fillPercent = record.maxFluidContent > 0
        and math.min(record.fluidContent / record.maxFluidContent * 100, 100) or 0
      record.flowFill = safeNum(proxy, "flowFill")
      record.flowDrain = safeNum(proxy, "flowDrain")
      record.flowLimit = safeNum(proxy, "flowLimit")
      record.standby = safeBool(proxy, "standby")
      record.potential = safeNum(proxy, "potential")
      record.productivity = safeNum(proxy, "productivity")
      record.active = not record.standby
      -- Try to get fluid type from reservoir directly
      record.fluidType = readFluidType(proxy, "getFluidType")
      scanResult.globalStats.reservoirCount = scanResult.globalStats.reservoirCount + 1

    elseif elem.elementType == "valve" then
      -- Valve: try pump-like props (might work on FGBuildablePipelineAttachment)
      local flowOk, flow = pcall(function() return proxy.flow end)
      record.flow = (flowOk and type(flow) == "number") and flow or nil
      local uflOk, ufl = pcall(function() return proxy.userFlowLimit end)
      record.userFlowLimit = (uflOk and type(ufl) == "number") and ufl or nil
      local flOk, fl = pcall(function() return proxy.flowLimit end)
      record.flowLimit = (flOk and type(fl) == "number") and fl or nil
      -- Active = userFlowLimit nil (unknown) or not 0
      if record.userFlowLimit ~= nil then
        record.active = (record.userFlowLimit ~= 0)
      else
        record.active = true -- assume open if we can't read
      end
      scanResult.globalStats.valveCount = scanResult.globalStats.valveCount + 1

    elseif elem.elementType == "extractor" then
      record.standby = safeBool(proxy, "standby")
      record.potential = safeNum(proxy, "potential")
      record.productivity = safeNum(proxy, "productivity")
      record.progress = safeNum(proxy, "progress")
      record.cycleTime = safeNum(proxy, "cycleTime")
      record.active = not record.standby
      -- Infer fluid type from extractor class: Water Pumps always produce Water
      if elem.category and elem.category:find("WaterPump") then
        record.fluidType = makeFluidType("Water")
      end
      scanResult.globalStats.extractorCount = scanResult.globalStats.extractorCount + 1
    end

    -- Fall back to pipe connection fluid type if element didn't provide one
    if not record.fluidType then
      record.fluidType = pipeData.fluidType
    end

    -- Collect network IDs for global network map
    for _, nid in ipairs(record.networkIDs) do
      if not allNetworkIDs[nid] then
        allNetworkIDs[nid] = { fluidType = record.fluidType, elements = {} }
      end
      table.insert(allNetworkIDs[nid].elements, record)
      if record.fluidType and not allNetworkIDs[nid].fluidType then
        allNetworkIDs[nid].fluidType = record.fluidType
      end
    end

    -- Group accumulation
    if not groupData[elem.groupName] then
      groupData[elem.groupName] = {
        name = elem.groupName,
        elements = {},
        elementCount = 0,
        pumpCount = 0,
        reservoirCount = 0,
        valveCount = 0,
        extractorCount = 0,
        totalCapacity = 0,
        totalContent = 0,
        avgFillPercent = 0,
        totalFlowIn = 0,
        totalFlowOut = 0,
        fluidType = nil,
        activeCount = 0,
      }
    end
    local gd = groupData[elem.groupName]
    table.insert(gd.elements, record)
    gd.elementCount = gd.elementCount + 1

    if elem.elementType == "pump" then gd.pumpCount = gd.pumpCount + 1 end
    if elem.elementType == "reservoir" then gd.reservoirCount = gd.reservoirCount + 1 end
    if elem.elementType == "valve" then gd.valveCount = gd.valveCount + 1 end
    if elem.elementType == "extractor" then gd.extractorCount = gd.extractorCount + 1 end

    if record.active then gd.activeCount = gd.activeCount + 1 end
    if not gd.fluidType and record.fluidType then gd.fluidType = record.fluidType end

    -- Accumulate reservoir fill data for group averages
    if elem.elementType == "reservoir" then
      gd.totalCapacity = gd.totalCapacity + (record.maxFluidContent or 0)
      gd.totalContent = gd.totalContent + (record.fluidContent or 0)
    end

    -- Accumulate flow across all pipe connections
    for _, conn in ipairs(pipeData.connections) do
      gd.totalFlowIn = gd.totalFlowIn + conn.fluidBoxFlowFill
      gd.totalFlowOut = gd.totalFlowOut + conn.fluidBoxFlowDrain
    end

    table.insert(scanResult.elements, record)
    scanResult.globalStats.totalElements = scanResult.globalStats.totalElements + 1
  end

  -- Second pass: propagate fluid type from networks back to elements.
  -- If an element has no fluid type but belongs to a network that does,
  -- it inherits the network's fluid type.
  for _, record in ipairs(scanResult.elements) do
    if not record.fluidType then
      for _, nid in ipairs(record.networkIDs or {}) do
        local net = allNetworkIDs[nid]
        if net and net.fluidType then
          record.fluidType = net.fluidType
          break
        end
      end
    end
  end

  -- Finalize groups
  for _, gName in ipairs(groupOrder) do
    local gd = groupData[gName]
    if gd then
      if gd.totalCapacity > 0 then
        gd.avgFillPercent = gd.totalContent / gd.totalCapacity * 100
      end
      scanResult.groups[gName] = gd
      table.insert(scanResult.groupOrder, gName)
    end
  end

  -- Default group count
  local defaultGd = groupData[config.defaultGroup]
  if defaultGd then
    scanResult.globalStats.defaultGroupCount = defaultGd.elementCount
  end

  -- Build network map
  local netCount = 0
  for nid, netData in pairs(allNetworkIDs) do
    -- Sort elements within network by location X for topology ordering
    table.sort(netData.elements, function(a, b)
      local ax = a.location and a.location.x or 0
      local bx = b.location and b.location.x or 0
      return ax < bx
    end)
    scanResult.networks[nid] = netData
    netCount = netCount + 1
  end
  scanResult.globalStats.networkCount = netCount
  scanResult.globalStats.groupCount = #scanResult.groupOrder

  lastScanResultCache = scanResult
  return scanResult
end

-- ============================================================================
-- Data export helpers
-- ============================================================================

--- Build an overview payload for network broadcast.
-- @param scanResult table
-- @return table
function FluidScanner.buildOverview(scanResult)
  if not scanResult then return {} end
  local overview = {
    stats = scanResult.globalStats,
    groups = {},
    timestamp = scanResult.timestamp,
  }
  for _, gName in ipairs(scanResult.groupOrder) do
    local g = scanResult.groups[gName]
    if g then
      table.insert(overview.groups, {
        name = g.name,
        elementCount = g.elementCount,
        pumpCount = g.pumpCount,
        reservoirCount = g.reservoirCount,
        valveCount = g.valveCount,
        extractorCount = g.extractorCount,
        avgFillPercent = g.avgFillPercent,
        totalFlowIn = g.totalFlowIn,
        totalFlowOut = g.totalFlowOut,
        activeCount = g.activeCount,
        fluidType = g.fluidType and g.fluidType.name or nil,
      })
    end
  end
  return overview
end

--- Build a detail payload for network broadcast.
-- @param scanResult table
-- @return table
function FluidScanner.buildDetail(scanResult)
  if not scanResult then return {} end
  local detail = {
    elements = {},
    timestamp = scanResult.timestamp,
  }
  for _, elem in ipairs(scanResult.elements) do
    table.insert(detail.elements, {
      id = elem.id,
      nick = elem.nick,
      groupName = elem.groupName,
      elementName = elem.elementName,
      elementType = elem.elementType,
      active = elem.active,
      controllable = elem.controllable,
      fluidType = elem.fluidType and elem.fluidType.name or nil,
      fillPercent = elem.fillPercent,
      flow = elem.flow,
      flowLimit = elem.flowLimit,
      userFlowLimit = elem.userFlowLimit,
      flowFill = elem.flowFill,
      flowDrain = elem.flowDrain,
      productivity = elem.productivity,
      networkIDs = elem.networkIDs,
    })
  end
  return detail
end

--- Build a controllable-elements payload for centralized management.
-- Only includes elements that can be toggled remotely (controllable=true).
-- This allows a central orchestrator to know which elements it can command.
-- @param scanResult table
-- @return table
function FluidScanner.buildControllables(scanResult)
  if not scanResult then return {} end
  local result = {
    controllables = {},
    timestamp = scanResult.timestamp,
  }
  for _, elem in ipairs(scanResult.elements) do
    if elem.controllable then
      table.insert(result.controllables, {
        id = elem.id,
        nick = elem.nick,
        groupName = elem.groupName,
        elementName = elem.elementName,
        elementType = elem.elementType,
        active = elem.active,
        fluidType = elem.fluidType and elem.fluidType.name or nil,
        -- Context data for rule evaluation
        fillPercent = elem.fillPercent,
        flow = elem.flow,
        flowLimit = elem.flowLimit,
        userFlowLimit = elem.userFlowLimit,
        flowFill = elem.flowFill,
        flowDrain = elem.flowDrain,
        productivity = elem.productivity,
        networkIDs = elem.networkIDs,
      })
    end
  end
  return result
end

--- Get raw element list (for controller/indicator pairing).
-- @return table
function FluidScanner.getElements()
  return elements
end

--- Get group order.
-- @return table
function FluidScanner.getGroupOrder()
  return groupOrder
end

--- Get the last scan result.
-- @return table|nil
function FluidScanner.getLastScanResult()
  return lastScanResultCache
end

return FluidScanner