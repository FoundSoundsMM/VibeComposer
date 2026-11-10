-- vibecomposer / dd / seq
--
-- The drum machine's eight sequencers (ported from drumdrum). They have no
-- clock of their own: vibe composer's sequencer (lib/seq) drives them from
-- its one 24-a-beat coroutine, so the drums and the melodic tracks share
-- one song position, one PLAY and STOP, one swing and one sync. Times here
-- are SONG beats, counted from the song's start.
--
-- THE SEQUENCER RUNS ONE PULSE AHEAD OF WHAT YOU HEAR. On each tick every
-- track works out the pulses coming up within one of its own pulses (plus
-- the SYNC LEAD), and puts each on its line plus swing plus the step's nudge
-- in lib/seq's event list. That is what lets a nudge go early as well as
-- late. The playhead the grid draws moves with the placed event, so it lands
-- when the sound does, not when the sequencer thought about it.
--
-- PULSES, after the Metropolix. A step owns 1-8 pulses of the track's clock,
-- so a step with four pulses holds the playhead for four steps' worth of
-- time and the pattern stretches around it. What happens inside that time is
-- the step's MODE:
--
--   WAIT     one hit, then rest for the remaining pulses
--   REPEAT   a hit on every pulse (a ratchet that takes up real time)
--   SUSTAIN  one hit with its decay stretched across the pulses
--   EDGE     a hit on the first and the last pulse
--   SCATTER  the first pulse always, each one after it on a coin toss
--
-- RAMP shapes the velocity across those hits and BEND walks their pitch.
--
-- DIRECTION is the order the track walks its steps in:
--
--   FWD   1 to LENGTH, round again
--   BWD   LENGTH to 1
--   PEND  there and back, without playing either end twice
--   WALK  a drunk's walk: a step on, a step back, or stay put, wrapping
--   RND   any step, at random
--
-- One pass of the pattern (what A:B and 1ST count) is a lap for FWD and BWD,
-- there-and-back for PEND, and LENGTH steps for WALK and RND.
--
-- DILLA is the feel of a beat played in by hand on an MPC with the quantise
-- off, the J Dilla way. Not random shake: each voice has its own place
-- against the beat (S.DILLA). The kicks push a hair early, the claps and
-- snares lay back late, and every off-beat (the second of each pair of
-- pulses) is dragged part of the way to where a triplet would put it -- the
-- hats almost all the way, the kicks only a little -- so the groove sits
-- somewhere between straight and swung, and the voices rub against each
-- other instead of locking. On top, a slow wander (a random walk pulled back
-- towards the lean, so a track drifts early or late for a bar or two the way
-- a player does) and a touch of hit-to-hit jitter. All of it grows with the
-- amount: low is a gentle loosening, 100 % is properly drunk.

local S = include("lib/dd/spec")

local Q = {}
local St, VQ    -- the drums' state, and vibe composer's sequencer

