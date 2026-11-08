-- vibecomposer / seq
--
-- Eight MIDI tracks on one clock.
--
-- ONE COROUTINE, 24 TICKS A BEAT. Everything runs from a single coroutine
-- that wakes on every MIDI clock tick of norns' clock (clock.sync(1/24)).
-- norns counts each sync from the previous target, not from "now", so the
-- ticks never drift and are never skipped, however late lua gets to them:
-- a late wake just runs the missed ticks back to back. On each tick the
-- coroutine, in this order,
--
--   1. sends MIDI Start / Continue if one is due on this tick, then the
--      0xF8 clock tick itself (see lib/midiout)
--   2. starts the song if PLAY is waiting for this tick
--   3. lets every track prepare the pulses coming up (below)
--   4. sends every note on / off due on this tick
--
-- so our beat 1 and a slave's beat 1 are the same tick, and with MIDI as the
-- clock source the ticks ARE the incoming ticks.
--
-- Time is counted in ticks from the song's start (Q.t). An event that falls
-- between two ticks (swing, micro timing, ratchets, strums) is sent from the
-- tick before it, after a sleep of the fraction that is left; nothing else
-- uses wall-clock time.
--
-- ONE PULSE AHEAD. Each track prepares a pulse half a step before its line,
-- which is the room negative micro timing needs. Track 8 prepares as far
-- ahead as the slowest track, so what it plays is known before any other
-- track's note on its line goes out.
--
-- TRACK 8. When one of its steps plays, what it played is written into a
-- history at that step's line. A following track looks its note up in the
-- history at its own line when the note is SENT, not when it was prepared,
-- so every track follows the chord that is actually under it.

local K = include("lib/const")
local T = include("lib/theory")

local Q = {}
local St, O

Q.playing = false
Q.paused = false
Q.origin = 0         -- the absolute tick (norns beats x 24) of song tick 0
Q.last_abs = nil     -- the last absolute tick handled
Q.t = -1             -- the last song tick processed
Q.pause_t = -1       -- where a pause left off
Q.gen = 0            -- bumped on every start / pause / stop
Q.events = {}        -- sorted by time: { at, pri, kind, ... }
Q.hist = {}          -- track 8, sorted: { t, m }
Q.fill = false
Q.start_abs = nil    -- send MIDI Start just before this absolute tick
Q.cont_abs = nil     -- send MIDI Continue just before this absolute tick
Q.join_abs = nil     -- start playing on this absolute tick ...
Q.join_t = 0         -- ... from this song tick
Q.pending = nil      -- a snapshot waiting for its bar: { at, fn }
Q.ext_spp = 0        -- the last song position pointer heard
Q.rt = {}            -- per track, what is playing (not saved)
Q.dirty = true

