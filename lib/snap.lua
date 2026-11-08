-- vibecomposer / snap
--
-- SETTINGS mode turns the grid into a session view.
--
-- CLIPS, rows A-D under columns 1-8: each track's column holds its four
-- clips, row A at the top. Tap one and the track moves to it on the next
-- bar (stopped: at once) and plays it from step 1. An empty slot launches as
-- an empty clip one bar long, so launching one is how a new sequence starts.
-- Hold a clip and tap another to copy it there (any track to any track).
-- Hold STOP and tap a clip to empty it.
--
-- SNAPSHOTS, the keyboard's 48 pads. A snapshot is the whole project: every
-- track's clips, settings and MIDI, the key, swing, signature and tempo
-- (the tempo only lands on the internal clock). Tap to load: on the next
-- bar while playing, every track from step 1 there. Hold to save: the pad
-- fills as you hold, and a save only happens once it is full. Hold STOP and
-- hold a pad to delete it the same way.

local K = include("lib/const")

local N = {}
local St, Q

N.HOLD = 0.6
N.slots = {}
N.last = 0
N.act = nil         -- a save or delete being held: { slot, t0, kind, done }
N.pulse = {}
N.clip_hold = nil   -- { t, c, used }

function N.init(state, seq)
  St, Q = state, seq
  for i = 1, K.NSNAPS do N.pulse[i] = 0 end
end

-- -------------------------------------------------------------- snapshots

local function capture()
  local s = St.copy(St.d)
  s.tempo = params:get("clock_tempo")
  return s
end

local function apply(s)
  local tempo = s.tempo
  St.d = St.fill(St.copy(s))
  if tempo and Q.source() == 1 and params:get("clock_tempo") ~= tempo then
    params:set("clock_tempo", tempo)
  end
end

local function path()
  if norns and norns.state and norns.state.data then
    return norns.state.data .. "snapshots.data"
  end
end

function N.save_file()
  local p = path()
  if p and tab and tab.save then pcall(tab.save, { v = 1, slots = N.slots }, p) end
end

function N.load_file()
  local p = path()
  if not (p and tab and tab.load and util.file_exists(p)) then return end
  local ok, d = pcall(tab.load, p)
  if ok and type(d) == "table" and d.slots then N.slots = d.slots end
end

function N.store(i)
  N.slots[i] = capture()
  N.last = i
  N.pulse[i] = 1
  N.save_file()
end

function N.delete(i)
  N.slots[i] = nil
  if N.last == i then N.last = 0 end
  N.save_file()
end

function N.recall(i)
  local s = N.slots[i]
  if not s then return end
  N.pending = i
  Q.on_bar(function()
    apply(s)
    N.last = i
    N.pulse[i] = 1
    N.pending = nil
    if N.on_load then N.on_load() end
  end)
end

function N.hold_start(i, kind)
  if kind == "delete" and not N.slots[i] then return end
  N.act = { slot = i, t0 = util.time(), kind = kind }
end

function N.progress()
  local a = N.act
  if not a then return 0 end
  return math.min(math.max((util.time() - a.t0) / N.HOLD, 0), 1)
end

local function commit(a)
  if a.kind == "delete" then N.delete(a.slot) else N.store(a.slot) end
end

-- every grid frame: a hold that has filled commits while still held
function N.tick(dt)
  local a = N.act
  if a and not a.done and N.progress() >= 1 then
    a.done = true
    commit(a)
  end
  for i = 1, K.NSNAPS do
    if N.pulse[i] > 0 then N.pulse[i] = math.max(0, N.pulse[i] - (dt / 0.45)) end
  end
end

-- a pad comes up: a short press on a save hold was a load
function N.hold_end(i)
  local a = N.act
  if not (a and a.slot == i) then return end
  N.act = nil
  if a.done then return end
  if (util.time() - a.t0) >= N.HOLD then
    commit(a)
  elseif a.kind == "save" then
    N.recall(i)
  end
end

function N.has(i) return N.slots[i] ~= nil end

-- ------------------------------------------------------------------ clips

function N.clip_has(t, c)
  local cl = St.track(t).clips[c]
  return cl ~= nil and next(cl.steps) ~= nil
end

function N.clip_press(t, c, clear)
  if clear then
    local tr = St.track(t)
    tr.clips[c] = St.new_clip(K.bar_steps(St.d.sig), tr.clips[c] and tr.clips[c].speed)
    return
  end
  local h = N.clip_hold
  if h then
    if not (h.t == t and h.c == c) then
      St.track(t).clips[c] = St.copy(St.track(h.t).clips[h.c])
      h.used = true
    end
    return
  end
  N.clip_hold = { t = t, c = c, used = false }
end

function N.clip_release(t, c)
  local h = N.clip_hold
  if not (h and h.t == t and h.c == c) then return end
  N.clip_hold = nil
  if h.used then return end
  local tr = St.track(t)
  if not N.clip_has(t, c) then
    -- an empty slot starts one bar long, at the speed the track was on
    local sp = St.clip(t).speed
    tr.clips[c] = St.new_clip(math.min(K.bar_steps(St.d.sig), K.MAXLEN), sp)
  end
  Q.launch(t, c)
end

return N
