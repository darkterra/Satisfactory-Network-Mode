-- modules/fluid_rules.lua
-- Automation rules engine for fluid network management.
--
-- Each rule defines:
--   - One or more TRIGGER elements (sensors): reservoir fill%, flow, rate%
--   - One or more TARGET elements (actuators): pump, valve, extractor
--   - A threshold condition with hysteresis (min/max)
--   - An action: enable or disable the target when condition is met
--
-- Hysteresis logic:
--   When the trigger value drops BELOW the min threshold → action fires (e.g. enable pump)
--   When the trigger value rises ABOVE the max threshold → reverse action (e.g. disable pump)
--   Between min and max → no change (deadband)
--
-- Rule structure:
-- {
--   id        = "rule_1",
--   name      = "Auto-fill Water",
--   enabled   = true,
--   triggers  = {
--     { elementId = "abc-123", property = "fillPercent", -- or "flow", "productivity"
--       min = 20, max = 80 },
--   },
--   targets   = {
--     { elementId = "def-456", actionBelow = "enable", actionAbove = "disable" },
--   },
--   logic     = "any",  -- "any" = any trigger fires, "all" = all triggers must agree
--   state     = "idle", -- "idle", "below", "above" (internal tracking)
-- }
--
-- Persistence: rules are saved to a JSON file on the computer's filesystem.

local FluidRules = {}

-- ============================================================================
-- State
-- ============================================================================

