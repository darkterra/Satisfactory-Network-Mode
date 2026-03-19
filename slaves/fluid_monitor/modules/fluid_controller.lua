-- modules/fluid_controller.lua
--- Controls fluid network elements: toggle pumps, valves, extractors.
--
-- Control mechanisms:
--   Pump (PipelinePump):  userFlowLimit  (0 = off, -1 = no limit / on)
--   Extractor (Factory child): standby  (true = off, false = on)
--   Valve (FGBuildablePipelineAttachment): userFlowLimit if available
--
-- Note: Reservoirs (PipeReservoir) are passive tanks and NOT controllable.

local FluidController = {}

-- ============================================================================
-- Toggle helpers
-- ============================================================================

--- Toggle a pump's userFlowLimit between 0 (off) and -1 (on / no limit).
-- @param proxy component proxy
-- @return boolean newState (true = now active)
local function togglePump(proxy)
  local ok, current = pcall(function() return proxy.userFlowLimit end)
  if not ok then
    print("[FLUID_CTL] Cannot read pump userFlowLimit")
    return true
  end
  -- If userFlowLimit == 0, pump is off -> turn on (-1 = no user limit)
  -- If userFlowLimit != 0, pump is on -> turn off (0)
  local newVal = (current == 0) and -1 or 0
  local setOk, err = pcall(function() proxy.userFlowLimit = newVal end)
  if not setOk then
    print("[FLUID_CTL] Failed to set pump userFlowLimit: " .. tostring(err))
    return (current ~= 0)
  end
  local state = (newVal ~= 0)
  print("[FLUID_CTL] Pump toggled -> " .. (state and "ON" or "OFF"))
  return state
end

--- Toggle a Factory-based element's standby (reservoir, extractor).
-- @param proxy component proxy
-- @return boolean newState (true = now active)
local function toggleFactory(proxy)
  local ok, current = pcall(function() return proxy.standby end)
  if not ok then
    print("[FLUID_CTL] Cannot read standby state")
    return true
  end
  -- standby = true means machine is OFF, false means ON
  local newVal = not current
  local setOk, err = pcall(function() proxy.standby = newVal end)
  if not setOk then
    print("[FLUID_CTL] Failed to set standby: " .. tostring(err))
    return not current
  end
  local state = not newVal
  print("[FLUID_CTL] Factory toggled -> " .. (state and "ON" or "OFF"))
  return state
end

--- Toggle a valve's userFlowLimit (same mechanism as pump, graceful fail).
-- @param proxy component proxy
-- @return boolean newState (true = now active), boolean success
local function toggleValve(proxy)
  local ok, current = pcall(function() return proxy.userFlowLimit end)
  if not ok then
    print("[FLUID_CTL] Valve userFlowLimit not accessible")
    return true, false
  end
  local newVal = (current == 0) and -1 or 0
  local setOk, err = pcall(function() proxy.userFlowLimit = newVal end)
  if not setOk then
    print("[FLUID_CTL] Valve control failed: " .. tostring(err))
    return (current ~= 0), false
  end
  local state = (newVal ~= 0)
  print("[FLUID_CTL] Valve toggled -> " .. (state and "OPEN" or "CLOSED"))
  return state, true
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Toggle an element on/off based on its type.
-- @param element table - scan result element record
-- @return boolean newActive - new active state
function FluidController.toggle(element)
  if not element or not element.controllable then
    print("[FLUID_CTL] Element not controllable")
    return element and element.active or false
  end

  -- Find the live proxy from the original element list
  -- (scan result elements don't hold proxy directly -- the feature file
  --  must pass the proxy or we retrieve it from component.proxy)
  local proxy = element.proxy
  if not proxy then
    local ok, p = pcall(component.proxy, element.id)
    if ok and p then
      proxy = p
    else
      print("[FLUID_CTL] Cannot get proxy for " .. (element.id or "?"))
      return element.active or false
    end
  end

  if element.elementType == "pump" then
    return togglePump(proxy)
  elseif element.elementType == "extractor" then
    return toggleFactory(proxy)
  elseif element.elementType == "valve" then
    local state, success = toggleValve(proxy)
    return state
  end

  print("[FLUID_CTL] Unknown element type: " .. tostring(element.elementType))
  return element.active or false
end

--- Check if an element is currently active.
-- @param element table - scan result element record
-- @return boolean
function FluidController.isActive(element)
  if not element then return false end
  if element.elementType == "pump" or element.elementType == "valve" then
    local ufl = element.userFlowLimit
    if ufl ~= nil then return ufl ~= 0 end
    return true
  elseif element.elementType == "reservoir" or element.elementType == "extractor" then
    return not (element.standby or false)
  end
  return true
end

return FluidController