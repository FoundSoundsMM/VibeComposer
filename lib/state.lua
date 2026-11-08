-- vibecomposer / state
--
-- The project: everything a snapshot holds and the data file keeps.
-- St.d is plain data (no functions), so it copies and saves as it is.
--
-- A track has four clips (Ableton-style slots). The clip that plays is
-- tr.clips[tr.clip]; editing the steps edits that clip.
--
-- A step is { notes = { midi notes }, and any of K.STEP_DEF's keys that
-- differ from the default }.

local K = include("lib/const")

local St = {}

function St.copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, e in pairs(v) do out[k] = St.copy(e) end
  return out
end

function St.new_clip(len, speed)
  return { steps = {}, len = len or 16, speed = speed or 1 }
end

function St.new_track(i)
  local clips = {}
  for c = 1, K.NCLIPS do clips[c] = St.new_clip() end
  return {
    type = 1,           -- 1 mono, 2 poly
    swing = 0,          -- offset on the global swing, in percent
    dev = 1,            -- MIDI port (norns vport 1-16)
    ch = i,             -- MIDI channel
    follow = (i ~= K.MASTER),
    mute = false,
    oct = 0,
    prog = -1,          -- program change sent when set; -1 is off
    clip = 1,
    clips = clips,
    tpl = {},           -- what a new step starts with (TC pages, nothing held)
  }
end

function St.new()
  local d = {
    v = 1,
    tracks = {},
    scale = 1,
    root = 48,          -- C3: the keyboard's bottom-left pad and the key
    swing = 50,         -- MPC percent, 50 straight to 75
    sig = 1,
    tempo = 120,
    layout = 1,
    inkey = false,
    vel = 100,
    cvel = 100,
    strum = 0,          -- ms between a chord's notes
    vlead = false,
    transpose = 1,      -- 1 chromatic, 2 in key
    mods = {},
    gen = { style = 1, density = 50, range = 2, pool = 1 },
    mut = { amount = 25, target = 3 },
  }
  for i = 1, K.NTRACKS do d.tracks[i] = St.new_track(i) end
  return d
end

St.d = St.new()

function St.track(t) return St.d.tracks[t] end
function St.clip(t)
  local tr = St.d.tracks[t]
  return tr.clips[tr.clip]
end

-- a step's value, or what it defaults to
function St.get(st, k)
  local v = st and st[k]
  if v == nil then return K.STEP_DEF[k] end
  return v
end

function St.has_notes(st)
  return st ~= nil and st.notes ~= nil and #st.notes > 0
end

-- a new step from the track's template
function St.new_step(t, notes)
  local st = St.copy(St.d.tracks[t].tpl)
  st.notes = notes
  return st
end

-- is anything on this step other than its notes? (brighter on the grid)
function St.has_params(st)
  if not st then return false end
  for k, def in pairs(K.STEP_DEF) do
    if st[k] ~= nil and st[k] ~= def then return true end
  end
  return st.strum ~= nil
end

-- ----------------------------------------------------------------- disk

local function dir()
  if norns and norns.state and norns.state.data then return norns.state.data end
end

-- an older or broken file is filled in from a fresh project
local function fill(d)
  local n = St.new()
  for k, v in pairs(n) do
    if d[k] == nil then d[k] = v end
  end
  for i = 1, K.NTRACKS do
    local tr = d.tracks[i] or St.new_track(i)
    for k, v in pairs(St.new_track(i)) do
      if tr[k] == nil then tr[k] = v end
    end
    for c = 1, K.NCLIPS do tr.clips[c] = tr.clips[c] or St.new_clip() end
    d.tracks[i] = tr
  end
  return d
end
St.fill = fill

function St.save()
  local p = dir()
  if p and tab and tab.save then pcall(tab.save, St.d, p .. "project.data") end
end

function St.load()
  local p = dir()
  if not (p and tab and tab.load and util.file_exists(p .. "project.data")) then return false end
  local ok, d = pcall(tab.load, p .. "project.data")
  if ok and type(d) == "table" and d.tracks then
    St.d = fill(d)
    return true
  end
  return false
end

return St
