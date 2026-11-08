-- vibecomposer / keys
--
-- The right of the grid, columns 11-16: an isomorphic keyboard (M) or a
-- chord keyboard (C).
--
-- KEYS. The bottom-left pad is the ROOT. Along a row the notes go up a
-- semitone (or a scale step, IN-KEY on); up a column by the LAYOUT's
-- interval: a fourth, a third, a fifth, or SEQ, which carries on where the
-- row below ended. Roots are dim lit.
--
-- CHORDS, after the Hapax. Rows G-H are twelve chords: H is degrees I-VI of
-- the key, G is VII and then I-V an octave up. Rows A-F are modifiers.
-- Tap one to latch it (one per group: a row, or half of row F), tap again to
-- let it go; hold one while you play a chord and it only lasts that chord.
--
--   A  7    M7    9     11    13    6        extensions
--   B  SUS2 SUS4  MAJ   MIN   DIM   AUG      the third and fifth
--   C  INV1 INV2  INV3  DROP2 DROP3 SPRD     voicing
--   D  -2   -1    +1    +2    BASS  TOP      octave, doubled root
--   E  PAR  V/    vii/  bII   TT    DOM7     borrowed chords
--   F  UP   DOWN  RAND |NO R  NO 3  NO 5     strum direction | omit
--
-- Whatever was played last (keys held together, or a chord) is what a step
-- takes when it is pressed.

local K = include("lib/const")
local T = include("lib/theory")

local Kb = {}
local St, Q, O

Kb.mode = 1          -- 1 keys, 2 chords
Kb.pads = {}         -- held pads, in press order: { x, y, notes, sent }
Kb.last = { notes = { 48 }, mono = 48 }
Kb.chord_name = nil
Kb.mod_hold = nil    -- a modifier held: { g, id, was, used }

function Kb.init(state, seq, out)
  St, Q, O = state, seq, out
  Kb.last = { notes = { St.d.root }, mono = St.d.root }
end

function Kb.in_area(x, y) return x >= K.KEY_X0 and y >= 1 and y <= 8 end

-- ---------------------------------------------------------------- mapping

function Kb.note_at(x, y)
  local d = St.d
  local L = K.LAYOUTS[d.layout] or K.LAYOUTS[1]
  local col, row = x - K.KEY_X0, 8 - y
  if d.inkey then
    return T.degree_note(d.root, d.scale, col + (row * L.deg))
  end
  return d.root + col + (row * L.semi)
end

-- a chord pad's degree (0-11), or nil
function Kb.degree_at(x, y)
  if y == 8 then return x - K.KEY_X0 end
  if y == 7 then return 6 + (x - K.KEY_X0) end
  return nil
end

function Kb.chord(deg)
  local d = St.d
  return T.chord({ base = d.root, scale = d.scale, deg = deg, mods = d.mods,
    prev = Kb.last_chord, lead = d.vlead })
end

function Kb.mod_on(g, id) return St.d.mods[g] == id end

-- --------------------------------------------------------------- playing

local function track() return St.track(Kb.sel()) end

-- the selected track, set by the grid
Kb.sel = function() return 1 end

