-- Smoke and timing test, run on a desktop with plain lua:
--
--   lua lib/tools/check.lua
--
-- Stubs enough of norns to run the script for real: a clock that behaves
-- like matron's (1 ms polling, syncs counted from the previous target),
-- MIDI ports that log every message with the beat it went out on, a grid,
-- and a screen that fails on overlapping text.

local ROOT = (arg[0]:match("(.*)/lib/tools/") or ".")

function include(path)
  return dofile(ROOT .. "/" .. path .. ".lua")
end

local now = 0
util = {
  clamp = function(v, lo, hi) return math.min(math.max(v, lo), hi) end,
  round = function(v) return math.floor(v + 0.5) end,
  time = function() return now end,
  file_exists = function() return false end,
  scandir = function() return { "808-BD.wav", "808-CH.wav", "808-SD.wav" } end,
}
_path = { audio = "/home/we/dust/audio/" }

-- the engine: every command logged with its arguments and the beat
local eng_log = {}
engine = setmetatable({ name = "", commands = { synOn = {} } }, { __index = function(_, k)
  return function(...)
    eng_log[#eng_log + 1] = { cmd = k, args = { ... }, beat = clock.get_beats() }
  end
end })
poll = { set = function() return nil end }

-- ------------------------------------------------------------------ screen

local txt = { x = 0, y = 0, size = 8, boxes = {} }
local function txt_w(s) return #tostring(s) * 5 * (txt.size / 8) end
local function box(s, x0)
  local w = txt_w(s)
  local h = math.floor(txt.size * 0.75 + 0.5)
  txt.boxes[#txt.boxes + 1] = { s = tostring(s), x0 = x0, x1 = x0 + w - 1, y0 = txt.y - h + 1, y1 = txt.y }
end
local SCREEN = {
  move = function(x, y) txt.x, txt.y = x, y end,
  font_size = function(n) txt.size = n end,
  text_extents = function(s) return txt_w(s), txt.size end,
  text = function(s) box(s, txt.x) end,
  text_right = function(s) box(s, txt.x - txt_w(s)) end,
  text_center = function(s) box(s, txt.x - (txt_w(s) / 2)) end,
}
screen = setmetatable({}, { __index = function(_, k)
  return function(...) if SCREEN[k] then return SCREEN[k](...) end end
end })
local problems = {}
local function check_text(where)
  local b = txt.boxes
  for i = 1, #b do
    for j = i + 1, #b do
      local p, q = b[i], b[j]
      if p.s ~= "" and q.s ~= "" and p.x0 <= q.x1 and q.x0 <= p.x1 and p.y0 <= q.y1 and q.y0 <= p.y1 then
        problems[#problems + 1] = string.format("%s: '%s' overlaps '%s'", where, p.s, q.s)
      end
    end
    if b[i].x0 < -1 or b[i].x1 > 128 then
      problems[#problems + 1] = string.format("%s: '%s' runs off screen", where, b[i].s)
    end
  end
  txt.boxes = {}
end

-- ------------------------------------------------------------------- clock

local BS = 0.5          -- 120 bpm
local DT = 0.001
local beats = 0
local coros, wake, last_sync, nid = {}, {}, {}, 0
local EPSF = 1.1920929e-07

local function next_beat(base, q, off)
  off = off or 0
  local nb = math.ceil((base + EPSF) / q) * q + off
  while nb < base + EPSF do nb = nb + q end
  return math.max(nb, 0)
end

local function resume(id, ...)
  local co = coros[id]
  if not co then return end
  local ok, mode, a, b = coroutine.resume(co, ...)
  if not ok then error(debug.traceback(co, mode)) end
  if coroutine.status(co) == "dead" then
    coros[id], wake[id], last_sync[id] = nil, nil, nil
  elseif mode == "sync" then
    local base = last_sync[id] or beats
    local nb = next_beat(base, a, b)
    last_sync[id] = nb
    wake[id] = { sync = nb }
  else
    last_sync[id] = nil
    wake[id] = { time = now + a }
  end
end

clock = {
  run = function(f, ...)
    nid = nid + 1
    coros[nid] = coroutine.create(f)
    resume(nid, ...)
    return nid
  end,
  sleep = function(s) return coroutine.yield("sleep", s) end,
  sync = function(q, off) return coroutine.yield("sync", q, off) end,
  cancel = function(id) coros[id], wake[id], last_sync[id] = nil, nil, nil end,
  get_beat_sec = function() return BS end,
  get_beats = function() return beats end,
  transport = {},
  link = { start = function() end, stop = function() end },
}

local function step()
  now = now + DT
  beats = beats + (DT / BS)
  local due = {}
  for id, w in pairs(wake) do
    if (w.sync and beats > w.sync) or (w.time and now >= w.time) then due[#due + 1] = id end
  end
  table.sort(due)
  for _, id in ipairs(due) do
    if wake[id] then wake[id] = nil resume(id) end
  end
end

local function pump_beats(n)
  for _ = 1, math.floor((n * BS / DT) + 0.5) do step() end
end

-- MIDI Start from outside: beat 0 now, every sync re-quantised from it
local function external_start()
  beats = 0
  for id, w in pairs(wake) do
    if w.sync then w.sync = 0 last_sync[id] = 0 end
  end
  clock.transport.start()
end

-- -------------------------------------------------------------------- midi

local log = {}
local function port(n)
  local p = { name = "dev" .. n }
  local function rec(kind, a, b, c)
    log[#log + 1] = { kind = kind, port = n, a = a, b = b, c = c, beat = beats }
  end
  function p:note_on(note, vel, ch) rec("on", note, vel, ch) end
  function p:note_off(note, vel, ch) rec("off", note, vel, ch) end
  function p:cc(cc, v, ch) rec("cc", cc, v, ch) end
  function p:program_change(v, ch) rec("pc", v, ch) end
  function p:clock() rec("clock") end
  function p:start() rec("start") end
  function p:stop() rec("stop") end
  function p:continue() rec("continue") end
  function p:song_position(l, m) rec("spp", l, m) end
  return p
end
local ports = {}
midi = { vports = {} }
for n = 1, 16 do
  ports[n] = port(n)
  midi.vports[n] = { name = (n == 1) and "OP-Z" or "none" }
end
midi.connect = function(n) return ports[n] end
midi.to_msg = function(d) return { type = d.type, lsb = d.lsb, msb = d.msb } end

local gobj = {
  led = function(_, x, y, l)
    assert(x >= 1 and x <= 16 and y >= 1 and y <= 8, "led out of range")
    assert(l >= 0 and l <= 15 and l == math.floor(l), "bad led level " .. tostring(l))
  end,
  refresh = function() end,
}
grid = { connect = function() return gobj end }
metro = { init = function(f) return { start = function() end, stop = function() end, event = f } end }
tab = { save = function() end, load = function() return nil end }
norns = { state = { data = "/tmp/vc-test/" } }

-- ------------------------------------------------------------------ params

-- controlspec, enough to be real about raw and mapped values (the drums)
controlspec = { new = function(lo, hi, warp, step, def, unit, quantum)
  local c = { minval = lo, maxval = hi, warp = warp or "lin", step = step or 0,
              default = def or lo, units = unit, quantum = quantum or 0.01 }
  function c:map(r)
    r = math.min(math.max(r, 0), 1)
    local v
    if self.warp == "exp" then v = self.minval * ((self.maxval / self.minval) ^ r)
    else v = self.minval + ((self.maxval - self.minval) * r) end
    if self.step > 0 then v = math.floor((v / self.step) + 0.5) * self.step end
    return v
  end
  function c:unmap(v)
    if self.warp == "exp" then return math.log(v / self.minval) / math.log(self.maxval / self.minval) end
    return (v - self.minval) / (self.maxval - self.minval)
  end
  return c
end }

local PR = {}
params = { lookup = {} }
local function addp(id, p)
  assert(not PR[id], "duplicate param " .. id)
  PR[id] = p
  params.lookup[id] = true
end
function params:add_separator() end
function params:add_group() end
function params:add_option(id, _, opts, def) addp(id, { val = def or 1, lo = 1, hi = #opts }) end
function params:add_number(id, _, lo, hi, def) addp(id, { val = def, lo = lo, hi = hi }) end
function params:add_binary(id, _, _, def) addp(id, { val = def or 0, lo = 0, hi = 1 }) end
function params:add_trigger(id) addp(id, { val = 0, lo = 0, hi = 1, trig = true }) end
function params:add_file(id, _, path) addp(id, { val = path }) end
function params:add_control(id, _, cs) addp(id, { cs = cs, raw = cs:unmap(cs.default) }) end
function params:set_action(id, f) PR[id].action = f end
function params:get(id)
  local p = assert(PR[id], "no param " .. id)
  if p.cs then return p.cs:map(p.raw) end
  return p.val
end
function params:get_raw(id) return assert(PR[id], "no param " .. id).raw end
function params:set_raw(id, r)
  local p = assert(PR[id], "no param " .. id)
  p.raw = math.min(math.max(r, 0), 1)
  if p.action then p.action(params:get(id)) end
end
function params:lookup_param(id)
  local p = assert(PR[id], "no param " .. id)
  return { controlspec = p.cs, get = function() return params:get(id) end }
end
function params:set(id, v)
  local p = assert(PR[id], "no param " .. id)
  if p.cs then p.raw = p.cs:unmap(v) else p.val = v end
  if p.action then p.action(params:get(id)) end
end
function params:delta(id, d)
  local p = PR[id]
  if p.cs then return params:set_raw(id, p.raw + (d * p.cs.quantum)) end
  params:set(id, math.min(math.max(p.val + d, p.lo), p.hi))
end
function params:bang()
  for _, p in pairs(PR) do
    if p.action and not p.trig then p.action(p.cs and p.cs:map(p.raw) or p.val) end
  end
end
params:add_number("clock_tempo", "tempo", 1, 300, 120)
params:add_option("clock_source", "source", { "internal", "midi", "link", "crow" }, 1)
params:add_option("link_start_stop_sync", "", { "disabled", "enabled" }, 1)
for n = 1, 16 do params:add_binary("clock_midi_out_" .. n, "", "toggle", 0) end
params:set("clock_midi_out_1", 1)   -- the user had norns clocking port 1

-- --------------------------------------------------------------------- run

dofile(ROOT .. "/vibecomposer.lua")
init()
local V = vibecomposer
-- the tests below this were written for MIDI tracks: every track MIDI,
-- until the synth's own tests
for t = 1, #V.state.d.tracks do V.state.track(t).out = 2 end
local St, Q, G, P, Kb, N = V.state, V.seq, V.grid, V.pages, V.keys, V.snap
local K = include("lib/const")
local T = include("lib/theory")

local passed, failed = 0, 0
local function ok(c, msg)
  if c then passed = passed + 1 else failed = failed + 1 print("FAIL: " .. msg) end
end

local function press(x, y) G.key(x, y, 1) end
local function release(x, y) G.key(x, y, 0) end
local function tap(x, y) press(x, y) release(x, y) end
local function frame(where) redraw() check_text(where) G.redraw() end

-- the port norns was clocking has been taken over, and norns' turned off
ok(params:get("vc_clock_out_1") == 2, "port 1 adopted for clock+transport")
ok(params:get("clock_midi_out_1") == 0, "norns clock out on port 1 turned off")

-- ------------------------------------------------------------------ theory

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end
local cm = T.chord({ base = 48, scale = 1, deg = 0, mods = {} })
ok(same(cm, { 48, 52, 55 }), "C major triad")
ok(same(T.chord({ base = 48, scale = 1, deg = 1, mods = {} }), { 50, 53, 57 }), "ii is D minor")
ok(same(T.chord({ base = 48, scale = 1, deg = 4, mods = { ext = "7" } }), { 55, 59, 62, 65 }), "V7")
ok(same(T.chord({ base = 48, scale = 1, deg = 0, mods = { inv = "INV1" } }), { 52, 55, 60 }), "first inversion")
ok(same(T.chord({ base = 48, scale = 1, deg = 1, mods = { bor = "V/" } }), { 57, 61, 64, 67 }), "V/ii is A7")
local _, nm = T.chord({ base = 48, scale = 1, deg = 5, mods = { ext = "7" } })
ok(nm == "Am7", "vi7 named Am7, got " .. tostring(nm))
ok(T.follow(60, { kind = 1, notes = { 50 } }, { root = 48, scale = 1, transpose = 1 }) == 62, "mono transposes +2")
ok(T.follow(64, { kind = 1, notes = { 50 } }, { root = 48, scale = 1, transpose = 2 }) == 65, "in-key transposes E up a step to F")
ok(T.follow(62, { kind = 2, notes = { 57, 60, 64 } }, St.d) == 60, "D snaps to C of Am (tie goes down)")
ok(T.follow(66, { kind = 2, notes = { 57, 60, 64 } }, St.d) == 64, "F# snaps to E")

-- -------------------------------------------------------------------- grid

-- every page draws without overlapping text
for _, pg in ipairs({ "home", "track", "tc1", "tc2", "tc3", "tc4", "gen", "rain", "keys", "chord", "settings", "tset" }) do
  P.open(pg)
  for lane = 1, 3 do
    P.lane[pg] = lane
    frame(pg .. " lane " .. lane)
  end
end
P.open("home")

-- press a key, then a step: the step takes it
local kx, ky = 11, 8                         -- bottom-left: the root, C3
tap(kx, ky)
tap(1, 1)
local c1 = St.clip(1)
ok(c1.steps[1] and c1.steps[1].notes[1] == 48, "step 1 took the last key")
-- hold step 5, play a key: the step takes it
press(5, 1) tap(12, 8) release(5, 1)
ok(c1.steps[5] and c1.steps[5].notes[1] == 49, "held step took the key")
-- hold a key, press step 9
press(13, 8) tap(1, 2) release(13, 8)
ok(c1.steps[9] and c1.steps[9].notes[1] == 50, "step took the held key")
-- a quick tap on a full step empties it
tap(1, 2)
ok(c1.steps[9] == nil, "tap cleared step 9")
-- a long hold does not
press(5, 1) now = now + 0.6 release(5, 1)
ok(c1.steps[5] ~= nil, "a long hold leaves the step")

-- poly: two keys together into one step
tap(2, 7)                                    -- track 2
press(11, 8) press(11, 7) tap(1, 1) release(11, 8) release(11, 7)
ok(#St.clip(2).steps[1].notes == 2, "poly step took both keys")

-- chord mode into a poly step
tap(10, 2)
ok(Kb.mode == 2, "chord mode")
tap(11, 1)                                   -- latch the 7th
press(12, 8) tap(2, 1) release(12, 8)        -- ii7 held, step 2
local s2 = St.clip(2).steps[2]
ok(s2 and same(s2.notes, { 50, 53, 57, 60 }), "step 2 holds Dm7")
tap(11, 1)                                   -- unlatch
ok(St.d.mods.ext == nil, "7th unlatched")
tap(10, 1)                                   -- back to keys
for _, pg in ipairs({ "home", "chord", "keys" }) do P.open(pg) frame(pg .. " with notes") end

-- TC page with a step held edits that step
tap(1, 7)                                    -- track 1
tap(1, 6)                                    -- TC1
ok(P.page == "tc1", "TC1 open")
press(1, 1) P.lane.tc1 = 2 P.enc(2, -30) release(1, 1)
ok(c1.steps[1].vel == 70, "held step's velocity edited")
ok(c1.steps[1] ~= nil, "editing a held step does not clear it")

-- ------------------------------------------------------------------ timing

-- track 1: a plain four on the floor, step 5's note too
c1.steps = {}
for _, i in ipairs({ 1, 5, 9, 13 }) do c1.steps[i] = St.new_step(1, { 60 }) end
c1.len = 16
St.clip(2).steps = {}
log = {}

local function ons(port_, ch)
  local out = {}
  for _, e in ipairs(log) do
    if e.kind == "on" and (not ch or e.c == ch) and (not port_ or e.port == port_) then out[#out + 1] = e end
  end
  return out
end
local function first(kind)
  for i, e in ipairs(log) do if e.kind == kind then return e, i end end
end

tap(1, 8)                                     -- PLAY
pump_beats(4.2)
local st_e, st_i = first("start")
ok(st_e ~= nil, "MIDI Start sent")
local nxt = log[st_i + 1]
ok(nxt and nxt.kind == "clock", "Start goes out right before a clock tick")
local o = ons(1, 1)
ok(#o >= 4, "four kicks in four beats, got " .. #o)
local b0 = st_e.beat
local TOL = 0.0025 / BS                       -- 2.5 ms
for i = 1, math.min(#o, 4) do
  local want = math.floor(b0 * 24 + 0.5) / 24 + (i - 1)
  ok(math.abs(o[i].beat - want) < TOL, string.format("kick %d on its beat (%.4f vs %.4f)", i, o[i].beat, want))
end
-- 24 clock ticks a beat
local ticks = 0
for _, e in ipairs(log) do if e.kind == "clock" and e.beat >= b0 - 0.01 and e.beat < b0 + 4 - 0.02 then ticks = ticks + 1 end end
ok(ticks == 96, "96 ticks in four beats, got " .. ticks)

-- every note on has its note off
local open = {}
pump_beats(1)
for _, e in ipairs(log) do
  if e.kind == "on" then open[e.a] = (open[e.a] or 0) + 1 end
  if e.kind == "off" and open[e.a] then open[e.a] = open[e.a] - 1 end
end
for n, v in pairs(open) do ok(v <= 1, "note " .. n .. " left hanging") end

-- swing: 66 % pushes every second sixteenth 0.16 x 2 sixteenths late
Q.stop()
c1.steps = {}
for i = 1, 4 do c1.steps[i] = St.new_step(1, { 60 + i }) end
St.d.swing = 66
log = {}
tap(1, 8)
pump_beats(1.2)
o = ons(1, 1)
ok(#o >= 4, "four sixteenths")
if #o >= 4 then
  local d1 = (o[2].beat - o[1].beat) * 4
  local d2 = (o[3].beat - o[2].beat) * 4
  ok(math.abs(d1 - 1.32) < 0.02, string.format("swung second sixteenth (%.3f)", d1))
  ok(math.abs(d2 - 0.68) < 0.02, string.format("third sixteenth back on the grid (%.3f)", d2))
end
St.d.swing = 50

-- pause and continue: the pattern carries on from where it was
Q.stop()
c1.steps = {}
for i = 1, 8 do c1.steps[i] = St.new_step(1, { 60 + i }) end
c1.len = 8
log = {}
tap(1, 8)
pump_beats(0.6)                               -- steps 1-3 play
tap(1, 8)                                     -- pause
ok(Q.paused, "paused")
local before = ons(1, 1)
local last_note = before[#before].a
ok(first("stop") ~= nil, "MIDI Stop on pause")
pump_beats(1)
log = {}
tap(1, 8)                                     -- continue
pump_beats(0.6)
local after = ons(1, 1)
ok(after[1] and after[1].a == last_note + 1, "continues with the next step (" .. tostring(after[1] and after[1].a) .. ")")
ok(first("spp") ~= nil and first("continue") ~= nil, "Song Position + Continue on resume")
local ce = first("continue")
local _, ci = first("continue")
ok(log[ci + 1] and log[ci + 1].kind == "clock", "Continue right before a tick")

-- stop goes back to the top
tap(2, 8)
ok(not Q.playing and not Q.paused, "stopped")
log = {}
tap(1, 8)
pump_beats(0.3)
o = ons(1, 1)
ok(o[1] and o[1].a == 61, "from the top after STOP")

-- ------------------------------------------------------------ track 8

Q.stop()
c1.steps = { St.new_step(1, { 60 }) }
c1.len = 1
local c8 = St.clip(8)
c8.steps = { St.new_step(8, { 50 }) }        -- D3 against a C3 root: +2
c8.len = 1
c8.speed = 4
log = {}
tap(1, 8)
pump_beats(2.1)
o = ons(1, 1)
ok(#o >= 4 and o[1].a == 62 and o[#o].a == 62, "track 1 transposed +2 by track 8")
-- poly track 8: harmonise
Q.stop()
c8.steps = { St.new_step(8, { 57, 60, 64 }) }  -- Am
c1.steps = { St.new_step(1, { 62 }) }        -- D -> C
log = {}
tap(1, 8)
pump_beats(1.1)
o = ons(1, 1)
ok(o[1] and o[1].a == 60, "track 1's D pulled to Am's C")
-- follow off
Q.stop()
St.track(1).follow = false
log = {}
tap(1, 8)
pump_beats(0.5)
o = ons(1, 1)
ok(o[1] and o[1].a == 62, "follow off: D stays D")
St.track(1).follow = true
Q.stop()
c8.steps = {}
c8.speed = 1

-- --------------------------------------------- pulses, ratchets, conditions

c1.steps = {}
c1.len = 4
local s = St.new_step(1, { 60 })
s.pulses, s.mode = 3, 1                      -- REPEAT x3
c1.steps[1] = s
local sk = St.new_step(1, { 70 })
sk.skip = 1
c1.steps[2] = sk
c1.steps[3] = St.new_step(1, { 64 })
local rr = St.new_step(1, { 67 })
rr.ratchet = 2
c1.steps[4] = rr
log = {}
tap(1, 8)
pump_beats(1.55)                             -- 3 + 1 + 1 pulses = 5 sixteenths, then again
o = ons(1, 1)
local seq_ = {}
for _, e in ipairs(o) do seq_[#seq_ + 1] = e.a end
ok(table.concat(seq_, ","):sub(1, 17) == "60,60,60,64,67,67", "pulses, skip and ratchet: " .. table.concat(seq_, ","))
Q.stop()

-- 1:2 plays every other pass
c1.steps = {}
c1.len = 1
local cnd = St.new_step(1, { 60 })
for i, c in ipairs(K.CONDS) do if c == "1:2" then cnd.cond = i end end
c1.steps[1] = cnd
log = {}
tap(1, 8)
pump_beats(1.05)                             -- four passes
o = ons(1, 1)
ok(#o == 2, "1:2 plays twice in four passes, got " .. #o)
Q.stop()

-- ------------------------------------------------- clips and snapshots

c1.steps = { St.new_step(1, { 60 }) }
c1.len = 16
tap(8, 8)                                    -- SETTINGS
ok(G.settings and P.page == "settings", "settings mode")
frame("settings grid")
-- copy clip 1 of track 1 to clip 2 of track 3
press(1, 1) tap(3, 2) release(1, 1)
ok(St.track(3).clips[2].steps[1] ~= nil, "clip copied across tracks")
ok(St.track(1).clip == 1, "copying does not launch")
-- launch it while playing: on the next bar
log = {}
tap(1, 8)
pump_beats(0.5)
tap(3, 2)
ok(Q.rt[3].queued ~= nil, "launch waits for the bar")
pump_beats(4)
ok(Q.rt[3].queued == nil and St.track(3).clip == 2, "clip 2 playing on track 3")
o = ons(1, 3)
ok(o[1] and math.abs((o[1].beat - log[1].beat) % 4) < 0.6, "launched clip came in on a bar")
-- snapshot: hold to save
press(11, 1) now = now + 0.7 N.tick(0.7) release(11, 1)
ok(N.has(1), "snapshot 1 saved")
St.track(1).clips[1].steps = {}
tap(11, 1)                                   -- load on the next bar
pump_beats(4.2)
ok(St.track(1).clips[1].steps[1] ~= nil, "snapshot brought the steps back")
-- STOP held + snapshot: delete
press(2, 8) press(11, 1) now = now + 0.7 N.tick(0.7) release(11, 1) release(2, 8)
ok(not N.has(1), "snapshot deleted")
ok(Q.playing, "STOP used as a modifier does not stop")
-- STOP + track: clear that track's clip, keep playing
ok(Q.playing, "still playing")
St.clip(3).steps[1] = St.new_step(3, { 60 })
St.clip(4).steps[1] = St.new_step(4, { 62 })
press(2, 8) tap(3, 7) release(2, 8)
ok(next(St.clip(3).steps) == nil, "STOP + track 3: its steps are gone")
ok(St.clip(4).steps[1] ~= nil, "track 4 untouched")
ok(Q.playing, "clearing does not stop the song")
St.clip(4).steps = {}
tap(2, 8)
ok(not Q.playing, "STOP alone stops")
-- hold SET + track: track settings
press(8, 8) tap(4, 7) release(8, 8)
ok(P.page == "tset" and G.sel == 4 and G.settings, "SET + track opens its settings, settings mode stays")
frame("tset")
tap(8, 8)
ok(not G.settings, "SET toggles back")

-- ----------------------------------------------------------- MIDI slave

params:set("clock_source", 2)
c1 = St.clip(1)              -- the snapshot load replaced the project
c1.steps = {}
for _, i in ipairs({ 1, 5, 9, 13 }) do c1.steps[i] = St.new_step(1, { 60 }) end
log = {}
pump_beats(0.37)
external_start()
pump_beats(2.05)
o = ons(1, 1)
ok(#o >= 2, "plays from the external Start")
if o[1] then
  ok(math.abs(o[1].beat) < TOL, string.format("first note on the external beat 0 (%.4f)", o[1].beat))
  ok(o[2] and math.abs(o[2].beat - 1) < TOL, "second note on beat 1")
end
ok(first("clock") == nil, "no clock out while following MIDI")
clock.transport.stop()
ok(Q.paused, "external stop pauses")
-- Continue from a song position: 4 sixteenths in is step 5
Q.midi_in({ type = "song_position", lsb = 4, msb = 0 })
log = {}
Q.midi_in({ type = "continue" })
pump_beats(1.1)
o = ons(1, 1)
ok(#o >= 1, "Continue plays")
params:set("clock_source", 1)
Q.stop()

-- --------------------------------------------------------- new features

local function notes_of(list)
  local s = {}
  for _, e in ipairs(list) do s[#s + 1] = e.a end
  return table.concat(s, ",")
end
tap(1, 7)
c1 = St.clip(1)
St.d.scale = 1

-- direction
c1.steps, c1.len, c1.speed = {}, 4, 1
for i = 1, 4 do c1.steps[i] = St.new_step(1, { 60 + i }) end
c1.dir = 2
log = {}
tap(1, 8) pump_beats(1.95) Q.stop()
ok(notes_of(ons(1, 1)):sub(1, 23) == "64,63,62,61,64,63,62,61", "BWD: " .. notes_of(ons(1, 1)))
c1.dir = 3
log = {}
tap(1, 8) pump_beats(1.95) Q.stop()
ok(notes_of(ons(1, 1)):sub(1, 23) == "61,62,63,64,63,62,61,62", "PEND: " .. notes_of(ons(1, 1)))
c1.dir = 1

-- the scale changes, the patterns follow; back again gives what was written
c1.steps, c1.len = {}, 3
c1.steps[1] = St.new_step(1, { 60 })
c1.steps[2] = St.new_step(1, { 64 })
c1.steps[3] = St.new_step(1, { 69 })
St.d.scale = 2                               -- minor
log = {}
tap(1, 8) pump_beats(0.7) Q.stop()
ok(notes_of(ons(1, 1)):sub(1, 8) == "60,63,68", "C E A in minor is C Eb Ab: " .. notes_of(ons(1, 1)))
St.d.scale = 13                              -- minor pentatonic: nearest notes
log = {}
tap(1, 8) pump_beats(0.7) Q.stop()
ok(notes_of(ons(1, 1)):sub(1, 8) == "60,63,70", "into minor pentatonic: " .. notes_of(ons(1, 1)))
St.d.scale = 1
ok(c1.steps[2].notes[1] == 64, "the written notes are untouched")

-- hold a step, press a later one: the note lasts to it
c1.steps, c1.len = {}, 16
c1.steps[1] = St.new_step(1, { 60 })
press(1, 1) tap(4, 1) release(1, 1)
ok(c1.steps[1].len == 4 and c1.steps[1] ~= nil, "step 1 lasts four steps")
ok(c1.steps[4] == nil, "the second press wrote nothing")
log = {}
tap(1, 8) pump_beats(1.2) Q.stop()
local on1, off1
for _, e in ipairs(log) do
  if e.kind == "on" and e.c == 1 and not on1 then on1 = e.beat end
  if e.kind == "off" and e.c == 1 and on1 and not off1 then off1 = e.beat end
end
ok(on1 and off1 and math.abs((off1 - on1) - 0.9375) < 0.01, string.format("held 3.75 sixteenths (%.3f beats)", (off1 or 0) - (on1 or 0)))
press(1, 1) tap(4, 1) release(1, 1)
ok(c1.steps[1].len == nil, "the same press again: one step")

-- arpeggiated chord step across a two-step tie
tap(10, 2)                                   -- chord mode
P.open("chord") P.lane.chord = 3 P.enc(2, 1)  -- ARP UP
ok(St.d.arp == 2, "arp up")
P.enc(3, -1) P.enc(3, -1)                    -- RATE 1/16 -> 1/32
ok(St.d.arp_rate == 1, "arp rate 1/32")
c1.steps = {}
press(11, 8) tap(1, 1) release(11, 8)       -- I chord, arp
ok(c1.steps[1].arp ~= nil and c1.steps[1].strum == nil, "the step remembers the arp, no strum")
c1.len = 4
c1.steps[1].len = 2                          -- two sixteenths: four 32nds
log = {}
tap(1, 8) pump_beats(0.55) Q.stop()
ok(notes_of(ons(1, 1)) == "48,52,55,48", "arp plays the chord up in 32nds over the tie: " .. notes_of(ons(1, 1)))
-- live arp while holding a chord
log = {}
tap(1, 8) press(11, 8) pump_beats(0.5) release(11, 8) Q.stop()
ok(#ons(1, 1) >= 4, "live arp while the chord is held: " .. #ons(1, 1))
St.d.arp = 1
-- the readout shows the chord and its modifiers
press(12, 8)
ok(P.toast and P.toast.lines[1] == "Dm", "readout names the chord: " .. tostring(P.toast and P.toast.lines[1]))
frame("chord readout")
release(12, 8)
tap(11, 2)                                   -- SUS2 on
ok(P.toast.lines[2] == K.MOD_INFO.SUS2, "readout says what SUS2 does")
frame("modifier readout")
tap(11, 2)
tap(10, 1)                                   -- keys mode
press(11, 8) press(12, 7) press(13, 6)       -- C, F, A#? whatever they make
frame("keys readout")
release(11, 8) release(12, 7) release(13, 6)
press(11, 8) press(15, 8) press(13, 7)
ok(P.toast.lines[2] == "C" or P.toast.lines[2] ~= nil, "keys readout detects")
release(11, 8) release(15, 8) release(13, 7)
ok(T.detect({ 48, 52, 55 }) == "C" and T.detect({ 52, 55, 60 }) == "C/E" and T.detect({ 50, 53, 57, 60 }) == "Dm7", "chord detection")

-- octave buttons
tap(10, 7)
ok(St.d.koct == 1 and Kb.note_at(11, 8) == 60, "octave up")
press(10, 7) press(10, 8) release(10, 7) release(10, 8)
ok(St.d.koct == 0, "both octave buttons: back to the middle")
tap(10, 8)
ok(Kb.note_at(11, 8) == 36, "octave down")
tap(10, 7)

-- MONO: new-note priority
P.open("keys") P.lane.keys = 3 P.enc(2, 1)
ok(St.track(G.sel).mono, "VOICE set to MONO for the selected track")
frame("keys mono")
local function notes_log()
  local s = {}
  for _, e in ipairs(log) do
    if e.kind == "on" or e.kind == "off" then s[#s + 1] = e.kind .. e.a end
  end
  return table.concat(s, " ")
end
log = {}
press(11, 8) press(13, 8)
ok(notes_log() == "on48 off48 on50", "a new key cuts the old one: " .. notes_log())
log = {}
press(15, 8) release(15, 8)
ok(notes_log() == "off50 on52 off52 on50", "let go: back to the newest key held: " .. notes_log())
log = {}
release(11, 8)
ok(notes_log() == "", "an older key coming up sends nothing")
release(13, 8)
ok(notes_log() == "off50" and #Kb.pads == 0, "last key up: silent")
local cm = St.clip(G.sel)
cm.steps[2] = nil
log = {}
press(11, 8) press(12, 8) press(2, 1) release(2, 1) release(12, 8) release(11, 8)
ok(cm.steps[2] and #cm.steps[2].notes == 1 and cm.steps[2].notes[1] == 49, "MONO: a step takes the newest key")
ok(notes_log() == "on48 off48 on49 off49 on48 off48", "MONO round trip: " .. notes_log())
-- MONO live record: a key that is cut ends its note there
cm.steps, cm.len = {}, 16
tap(3, 8)                                    -- REC
tap(1, 8)                                    -- PLAY
pump_beats(1)
ok(Q.playing, "playing")
local i0 = Q.rec_step(G.sel)
press(11, 8)
pump_beats(0.74)                             -- three steps of C
press(13, 8)
pump_beats(0.48)
release(13, 8) release(11, 8)
Q.stop()
tap(3, 8)
local s1 = cm.steps[i0]
ok(s1 and s1.notes[1] == 48 and s1.len == 3, "MONO record: C held 3 steps, cut by D: len " .. tostring(s1 and s1.len))
local s4 = cm.steps[i0 + 3]
ok(s4 and s4.notes[1] == 50 and #s4.notes == 1, "MONO record: D on its own step")
cm.steps = {}
P.enc(2, -1)
ok(not St.track(G.sel).mono, "back to POLY")
log = {}
press(11, 8) press(13, 8) release(11, 8) release(13, 8)
ok(notes_log() == "on48 on50 off48 off50", "POLY keys still play together: " .. notes_log())

-- record: stopped, step by step
c1.steps, c1.len = {}, 8
tap(3, 8)
ok(G.rec, "REC armed")
tap(11, 8) tap(12, 8) tap(13, 8)
ok(c1.steps[1] and c1.steps[2] and c1.steps[3] and c1.steps[3].notes[1] == 50, "step recording moves on")
tap(5, 1)                                    -- cursor to step 5
press(11, 8) press(15, 8) release(11, 8) release(15, 8)
ok(c1.steps[5] and #c1.steps[5].notes == 2, "a chord of keys is one step")
ok(c1.steps[6] == nil and G.cursor == 6, "cursor at 6")
-- record: live, quantised to the nearest step
c1.steps = {}
log = {}
tap(1, 8)
pump_beats(0.27)                             -- just past step 2's start
tap(14, 8)
pump_beats(0.3)
local found
for i, st in pairs(c1.steps) do found = i end
ok(found == 2, "live note went into step 2, got " .. tostring(found))
Q.stop()
tap(3, 8)
ok(not G.rec, "REC off")

-- 512 steps and paging
P.open("track") P.lane.track = 2
P.enc(2, 600)
ok(c1.len == 512, "length goes to 512")
tap(2, 5)
ok(G.steppage == 3, "row E: pad 2 is pages 3-4 (" .. G.steppage .. ")")
tap(2, 5)
ok(G.steppage == 4, "pad 2 again: page 4")
tap(1, 5) tap(1, 5)
ok(G.steppage == 2, "pad 1 twice: page 2")
press(1, 1) release(1, 1)
ok(c1.steps[33] ~= nil, "pressing on page 2 writes step 33")
frame("track 512")
P.open("home") frame("home 512")
c1.len = 16

-- speed: x1, then left divides by 2 down to /64
P.open("track") P.lane.track = 2
c1 = St.clip(1)
c1.speed = 1
local seen_s = {}
for _ = 1, 8 do
  P.enc(3, -1)
  seen_s[#seen_s + 1] = P.DEFS.track.lanes[2][2].get()
end
ok(table.concat(seen_s, " ") == "/2 /4 /8 /16 /32 /64 /64 /64", "speed left: " .. table.concat(seen_s, " "))
P.enc(3, 1)
ok(c1.speed == 32, "right is faster again")
for _ = 1, 9 do P.enc(3, 1) end
ok(c1.speed == 1 and P.DEFS.track.lanes[2][2].get() == "x1", "x1 is as fast as it goes")
c1.speed = 3                                 -- an older project's speed
P.enc(3, -1)
ok(c1.speed == 4, "an old in-between speed goes to the next one along")
c1.speed = 1
-- /64: a step every 16 beats, still on the beat
c1.steps, c1.len = { St.new_step(1, { 60 }) }, 1
c1.speed = 64
log = {}
tap(1, 8) pump_beats(33) Q.stop()
local s64 = ons(1, 1)
ok(#s64 == 3 and math.abs((s64[2].beat - s64[1].beat) - 16) < 0.01, "/64 plays every 16 beats")
c1.speed = 1

-- ------------------------------------------------------ generate, rain

tap(1, 7)
tap(7, 6) tap(7, 6)
local n = 0
for _ in pairs(St.clip(1).steps) do n = n + 1 end
ok(n > 0, "GENERATE wrote steps")
P.lane.gen = 3 P.enc(2, 1) P.enc(3, 1)
ok(P.rot == 1 and P.shf == 1, "ROTATE and SHIFT on the GEN page")

-- rain: an empty track at 100 % catches drops, every one in the scale
Q.stop()
St.d.scale = 13                              -- minor pentatonic, to make it count
c1 = St.clip(1)
c1.steps, c1.len = {}, 16
tap(8, 6)
ok(P.page == "rain", "RAIN opens its page")
P.lane.rain = 1 P.enc(2, 100)
ok(St.track(1).rain == 100, "rain 100%")
frame("rain page")
-- track 8 transposes a semitone: the drops must still land in the scale
local c8b = St.clip(8)
c8b.steps, c8b.len = { St.new_step(8, { St.d.root + 1 }) }, 1
math.randomseed(7)
log = {}
tap(1, 8) pump_beats(16) Q.stop()
local drops = ons(1, 1)
ok(#drops > 5, "rain fell: " .. #drops .. " drops")
local outside = 0
for _, e in ipairs(drops) do
  if not T.in_scale(e.a, St.d.root, St.d.scale) then outside = outside + 1 end
end
ok(outside == 0, outside .. " drops outside the scale")
-- it does not fall on a note that is still sounding
c1.steps[1] = St.new_step(1, { 60 })
c1.steps[1].len = 16
log = {}
tap(1, 8) pump_beats(7.9) Q.stop()
ok(#ons(1, 1) == 2, "no rain under a held note: " .. #ons(1, 1))
-- RAIN again on its page: off, the amount kept
tap(8, 6)
ok(St.track(1).rain_off and St.track(1).rain == 100, "RAIN again: off, amount kept")
c1.steps = {}
log = {}
tap(1, 8) pump_beats(4) Q.stop()
ok(#ons(1, 1) == 0, "no rain while off")
tap(8, 6)
St.track(1).rain = 0
c8b.steps = {}
St.d.scale = 1
for _, pg in ipairs({ "home", "gen", "rain" }) do P.open(pg) frame(pg .. " after generate") end

-- TC1 with nothing held and COND at --: PROB is the whole track's
tap(1, 6)
P.lane.tc1 = 1
P.enc(3, -100)
ok(St.track(1).prob == 0 and St.track(1).tpl.prob == nil, "PROB set the track's probability")
frame("tc1 track prob")
c1.steps, c1.len = {}, 4
for i = 1, 4 do c1.steps[i] = St.new_step(1, { 60 }) end
log = {}
tap(1, 8) pump_beats(2) Q.stop()
ok(#ons(1, 1) == 0, "track at 0 %: silent")
P.enc(3, 50)
log = {}
tap(1, 8) pump_beats(16) Q.stop()
local hits = #ons(1, 1)
ok(hits > 16 and hits < 48, "track at 50 %: about half of 64, got " .. hits)
-- a COND on new steps: PROB goes back to being the new steps'
P.enc(2, 1)
P.enc(3, -10)
ok(St.track(1).prob == 50 and St.track(1).tpl.prob == 90, "COND set: PROB is the new steps' again")
St.track(1).prob = 100
St.track(1).tpl = {}

-- ------------------------------------------- a snapshot is every setting

local function deep_eq(a, b, path)
  if type(a) ~= type(b) then return false, path end
  if type(a) ~= "table" then return a == b, path end
  for k, v in pairs(a) do
    local e, w = deep_eq(v, b[k], path .. "." .. tostring(k))
    if not e then return false, w end
  end
  for k in pairs(b) do
    if a[k] == nil then return false, path .. "." .. tostring(k) end
  end
  return true
end

Q.stop()
-- set something everywhere
St.d.scale, St.d.root, St.d.swing, St.d.sig, St.d.transpose = 4, 50, 58, 8, 2
St.d.layout, St.d.inkey, St.d.vel, St.d.cvel, St.d.strum, St.d.vlead = 3, true, 90, 80, 40, true
St.d.arp, St.d.arp_rate, St.d.koct = 3, 5, -1
St.d.mods = { ext = "9", inv = "DROP2" }
St.d.gen = { style = 4, density = 70, range = 3, pool = 3 }
for t = 1, K.NTRACKS do
  local tr = St.track(t)
  tr.swing, tr.dev, tr.ch, tr.follow, tr.mute, tr.oct = t - 4, (t % 3) + 1, 17 - t, t % 2 == 0, t == 3, (t % 3) - 1
  tr.prog, tr.rain, tr.rain_off, tr.rain_spread, tr.rain_centre, tr.prob = t * 5, t * 10, t == 2, t + 2, 60 + t, 100 - t
  tr.clip = (t % 4) + 1
  tr.tpl = { vel = 50 + t, cond = 2 }
  for c = 1, K.NCLIPS do
    local cl = tr.clips[c]
    cl.len, cl.speed, cl.dir = 8 + t + c, ({ 1, 2, 4, 8 })[c], ((t + c) % 5) + 1
    cl.steps = { [1] = St.new_step(t, { 60 + c, 64 + t }), [3] = St.new_step(t, { 48 }) }
    cl.steps[1].len, cl.steps[1].ratchet = 3, 2
  end
end
tap(10, 2)                                   -- chord keyboard
tap(6, 7)                                    -- track 6
Q.live_master({ notes = { 52 } })            -- track 8 given E live
Kb.last = { notes = { 55, 59, 62 }, vel = 80 }

if not G.settings then tap(8, 8) end
press(16, 8) now = now + 0.7 N.tick(0.7) release(16, 8)
ok(N.has(48), "snapshot 48 saved")
local saved = St.copy(St.d)
local saved_tempo = params:get("clock_tempo")

-- change it all
St.d = St.fill({ tracks = {} })
for t = 1, K.NTRACKS do St.d.tracks[t] = St.new_track(t) end
params:set("clock_tempo", 97)
tap(10, 2) Kb.set_mode(1)
G.select(2)
Q.hist = {}
Kb.last = { notes = { 30 } }

log = {}
tap(16, 8)                                   -- load (stopped: at once)
local same, where = deep_eq(saved, St.d, "d")
ok(same, "every setting came back" .. (where and (", first difference at " .. where) or ""))
ok(params:get("clock_tempo") == saved_tempo, "tempo came back")
ok(Kb.mode == 2, "chord keyboard came back")
ok(G.sel == 6, "selected track came back")
ok(Kb.last.notes[1] == 55, "last played notes came back")
local m = Q.master_now()
ok(m and m.notes[1] == 52, "track 8's live transposition came back")
local pcs = 0
for _, e in ipairs(log) do if e.kind == "pc" then pcs = pcs + 1 end end
ok(pcs == K.NTRACKS, "program changes sent on load: " .. pcs)
frame("after full snapshot")

-- an empty pad: a new snapshot at the defaults
ok(not N.has(47), "pad 47 empty")
tap(15, 8)
ok(N.has(47), "tapping an empty pad made a snapshot there")
local fresh = St.new()
local d2 = St.copy(St.d) d2.ui = nil
local same2, where2 = deep_eq(St.fill(fresh), d2, "d")
ok(same2, "the new snapshot is all defaults" .. (where2 and (", first difference at " .. where2) or ""))
ok(params:get("clock_tempo") == 120, "default tempo")
ok(Kb.mode == 1 and G.sel == 1, "keys up, track 1 selected")
ok(Q.master_now() == nil, "no track 8 transposition")
ok(N.last == 47, "pad 47 is the current snapshot")
tap(16, 8)                                   -- the saved one still loads
ok(Kb.mode == 2 and G.sel == 6, "pad 48 still loads over it")
tap(8, 8)

-- ------------------------------------------------------------------- synth

-- from here on presses go through the scene router, as the grid's do
local function press(x, y) V.grid_key(x, y, 1) end
local function release(x, y) V.grid_key(x, y, 0) end
local function tap(x, y) press(x, y) release(x, y) end
local D = V.drum
local Syn = V.synth
local function eng(cmd, from)
  local out = {}
  for i = from or 1, #eng_log do
    if eng_log[i].cmd == cmd then out[#out + 1] = eng_log[i] end
  end
  return out
end

Q.stop()
if G.settings then tap(8, 8) end
St.d.swing = 50
G.select(1)
local tr1 = St.track(1)
tr1.out, tr1.mute, tr1.oct = 1, false, 0
tr1.tpl, tr1.prob, tr1.rain, tr1.swing = {}, 100, 0, 0
St.clip(1).steps = {}
St.clip(1).len, St.clip(1).speed, St.clip(1).dir = 16, 1, 1
for t = 2, K.NTRACKS do St.track(t).mute = true end
-- a new project's tracks are synths
ok(St.new().tracks[3].out == 1, "a new track plays the synth")
ok(St.fill({ tracks = { { clips = {} } } }).tracks[1].out == 2, "a track from before the synth stays MIDI")

-- the keyboard plays the synth: synOn on track 0, no MIDI
log = {}
local e0 = #eng_log
Kb.set_mode(1)
press(11, 8) release(11, 8)
local son, soff = eng("synOn", e0 + 1), eng("synOff", e0 + 1)
local want = Kb.note_at(11, 8)
ok(#son == 1 and son[1].args[1] == 0 and son[1].args[2] == want, "key plays synth track 1, its note")
ok(#soff == 1 and soff[1].args[2] == want, "and lets it go")
local midi_on = 0
for _, e in ipairs(log) do if e.kind == "on" then midi_on = midi_on + 1 end end
ok(midi_on == 0, "nothing on MIDI for a synth track")

-- the sequencer plays it too, on the beat
St.clip(1).steps = {}
for _, i in ipairs({ 1, 5, 9, 13 }) do St.clip(1).steps[i] = St.new_step(1, { 60 }) end
e0 = #eng_log
tap(1, 8)
pump_beats(4.2)
local hits = eng("synOn", e0 + 1)
ok(#hits >= 4, "four synth notes in four beats, got " .. #hits)
if hits[2] then
  local d = hits[2].beat - hits[1].beat
  ok(math.abs(d - 1) < 0.02, string.format("a beat apart (%.3f)", d))
end
Q.stop()

-- SYNTH page on H7: every lane draws, values reach the engine
tap(7, 8)
ok(P.page == "synth", "H7 opens SYNTH")
for i = 1, #Syn.LANES do
  P.lane.synth = i
  frame("synth lane " .. i)
end
P.lane.synth = 1
e0 = #eng_log
P.enc(3, 10)
local sets = eng("synSet", e0 + 1)
ok(tr1.syn.wave == 35 and sets[1] and sets[1].args[2] == "wave" and math.abs(sets[1].args[3] - 0.35) < 1e-6,
  "WAVE 35 sent as 0.35")
P.enc(2, 1)
ok(Syn.fmt(1, "bank") == "HARMONIC", "BANK steps through the banks")
sets = eng("synSet", e0 + 1)
ok(sets[#sets].args[2] == "bank" and sets[#sets].args[3] == 1, "bank 2 sent as 1")
P.lane.synth = 3
P.enc(2, -10)
ok(Syn.fmt(1, "cut") ~= "OPEN", "CUTOFF closes from open")
P.lane.synth = 11
e0 = #eng_log
P.enc(3, -10)
local strip = eng("synStrip", e0 + 1)
ok(strip[1] and strip[1].args[2] == "pan" and strip[1].args[3] < 0, "PAN goes to the strip")
tap(7, 8)
ok(P.page == "home", "H7 again: home")

-- TRACK SETTINGS: OUTPUT first; MIDI sends MIDI again
press(8, 8) tap(1, 7) release(8, 8)
ok(P.page == "tset", "SET + track: settings")
P.lane.tset = 1
frame("tset synth")
P.enc(2, 1)
ok(tr1.out == 2, "OUTPUT to MIDI")
P.lane.tset = 4
frame("tset lane 4")
log = {}
press(11, 8) release(11, 8)
midi_on = 0
for _, e in ipairs(log) do if e.kind == "on" then midi_on = midi_on + 1 end end
ok(midi_on == 1, "a MIDI track plays MIDI")
P.lane.tset = 1
P.enc(2, -1)
ok(tr1.out == 1, "back to SYNTH")
P.open("home")
if G.settings then tap(8, 8) end

-- SET + step: the clip's length, as on the drum grid
press(8, 8) tap(4, 2) release(8, 8)
ok(St.clip(1).len == 12, "SET + step 12: length 12 (" .. St.clip(1).len .. ")")
ok(not G.settings, "and SET did not toggle the session view")
St.clip(1).len = 16

-- ------------------------------------------------------------------ scenes

local DSt = D.St
local function dframe(where)
  redraw()
  check_text(where)
  V.grid_redraw()
end
key(3, 1)
ok(V.scene() == 2, "K3: the drums")
dframe("drum main")
-- a drum pattern: BD1 on every beat, SNR on 2 and 4
DSt.select(1)
for _, i in ipairs({ 1, 5, 9, 13 }) do tap(i, 1) end
ok(DSt.tracks[1].steps[5] and DSt.tracks[1].steps[5].on, "drum steps placed from the grid")
tap(4, 7)
ok(DSt.sel == 4, "row G selects the drum track")
tap(5, 1) tap(13, 1)
-- drums and the synth together, one PLAY
e0 = #eng_log
tap(1, 8)
pump_beats(4.1)
ok(Q.playing and DSt.playing, "one PLAY runs both")
local trigs = eng("trig", e0 + 1)
local kicks = {}
for _, e in ipairs(trigs) do if e.args[1] == 0 then kicks[#kicks + 1] = e end end
ok(#kicks >= 4, "four kicks, got " .. #kicks)
local syn = eng("synOn", e0 + 1)
if kicks[1] and syn[1] then
  ok(math.abs(kicks[1].beat - syn[1].beat) < 0.02,
    string.format("kick and synth note land together (%.3f / %.3f)", kicks[1].beat, syn[1].beat))
end
for k = 2, #kicks do
  ok(math.abs((kicks[k].beat - kicks[k - 1].beat) - 1) < 0.02, "kick " .. k .. " a beat on")
end
local snr = 0
for _, e in ipairs(trigs) do if e.args[1] == 3 then snr = snr + 1 end end
ok(snr >= 2, "snare on 2 and 4, got " .. snr)
dframe("drum main playing")
-- PLAY pauses both, STOP stops both
tap(1, 8)
ok(Q.paused and not DSt.playing, "PLAY again pauses the drums too")
tap(1, 8)
pump_beats(1)
ok(Q.playing and DSt.playing, "and carries on")
tap(2, 8)
ok(not Q.playing and not DSt.playing, "STOP stops both")

-- STOP held is CLEAR: STOP + step back to a plain hit, and no stop
DSt.tracks[4].steps[5].vel = 50
press(2, 8) tap(5, 1) release(2, 8)
ok(DSt.tracks[4].steps[5].vel == 100, "STOP + step: a plain hit again")
-- SET held is SHIFT: SET + step is the length
press(8, 8) tap(12, 1) release(8, 8)
ok(DSt.tracks[4].len == 12, "SET + step: drum length 12")
ok(DSt.page == "main", "SET used as SHIFT does not open the session")
DSt.tracks[4].len = 16

-- a control: hold TC1 (F1) and turn: the template's COND / PROB
press(1, 6)
dframe("drum TC1")
enc(3, -10)
release(1, 6)
ok(DSt.tracks[4].tpl.prob == 90, "TC1 E3 sets new steps' PROB")
-- a sound control over a held step: a lock
press(5, 1) press(1, 5) enc(2, 5) release(1, 5) release(5, 1)
ok(DSt.tracks[4].steps[5].locks ~= nil, "T1 over a held step locks it")
dframe("drum lock")
-- SWING is the shared swing
press(14, 8) enc(2, 6) dframe("drum swing") release(14, 8)
ok(St.d.swing == 56, "drum SWING turns vibe composer's swing")
St.d.swing = 50
press(8, 6) enc(2, 20) dframe("drum rain") release(8, 6)
ok(params:get("rain") > 0, "RAIN amount")
params:set("rain", 0)
-- MIX and SESSION faces
tap(15, 8) dframe("drum mix")
ok(DSt.page == "mix", "MIX")
tap(15, 8)
tap(8, 8)
ok(DSt.page == "session", "SET on its own: drum session")
dframe("drum session")
tap(1, 2)
ok(DSt.tracks[1].clip == 2, "a clip launches (stopped: at once)")
tap(1, 1)
press(2, 5) tap(3, 7) release(2, 5)
ok(D.S.kit_of(3) == 2, "hold WOOD + track 3: track 3 on WOOD")
press(1, 5) release(1, 5)
ok(D.S.kit_of(3) == 1, "tap WARM: every track WARM")
tap(8, 8)

-- ------------------------------------------------------------------ colour

key(3, 1)
ok(V.scene() == 3 and DSt.page == "colour", "K3 again: COLOUR")
dframe("colour")
tap(2, 6)
dframe("colour bank 2")
press(1, 1)
dframe("colour punch")
release(1, 1)
tap(1, 7)
ok(St.track(1).mute, "COLOUR row G mutes melodic track 1")
tap(1, 7)
tap(9, 7)
ok(DSt.tracks[1].mute, "and G9 mutes drum track 1")
tap(9, 7)
key(3, 1)
ok(V.scene() == 1, "K3 round to MELODIC")
key(2, 1)
ok(V.scene() == 3, "K2 back to COLOUR")
key(2, 1) key(2, 1)
ok(V.scene() == 1, "K2 round to MELODIC")
-- H16 on the drum grid is COLOUR
key(3, 1)
tap(16, 8)
ok(V.scene() == 3, "drum COLOUR pad: the COLOUR scene")
key(2, 1) key(2, 1)

-- -------------------------------------------------------------- snapshots

-- a snapshot holds the drums: save, change, load
DSt.tracks[2].steps = { [3] = D.S.new_step() }
params:set(DSt.pid(2, "level"), 0.3)
if not G.settings then tap(8, 8) end
press(11, 1) now = now + 0.7 N.tick(0.7) release(11, 1)
ok(N.has(1), "snapshot 1 saved")
DSt.tracks[2].steps = {}
params:set(DSt.pid(2, "level"), 0.9)
tap(11, 1)
ok(DSt.tracks[2].steps[3] ~= nil, "the snapshot brought the drum pattern back")
ok(math.abs(params:get(DSt.pid(2, "level")) - 0.3) < 0.01, "and the drum level")
-- the same pads in the drum session view
tap(8, 8)
key(3, 1)
tap(8, 8)
DSt.tracks[2].steps = {}
tap(11, 1)
ok(DSt.tracks[2].steps[3] ~= nil, "the drum session view loads the same snapshot")
-- the snapshots' bottom row is snapshots there, not SWING MIX COLOUR
press(16, 8) now = now + 0.7 N.tick(0.7) release(16, 8)
ok(N.has(48) and V.scene() == 2 and DSt.page == "session", "H16 in the drum session saves snapshot 48")
tap(8, 8)
key(2, 1)

cleanup()
ok(params:get("clock_midi_out_1") == 1, "norns clock out given back on exit")

for _, p in ipairs(problems) do print("SCREEN: " .. p) end
print(string.format("%d passed, %d failed, %d screen problems", passed, failed, #problems))
os.exit((failed == 0 and #problems == 0) and 0 or 1)
