-- lib/task_manager.lua
-- Task watchdog: monitors async tasks and restarts them if they become stale.
-- Features register task factories with expected heartbeat intervals.
-- The main event loop calls TaskManager.check() to detect and restart dead tasks.

local TaskManager = {}

-- Registered tasks keyed by name
local tasks = {}

--- Register and start a named async task.
-- @param name string - unique task identifier
-- @param config table - { interval = number (seconds), factory = function() returning a Future }
function TaskManager.register(name, config)
  if not config or not config.factory then
    print("[TASK_MGR] Cannot register '" .. name .. "': missing factory")
    return
  end

  print("--- [TASK_MGR] Registering task: " .. name .. " (interval: " .. (config.interval or 30) .. "s)")

  tasks[name] = {
    factory = config.factory,
    interval = config.interval or 30,
    lastHeartbeat = 0,
  }

  TaskManager.start(name)
end

--- Signal that a task is still alive.
-- Must be called from inside the async task loop on each iteration.
-- @param name string - task identifier
function TaskManager.heartbeat(name)
  if tasks[name] then
    tasks[name].lastHeartbeat = computer.millis()
  end
end

--- Start (or restart) a named task.
-- @param name string - task identifier
function TaskManager.start(name)
  local task = tasks[name]
  if not task then
    print("[TASK_MGR] Unknown task: " .. name)
    return
  end

  task.lastHeartbeat = computer.millis()
  future.addTask(task.factory())
  print("- [TASK_MGR] Started task: " .. name)
end

--- Check all tasks and restart any that are stale.
-- A task is considered stale if no heartbeat was received within 3x its expected interval.
-- Call this periodically from the main event loop.
function TaskManager.check()
  local now = computer.millis()
  for name, task in pairs(tasks) do
    local timeoutMs = task.interval * 3 * 1000
    if (now - task.lastHeartbeat) > timeoutMs then
      print("[TASK_MGR] Task '" .. name .. "' stale (no heartbeat for "
        .. math.floor((now - task.lastHeartbeat) / 1000) .. "s), restarting...")
      TaskManager.start(name)
    end
  end
end

return TaskManager