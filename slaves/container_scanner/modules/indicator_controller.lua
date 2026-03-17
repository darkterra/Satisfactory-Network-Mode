-- modules/indicator_controller.lua
-- Controls Modular Indicator Poles and Buzzer modules.
-- Pairs indicator poles with containers by matching their network nick.
--
-- Nick convention (same as container_scanner):
--   pole nick = "GroupName:ContainerName" → monitors the container with the same nick.
--
-- Indicator color scheme (3-level fill gauge):
--   Module 0 (bottom): lit if fill > 0%    → color by fill level
--   Module 1 (middle): lit if fill > 33%   → color by fill level
--   Module 2 (top):    lit if fill > 66%   → color by fill level
--   Extra modules follow the same proportional pattern.
--
-- Buzzer modules: beep when the paired container is empty (fill <= 0%).
--
-- API:
--   ModularIndicatorPole:getModule(index) → Actor (Indicator or Buzzer)
--   ModularPoleModule_Indicator:setColor(r, g, b, emissive)
--   ModularPoleModule_Buzzer:beep(), :stop(), .frequency, .volume

local IndicatorController = {}

-- Configuration
local config = {
  enabled = true,
  buzzerEnabled = true,
  buzzerFrequency = 800,
  buzzerVolume = 0.5,
  thresholdLow = 33,
  thresholdHigh = 66,
}

-- Indicator color definitions (RGBA + emissive)
local INDICATOR_COLORS = {
  off     = { 0.05, 0.05, 0.05, 0.2 },
  red     = { 1.0,  0.0,  0.0,  5.0 },
  yellow  = { 1.0,  0.8,  0.0,  5.0 },
  green   = { 0.0,  1.0,  0.0,  5.0 },
}

-- Discovered poles: array of { proxy, nick, indicators = {}, buzzers = {} }
local poles = {}

-- Pairing table: containerNick -> pole descriptor
local pairings = {}

-- Buzzer state tracking (avoid spamming beep/stop)
local buzzerStates = {} -- containerNick -> boolean (true = currently buzzing)

-- Empty container poles for blink effect (populated by update, consumed by blinkTick)
local emptyPoles = {}

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the indicator controller.
-- @param options table - { enabled, buzzerEnabled, buzzerFrequency, buzzerVolume,
--                          thresholdLow, thresholdHigh }
function IndicatorController.init(options)
  if options then
    if options.enabled ~= nil then config.enabled = options.enabled end
    if options.buzzerEnabled ~= nil then config.buzzerEnabled = options.buzzerEnabled end
    config.buzzerFrequency = options.buzzerFrequency or config.buzzerFrequency
    config.buzzerVolume = options.buzzerVolume or config.buzzerVolume
    config.thresholdLow = options.thresholdLow or config.thresholdLow
    config.thresholdHigh = options.thresholdHigh or config.thresholdHigh
  end
  print("[INDICATOR] Initialized (enabled: " .. tostring(config.enabled) .. ", buzzer: " .. tostring(config.buzzerEnabled) .. ")")
end

-- ============================================================================
-- Discovery
-- ============================================================================

