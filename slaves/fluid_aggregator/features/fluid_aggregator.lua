-- features/fluid_aggregator.lua
-- Aggregates data from multiple fluid_monitor slaves via the network bus
-- and provides a centralized dashboard for monitoring and rule management.
--
-- This slave does NOT scan local hardware. It subscribes to network bus
-- channels published by fluid_monitor slaves, collects their overview,
-- detail, controllables, and rule data, and renders everything on a local
-- GPU T1 screen.
--
-- Display modes (cycled via footer click):
--   "overview"      - Compact fleet view of all discovered fluid_monitors
--   "slave_detail"  - Detailed element table for a selected slave
--   "rules_config"  - Click-based rules editor (create/edit/delete/toggle)
--
-- All interaction is click-based (external screens have no keyboard input).

local collector = filesystem.doFile(DRIVE_PATH .. "/modules/aggregator_collector.lua")
local display   = filesystem.doFile(DRIVE_PATH .. "/modules/aggregator_display.lua")

-- ============================================================================
-- Configuration
-- ============================================================================

CONFIG_MANAGER.register("fluid_aggregator", {
  { key = "scanInterval",   label = "Refresh interval (sec)",             type = "number",  default = 3 },
  { key = "pingInterval",   label = "Ping all monitors interval (sec)",   type = "number",  default = 10 },
  { key = "staleTimeout",   label = "Offline timeout (sec)",              type = "number",  default = 15 },
  { key = "outputMode",     label = "Output (auto/screen/console)",       type = "string",  default = "auto" },
  { key = "displayMode",    label = "Initial display mode",               type = "string",  default = "overview" },
  { key = "screenId",       label = "Screen UUID (if mode=screen)",       type = "string" },
})

local aggConfig = CONFIG_MANAGER.getSection("fluid_aggregator")

-- ============================================================================
-- Module initialization
-- ============================================================================

local initOk = collector.init({
  staleTimeout = (aggConfig.staleTimeout or 15) * 1000,
})

if not initOk then
  print("[AGG] Collector init failed (no NETWORK_BUS?) - feature disabled")
  return
end

-- ============================================================================
-- Display setup
-- ============================================================================

local outputMode = aggConfig.outputMode or "auto"
local displayReady = false

if outputMode == "console" then
  print("[AGG] Output mode: console (forced)")

elseif outputMode == "screen" then
  if aggConfig.screenId and aggConfig.screenId ~= "" then
    local targetScreen = component.proxy(aggConfig.screenId)
    if targetScreen then
      local spareGpu = REGISTRY.pci.gpuT2[1] or REGISTRY.pci.gpuT1[1]
      if spareGpu then
        displayReady = display.init(spareGpu, targetScreen, {
          collector = collector,
        })
      else
        print("[AGG] No spare GPU available to drive screen " .. aggConfig.screenId)
      end
    else
      print("[AGG] Screen not found: " .. aggConfig.screenId)
    end
  else
    print("[AGG] outputMode=screen but no Screen UUID configured")
  end

elseif outputMode == "auto" then
  local autoGpu, autoScreen, autoGpuType = REGISTRY.getAvailableDisplay()
  if autoGpu and autoScreen then
    displayReady = display.init(autoGpu, autoScreen, {
      collector = collector,
    })
    print("[AGG] Auto-selected display (GPU " .. autoGpuType .. ")")
  else
    local hasGpu = REGISTRY.pci.gpuT2[1] or REGISTRY.pci.gpuT1[1]
    if not hasGpu then
      print("[AGG] No spare GPU available - falling back to console")
    else
      print("[AGG] No spare screen available - falling back to console")
    end
  end
end

-- ============================================================================
-- Timing
-- ============================================================================

local scanInterval = aggConfig.scanInterval or 3
local pingInterval = aggConfig.pingInterval or 10
local lastPing = 0

-- ============================================================================
-- Main refresh cycle
-- ============================================================================

local function performRefresh()
  -- Update slave state (mark stale ones offline)
  collector.updateStates()

  -- Periodic ping to discover / keep-alive fluid_monitors
  local now = computer.millis()
  if now - lastPing >= pingInterval * 1000 then
    collector.pingAll()
    lastPing = now
  end

  -- Render display
  if displayReady then
    display.render()
  else
    display.printReport()
  end
end

-- ============================================================================
-- Task registration
-- ============================================================================

TASK_MANAGER.register("fluid_aggregator_refresh", {
  interval = scanInterval,
  factory = function()
    return async(function()
      -- Initial ping to discover existing monitors
      collector.pingAll()
      collector.requestAllRuleLists()
      lastPing = computer.millis()

      while true do
        TASK_MANAGER.heartbeat("fluid_aggregator_refresh")
        performRefresh()
        sleep(scanInterval)
      end
    end)
  end,
})

local modeStr = displayReady and "screen" or "console"
print("[AGG] Fluid aggregator active - refreshing every " .. scanInterval .. "s (" .. modeStr .. ")")
