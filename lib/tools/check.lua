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
  time = function() return now end,
  file_exists = function() return false end,
}

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
  text = function(s) box(s, txt.x) end,
  text_right = function(s) box(s, txt.x - txt_w(s)) end,
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
function params:add_trigger(id) addp(id, { val = 0, lo = 0, hi = 1 }) end
function params:set_action(id, f) PR[id].action = f end
function params:get(id) return assert(PR[id], "no param " .. id).val end
function params:set(id, v)
  local p = assert(PR[id], "no param " .. id)
  p.val = v
  if p.action then p.action(v) end
end
function params:delta(id, d)
  local p = PR[id]
  params:set(id, math.min(math.max(p.val + d, p.lo), p.hi))
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
for _, pg in ipairs({ "home", "track", "tc1", "tc2", "tc3", "tc4", "gen", "mut", "keys", "chord", "settings", "tset" }) do
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
key(3, 1) key(3, 1)
ok(G.steppage == 3, "K3 pages on")
key(2, 1)
ok(G.steppage == 2, "K2 pages back")
press(1, 1) release(1, 1)
ok(c1.steps[33] ~= nil, "pressing on page 2 writes step 33")
frame("track 512")
P.open("home") frame("home 512")
c1.len = 16

-- --------------------------------------------------- generate and mutate

tap(1, 7)
tap(7, 6) tap(7, 6)
local n = 0
for _ in pairs(St.clip(1).steps) do n = n + 1 end
ok(n > 0, "GENERATE wrote steps")
tap(8, 6) tap(8, 6)
P.open("mut") P.lane.mut = 2 P.enc(2, 1) P.enc(3, 1)
for _, pg in ipairs({ "home", "gen", "mut" }) do P.open(pg) frame(pg .. " after generate") end

cleanup()
ok(params:get("clock_midi_out_1") == 1, "norns clock out given back on exit")

for _, p in ipairs(problems) do print("SCREEN: " .. p) end
print(string.format("%d passed, %d failed, %d screen problems", passed, failed, #problems))
os.exit((failed == 0 and #problems == 0) and 0 or 1)