-- the swing every track shares (vibe composer's SWING, 50-75)
Q.swing_amt = function() return 50 end

function Q.init(state, vq) St, VQ = state, vq end

local function transport_changed()
  if St.push_hiss then St.push_hiss() end
end

-- --------------------------------------------------------------- conditions
--
-- Elektron's set. A:B fires on the A-th of every B passes of the pattern.
-- PRE is whether the last condition on this track passed, NEI the same for
-- the track to the left. PRE and NEI do not themselves count as "the last
-- condition", or chaining them would only ever look at themselves.

function Q.cond(tr, t, st)
  local c = S.CONDS[st.cond] or "ALWAYS"
  local res
  if c == "ALWAYS" then res = true
  elseif c == "FILL" then res = St.fill
  elseif c == "!FILL" then res = not St.fill
  elseif c == "PRE" then res = tr.pre
  elseif c == "!PRE" then res = not tr.pre
  elseif c == "NEI" or c == "!NEI" then
    local nb = St.tracks[(t == 1) and S.NTRACKS or (t - 1)]
    res = nb.pre
    if c == "!NEI" then res = not res end
  elseif c == "1ST" then res = (tr.loop == 0)
  elseif c == "!1ST" then res = (tr.loop ~= 0)
  else
    local a, b = c:match("^(%d):(%d)$")
    a, b = tonumber(a), tonumber(b)
    -- not `x and (cmp) or true`: a false comparison would fall through to true
    if a and b then res = ((tr.loop % b) == (a - 1)) else res = true end
  end
  if res and (st.prob or 100) < 100 then
    res = math.random(100) <= st.prob
  end
  if c ~= "PRE" and c ~= "!PRE" and c ~= "NEI" and c ~= "!NEI" then
    tr.pre = res
  end
  return res
end

-- -------------------------------------------------------------------- step

-- the next step for the track's direction
local function next_pos(tr)
  local len = tr.len
  local d = S.DIRS[tr.dir or 1] or "FWD"
  local pos = tr.pos
  if pos > len then pos = len end
  if d == "BWD" then
    if pos <= 1 then
      if tr.pos ~= 0 then tr.loop = tr.loop + 1 end
      return len
    end
    return pos - 1
  elseif d == "PEND" then
    if pos == 0 then tr.pdir = 1 return 1 end
    if len <= 1 then tr.loop = tr.loop + 1 return 1 end
    local n = pos + tr.pdir
    if n > len then tr.pdir = -1 n = len - 1 end
    if n < 1 then
      tr.pdir = 1
      n = 2
    end
    -- back at the start: a pass is there and back
    if n == 1 then tr.loop = tr.loop + 1 end
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
      tr.count = tr.count + 1
      if tr.count >= len then
        tr.count = 0
        tr.loop = tr.loop + 1
      end
    end
    return n
  end
  if pos + 1 > len then
    if tr.pos ~= 0 then tr.loop = tr.loop + 1 end
    return 1
  end
  return pos + 1
end

function Q.advance(tr)
  if tr.pulse < tr.npulses then
    tr.pulse = tr.pulse + 1
    return
  end
  tr.pulse = 1
  tr.pos = next_pos(tr)
  local st = tr.steps[tr.pos]
  tr.npulses = (st and st.on) and (st.pulses or 1) or 1
end

-- this hit's DILLA, in pulses, for a pulse on line b of a grid of div
local function dilla(t, tr, b, div)
  local amt = (tr.dilla or 0) / 100
  if amt <= 0 then return 0 end
  local D = S.DILLA
  local off = (math.floor((b / div) + 1e-6) % 2) == 1
  tr.dw = util.clamp((tr.dw * 0.92) + ((math.random() - 0.5) * 0.5), -1, 1)
  local jit = (math.random() - 0.5) * 2
  local o = D.LEAN[t] + (D.WANDER * tr.dw) + (D.JITTER * jit)
  if off then o = o + (D.SWAY[t] * D.TRIP) end
  return o * amt
end

-- what the current pulse plays, or nil
function Q.hit_for(tr, t)
  local st = tr.steps[tr.pos]
  if not (st and st.on) then return nil end
  local pulse, n = tr.pulse, tr.npulses
  if pulse == 1 then tr.pass = Q.cond(tr, t, st) end
  if not tr.pass then return nil end

  local mode = S.PMODES[st.pmode] or "WAIT"
  local fire
  if n <= 1 or pulse == 1 then fire = true
  elseif mode == "REPEAT" then fire = true
  elseif mode == "EDGE" then fire = (pulse == n)
  elseif mode == "SCATTER" then fire = math.random() < 0.5
  else fire = false end
  if not fire then return nil end

  local frac = (n > 1) and ((pulse - 1) / (n - 1)) or 0
  local ramp = (st.ramp or 0) / 100
  local vf = (ramp >= 0) and ((1 - ramp) + (ramp * frac)) or (1 + (ramp * frac))
  local decm = 2 ^ (((st.dec or 0) / 100) * 1.5)
  if mode == "SUSTAIN" and n > 1 then decm = decm * n end
  return {
    vel = ((st.vel or 100) / 100) * vf,
    pitch = (st.pitch or 0) + ((st.bend or 0) * frac),
    decm = decm,
    mix = (st.mix or 0) / 100,
    locks = st.locks,
    flam = (pulse == 1) and (st.flam or 0) or 0,
    nudge = (pulse == 1) and ((st.nudge or 0) / 100) or 0,
  }
end

-- --------------------------------------------------------------------- swing
--
-- A time warp over each pair of swing units: the first unit is stretched to
-- SWING% of the pair and the second squeezed into what is left, so every
-- pulse inside the pair moves in proportion rather than only the off-beat.

function Q.swing_delay(beat)
  local s = Q.swing_amt() / 100
  local u = S.SWING_UNIT[params:get("swing_grid")] or 0.25
  local p = beat % (2 * u)
  local w
  if p < u then w = p * (2 * s)
  else w = (2 * u * s) + ((p - u) * (2 - (2 * s))) end
  return w - p
end

-- ---------------------------------------------------------------------- run

local EPS = 1e-6
local PPQ = 24

Q.gen = 0        -- bumped on every start and stop: a flam from an older run
                 -- sees a different number and drops out
Q.waiter = nil   -- never set: PLAY is vibe composer's, and it waits for us

local function speed(tr) return S.SPEED_BEATS[tr.speed] or 0.25 end

-- the first line of a grid of div strictly after beat b
local function line_after(b, div)
  return (math.floor((b / div) + EPS) + 1) * div
end

-- the SYNC LEAD, in beats (see lib/seq)
function Q.lead() return VQ.lead_ticks() / PPQ end

-- where the song is, in beats
function Q.now_beats() return VQ.song_now() / PPQ end

-- a bar, in beats: the time signature's
function Q.bar() return VQ.bar_ticks() / PPQ end

-- inside a clock coroutine: wait for the next line of n beats (the lead
-- early) and return it
function Q.wait_line(n)
  local now = Q.now_beats()
  local lead = Q.lead()
  local line = (math.floor(((now + lead) / n) + EPS) + 1) * n
  local dt = (line - lead - now) * clock.get_beat_sec()
  if dt > 0 then clock.sleep(dt) end
  return line
end

local function fire(t, h, gen)
  St.hit(t, h.vel, h.pitch, h.decm, h.mix, h.locks)
  if h.rain and Q.on_rain and not St.tracks[t].mute then Q.on_rain(t) end
  if h.flam > 0 then
    clock.run(function()
      clock.sleep(h.flam / 1000)
      if gen == Q.gen then St.hit(t, h.vel * 0.6, h.pitch, h.decm, h.mix, h.locks) end
    end)
  end
end

-- advance track t one pulse and put that pulse on line b
function Q.tick(t, b, div)
  local tr = St.tracks[t]
  local gen = Q.gen
  -- a clip launch due on this line swaps the pattern in before it is read
  if Q.on_tick then Q.on_tick(t, b) end
  Q.advance(tr)
  local pos = tr.pos
  local h = Q.hit_for(tr, t)
  -- RAIN only falls where the track itself is silent (see lib/dd/clips)
  if not h and Q.rain then h = Q.rain(t) end

  local at = b + Q.swing_delay(b) - Q.lead()
  local nudge = h and ((h.nudge + dilla(t, tr, b, div)) * div) or 0
  -- the playhead moves with the line, so it lands when the beat does
  VQ.push_fn(at * PPQ, function()
    tr.ph = pos
    if h and nudge == 0 then fire(t, h, gen) end
    St.dirty = true
  end, b * PPQ)
  if nudge ~= 0 then
    VQ.push_fn((at + nudge) * PPQ, function() fire(t, h, gen) end, b * PPQ)
  end
end

function Q.reset(from)
  for _, tr in ipairs(St.tracks) do
    tr.pos, tr.pulse, tr.npulses, tr.loop = 0, 1, 1, 0
    tr.pass, tr.pre, tr.ph = false, false, 0
    tr.pdir, tr.count, tr.dw = 1, 0, 0
    tr.next_b = from or 0
  end
  St.dirty = true
end

-- ------------------------------------------------------- driven by lib/seq
--
-- Q.follow in lib/seq: these are called from its coroutine.

local function transport_changed()
  if St.push_hiss then St.push_hiss() end
end

-- every song tick t while playing: prepare whatever is due within a pulse
-- (and the lead) of now
function Q.process(t)
  if not St.playing then return end
  St.fill = VQ.fill and true or false
  local now = t / PPQ
  local lead = Q.lead()
  for i = 1, S.NTRACKS do
    local tr = St.tracks[i]
    local guard = 0
    while guard < 32 do
      local div = speed(tr)
      local b = tr.next_b or 0
      if b - div - lead - (1 / PPQ) > now then break end
      Q.tick(i, b, div)
      tr.next_b = line_after(b, speed(tr))
      guard = guard + 1
    end
  end
end

-- the song starts (t0 = 0) or carries on (t0 > 0, after Q.locate)
function Q.begin(t0)
  Q.gen = Q.gen + 1
  St.playing = true
  transport_changed()
  if t0 <= 0 then
    Q.reset(0)
    -- step 1 is now: a sample take armed for PLAY starts here
    if Q.on_begin then Q.on_begin(0) end
  end
  St.dirty = true
end

-- every track where it would be at song tick R, walked through silently
function Q.locate(R)
  Q.reset(0)
  local to = R / PPQ
  for _, tr in ipairs(St.tracks) do
    local guard = 0
    while tr.next_b < to - EPS and guard < 100000 do
      Q.advance(tr)
      tr.next_b = line_after(tr.next_b, speed(tr))
      guard = guard + 1
    end
  end
end

function Q.pause()
  Q.gen = Q.gen + 1
  St.playing = false
  transport_changed()
  St.dirty = true
end

-- everything stops and goes back to the top
function Q.halt()
  Q.gen = Q.gen + 1
  if Q.on_halt then Q.on_halt() end
  St.playing = false
  transport_changed()
  Q.reset(0)
end

-- back to step 1 at song tick `at` without stopping (a snapshot landing):
-- tracks of different lengths and speeds line up again from there
function Q.restart(at)
  VQ.cancel_drum(at)
  Q.reset(at / PPQ)
end

-- ---------------------------------------------------------------- transport
--
-- PLAY and STOP belong to vibe composer (lib/seq): these are here so the
-- drum code can still ask for them.

function Q.play() if not VQ.playing then VQ.play() end end
function Q.stop() VQ.stop() end
function Q.toggle() if VQ.playing then VQ.stop() else VQ.play() end end

return Q
