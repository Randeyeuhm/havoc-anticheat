--[[
  ============================================================
  HAVOC ADONIS KILL  (full bypass / zombifier)
  ============================================================
  Target: the paid "Adonis Anti Cheat" client (hidden tree
  "" > Client > Core > Anti). Strategy: keep the AC loop ALIVE and
  every other check green, but replace every DETECTOR closure in its
  registry with `function() return false end` (via hookfunction).

  Why this is the clean kill:
    * detector -> always returns boolean false => the loop treats it
      as clean; the tamper paths (error / non-boolean) can never fire
    * u8 (the kick/report fn) is NEVER touched => its debug.info
      self-check keeps passing => the loop keeps ticking => framework
      supervision, heartbeat patterns and the probe batteries stay
      satisfied and identical to a clean client
    * nothing ever reports => no "Detected" packets to the server
    * auto-rediscovery: re-scans every ~20s; any new detector closures
      (module reload / new server) get zombified within one cycle

  Usage:
    loadstring(readfile("havoc_db/adonis_kill.luau"))()
    HAVOC_ACKILL.status()   -- hooked count, detector names, ticks
    HAVOC_ACKILL.stop()     -- restore originals (best effort)
  Re-run after every rejoin / for every new game.
]]

local KILL = {}
local genv = (type(getgenv) == "function" and getgenv()) or _G
local STATE = genv.HAVOC_ACKILL_STATE
if type(STATE) ~= "table" then
  STATE = { hooked = {}, origs = {} }
  genv.HAVOC_ACKILL_STATE = STATE
end
do
  local prev = genv.HAVOC_ACKILL
  if type(prev) == "table" and prev.alive then
    prev.alive = false -- retire old refresher; hooks + STATE stay shared
  end
end
genv.HAVOC_ACKILL = KILL
KILL.alive = true
KILL.log = {}
local rawPrint = print
local function log(msg)
  KILL.log[#KILL.log + 1] = tostring(msg)
  pcall(rawPrint, "[adonis_kill] " .. tostring(msg))
end

local REG_FOUND = false
local function findRegistry()
  if type(getgc) ~= "function" then return nil end
  local gc = getgc(true)
  for _, o in ipairs(gc) do
    if type(o) == "table" then
      local a, b = rawget(o, "namecallInstance"), rawget(o, "indexInstance")
      if type(a) == "table" and type(a[2]) == "function" and type(b) == "table" and type(b[2]) == "function" then
        return o
      end
    end
  end
  return nil
end

local function zombify(registry)
  local n = 0
  for k, v in pairs(registry) do
    if type(v) == "table" and type(v[2]) == "function" then
      local fn = v[2]
      if not STATE.hooked[fn] then
        local ok, handle = pcall(hookfunction, fn, function() return false end)
        if ok then
          STATE.hooked[fn] = true
          STATE.origs[#STATE.origs + 1] = { fn = fn, handle = handle, name = tostring(k) }
          n = n + 1
        end
      end
    end
  end
  return n
end

-- first pass
local reg = findRegistry()
if reg then
  REG_FOUND = true
  local n = zombify(reg)
  -- verify one detector -- SAFE: only call it if OUR hook is confirmed installed
  -- (never call a real detector from our thread!)
  local okV, res = pcall(function()
    local e = rawget(reg, "namecallInstance")
    if type(e) == "table" and type(e[2]) == "function" and STATE.hooked[e[2]] then
      return e[2]()
    end
    return "hook-not-confirmed"
  end)
  KILL.verifyFirst = okV and tostring(res) or ("ERR " .. tostring(res))
  log("registry found; zombified " .. n .. " detector(s); test-call -> " .. KILL.verifyFirst)
else
  log("registry not found yet (AC not loaded?) - refresher will keep hunting")
end

-- refresher
local ticks = 0
KILL.ticks = 0
task.spawn(function()
  while KILL.alive do
    task.wait(20)
    ticks = ticks + 1
    KILL.ticks = ticks
    local r = findRegistry()
    if r then
      if not REG_FOUND then
        REG_FOUND = true
        log("registry appeared - zombifying")
      end
      local n = zombify(r)
      if n > 0 then log("zombified " .. n .. " new detector(s)") end
    end
  end
end)

KILL.stop = function()
  KILL.alive = false
  local restored = 0
  for _, rec in ipairs(STATE.origs) do
    local ok = false
    if type(restorefunction) == "function" then
      if rec.handle then ok = pcall(restorefunction, rec.handle) end
      if not ok then ok = pcall(restorefunction, rec.fn) end
    end
    if ok then restored = restored + 1 end
  end
  log("stop: restored " .. restored .. "/" .. #STATE.origs .. " (restorefunction " .. (type(restorefunction) == "function" and "available" or "UNAVAILABLE") .. ")")
  return restored
end

KILL.status = function()
  local names = {}
  for _, rec in ipairs(STATE.origs) do names[#names + 1] = rec.name end
  return {
    alive = KILL.alive,
    hooked = #STATE.origs,
    names = table.concat(names, ","),
    ticks = ticks,
    registryFound = REG_FOUND,
    verifyFirst = KILL.verifyFirst,
  }
end

log("READY (hooked=" .. #STATE.origs .. ")")
return KILL