local rules = {}           -- { [id] = rule, ... }
local ruleOrder = {}       -- ordered list of rule IDs
local nextRuleNum = 1      -- for auto-generating IDs
local rulesFilePath = nil  -- set on init (filesystem path for persistence)
local controllerRef = nil  -- reference to FluidController for toggle actions

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the rules engine.
-- @param options table - { filePath, controller }
function FluidRules.init(options)
  options = options or {}
  rulesFilePath = options.filePath or nil
  controllerRef = options.controller or nil

  if rulesFilePath then
    FluidRules.load()
  end

  print("[FLUID_RULES] Initialized (" .. #ruleOrder .. " rules loaded)")
end

-- ============================================================================
-- Persistence (JSON-like serialization via Lua tables)
-- ============================================================================

--- Simple table-to-string serializer (for FicsIt-Networks filesystem).
local function serializeTable(t, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local pad1 = string.rep("  ", indent + 1)
  local parts = {}

  if #t > 0 then
    -- Array
    table.insert(parts, "{\n")
    for i, v in ipairs(t) do
      local comma = (i < #t) and ",\n" or "\n"
      if type(v) == "table" then
        table.insert(parts, pad1 .. serializeTable(v, indent + 1) .. comma)
      elseif type(v) == "string" then
        table.insert(parts, pad1 .. '"' .. v:gsub('"', '\\"') .. '"' .. comma)
      elseif type(v) == "boolean" then
        table.insert(parts, pad1 .. tostring(v) .. comma)
      else
        table.insert(parts, pad1 .. tostring(v) .. comma)
      end
    end
    table.insert(parts, pad .. "}")
  else
    -- Dictionary
    table.insert(parts, "{\n")
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for i, k in ipairs(keys) do
      local v = t[k]
      local comma = (i < #keys) and ",\n" or "\n"
      local keyStr = '["' .. tostring(k) .. '"]'
      if type(v) == "table" then
        table.insert(parts, pad1 .. keyStr .. " = " .. serializeTable(v, indent + 1) .. comma)
      elseif type(v) == "string" then
        table.insert(parts, pad1 .. keyStr .. ' = "' .. v:gsub('"', '\\"') .. '"' .. comma)
      elseif type(v) == "boolean" then
        table.insert(parts, pad1 .. keyStr .. " = " .. tostring(v) .. comma)
      else
        table.insert(parts, pad1 .. keyStr .. " = " .. tostring(v) .. comma)
      end
    end
    table.insert(parts, pad .. "}")
  end

  return table.concat(parts)
end

--- Save rules to filesystem.
function FluidRules.save()
  if not rulesFilePath then return false end

  local data = { rules = {}, ruleOrder = ruleOrder, nextRuleNum = nextRuleNum }
  for _, id in ipairs(ruleOrder) do
    local r = rules[id]
    if r then
      -- Strip internal runtime state before saving
      local saved = {
        id = r.id,
        name = r.name,
        enabled = r.enabled,
        triggers = r.triggers,
        targets = r.targets,
        logic = r.logic,
      }
      table.insert(data.rules, saved)
    end
  end

  local content = "return " .. serializeTable(data)
  local ok, err = pcall(function()
    -- Ensure the data directory exists
    local dir = rulesFilePath:match("(.+)/[^/]+$")
    if dir then pcall(function() filesystem.createDir(dir, true) end) end
    local file = filesystem.open(rulesFilePath, "w")
    if not file then error("Failed to open file for writing: " .. rulesFilePath) end
    file:write(content)
    file:close()
  end)

  if ok then
    print("[FLUID_RULES] Saved " .. #ruleOrder .. " rules to " .. rulesFilePath)
  else
    print("[FLUID_RULES] Save failed: " .. tostring(err))
  end
  return ok
end

--- Load rules from filesystem.
function FluidRules.load()
  if not rulesFilePath then return false end

  local ok, data = pcall(function()
    return filesystem.doFile(rulesFilePath)
  end)

  if not ok or not data then
    print("[FLUID_RULES] No rules file found or parse error - starting fresh")
    return false
  end

  rules = {}
  ruleOrder = data.ruleOrder or {}
  nextRuleNum = data.nextRuleNum or 1

  for _, saved in ipairs(data.rules or {}) do
    saved.state = "idle" -- reset runtime state
    rules[saved.id] = saved
  end

  print("[FLUID_RULES] Loaded " .. #ruleOrder .. " rules")
  return true
end

-- ============================================================================
-- CRUD operations
-- ============================================================================

--- Create a new rule.
-- @param params table - { name, triggers, targets, logic, enabled }
-- @return table - the created rule
function FluidRules.create(params)
  params = params or {}
  local id = "rule_" .. nextRuleNum
  nextRuleNum = nextRuleNum + 1

  local rule = {
    id = id,
    name = params.name or ("Rule " .. (nextRuleNum - 1)),
    enabled = params.enabled ~= false, -- default true
    triggers = params.triggers or {},
    targets = params.targets or {},
    logic = params.logic or "any",
    state = "idle",
  }

  rules[id] = rule
  table.insert(ruleOrder, id)
  FluidRules.save()

  print("[FLUID_RULES] Created rule '" .. rule.name .. "' (" .. id .. ")")
  return rule
end

--- Update an existing rule.
-- @param id string - rule ID
-- @param params table - fields to update
-- @return table|nil - updated rule, or nil if not found
function FluidRules.update(id, params)
  local rule = rules[id]
  if not rule then
    print("[FLUID_RULES] Rule not found: " .. tostring(id))
    return nil
  end

  if params.name ~= nil then rule.name = params.name end
  if params.enabled ~= nil then rule.enabled = params.enabled end
  if params.triggers ~= nil then rule.triggers = params.triggers end
  if params.targets ~= nil then rule.targets = params.targets end
  if params.logic ~= nil then rule.logic = params.logic end

  FluidRules.save()
  print("[FLUID_RULES] Updated rule '" .. rule.name .. "'")
  return rule
end

--- Delete a rule.
-- @param id string - rule ID
-- @return boolean
function FluidRules.delete(id)
  if not rules[id] then
    print("[FLUID_RULES] Rule not found: " .. tostring(id))
    return false
  end

  local name = rules[id].name
  rules[id] = nil

  -- Remove from order
  for i, rid in ipairs(ruleOrder) do
    if rid == id then
      table.remove(ruleOrder, i)
      break
    end
  end

  FluidRules.save()
  print("[FLUID_RULES] Deleted rule '" .. name .. "'")
  return true
end

--- Toggle a rule's enabled state.
-- @param id string
-- @return boolean|nil - new enabled state, or nil if not found
function FluidRules.toggleEnabled(id)
  local rule = rules[id]
  if not rule then return nil end
  rule.enabled = not rule.enabled
  FluidRules.save()
  return rule.enabled
end

--- Get a rule by ID.
-- @param id string
-- @return table|nil
function FluidRules.get(id)
  return rules[id]
end

--- Get all rules in order.
-- @return table - array of rules
function FluidRules.getAll()
  local result = {}
  for _, id in ipairs(ruleOrder) do
    if rules[id] then
      table.insert(result, rules[id])
    end
  end
  return result
end

--- Get ordered rule IDs.
-- @return table
function FluidRules.getOrder()
  return ruleOrder
end

-- ============================================================================
-- Rule evaluation
-- ============================================================================

--- Read a trigger property value from a scan element.
-- @param element table - scan result element record
-- @param property string - "fillPercent", "flow", "productivity", "flowFill", "flowDrain"
-- @return number|nil
local function readTriggerValue(element, property)
  if not element then return nil end
  if property == "fillPercent" then
    return element.fillPercent
  elseif property == "flow" then
    -- Convert to m3/min for consistency with display
    return element.flow and (element.flow * 60) or nil
  elseif property == "flowFill" then
    return element.flowFill and (element.flowFill * 60) or nil
  elseif property == "flowDrain" then
    return element.flowDrain and (element.flowDrain * 60) or nil
  elseif property == "productivity" then
    return element.productivity and (element.productivity * 100) or nil
  end
  return nil
end

--- Evaluate a single trigger against its element.
-- @param trigger table - { elementId, property, min, max }
-- @param elemLookup table - { [id] = element }
-- @return string - "below", "above", or "between"
local function evaluateTrigger(trigger, elemLookup)
  local elem = elemLookup[trigger.elementId]
  if not elem then return "between" end -- can't evaluate → no change

  local value = readTriggerValue(elem, trigger.property)
  if value == nil then return "between" end

  if value <= (trigger.min or 0) then
    return "below"
  elseif value >= (trigger.max or 100) then
    return "above"
  end
  return "between"
end

--- Execute an action on a target element.
-- @param target table - { elementId, actionBelow, actionAbove }
-- @param action string - "enable" or "disable"
-- @param elemLookup table - { [id] = element }
local function executeAction(target, action, elemLookup)
  if not controllerRef then return end
  local elem = elemLookup[target.elementId]
  if not elem or not elem.controllable then return end

  local shouldBeActive = (action == "enable")
  if elem.active ~= shouldBeActive then
    controllerRef.toggle(elem)
    print("[FLUID_RULES] Action: " .. action .. " on " .. (elem.elementName or elem.id))
  end
end

--- Evaluate all rules against current scan data.
-- @param scanResult table - full scan result from FluidScanner.scan()
function FluidRules.evaluate(scanResult)
  if not scanResult or not scanResult.elements then return end

  -- Build element lookup by ID
  local elemLookup = {}
  for _, elem in ipairs(scanResult.elements) do
    elemLookup[elem.id] = elem
  end

  for _, id in ipairs(ruleOrder) do
    local rule = rules[id]
    if rule and rule.enabled and #rule.triggers > 0 and #rule.targets > 0 then
      -- Evaluate all triggers
      local belowCount = 0
      local aboveCount = 0
      local totalTriggers = #rule.triggers

      for _, trigger in ipairs(rule.triggers) do
        local result = evaluateTrigger(trigger, elemLookup)
        if result == "below" then
          belowCount = belowCount + 1
        elseif result == "above" then
          aboveCount = aboveCount + 1
        end
      end

      -- Determine overall rule state based on logic mode
      local newState = nil
      if rule.logic == "all" then
        -- All triggers must agree
        if belowCount == totalTriggers then
          newState = "below"
        elseif aboveCount == totalTriggers then
          newState = "above"
        end
      else -- "any"
        -- Any trigger can fire
        if belowCount > 0 then
          newState = "below"
        elseif aboveCount > 0 and belowCount == 0 then
          newState = "above"
        end
      end

      -- Only act on state transitions (hysteresis: ignore "between")
      if newState and newState ~= rule.state then
        rule.state = newState
        for _, target in ipairs(rule.targets) do
          local action = (newState == "below") and target.actionBelow or target.actionAbove
          if action then
            executeAction(target, action, elemLookup)
          end
        end
      end
    end
  end
end

-- ============================================================================
-- Helper: list available trigger properties
-- ============================================================================

FluidRules.TRIGGER_PROPERTIES = {
  { key = "fillPercent",  label = "Fill %",        unit = "%",      appliesTo = { "reservoir" } },
  { key = "flow",         label = "Flow",          unit = "m3/min", appliesTo = { "pump", "valve", "extractor" } },
  { key = "flowFill",     label = "Flow In",       unit = "m3/min", appliesTo = { "reservoir" } },
  { key = "flowDrain",    label = "Flow Out",      unit = "m3/min", appliesTo = { "reservoir" } },
  { key = "productivity", label = "Productivity",  unit = "%",      appliesTo = { "reservoir", "extractor" } },
}

return FluidRules
