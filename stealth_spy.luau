--[[
  ============================================================
  HAVOC STEALTH SPY  (anti-cheat-aware namecall spyer)
  ============================================================
  Built for games running "Adonis Anti Cheat" (the paid product;
  hidden client tree: "" > Client > Core > Anti).

  Why custom: that AC runs a "namecallInstance" detector every ~5s:
    (a) probes game:____________(), captures the erroring function and
        verifies it is a pristine C function ([C], line -1, name "", arity 0)
    (b) samples debug stack levels 3/4 and compares them to a baseline
        stored ONCE at game start (u9.namecallInstance + tbl_upv_1.namecallInstance)
  A late-installed hook shifts those stack levels => baseline mismatch
  => "namecallInstance detector detected" kick.

  Verified live (10/5): Volt's hookmetamethod keeps the probe-captured
  function IDENTITY EQUAL to pristine => check (a) PASSES with a hook.
  Only (b) catches hooks. This script blinds (b) with DATA-ONLY writes
  (never calls AC functions): it keeps the two baseline containers empty
  so every AC scan re-baselines from its own correct stack => no misfire.

  SAFETY RULES baked in:
    * NEVER calls the AC's internals (checkStack/detectors) - data only
    * hook forwards ALL calls verbatim (errors intact, so their
      "FireServer function hooks detected" string-probes keep passing)
    * self-test right after install; auto-revert on any anomaly
    * stop() restores the original metatable (verified)

  Run:   loadstring(readfile("havoc_db/stealth_spy.luau"))()
  Stop:  getgenv().HAVOC_SPY.stop()
  Hub:   getgenv().HAVOC_SPY.drain() / .status()
  Re-run after every rejoin (fresh client = fresh AC state).
]]

local SPY = {}
local genv = (type(getgenv) == "function" and getgenv()) or _G
do
  local prev = genv.HAVOC_SPY
  if type(prev) == "table" and type(prev.stop) == "function" and prev.alive then
    pcall(prev.stop)
  end
end
genv.HAVOC_SPY = SPY
SPY.alive = true
SPY.log = {}