local function play(notes, vel, strum)
  local t = Kb.sel()
  local tr = St.track(t)
  local sent = {}
  local order = notes
  if strum and strum.dir == 2 then
    order = {}
    for i = #notes, 1, -1 do order[#order + 1] = notes[i] end
  end
  local function one(n)
    if tr.mute then return end
    local out = math.min(math.max(n + (tr.oct * 12), 0), 127)
    local k, tok = O.on(tr.dev, tr.ch, out, vel)
    sent[#sent + 1] = { k, tok }
  end
  if strum and (strum.ms or 0) > 0 and #order > 1 then
    one(order[1])
    clock.run(function()
      for i = 2, #order do
        clock.sleep(strum.ms / 1000)
        if sent.done then return end
        one(order[i])
      end
    end)
  else
    for _, n in ipairs(order) do one(n) end
  end
  if t == K.MASTER then
    Q.live_master({ kind = tr.type, notes = (tr.type == 1) and { notes[#notes] } or notes })
  end
  return sent
end

local function stop(sent)
  if not sent then return end
  sent.done = true
  for _, e in ipairs(sent) do O.off(e[1], e[2]) end
end

-- the strum a chord takes, or nil
function Kb.strum()
  local ms = St.d.strum
  if ms <= 0 then return nil end
  local dir = ({ UP = 1, DOWN = 2, RAND = 3 })[St.d.mods.strum] or 1
  return { ms = ms, dir = dir }
end

-- every note held on the keyboard right now, in press order
function Kb.held_notes()
  local out, seen = {}, {}
  for _, p in ipairs(Kb.pads) do
    for _, n in ipairs(p.notes) do
      if not seen[n] then seen[n] = true out[#out + 1] = n end
    end
  end
  return out
end

function Kb.held_any() return #Kb.pads > 0 end

-- a note or a chord was played: remember it for the steps
local function remember(notes, mono, vel, strum, fresh)
  if fresh then
    Kb.last = { notes = {}, mono = mono, vel = vel, strum = strum }
  end
  local L = Kb.last
  for _, n in ipairs(notes) do L.notes[#L.notes + 1] = n end
  table.sort(L.notes)
  L.mono, L.vel, L.strum = mono, vel, strum or L.strum
end

-- ------------------------------------------------------------------ input

-- a pad goes down. Returns the notes it played (nil for a modifier).
function Kb.press(x, y)
  local fresh = (#Kb.pads == 0)
  if Kb.mode == 1 then
    local n = Kb.note_at(x, y)
    local p = { x = x, y = y, notes = { n } }
    p.sent = play(p.notes, St.d.vel)
    Kb.pads[#Kb.pads + 1] = p
    remember({ n }, n, St.d.vel, nil, fresh)
    return p.notes
  end

  local deg = Kb.degree_at(x, y)
  if deg then
    local notes, name, root = Kb.chord(deg)
    if Kb.mod_hold then Kb.mod_hold.used = true end
    local strum = Kb.strum()
    local p = { x = x, y = y, notes = notes }
    p.sent = play(notes, St.d.cvel, strum)
    Kb.pads[#Kb.pads + 1] = p
    Kb.last_chord = notes
    Kb.chord_name = name
    remember(notes, root, St.d.cvel, strum, true)
    return notes, strum
  end

  -- a modifier
  local g, id = K.mod_at(y, x - K.KEY_X0 + 1)
  if not g then return nil end
  local was = St.d.mods[g] == id
  St.d.mods[g] = id
  Kb.mod_hold = { g = g, id = id, was = was, used = false }
  return nil
end

function Kb.release(x, y)
  for i, p in ipairs(Kb.pads) do
    if p.x == x and p.y == y then
      stop(p.sent)
      table.remove(Kb.pads, i)
      return
    end
  end
  local h = Kb.mod_hold
  if Kb.mode == 2 and h then
    local g, id = K.mod_at(y, x - K.KEY_X0 + 1)
    if g == h.g and id == h.id then
      -- held through a chord and new: it was only for that chord.
      -- Tapped while already on: off.
      if (h.used and not h.was) or (not h.used and h.was) then St.d.mods[g] = nil end
      Kb.mod_hold = nil
    end
  end
end

-- everything up (a mode change, a track change)
function Kb.release_all()
  for _, p in ipairs(Kb.pads) do stop(p.sent) end
  Kb.pads = {}
  Kb.mod_hold = nil
end

function Kb.set_mode(m)
  if m ~= Kb.mode then Kb.release_all() end
  Kb.mode = m
end

-- --------------------------------------------------------------- display

-- the pads (x, y) a note sits on, for lighting notes up
function Kb.pads_for(note)
  local out = {}
  for y = 1, 8 do
    for x = K.KEY_X0, 16 do
      if Kb.note_at(x, y) == note then out[#out + 1] = { x, y } end
    end
  end
  return out
end

return Kb
