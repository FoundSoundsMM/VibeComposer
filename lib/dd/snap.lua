-- vibecomposer / dd / snap
--
-- The drum machine's half of a snapshot. Vibe composer's snapshots (the
-- 48 pads of either session view, lib/snap) hold the whole song, and the
-- drums are part of it: every drum param (every kit's sound and which kit
-- each track is on, samples, mix, LFO settings, the swing grid and RAIN,
-- the master COLOUR and SPACE, ANALOG and HISS, the hidden TAPE's pitch
-- and length) and every track's pattern (steps, lengths, speeds, mutes,
-- templates, LFO patch points, its four clip slots and which one plays)
-- and the selected drum track. PERFORM latches are not: they are hands on
-- the machine, not the machine.
--
-- N.capture() takes it, N.apply() puts it back, and N.init() is the drums
-- as the script starts them: what a blank snapshot loads.

local S = include("lib/dd/spec")

local N = {}
local St, Q, L, C

function N.init_mod(state, seq, lfo, clips)
  St, Q, L, C = state, seq, lfo, clips
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, e in pairs(v) do out[k] = copy(e) end
  return out
end

-- every param a snapshot holds, built once params exist
local ids

local function param_ids()
  if ids then return ids end
  ids = {}
  for t = 1, S.NTRACKS do
    -- every kit's tone params, not just the one playing
    for _, key in ipairs(St.KEYS) do
      if S.is_tone(key) then
        for k = 1, #S.KITS do ids[#ids + 1] = St.pid(t, key, k) end
      elseif not S.param(t, key).special then
        ids[#ids + 1] = St.pid(t, key)
      end
    end
    for _, k in ipairs({ "kit", "file", "level", "pan", "tilt" }) do
      ids[#ids + 1] = St.pid(t, k)
    end
    for i = 1, 2 do
      for _, k in ipairs({ "rate", "depth", "shape" }) do
        ids[#ids + 1] = St.pid(t, "l" .. i .. "_" .. k)
      end
    end
  end
  for _, id in ipairs({ "swing_grid", "rain", "analog", "hiss", "tape_pitch", "tape_len" }) do
    ids[#ids + 1] = id
  end
  for _, cell in ipairs(S.COLOUR) do
    ids[#ids + 1] = "col_" .. cell.a.arg
    ids[#ids + 1] = "col_" .. cell.b.arg
  end
  ids[#ids + 1] = "col_bypass"
  return ids
end

local function capture()
  local snap = { p = {}, tracks = {}, sel = St.sel }
  for _, id in ipairs(param_ids()) do snap.p[id] = params:get(id) end
  for t, tr in ipairs(St.tracks) do
    snap.tracks[t] = {
      steps = copy(tr.steps), len = tr.len, speed = tr.speed, mute = tr.mute,
      dir = tr.dir, dilla = tr.dilla,
      tpl = copy(tr.tpl), lfo = L.save(t), clips = C.save(t),
    }
  end
  return snap
end

local function apply_track(snap, t)
  local e = snap.tracks[t]
  local tr = St.tracks[t]
  if not (e and tr) then return end
  tr.steps = copy(e.steps or {})
  tr.len = e.len or 16
  tr.speed = e.speed or 3
  tr.dir = e.dir or 1
  tr.dilla = e.dilla or 0
  tr.tpl = copy(e.tpl or tr.tpl)
  if e.lfo then L.load(t, e.lfo) end
  -- a snapshot from before the clips: what it played becomes slot 1
  C.load(t, e.clips)
end

-- mutes go with the sound, not the pattern: a track's new steps arrive a
-- pulse early, and muting then would cut the last hit before the beat
local function apply_params(snap)
  for t, e in ipairs(snap.tracks) do
    local m = e.mute or false
    if St.tracks[t] and St.tracks[t].mute ~= m then St.set_mute(t, m) end
  end
  for id, v in pairs(snap.p) do
    -- a snapshot from an older drumdrum can name a param that is gone
    -- (the reverb's, before it was a spring); a sample is only re-read
    -- when it is a different file
    local known = (params.lookup == nil) or (params.lookup[id] ~= nil)
    if known and params:get(id) ~= v then params:set(id, v) end
  end
  -- a snapshot from before the kits was a WARM one
  for t = 1, S.NTRACKS do
    if snap.p[St.pid(t, "kit")] == nil then St.set_kit(t, 1) end
  end
  if snap.sel then St.select(snap.sel) end
end

-- the INIT patch: taken once params exist and before anything is loaded
-- over them, so it is exactly the state a fresh start is in
local init_snap

function N.capture_init()
  init_snap = capture()
end


function N.capture() return capture() end

-- everything in, from a capture (nil: the INIT patch)
function N.apply(snap)
  snap = snap or init_snap
  if not snap then return end
  for t = 1, S.NTRACKS do apply_track(snap, t) end
  apply_params(snap)
  St.dirty = true
end

function N.init() return init_snap end

return N