local rawPrint = print
local function log(msg)
  SPY.log[#SPY.log + 1] = tostring(msg)
  pcall(rawPrint, "[stealth_spy] " .. tostring(msg))
end

-- own replica probe (identical semantics to theirs; harmless read-only)
local function probeGame()
  local c
  xpcall(function() local _ = game:____________() end, function() c = debug.info(2, "f") end)
  return c
end

-- locate AC baseline containers (read-only scan of the GC)
local function findRefs()
  if type(getgc) ~= "function" then return nil, "no getgc" end
  local gc = getgc(true)
  local function upvals(f)
    local ok2, t = pcall(getupvalues, f)
    if ok2 and type(t) == "table" and #t > 0 then return t end
    local r = {}
    for i = 1, 60 do
      local ok3, v = pcall(getupvalue, f, i)
      if not ok3 then break end
      r[i] = v
    end
    return r
  end
  local u9keys = {"indexInstance","newindexInstance","namecallInstance","indexEnum","namecallEnum","eqEnum"}
  local function isU9(t)
    if type(t) ~= "table" then return false end
    for _, k in ipairs(u9keys) do if rawget(t, k) == nil then return false end end
    return true
  end
  local detFn
  for _, o in ipairs(gc) do
    if type(o) == "table" then
      local e = rawget(o, "namecallInstance")
      if type(e) == "table" and type(e[2]) == "function" then detFn = e[2] break end
    end
  end
  if not detFn then return nil, "AC registry not found (module not loaded?)" end
  local uvs = upvals(detFn)
  local checkStack, tbl1 = uvs[3], uvs[8]
  if type(checkStack) ~= "function" or type(tbl1) ~= "table" then return nil, "AC shape mismatch" end
  local csUvs = upvals(checkStack)
  local u9 = csUvs[1]
  if not isU9(u9) then return nil, "u9 shape mismatch" end
  return { u9 = u9, tbl1 = tbl1 }
end

local refs, findErr = findRefs()
if not refs then
  log("ABORT (no hook installed): " .. tostring(findErr))
  return SPY
end
SPY.u9 = refs.u9
SPY.tbl1 = refs.tbl1
log("AC baseline containers located (data-only access).")

-- blinder: keep the namecallInstance baselines EMPTY so every AC scan
-- re-baselines from its own (correct) stack and never misfires.
local blindTicks = 0
SPY.blindTicks = 0
task.spawn(function()
  while SPY.alive do
    pcall(function()
      SPY.u9.namecallInstance = {}
      SPY.tbl1.namecallInstance = nil
    end)
    blindTicks = blindTicks + 1
    SPY.blindTicks = blindTicks
    task.wait(0.2)
  end
end)

-- refresh refs occasionally (in case the AC module re-inits)
task.spawn(function()
  while SPY.alive do
    task.wait(60)
    local newRefs = findRefs()
    if newRefs and newRefs.u9 ~= SPY.u9 then
      SPY.u9 = newRefs.u9
      SPY.tbl1 = newRefs.tbl1
      log("baseline containers refreshed")
    end
  end
end)

-- install hook (dumb-forward: queue raw refs only, serialize off-hook)
SPY.origFn = probeGame()
SPY.savedMT = getrawmetatable(game)
local rawQueue = {}
local oldNamecall
local hookOk = pcall(function()
  oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    if SPY.alive then
      local okM, method = pcall(getnamecallmethod)
      if okM and (method == "FireServer" or method == "InvokeServer") then
        if #rawQueue < 300 then
          local origin = nil
          if getcallingscript then origin = getcallingscript() end
          rawQueue[#rawQueue + 1] = { self, method, table.pack(...), origin }
        end
      end
    end
    return oldNamecall(self, ...)
  end)
end)
if not hookOk then
  SPY.alive = false
  log("hookmetamethod failed; blinder stopped; no hook installed.")
  return SPY
end

function SPY.stop()
  SPY.alive = false
  local restored = false
  if SPY.savedMT then
    pcall(setrawmetatable, game, SPY.savedMT)
    restored = (probeGame() == SPY.origFn)
  end
  if not restored and type(restorefunction) == "function" and oldNamecall then
    pcall(restorefunction, oldNamecall)
    restored = (probeGame() == SPY.origFn)
  end
  if not restored and oldNamecall then
    pcall(hookmetamethod, game, "__namecall", oldNamecall)
    restored = (probeGame() == SPY.origFn)
  end
  if not restored then
    pcall(function() rawset(getrawmetatable(game), "__namecall", SPY.origFn) end)
    restored = (probeGame() == SPY.origFn)
  end
  log("stop: hookRestored=" .. tostring(restored))
  return restored
end

-- self-test: (1) probe capture still pristine, (2) wrapper actually intercepts
local probeOk = (probeGame() == SPY.origFn)
local interceptOk = false
if probeOk then
  local okT = pcall(function()
    local r = Instance.new("RemoteEvent")
    r:FireServer()
  end)
  interceptOk = okT and (#rawQueue > 0)
end
if not (probeOk and interceptOk) then
  SPY.stop()
  log("self-test FAILED (probe=" .. tostring(probeOk) .. " intercept=" .. tostring(interceptOk) .. ") - reverted.")
  return SPY
end
rawQueue = {}
log("hook installed; self-test PASSED (probe pristine + interception live).")

-- API for the hub (accessed through the bridge via run_luau)
function SPY.drain()
  local out = rawQueue
  rawQueue = {}
  local res = {}
  for i, e in ipairs(out) do
    local okS, s = pcall(function()
      return { remote = e[1]:GetFullName(), method = e[2], args = e[3], origin = e[4] and tostring(e[4]) or nil }
    end)
    res[i] = okS and s or { err = "serialize fail" }
  end
  return res
end

function SPY.status()
  return {
    alive = SPY.alive,
    blindTicks = blindTicks,
    queued = #rawQueue,
    hookIntact = (probeGame() == SPY.origFn),
    hasU9 = SPY.u9 ~= nil and rawget(SPY.u9, "namecallInstance") ~= nil,
  }
end

-- mirror queue to disk now and then (survives a kick)
task.spawn(function()
  while SPY.alive do
    task.wait(4)
    local q = rawQueue
    if #q > 0 and type(writefile) == "function" then
      local lines = {}
      local from = math.max(1, #q - 199)
      for i = from, #q do
        local e = q[i]
        local ok1, name = pcall(function() return e[1]:GetFullName() end)
        local ok2, a1 = pcall(function() return tostring(e[3][1]) end)
        lines[#lines + 1] = "[" .. tostring(e[2]) .. "] " .. (ok1 and name or "?") .. " :: " .. (ok2 and a1 or "?")
      end
      pcall(writefile, "havoc_db/spy.txt", table.concat(lines, "\n"))
    end
  end
end)

log("READY.")
return SPY
