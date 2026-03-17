-- modules/container_scanner.lua
-- Scans container inventories and groups them by network nick convention.
--
-- Containers are identified by their network nick using a separator convention:
--   nick = "GroupName:ContainerName"
-- Groups are automatically derived from the nick prefix.
-- Containers without the separator in their nick fall into the default group.
--
-- Discovery is done by the feature file which passes resolved proxies.
-- This module handles nick parsing, inventory scanning, and aggregation.

local ContainerScanner = {}

-- Configuration
local config = {
  separator = ":",
  defaultGroup = "default",
  groupFilter = nil, -- nil = all groups, or array of allowed group names
}

-- Cached container references after discovery
-- { proxy, id, nick, groupName, containerName }
local containers = {}

-- Group ordering (array of group names, in discovery or config order)
local groupOrder = {}

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the scanner with configuration options.
-- @param options table - { separator, defaultGroup, groupFilter }
function ContainerScanner.init(options)
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
  print("[SCANNER] Initialized (separator: '" .. config.separator .. "')")
end

-- ============================================================================
-- Discovery
-- ============================================================================

--- Parse a nick into group name and container name.
-- @param nick string - full nick from network component
-- @return string groupName, string containerName
local function parseNick(nick)
  local sep = config.separator
  local sepPos = nick:find(sep, 1, true)
  if sepPos and sepPos > 1 and sepPos < #nick then
    return nick:sub(1, sepPos - 1), nick:sub(sepPos + #sep)
  end
  return config.defaultGroup, nick
end

--- Discover containers from an array of pre-resolved proxies.
-- The feature file is responsible for finding the proxies (via REGISTRY
-- or component.findComponent). This method filters by nick convention
-- and inventory presence, then groups the results.
-- @param proxies table - array of component proxies to evaluate
-- @return number - count of containers retained
function ContainerScanner.discover(proxies)
  containers = {}
  groupOrder = {}
  local groupSeen = {}

  if not proxies or #proxies == 0 then
    print("[SCANNER] No proxies provided for discovery")
    return 0
  end

  print("[SCANNER] Evaluating " .. #proxies .. " candidates...")

  for _, proxy in ipairs(proxies) do
    local nickOk, nick = pcall(function() return proxy.nick end)
    if nickOk and nick and nick ~= "" then
      -- Only include components with inventories (= actual containers)
      local invOk, inventories = pcall(proxy.getInventories, proxy)
      if invOk and inventories and #inventories > 0 then
        local groupName, containerName = parseNick(nick)

        -- Apply group filter if configured
        local included = true
        if config.groupFilter then
          included = false
          for _, allowed in ipairs(config.groupFilter) do
            if allowed == groupName then
              included = true
              break
            end
          end
        end

        if included then
          local idOk, id = pcall(function() return proxy.id end)
          table.insert(containers, {
            proxy = proxy,
            id = idOk and id or "unknown",
            nick = nick,
            groupName = groupName,
            containerName = containerName,
          })
          if not groupSeen[groupName] then
            groupSeen[groupName] = true
            table.insert(groupOrder, groupName)
          end
        end
      end
    end
  end

  -- Sort group order: use groupFilter order if configured, otherwise alphabetical
  if config.groupFilter then
    groupOrder = {}
    for _, name in ipairs(config.groupFilter) do
      if groupSeen[name] then
        table.insert(groupOrder, name)
      end
    end
  else
    table.sort(groupOrder)
  end

  print("[SCANNER] Discovered " .. #containers .. " containers in " .. #groupOrder .. " groups")
  return #containers
end

--- Get the list of discovered containers.
-- @return table - array of container descriptors
function ContainerScanner.getContainers()
  return containers
end

--- Get the ordered list of group names.
-- @return table - array of group name strings
function ContainerScanner.getGroupOrder()
  return groupOrder
end

--- Check whether a container is still reachable on the network.
-- @param container table - a container descriptor from discovery
-- @return boolean
function ContainerScanner.isReachable(container)
  local ok, nick = pcall(function() return container.proxy.nick end)
  return ok and nick ~= nil
end

-- ============================================================================
-- Inventory scanning
-- ============================================================================

--- Compute fill data for a single Inventory.
-- @param inventory Trace<Inventory>
-- @return table { fillPercent, itemCount, capacity, slotsUsed, totalSlots, items }
local function getInventoryFill(inventory)
  local totalSlots = inventory.size or 0
  if totalSlots == 0 then
    return { fillPercent = 0, itemCount = 0, capacity = 0, slotsUsed = 0, totalSlots = 0, items = {} }
  end

  local slotsUsed = 0
  local totalCount = 0
  local totalMaxUsedSlots = 0
  local itemCounts = {}

  for slot = 0, totalSlots - 1 do
    local ok, stack = pcall(inventory.getStack, inventory, slot)
    if ok and stack and stack.count > 0 then
      slotsUsed = slotsUsed + 1
      totalCount = totalCount + stack.count

      local maxOk, maxSize = pcall(function() return stack.item.type.max end)
      if maxOk and maxSize and maxSize > 0 then
        totalMaxUsedSlots = totalMaxUsedSlots + maxSize
      else
        totalMaxUsedSlots = totalMaxUsedSlots + stack.count
      end

      local nameOk, itemName = pcall(function() return stack.item.type.name end)
      if nameOk and itemName then
        itemCounts[itemName] = (itemCounts[itemName] or 0) + stack.count
      end
    end
  end

  -- Build sorted item breakdown
  local items = {}
  for name, count in pairs(itemCounts) do
    table.insert(items, {
      name = name,
      count = count,
      percent = totalCount > 0 and math.floor((count / totalCount) * 100 + 0.5) or 0,
    })
  end
  table.sort(items, function(a, b) return a.count > b.count end)

  -- Fill percent is slot-based (consistent regardless of item types)
  local fillPercent = totalSlots > 0 and (slotsUsed / totalSlots) * 100 or 0

  -- Item-level capacity (extrapolated from used slots, for network payloads)
  local itemCapacity = 0
  if slotsUsed > 0 then
    local avgMaxPerSlot = totalMaxUsedSlots / slotsUsed
    itemCapacity = math.floor(avgMaxPerSlot * totalSlots)
  end

  return {
    fillPercent = math.floor(fillPercent * 10) / 10,
    itemCount = totalCount,
    capacity = totalSlots,
    itemCapacity = itemCapacity,
    slotsUsed = slotsUsed,
    totalSlots = totalSlots,
    items = items,
  }
end

--- Scan all discovered containers and return structured results.
-- @return table - full scan result with groups, containers, inventories, global stats
function ContainerScanner.scan()
  local result = {
    timestamp = computer.millis(),
    groups = {},
    groupOrder = groupOrder,
    globalStats = {
      totalGroups = 0,
      totalContainers = 0,
      totalItems = 0,
      totalCapacity = 0,
      avgFill = 0,
    },
  }

  -- Build group map from containers
  local groupMap = {}
  for _, container in ipairs(containers) do
    if not groupMap[container.groupName] then
      groupMap[container.groupName] = {
        name = container.groupName,
        containers = {},
        avgFill = 0,
        totalItems = 0,
        totalCapacity = 0,
        itemCapacity = 0,
        slotsUsed = 0,
        totalSlots = 0,
        containerCount = 0,
        topItems = {},
      }
    end

    -- Scan all inventories of this container
    local invData = {}
    local cTotalItems = 0
    local cTotalCapacity = 0
    local cItemCapacity = 0
    local cSlotsUsed = 0
    local cTotalSlots = 0
    local cFillSum = 0
    local cFillCount = 0
    local cItemCounts = {}

    local invOk, inventories = pcall(container.proxy.getInventories, container.proxy)
    if invOk and inventories then
      -- Find the main storage inventory (largest by slot count).
      -- Satisfactory containers expose I/O buffer inventories (typically 3 slots)
      -- alongside the main storage; we only want the primary one.
      local mainInv = nil
      local mainSize = 0
      for _, inventory in ipairs(inventories) do
        local sz = inventory.size or 0
        if sz > mainSize then
          mainSize = sz
          mainInv = inventory
        end
      end

      if mainInv then
        local fill = getInventoryFill(mainInv)
        fill.index = 1
        table.insert(invData, fill)

        cTotalItems = cTotalItems + fill.itemCount
        cTotalCapacity = cTotalCapacity + fill.capacity
        cItemCapacity = cItemCapacity + fill.itemCapacity
        cSlotsUsed = cSlotsUsed + fill.slotsUsed
        cTotalSlots = cTotalSlots + fill.totalSlots
        cFillSum = cFillSum + fill.fillPercent
        cFillCount = cFillCount + 1

        -- Merge items for container-level aggregation
        for _, item in ipairs(fill.items) do
          cItemCounts[item.name] = (cItemCounts[item.name] or 0) + item.count
        end
      end
    end

    -- Build container-level item list
    local containerItems = {}
    for name, count in pairs(cItemCounts) do
      table.insert(containerItems, { name = name, count = count })
    end
    table.sort(containerItems, function(a, b) return a.count > b.count end)

    local containerResult = {
      id = container.id,
      nick = container.nick,
      name = container.containerName,
      groupName = container.groupName,
      inventories = invData,
      totalFill = cFillCount > 0 and math.floor((cFillSum / cFillCount) * 10) / 10 or 0,
      totalItems = cTotalItems,
      totalCapacity = cTotalCapacity,
      itemCapacity = cItemCapacity,
      slotsUsed = cSlotsUsed,
      totalSlots = cTotalSlots,
      topItems = containerItems,
    }

    table.insert(groupMap[container.groupName].containers, containerResult)
  end

  -- Sort containers alphanumerically within each group
  for _, group in pairs(groupMap) do
    table.sort(group.containers, function(a, b) return a.name < b.name end)
  end

  -- Aggregate per group and build global stats
  local globalTotalItems = 0
  local globalTotalCapacity = 0
  local globalItemCapacity = 0
  local globalSlotsUsed = 0
  local globalTotalSlots = 0
  local globalFillSum = 0
  local globalContainerCount = 0

  for _, groupName in ipairs(groupOrder) do
    local group = groupMap[groupName]
    if group then
      local groupFillSum = 0
      local groupItemCounts = {}

      for _, c in ipairs(group.containers) do
        group.totalItems = group.totalItems + c.totalItems
        group.totalCapacity = group.totalCapacity + c.totalCapacity
        group.itemCapacity = group.itemCapacity + c.itemCapacity
        group.slotsUsed = group.slotsUsed + c.slotsUsed
        group.totalSlots = group.totalSlots + c.totalSlots
        groupFillSum = groupFillSum + c.totalFill

        for _, item in ipairs(c.topItems) do
          groupItemCounts[item.name] = (groupItemCounts[item.name] or 0) + item.count
        end
      end

      group.containerCount = #group.containers
      group.avgFill = group.containerCount > 0
        and math.floor((groupFillSum / group.containerCount) * 10) / 10
        or 0

      -- Build group top items (limit to top 5)
      local groupItems = {}
      for name, count in pairs(groupItemCounts) do
        table.insert(groupItems, { name = name, count = count })
      end
      table.sort(groupItems, function(a, b) return a.count > b.count end)
      group.topItems = {}
      for i = 1, math.min(5, #groupItems) do
        table.insert(group.topItems, groupItems[i])
      end

      result.groups[groupName] = group

      globalTotalItems = globalTotalItems + group.totalItems
      globalTotalCapacity = globalTotalCapacity + group.totalCapacity
      globalItemCapacity = globalItemCapacity + group.itemCapacity
      globalSlotsUsed = globalSlotsUsed + group.slotsUsed
      globalTotalSlots = globalTotalSlots + group.totalSlots
      globalFillSum = globalFillSum + groupFillSum
      globalContainerCount = globalContainerCount + group.containerCount
    end
  end

  result.globalStats = {
    totalGroups = #groupOrder,
    totalContainers = globalContainerCount,
    totalItems = globalTotalItems,
    totalCapacity = globalTotalCapacity,
    itemCapacity = globalItemCapacity,
    slotsUsed = globalSlotsUsed,
    totalSlots = globalTotalSlots,
    avgFill = globalContainerCount > 0
      and math.floor((globalFillSum / globalContainerCount) * 10) / 10
      or 0,
  }

  return result
end

-- ============================================================================
-- Network payloads (pre-aggregated for broadcast)
-- ============================================================================

--- Build a lightweight overview payload for network broadcast.
-- Contains group-level summaries only (no per-container detail).
-- @param scanResult table - result from ContainerScanner.scan()
-- @return table - serializable overview payload
function ContainerScanner.buildOverview(scanResult)
  local groups = {}
  for _, groupName in ipairs(scanResult.groupOrder) do
    local group = scanResult.groups[groupName]
    if group then
      table.insert(groups, {
        name = group.name,
        count = group.containerCount,
        avgFill = group.avgFill,
        totalItems = group.totalItems,
        totalCapacity = group.totalCapacity,
        itemCapacity = group.itemCapacity,
        slotsUsed = group.slotsUsed,
        totalSlots = group.totalSlots,
        topItems = group.topItems,
      })
    end
  end

  return {
    type = "container_overview",
    timestamp = scanResult.timestamp,
    totalContainers = scanResult.globalStats.totalContainers,
    totalItems = scanResult.globalStats.totalItems,
    totalCapacity = scanResult.globalStats.totalCapacity,
    itemCapacity = scanResult.globalStats.itemCapacity,
    slotsUsed = scanResult.globalStats.slotsUsed,
    totalSlots = scanResult.globalStats.totalSlots,
    avgFill = scanResult.globalStats.avgFill,
    groups = groups,
  }
end

--- Build a detailed payload for network broadcast.
-- Contains per-container breakdown within each group.
-- @param scanResult table - result from ContainerScanner.scan()
-- @return table - serializable detail payload
function ContainerScanner.buildDetail(scanResult)
  local groups = {}
  for _, groupName in ipairs(scanResult.groupOrder) do
    local group = scanResult.groups[groupName]
    if group then
      local containerList = {}
      for _, c in ipairs(group.containers) do
        -- Include top 3 items per container
        local items = {}
        for i = 1, math.min(3, #c.topItems) do
          table.insert(items, { name = c.topItems[i].name, count = c.topItems[i].count })
        end
        table.insert(containerList, {
          name = c.name,
          fill = c.totalFill,
          items = c.totalItems,
          capacity = c.totalCapacity,
          itemCapacity = c.itemCapacity,
          slotsUsed = c.slotsUsed,
          totalSlots = c.totalSlots,
          topItems = items,
        })
      end
      table.insert(groups, {
        name = group.name,
        containers = containerList,
      })
    end
  end

  return {
    type = "container_detail",
    timestamp = scanResult.timestamp,
    groups = groups,
  }
end

return ContainerScanner