--- Discover indicator poles on the network and classify their modules.
-- Uses the network category registered in the feature file.
-- @param poleProxies table - array of ModularIndicatorPole proxies from REGISTRY
-- @return number - count of poles found with at least one module
function IndicatorController.discover(poleProxies)
  poles = {}
  pairings = {}
  buzzerStates = {}

  if not poleProxies or #poleProxies == 0 then
    print("[INDICATOR] No indicator poles found")
    return 0
  end

  for _, proxy in ipairs(poleProxies) do
    local nickOk, nick = pcall(function() return proxy.nick end)
    if nickOk and nick and nick ~= "" then
      local poleData = {
        proxy = proxy,
        nick = nick,
        indicators = {},
        buzzers = {},
      }

      -- Walk through modules on the pole (index 0, 1, 2, ...)
      for moduleIdx = 0, 20 do  -- up to 20 modules (safety limit)
        local modOk, moduleProxy = pcall(proxy.getModule, proxy, moduleIdx)
        if not modOk or not moduleProxy then break end

        -- Classify module type
        local isIndicator = false
        local isBuzzer = false

        local indOk, indResult = pcall(moduleProxy.isA, moduleProxy, classes.ModularPoleModule_Indicator)
        if indOk and indResult then
          isIndicator = true
        end

        if not isIndicator then
          local buzOk, buzResult = pcall(moduleProxy.isA, moduleProxy, classes.ModularPoleModule_Buzzer)
          if buzOk and buzResult then
            isBuzzer = true
          end
        end

        if isIndicator then
          table.insert(poleData.indicators, moduleProxy)
        elseif isBuzzer then
          table.insert(poleData.buzzers, moduleProxy)
          -- Configure buzzer
          pcall(function()
            moduleProxy.frequency = config.buzzerFrequency
            moduleProxy.volume = config.buzzerVolume
          end)
        end
      end

      if #poleData.indicators > 0 or #poleData.buzzers > 0 then
        table.insert(poles, poleData)
        pairings[nick] = poleData
        print("[INDICATOR] Pole '" .. nick .. "': " .. #poleData.indicators .. " indicators, " .. #poleData.buzzers .. " buzzers")
      end
    end
  end

  print("[INDICATOR] Discovered " .. #poles .. " indicator poles")
  return #poles
end

-- ============================================================================
-- Update logic
-- ============================================================================

--- Determine the indicator color for a given fill percentage.
-- @param fillPercent number
-- @return table - { r, g, b, emissive }
local function getIndicatorColor(fillPercent)
  if fillPercent <= 0 then
    return INDICATOR_COLORS.red
  elseif fillPercent < config.thresholdLow then
    return INDICATOR_COLORS.red
  elseif fillPercent < config.thresholdHigh then
    return INDICATOR_COLORS.yellow
  else
    return INDICATOR_COLORS.green
  end
end

--- Update all indicator poles based on scan results.
-- Matches pole nicks to container nicks and sets indicators/buzzers accordingly.
-- @param scanResult table - from ContainerScanner.scan()
function IndicatorController.update(scanResult)
  if not config.enabled then return end

  -- Reset empty poles list (blinkTick uses this)
  emptyPoles = {}

  -- Build a lookup: containerNick -> container fill data
  local fillByNick = {}
  for _, groupName in ipairs(scanResult.groupOrder) do
    local group = scanResult.groups[groupName]
    if group then
      for _, container in ipairs(group.containers) do
        -- Get only the first part separated by space 
        fillByNick[container.nick:match("([^%s]+)")] = container.totalFill
      end
    end
  end

  -- Update each discovered pole
  for _, pole in ipairs(poles) do
    -- Get only the first part separated by space
    local poleNickBase = pole.nick:match("([^%s]+)")
    local fillPercent = fillByNick[poleNickBase]
    if fillPercent ~= nil then
      local numIndicators = #pole.indicators

      if fillPercent <= 0 then
        -- Empty container: all indicators off except bottom (blinked by blinkTick)
        table.insert(emptyPoles, pole)
        for i, indicator in ipairs(pole.indicators) do
          if i > 1 then
            pcall(indicator.setColor, indicator, table.unpack(INDICATOR_COLORS.off))
          end
          -- i == 1 (bottom) is left to blinkTick for blink effect
        end
      elseif numIndicators > 0 then
        -- Proportional gauge: color by fill level
        local color = getIndicatorColor(fillPercent)
        local litCount = math.max(1, math.ceil(numIndicators * fillPercent / 100))

        for i, indicator in ipairs(pole.indicators) do
          local setOk
          if i <= litCount then
            setOk = pcall(indicator.setColor, indicator, table.unpack(color))
          else
            setOk = pcall(indicator.setColor, indicator, table.unpack(INDICATOR_COLORS.off))
          end
          if not setOk then
            print("[INDICATOR] Failed to set color on '" .. poleNickBase .. "' module " .. i)
          end
        end
      end

      -- Buzzer control: beep when empty, stop when not empty
      if config.buzzerEnabled and #pole.buzzers > 0 then
        local shouldBuzz = fillPercent <= 0
        local currentlyBuzzing = buzzerStates[poleNickBase] or false

        if shouldBuzz and not currentlyBuzzing then
          for _, buzzer in ipairs(pole.buzzers) do
            pcall(buzzer.beep, buzzer)
          end
          buzzerStates[poleNickBase] = true
        elseif not shouldBuzz and currentlyBuzzing then
          for _, buzzer in ipairs(pole.buzzers) do
            pcall(buzzer.stop, buzzer)
          end
          buzzerStates[poleNickBase] = false
        end
      end
    else
      -- No container data for this pole → turn off all indicators
      for _, indicator in ipairs(pole.indicators) do
        pcall(indicator.setColor, indicator, table.unpack(INDICATOR_COLORS.off))
      end
      -- Stop any active buzzer
      if buzzerStates[poleNickBase] then
        for _, buzzer in ipairs(pole.buzzers) do
          pcall(buzzer.stop, buzzer)
        end
        buzzerStates[poleNickBase] = false
      end
    end
  end
end

--- Get the number of discovered poles.
-- @return number
function IndicatorController.getPoleCount()
  return #poles
end

--- Get paired pole info for a specific container nick.
-- @param nick string - container nick
-- @return table or nil - pole descriptor
function IndicatorController.getPairing(nick)
  return pairings[nick]
end

--- Get all discovered pole descriptors.
-- @return table - array of pole descriptors
function IndicatorController.getPoles()
  return poles
end

--- Toggle blink state for empty container indicators (bottom indicator).
-- Call at ~1-2 Hz for a visible blink effect.
function IndicatorController.blinkTick()
  if not config.enabled then return end
  local on = math.floor(computer.millis() / 1000) % 2 == 0
  for _, pole in ipairs(emptyPoles) do
    if #pole.indicators > 0 then
      local bottom = pole.indicators[1]
      if on then
        pcall(bottom.setColor, bottom, table.unpack(INDICATOR_COLORS.red))
      else
        pcall(bottom.setColor, bottom, table.unpack(INDICATOR_COLORS.off))
      end
    end
  end
end

--- Stop all buzzers and turn off all indicators (cleanup).
function IndicatorController.shutdown()
  for _, pole in ipairs(poles) do
    for _, indicator in ipairs(pole.indicators) do
      pcall(indicator.setColor, indicator, table.unpack(INDICATOR_COLORS.off))
    end
    for _, buzzer in ipairs(pole.buzzers) do
      pcall(buzzer.stop, buzzer)
    end
  end
  buzzerStates = {}
  print("[INDICATOR] All indicators and buzzers shut down")
end

return IndicatorController