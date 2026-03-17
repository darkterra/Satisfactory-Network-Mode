-- lib/component_registry.lua
-- Auto-discovers all PCI devices and stores them by type.
-- Provides a generic registry where features can register and discover network components.
-- Must be loaded after EEPROM sets GPU/SCREEN globals.

local Registry = {
  pci = {
    gpuT1 = {},        -- GPU T1 PCI devices (excluding EEPROM reserved)
    gpuT2 = {},        -- GPU T2 PCI devices (FINComputerGPUT2)
    screens = {},      -- Screen Driver PCI devices (excluding EEPROM reserved)
    networkCards = {},  -- NetworkCard PCI devices
    internetCards = {}, -- FINInternetCard PCI devices
  },
  network = {},        -- dynamically populated by features via registerNetworkCategory()
  _networkMap = {},    -- { categoryName = className } registered by features
}

--- Discover all PCI devices beyond what EEPROM reserved.
local function discoverPCI()
  -- GPU T2 devices
  local allGpuT2 = computer.getPCIDevices(classes.FINComputerGPUT2) or {}
  for _, gpu in ipairs(allGpuT2) do
    if gpu ~= GPU then
      table.insert(Registry.pci.gpuT2, gpu)
    end
  end
  print("[REGISTRY] PCI GPU T2 available (excl. EEPROM): " .. #Registry.pci.gpuT2)

  -- GPU T1 devices
  local allGpuT1 = computer.getPCIDevices(classes.GPUT1) or {}
  for _, gpu in ipairs(allGpuT1) do
    if gpu ~= GPU then
      -- Exclude T2 devices that may also appear in T1 listing
      local isT2 = false
      for _, gpuT2 in ipairs(Registry.pci.gpuT2) do
        if gpuT2 == gpu then
          isT2 = true
          break
        end
      end
      if not isT2 then
        table.insert(Registry.pci.gpuT1, gpu)
      end
    end
  end
  print("[REGISTRY] PCI GPU T1 available (excl. EEPROM): " .. #Registry.pci.gpuT1)

  -- Screen Driver devices
  local allScreens = computer.getPCIDevices(classes.FINComputerScreen) or {}
  for _, screen in ipairs(allScreens) do
    if screen ~= SCREEN then
      table.insert(Registry.pci.screens, screen)
    end
  end
  print("[REGISTRY] PCI Screens available (excl. EEPROM): " .. #Registry.pci.screens)

  -- NetworkCard devices
  -- If EEPROM already initialized a NetworkCard, place it first and avoid duplicates
  if NETWORK_CARD then
    table.insert(Registry.pci.networkCards, NETWORK_CARD)
    local allNetCards = computer.getPCIDevices(classes.NetworkCard) or {}
    for _, netCard in ipairs(allNetCards) do
      if netCard ~= NETWORK_CARD then
        table.insert(Registry.pci.networkCards, netCard)
      end
    end
    print("[REGISTRY] PCI NetworkCards: " .. #Registry.pci.networkCards .. " (primary from EEPROM)")
  else
    local allNetCards = computer.getPCIDevices(classes.NetworkCard) or {}
    for _, netCard in ipairs(allNetCards) do
      table.insert(Registry.pci.networkCards, netCard)
    end
    print("[REGISTRY] PCI NetworkCards: " .. #Registry.pci.networkCards)
  end

  -- InternetCard devices (FINInternetCard)
  local allInternetCards = computer.getPCIDevices(classes.FINInternetCard) or {}
  for _, iCard in ipairs(allInternetCards) do
    table.insert(Registry.pci.internetCards, iCard)
  end
  print("[REGISTRY] PCI InternetCards: " .. #Registry.pci.internetCards)
end

--- Safely discover network components of a given class name.
-- @param className string - key in classes table
-- @return table - array of component proxies (may be empty)
local function findNetworkComponents(className)
  local classRef = classes[className]
  if not classRef then
    print("[REGISTRY] Unknown class: " .. className)
    return {}
  end
  local ids = component.findComponent(classRef)
  if not ids or #ids == 0 then
    return {}
  end
  local proxies = component.proxy(ids)
  if type(proxies) ~= "table" then
    return { proxies }
  end
  return proxies
end

--- Register a network component category for discovery.
-- Features call this before discoverNetwork() runs.
-- @param categoryName string - unique key (e.g. "stations", "speakers")
-- @param className string - FicsIt-Networks class name (e.g. "RailroadStation")
function Registry.registerNetworkCategory(categoryName, className)
  Registry._networkMap[categoryName] = className
  if not Registry.network[categoryName] then
    Registry.network[categoryName] = {}
  end
end

--- Discover all registered network component categories.
function Registry.discoverNetwork()
  for categoryName, className in pairs(Registry._networkMap) do
    local success, result = pcall(findNetworkComponents, className)
    if success then
      Registry.network[categoryName] = result
      if #result > 0 then
        print("[REGISTRY] Network " .. className .. " (" .. categoryName .. "): " .. #result .. " found")
      end
    else
      print("[REGISTRY] Error discovering " .. className .. ": " .. tostring(result))
      Registry.network[categoryName] = {}
    end
  end
end

--- Run PCI discovery only (called early by main.lua).
function Registry.discoverPCI()
  print("[REGISTRY] PCI discovery...")
  discoverPCI()
end

--- Get all components for a registered network category.
-- @param categoryName string
-- @return table - array of proxies (empty if not found)
function Registry.getCategory(categoryName)
  return Registry.network[categoryName] or {}
end

--- Get the best available GPU + screen pair for a feature (excluding EEPROM reserved).
-- Prefers GPU T2 over T1. Requires BOTH a spare GPU AND a spare screen.
-- @return gpu, screen, gpuType (or nil, nil, nil if either is missing)
function Registry.getAvailableDisplay()
  -- Prefer T2, fallback to T1
  local gpu = Registry.pci.gpuT2[1]
  local gpuType = "T2"
  if not gpu then
    gpu = Registry.pci.gpuT1[1]
    gpuType = "T1"
  end
  if not gpu then
    return nil, nil, nil
  end

  -- Prefer a spare PCI screen
  local screen = Registry.pci.screens[1]
  if screen then
    return gpu, screen, gpuType
  end

  -- Fallback to a network external screen (requires "screens" category to be registered)
  local networkScreens = Registry.network["screens"] or {}
  if #networkScreens > 0 then
    return gpu, networkScreens[1], gpuType
  end

  -- No screen available
  return nil, nil, nil
end

--- Get the first component in a network category (convenience).
-- @param categoryName string
-- @return proxy or nil
function Registry.getFirst(categoryName)
  local list = Registry.network[categoryName]
  if list and #list > 0 then
    return list[1]
  end
  return nil
end

return Registry