local ORDER = { K.MASTER }
for t = 1, K.NTRACKS do
  if t ~= K.MASTER then ORDER[#ORDER + 1] = t end
end

local INTERNAL, MIDI, LINK = 1, 2, 3

local function clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end

local function source()
  local ok, v = pcall(function() return params:get("clock_source") end)
  return ok and v or INTERNAL
end
Q.source = source

local function link_sync()
  local ok, v = pcall(function() return params:get("link_start_stop_sync") end)
  return ok and v == 2
end

local function div(t) return St.clip(t).speed * K.T16 end
local function la(t) return div(t) / 2 end

function Q.la_max()
  local m = 0
  for t = 1, K.NTRACKS do m = math.max(m, la(t)) end
  return m
end

function Q.bar_ticks() return K.bar_steps(St.d.sig) * K.T16 end

-- the first bar line after song tick `after`
function Q.next_bar(after)
  local bar = Q.bar_ticks()
  return (math.floor(after / bar) + 1) * bar
end

function Q.abs_now() return math.floor((clock.get_beats() * K.PPQ) + 0.5) end

-- ----------------------------------------------------------------- tracks

function Q.reset_track(t, line)
  local rt = Q.rt[t]
  rt.pos, rt.pulse, rt.npulses, rt.loop = 0, 1, 1, 0
  rt.pass, rt.pre, rt.k = false, false, 0
  rt.pdir, rt.count = 1, 0
  rt.accs, rt.acc_off = {}, 0
  rt.next_line = line or 0
  rt.ph = 0
end

function Q.reset_tracks()
  for t = 1, K.NTRACKS do Q.reset_track(t, 0) end
  Q.dirty = true
end

function Q.init(state, out)
  St, O = state, out
  for t = 1, K.NTRACKS do
    Q.rt[t] = { flash = 0, last = nil, queued = nil, sounding = {} }
  end
  Q.reset_tracks()
end

-- DIRECTION. One pass of the pattern (what A:B and 1ST count) is a lap for
-- FWD and BWD, there and back for PEND, and LENGTH steps for WALK and RND.
local function step_once(rt, c)
  local len = c.len
  local d = K.DIRS[c.dir or 1] or "FWD"
  local pos = math.min(rt.pos, len)
  if d == "BWD" then
    if pos <= 1 then
      if rt.pos ~= 0 then rt.loop = rt.loop + 1 end
      return len
    end
    return pos - 1
  elseif d == "PEND" then
    if pos == 0 then
      rt.pdir = 1
      return 1
    end
    if len <= 1 then
      rt.loop = rt.loop + 1
      return 1
    end
    local n = pos + rt.pdir
    if n > len then
      rt.pdir = -1
      n = len - 1
    elseif n < 1 then
      rt.pdir = 1
      n = 2
    end
    if n == 1 then rt.loop = rt.loop + 1 end
    return n
  elseif d == "WALK" or d == "RND" then
    local n
    if pos == 0 then n = (d == "RND") and math.random(len) or 1
    elseif d == "RND" then n = math.random(len)
    else
      local r = math.random()
      n = pos + ((r < 0.5) and 1 or ((r < 0.75) and -1 or 0))
      if n > len then n = 1 elseif n < 1 then n = len end
    end
    if pos ~= 0 then
      rt.count = rt.count + 1
      if rt.count >= len then
        rt.count = 0
        rt.loop = rt.loop + 1
      end
    end
    return n
  end
  if pos + 1 > len then
    if rt.pos ~= 0 then rt.loop = rt.loop + 1 end
    return 1
  end
  return pos + 1
end

-- the next step: skipped steps take no time
local function next_pos(rt, c)
  local p = rt.pos
  for _ = 1, c.len do
    p = step_once(rt, c)
    rt.pos = p
    if St.get(c.steps[p], "skip") == 0 then return p end
  end
  return p
end

-- --------------------------------------------------------------- conditions
--
-- Elektron's set. A:B is true on the A-th of every B passes of the
-- pattern. PRE is whether this track's last condition passed, NEI the same
-- for the track to the left (track 1 looks at track 8). PRE and NEI do not
-- themselves count as the last condition.

function Q.cond(t, rt, st)
  local c = K.CONDS[St.get(st, "cond")] or "--"
  local res
  if c == "--" then res = true
  elseif c == "FILL" then res = Q.fill
  elseif c == "!FILL" then res = not Q.fill
  elseif c == "PRE" then res = rt.pre
  elseif c == "!PRE" then res = not rt.pre
  elseif c == "NEI" or c == "!NEI" then
    res = Q.rt[(t == 1) and K.NTRACKS or (t - 1)].pre
    if c == "!NEI" then res = not res end
  elseif c == "1ST" then res = (rt.loop == 0)
  elseif c == "!1ST" then res = (rt.loop ~= 0)
  else
    local a, b = c:match("^(%d):(%d)$")
    a, b = tonumber(a), tonumber(b)
    res = (rt.loop % b) == (a - 1)
  end
  local prob = St.get(st, "prob")
  if res and prob < 100 then res = math.random(100) <= prob end
  if c ~= "PRE" and c ~= "!PRE" and c ~= "NEI" and c ~= "!NEI" then rt.pre = res end
  return res
end

-- ------------------------------------------------------------------ events

local PRI = { [0] = 0, [2] = 1, [1] = 2 }  -- offs, then playheads, then ons

local function push(e)
  e.pri = PRI[e.kind]
  local ev = Q.events
  local i = #ev
  while i >= 1 and (ev[i].at > e.at or (ev[i].at == e.at and ev[i].pri > e.pri)) do i = i - 1 end
  table.insert(ev, i + 1, e)
end

-- drop the note ons (not the offs: a note may already be sounding) of
-- track t (or every track) on lines from `at` on
function Q.cancel_from(t, at)
  local keep = {}
  for _, e in ipairs(Q.events) do
    local tt = e.t or (e.rec and e.rec.t)
    local line = e.line or (e.rec and e.rec.line) or 0
    if e.kind == 0 or line < at or (t and tt ~= t) then keep[#keep + 1] = e end
  end
  Q.events = keep
end

-- ------------------------------------------------------------------ master

function Q.set_master(line, m)
  local h = Q.hist
  local i = #h
  while i >= 1 and h[i].t > line do i = i - 1 end
  table.insert(h, i + 1, { t = line, m = m })
end

function Q.master_at(line)
  local h = Q.hist
  for i = #h, 1, -1 do
    if h[i].t <= line then return h[i].m end
  end
  return nil
end

function Q.master_now()
  if Q.playing then return Q.master_at(Q.t) end
  local h = Q.hist
  return h[#h] and h[#h].m
end

-- the keyboard, played live on track 8
function Q.live_master(m)
  if Q.playing then
    -- whatever track 8 already prepared after now still lands after it
    Q.set_master(Q.t, m)
  else
    Q.hist = { { t = -1e9, m = m } }
  end
  Q.dirty = true
end

local function prune_hist(t)
  local h = Q.hist
  local last
  for i = #h, 1, -1 do
    if h[i].t <= t then last = i break end
  end
  if last and last > 1 then
    for _ = 1, last - 1 do table.remove(h, 1) end
  end
end

-- a step's notes as they play: in the key's scale now, plus the step's
-- octave and its accumulator
local function step_notes(st, acc)
  local add = (St.get(st, "oct") * 12) + acc
  local out = {}
  for i, n in ipairs(St.notes(st)) do out[i] = n + add end
  return out
end

-- the note that goes out: track 8's transposition or chord, then the
-- track's own octave
function Q.final(t, n, line)
  local tr = St.track(t)
  if t ~= K.MASTER and tr.follow then
    local m = Q.master_at(line)
    if m then n = T.follow(n, m, St.d) end
  end
  return clamp(n + (tr.oct * 12), 0, 127)
end

-- ----------------------------------------------------------------- prepare

-- track t's pulse on song tick L. Silent: only move the track on (a locate).
local function prepare(t, L, silent)
  local tr, rt, c = St.track(t), Q.rt[t], St.clip(t)
  local dv = c.speed * K.T16

  if rt.pulse < rt.npulses then
    rt.pulse = rt.pulse + 1
  else
    rt.pulse = 1
    rt.pos = next_pos(rt, c)
    local s = c.steps[rt.pos]
    rt.npulses = St.has_notes(s) and St.get(s, "pulses") or 1
  end
  local k = rt.k
  rt.k = k + 1
  local pos, st = rt.pos, c.steps[rt.pos]

  -- MPC swing: every second step of the pair lands late by the swing
  local at = L
  if k % 2 == 1 then
    local s = clamp(St.d.swing + tr.swing, 50, 75) / 100
    at = L + ((s - 0.5) * 2 * dv)
  end
  if not silent then push({ at = at, kind = 2, t = t, line = L, pos = pos }) end
  if not St.has_notes(st) then return end

  local n, p = rt.npulses, rt.pulse
  if p == 1 then
    rt.pass = Q.cond(t, rt, st)
    if rt.pass then
      local cnt = rt.accs[pos] or 0
      rt.accs[pos] = cnt + 1
      rt.acc_off = St.get(st, "acc") * (cnt % math.max(1, St.get(st, "limit")))
      if t == K.MASTER then
        Q.set_master(L, { notes = step_notes(st, rt.acc_off) })
      end
    end
  end
  if silent or not rt.pass then return end

  local mode = K.MODES[St.get(st, "mode")] or "REPEAT"
  local sound = (mode == "REPEAT") or (p == 1 and (mode == "HOLD" or mode == "SINGLE"))
  if not sound then return end

  local span = (mode == "HOLD") and (dv * n) or dv
  local frac = (n > 1) and ((p - 1) / (n - 1)) or 0
  local ramp = St.get(st, "ramp") / 100
  local vf = (ramp >= 0) and ((1 - ramp) + (ramp * frac)) or (1 + (ramp * frac))
  local micro = (St.get(st, "micro") / 100) * dv
  local r = St.get(st, "ratchet")
  local rf = St.get(st, "rfade") / 100
  local gate = St.get(st, "gate") / 100
  local slide = St.get(st, "slide") == 1
  local base = St.get(st, "vel")
  local notes = step_notes(st, rt.acc_off)
  local tie = st.len or 1

  -- an arpeggio across the step (and across its tie, if it has one)
  if st.arp and #notes > 1 then
    local rate = (K.ARP_RATES[st.arp.rate] or K.ARP_RATES[3]).t
    local order = T.arp_order(notes, st.arp.mode)
    local dur = (tie > 1) and (tie * dv) or span
    local j = 0
    while (j * rate) < dur - 1e-6 do
      local note = (st.arp.mode == 5) and order[math.random(#order)] or order[(j % #order) + 1]
      local o = math.max(at + micro + (j * rate), Q.t)
      local rec = { t = t, line = L, note = note, vel = clamp(math.floor((base * vf) + 0.5), 1, 127) }
      push({ at = o, kind = 1, rec = rec })
      push({ at = o + math.max(0.2, rate * gate), kind = 0, rec = rec })
      j = j + 1
    end
    return
  end

  -- strum: the chord's notes one after another, up, down or shuffled
  local gap = 0
  if st.strum and #notes > 1 and (st.strum.ms or 0) > 0 then
    gap = (st.strum.ms / 1000) * K.PPQ / clock.get_beat_sec()
    if st.strum.dir == 2 then
      local rev = {}
      for i = #notes, 1, -1 do rev[#rev + 1] = notes[i] end
      notes = rev
    elseif st.strum.dir == 3 then
      for i = #notes, 2, -1 do
        local j = math.random(i)
        notes[i], notes[j] = notes[j], notes[i]
      end
    end
  end

  local sub = span / r
  for i = 0, r - 1 do
    local rfrac = (r > 1) and (i / (r - 1)) or 0
    local vr = (rf >= 0) and (1 - (rf * rfrac)) or (1 + (rf * (1 - rfrac)))
    local vel = clamp(math.floor((base * vf * vr) + 0.5), 1, 127)
    local on = math.max(at + micro + (i * sub), Q.t)
    local len
    if tie > 1 and r == 1 then
      -- held over steps (hold a step, press a later one)
      len = ((tie - 1) * dv) + (slide and (dv + 0.5) or (dv * gate))
    elseif slide and i == r - 1 then
      len = (span - (i * sub)) + 0.5   -- past the next note on: legato
    else
      len = math.max(0.2, sub * gate)
    end
    for j, note in ipairs(notes) do
      local o = on + ((j - 1) * gap)
      local rec = { t = t, line = L, note = note, vel = vel }
      push({ at = o, kind = 1, rec = rec })
      push({ at = math.max(o + 0.2, on + len), kind = 0, rec = rec })
    end
  end
end

-- ------------------------------------------------------------------- fire

local function fire(e)
  if e.kind == 2 then
    Q.rt[e.t].ph = e.pos
    Q.rt[e.t].ph_line = e.line
    Q.dirty = true
  elseif e.kind == 1 then
    local rec = e.rec
    local tr, rt = St.track(rec.t), Q.rt[rec.t]
    local n = Q.final(rec.t, rec.note, rec.line)
    rt.flash = util.time()
    rt.sounding[n] = (rt.sounding[n] or 0) + 1
    rec.sent = n
    if not tr.mute then
      rec.k, rec.tok = O.on(tr.dev, tr.ch, n, rec.vel)
    end
    -- what the screen shows: the notes of the latest line
    if rt.last_line ~= rec.line or not rt.last then rt.last = {} end
    rt.last_line = rec.line
    local seen = false
    for _, v in ipairs(rt.last) do seen = seen or (v == n) end
    if not seen then rt.last[#rt.last + 1] = n end
    Q.dirty = true
  else
    local rec = e.rec
    if rec.sent then
      local rt = Q.rt[rec.t]
      local c = (rt.sounding[rec.sent] or 1) - 1
      rt.sounding[rec.sent] = (c > 0) and c or nil
      rec.sent = nil
    end
    if rec.k then O.off(rec.k, rec.tok) end
  end
end

-- ---------------------------------------------------------------- process

function Q.process(t)
  Q.t = t

  -- a snapshot due on a bar: every track from step 1 there
  local p = Q.pending
  if p and t >= p.at - Q.la_max() then
    Q.pending = nil
    p.fn()
    Q.cancel_from(nil, p.at)
    for i = 1, K.NTRACKS do
      Q.rt[i].queued = nil
      Q.reset_track(i, math.max(p.at, t))
    end
  end

  local lmax = Q.la_max()
  for _, i in ipairs(ORDER) do
    local rt = Q.rt[i]
    -- a clip launched for a bar: in, from its step 1, on that bar
    local q = rt.queued
    if q then
      local nc = St.track(i).clips[q.c]
      local lq = math.max(la(i), nc and (nc.speed * K.T16 / 2) or 0)
      if t >= q.at - lq then
        rt.queued = nil
        St.track(i).clip = q.c
        Q.cancel_from(i, q.at)
        Q.reset_track(i, math.max(q.at, t))
      end
    end
    local ahead = (i == K.MASTER) and lmax or la(i)
    local guard = 0
    while rt.next_line - ahead <= t and guard < 64 do
      local L = rt.next_line
      prepare(i, L)
      rt.next_line = L + div(i)
      guard = guard + 1
    end
  end

  local g = Q.gen
  while Q.events[1] and Q.events[1].at < t + 1 - 1e-9 do
    local e = table.remove(Q.events, 1)
    local dt = e.at - t
    if dt <= 0.01 then
      fire(e)
    else
      clock.run(function()
        clock.sleep(dt * clock.get_beat_sec() / K.PPQ)
        if g == Q.gen then fire(e) end
      end)
    end
  end

  if t % K.PPQ == 0 then prune_hist(t) end
end

-- ------------------------------------------------------------------ clock

function Q.tick_abs(x)
  if source() ~= MIDI and O.any_clock() then
    if Q.start_abs == x then O.start() end
    if Q.cont_abs == x then O.continue() end
    O.tick()
  end
  if Q.start_abs and x >= Q.start_abs then Q.start_abs = nil end
  if Q.cont_abs and x >= Q.cont_abs then Q.cont_abs = nil end
  if Q.join_abs and x >= Q.join_abs then
    Q.join_abs = nil
    Q.begin(x, Q.join_t)
  end
  if Q.playing then
    local t = x - Q.origin
    if t > Q.t then Q.process(t) end
  end
  if Q.on_tick then Q.on_tick(x) end
end

function Q.run()
  Q.last_abs = Q.abs_now()
  while true do
    clock.sync(1 / K.PPQ)
    local a = Q.abs_now()
    if a < Q.last_abs then
      -- the beat went back (a reset, a new source): carry on from here
      Q.origin = Q.origin - (Q.last_abs + 1 - a)
      Q.last_abs = a - 1
    end
    for x = Q.last_abs + 1, a do Q.tick_abs(x) end
    if a > Q.last_abs then Q.last_abs = a end
  end
end

-- ------------------------------------------------------------- transport

-- the song plays from song tick t0, on absolute tick x
function Q.begin(x, t0)
  Q.gen = Q.gen + 1
  Q.events = {}
  Q.origin = x - t0
  Q.t = t0 - 1
  Q.playing, Q.paused = true, false
  Q.dirty = true
end

-- every track where it would be at song tick R, played through silently
function Q.locate(R)
  for t = 1, K.NTRACKS do Q.reset_track(t, 0) end
  local h = {}
  for _, e in ipairs(Q.hist) do
    if e.t < 0 then h[#h + 1] = e end
  end
  Q.hist = h
  for _, t in ipairs(ORDER) do
    local rt = Q.rt[t]
    local guard = 0
    while rt.next_line < R and guard < 200000 do
      prepare(t, rt.next_line, true)
      rt.next_line = rt.next_line + div(t)
      guard = guard + 1
    end
  end
  prune_hist(R)
  Q.t = R - 1
  Q.dirty = true
end

-- PLAY: from the top when stopped, from where it left off when paused
function Q.play()
  if Q.playing then return Q.pause() end
  if Q.join_abs then
    -- pressed again while waiting for the bar: never mind
    Q.join_abs, Q.start_abs, Q.cont_abs = nil, nil, nil
    Q.dirty = true
    return
  end
  local from = Q.paused and (Q.pause_t + 1) or 0
  Q.locate(from)
  local src = source()
  local now = Q.abs_now()
  Q.join_t = from
  if src == INTERNAL then
    -- two ticks out: time to get the Start in ahead of the first tick
    local x = now + 2
    Q.join_abs = x
    if from == 0 then
      Q.start_abs = x
    else
      -- a slave picks up on the next sixteenth: tell it which, then
      -- Continue just before the tick that sixteenth starts on
      local s16 = math.ceil(from / K.T16)
      O.song_position(s16)
      Q.cont_abs = x + ((s16 * K.T16) - from)
    end
  elseif src == LINK and link_sync() and from == 0 then
    -- the session starts and its start (Q.ext_start) starts us
    pcall(function() clock.link.start() end)
  else
    -- someone else's clock: in on their next bar
    local bar = Q.bar_ticks()
    if src == LINK then
      local ok, qn = pcall(function() return params:get("link_quantum") end)
      if ok and qn then bar = qn * K.PPQ end
    end
    Q.join_abs = (math.floor(now / bar) + 1) * bar
  end
  Q.dirty = true
end

function Q.pause()
  if not Q.playing then return end
  Q.playing, Q.paused = false, true
  Q.pause_t = Q.t
  Q.gen = Q.gen + 1
  Q.events = {}
  O.all_off()
  for t = 1, K.NTRACKS do Q.rt[t].sounding = {} end
  -- what track 8 prepared past here never played
  for i = #Q.hist, 1, -1 do
    if Q.hist[i].t > Q.t then table.remove(Q.hist, i) end
  end
  if source() ~= MIDI then O.stop() end
  if source() == LINK and link_sync() then pcall(function() clock.link.stop() end) end
  Q.dirty = true
end

-- STOP: everything off, back to the top, track 8's transposition gone
function Q.stop()
  local was = Q.playing or Q.paused or Q.join_abs ~= nil
  Q.playing, Q.paused = false, false
  Q.join_abs, Q.start_abs, Q.cont_abs = nil, nil, nil
  Q.gen = Q.gen + 1
  Q.events = {}
  Q.pending = nil
  O.all_off()
  for t = 1, K.NTRACKS do
    Q.rt[t].queued = nil
    Q.rt[t].sounding = {}
  end
  if was and source() ~= MIDI then O.stop() end
  if was and source() == LINK and link_sync() then pcall(function() clock.link.stop() end) end
  Q.hist = {}
  Q.t, Q.pause_t = -1, -1
  Q.reset_tracks()
  return was
end

-- clock.transport.start: MIDI Start (on its first tick) or a Link start
function Q.ext_start()
  if source() == INTERNAL then return end
  Q.ext_spp = 0
  Q.join_abs, Q.start_abs, Q.cont_abs = nil, nil, nil
  Q.locate(0)
  local x = Q.abs_now()
  Q.last_abs = x - 1
  Q.begin(x, 0)
  Q.tick_abs(x)
  Q.last_abs = x
end

-- clock.transport.stop: the other end stopped. A pause, so a Continue
-- picks up from here.
function Q.ext_stop()
  if source() == INTERNAL then return end
  Q.pause()
end

-- raw MIDI in, for what norns' clock leaves out: Song Position and Continue
function Q.midi_in(msg)
  if source() ~= MIDI then return end
  if msg.type == "song_position" then
    Q.ext_spp = (msg.lsb or 0) + ((msg.msb or 0) * 128)
  elseif msg.type == "continue" and not Q.playing then
    local R = Q.ext_spp * K.T16
    Q.locate(R)
    Q.join_abs = Q.abs_now() + 1
    Q.join_t = R
    Q.dirty = true
  end
end

-- ------------------------------------------------------ clips, snapshots

-- clip c on track t: now when stopped, else on the next bar line
function Q.launch(t, c)
  local rt = Q.rt[t]
  if not Q.playing then
    rt.queued = nil
    St.track(t).clip = c
    if not Q.paused then Q.reset_track(t, 0) end
  else
    rt.queued = { c = c, at = Q.next_bar(Q.t + Q.la_max()) }
  end
  Q.dirty = true
end

-- fn swaps the project; playing, it happens on the next bar
function Q.on_bar(fn)
  if not Q.playing then
    fn()
    if not Q.paused then Q.reset_tracks() end
    return
  end
  Q.pending = { at = Q.next_bar(Q.t + Q.la_max()), fn = fn }
  Q.dirty = true
end

-- RECORD: the step a note played now belongs to. Past the middle of the
-- step that is playing, it is the next one (it plays on the next pass).
function Q.rec_step(t)
  local rt, c = Q.rt[t], St.clip(t)
  if rt.ph == 0 or not rt.ph_line then return 1 end
  local dv = c.speed * K.T16
  if (Q.t - rt.ph_line) >= (dv / 2) then
    local back = K.DIRS[c.dir or 1] == "BWD"
    if back then return ((rt.ph - 2) % c.len) + 1 end
    return (rt.ph % c.len) + 1
  end
  return math.min(rt.ph, c.len)
end

-- bar.beat.sixteenth of the song, for the screen
function Q.position()
  local t = Q.playing and Q.t or Q.pause_t
  if t < 0 then return "1.1.1" end
  local s16 = math.floor(t / K.T16)
  local bar = K.bar_steps(St.d.sig)
  local b = math.floor(s16 / bar) + 1
  local in_bar = s16 % bar
  return string.format("%d.%d.%d", b, math.floor(in_bar / 4) + 1, (in_bar % 4) + 1)
end

return Q
