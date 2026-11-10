-- vibecomposer / keys
--
-- The right of the grid, columns 11-16: an isomorphic keyboard (M) or a
-- chord keyboard (C). G10 / H10 move either up or down an octave.
--
-- KEYS. The bottom-left pad is the ROOT. Along a row the notes go up a
-- semitone (or a scale step, IN-KEY on); up a column by the LAYOUT's
-- interval: a fourth, a third, a fifth, or SEQ, which carries on where the
-- row below ended. Roots are dim lit. Keys held together are a chord.
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
-- ARP (CHORD page, lane 3) plays a held chord one note at a time on the
-- clock instead of all at once, and a step recorded from it arpeggiates
-- too. With ARP on there is no strum.
--
-- MONO (KEYS page, per track) is for monosynths: new-note priority. A new
-- key cuts the one sounding; let it go and the newest key still held comes
-- back. Keys held together don't make a chord: a step takes the newest.
--
-- Whatever was played last (keys held together, or a chord) is what a step
-- takes when it is pressed.

local K = include("lib/const")
local T = include("lib/theory")

local Kb = {}
local St, Q, O

Kb.mode = 1          -- 1 keys, 2 chords
Kb.pads = {}         -- held pads, in press order: { x, y, notes, sent }
Kb.last = { notes = { 48 } }
Kb.chord_name = nil
Kb.mod_hold = nil    -- a modifier held: { g, id, was, used }
Kb.gesture = 0       -- counts up each time the first pad of a chord goes down
Kb.arp = nil         -- a chord being arpeggiated live
Kb.show = function() end   -- the screen's readout, set by the main script

function Kb.init(state, seq, out)
  St, Q, O = state, seq, out
  Kb.last = { notes = { St.d.root } }
end

function Kb.in_area(x, y) return x >= K.KEY_X0 and y >= 1 and y <= 8 end

-- ---------------------------------------------------------------- mapping

-- the key's root, moved by the octave buttons
function Kb.base()
  return St.d.root + ((St.d.koct or 0) * 12)
end

function Kb.note_at(x, y)
  local d = St.d
  local L = K.LAYOUTS[d.layout] or K.LAYOUTS[1]
  local col, row = x - K.KEY_X0, 8 - y
  if d.inkey then
    return T.degree_note(Kb.base(), d.scale, col + (row * L.deg))
  end
  return Kb.base() + col + (row * L.semi)
end

-- a chord pad's degree (0-11), or nil
function Kb.degree_at(x, y)
  if y == 8 then return x - K.KEY_X0 end
  if y == 7 then return 6 + (x - K.KEY_X0) end
  return nil
end

function Kb.chord(deg)
  local d = St.d
  return T.chord({ base = Kb.base(), scale = d.scale, deg = deg, mods = d.mods,
    prev = Kb.last_chord, lead = d.vlead })
end

function Kb.octave(d)
  Kb.release_all()
  if d == 0 then St.d.koct = 0
  else St.d.koct = math.min(math.max((St.d.koct or 0) + d, -3), 3) end
  Kb.show({ "OCTAVE " .. ((St.d.koct > 0) and "+" or "") .. St.d.koct,
    "ROOT PAD " .. K.note_name(Kb.base()), "" })
end

-- --------------------------------------------------------------- playing

-- the selected track, set by the grid
Kb.sel = function() return 1 end

local function out_note(tr, n) return math.min(math.max(n + (tr.oct * 12), 0), 127) end

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
    local k, tok = O.on(tr.dev, tr.ch, out_note(tr, n), vel)
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
  if t == K.MASTER then Q.live_master({ notes = notes }) end
  return sent
end

local function stop(sent)
  if not sent then return end
  sent.done = true
  for _, e in ipairs(sent) do O.off(e[1], e[2]) end
end

-- the strum a chord takes, or nil (ARP on: none)
function Kb.strum()
  local ms = St.d.strum
  if ms <= 0 or (St.d.arp or 1) > 1 then return nil end
  local dir = ({ UP = 1, DOWN = 2, RAND = 3 })[St.d.mods.strum] or 1
  return { ms = ms, dir = dir }
end

-- the arpeggio a chord takes, or nil
function Kb.arp_spec()
  if (St.d.arp or 1) <= 1 then return nil end
  return { mode = St.d.arp, rate = St.d.arp_rate }
end

-- every MIDI clock tick (lib/seq): the live arpeggio's next note
function Kb.arp_tick(x)
  local a = Kb.arp
  if not a then return end
  if a.off and x >= a.off_at then
    stop(a.off)
    a.off = nil
  end
  local rate = (K.ARP_RATES[a.spec.rate] or K.ARP_RATES[3]).t
  if x % rate ~= 0 then return end
  if a.off then stop(a.off) end
  local n
  if a.spec.mode == 5 then n = a.order[math.random(#a.order)]
  else
    n = a.order[(a.i % #a.order) + 1]
    a.i = a.i + 1
  end
  local tr = St.track(Kb.sel())
  a.off = {}
  if not tr.mute then
    local k, tok = O.on(tr.dev, tr.ch, out_note(tr, n), a.vel)
    a.off[1] = { k, tok }
  end
  a.off_at = x + math.max(1, math.floor(rate / 2))
end

local function arp_stop()
  if Kb.arp and Kb.arp.off then stop(Kb.arp.off) end
  Kb.arp = nil
end

-- the selected track is MONO and the keys keyboard is up
function Kb.mono()
  return Kb.mode == 1 and St.track(Kb.sel()).mono == true
end

-- keys held together add up to a chord
function Kb.stacks() return Kb.mode == 1 and not Kb.mono() end

-- every note held on the keyboard right now, in press order
-- (MONO: only the one sounding)
function Kb.held_notes()
  if Kb.mono() then
    local p = Kb.pads[#Kb.pads]
    return p and { p.notes[1] } or {}
  end
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
local function remember(notes, vel, strum, arp, fresh)
  if fresh then Kb.last = { notes = {} } end
  local L = Kb.last
  for _, n in ipairs(notes) do L.notes[#L.notes + 1] = n end
  table.sort(L.notes)
  L.vel, L.strum, L.arp = vel, strum, arp
end

local function names(notes)
  local s = {}
  for i, n in ipairs(notes) do
    if i > 5 then break end
    s[#s + 1] = K.note_name(n)
  end
  return table.concat(s, " ")
end

local function mods_line()
  local s = {}
  for _, row in ipairs(K.MODS) do
    for col, id in ipairs(row.ids) do
      local g = (type(row.g) == "table") and row.g[col] or row.g
      if St.d.mods[g] == id then s[#s + 1] = id end
    end
  end
  if #s == 0 then return "no modifiers" end
  return table.concat(s, " ")
end
Kb.mods_line = mods_line

-- ------------------------------------------------------------------ input

-- a pad goes down. Returns the notes it played (nil for a modifier), its
-- strum and its arpeggio.
function Kb.press(x, y)
  local fresh = (#Kb.pads == 0)
  if fresh then Kb.gesture = Kb.gesture + 1 end
  if Kb.mode == 1 then
    local n = Kb.note_at(x, y)
    local p = { x = x, y = y, notes = { n } }
    local mono = Kb.mono()
    if mono then
      -- new-note priority: the note sounding stops first
      local q = Kb.pads[#Kb.pads]
      if q then stop(q.sent) q.sent = nil end
    end
    p.sent = play(p.notes, St.d.vel)
    Kb.pads[#Kb.pads + 1] = p
    remember({ n }, St.d.vel, nil, nil, fresh or mono)
    if mono then
      Kb.show({ K.note_name(n), "MONO", "", hold = true })
      return p.notes
    end
    local held = Kb.held_notes()
    Kb.show({ names(held), T.detect(held) or ((#held == 1) and "" or "?"), "", hold = true })
    return p.notes
  end

  local deg = Kb.degree_at(x, y)
  if deg then
    local notes, name = Kb.chord(deg)
    if Kb.mod_hold then Kb.mod_hold.used = true end
    local strum, arp = Kb.strum(), Kb.arp_spec()
    -- one chord at a time
    for _, q in ipairs(Kb.pads) do stop(q.sent) end
    Kb.pads = {}
    arp_stop()
    local p = { x = x, y = y, notes = notes }
    if arp then
      Kb.arp = { spec = arp, order = T.arp_order(notes, arp.mode), i = 0, vel = St.d.cvel }
      if Kb.sel() == K.MASTER then Q.live_master({ notes = notes }) end
    else
      p.sent = play(notes, St.d.cvel, strum)
    end
    Kb.pads[#Kb.pads + 1] = p
    Kb.last_chord = notes
    Kb.chord_name = name
    remember(notes, St.d.cvel, strum, arp, true)
    Kb.show({ name, names(notes), mods_line(), hold = true })
    return notes, strum, arp
  end

  -- a modifier
  local g, id = K.mod_at(y, x - K.KEY_X0 + 1)
  if not g then return nil end
  local was = St.d.mods[g] == id
  St.d.mods[g] = id
  Kb.mod_hold = { g = g, id = id, was = was, used = false }
  Kb.show({ id .. (was and " (tap: off)" or " ON"), K.MOD_INFO[id] or "", K.MOD_GROUPS[g] or "", hold = true })
  return nil
end

function Kb.release(x, y)
  for i, p in ipairs(Kb.pads) do
    if p.x == x and p.y == y then
      local top = (i == #Kb.pads)
      stop(p.sent)
      table.remove(Kb.pads, i)
      if Kb.mode == 2 then arp_stop() end
      if #Kb.pads == 0 then Kb.show(nil)
      elseif top and Kb.mono() then
        -- MONO: back to the newest key still held
        local q = Kb.pads[#Kb.pads]
        q.sent = play(q.notes, St.d.vel)
        Kb.show({ K.note_name(q.notes[1]), "MONO", "", hold = true })
      end
      return p
    end
  end
  local h = Kb.mod_hold
  if Kb.mode == 2 and h then
    local g, id = K.mod_at(y, x - K.KEY_X0 + 1)
    if g == h.g and id == h.id then
      -- held through a chord and new: it was only for that chord.
      -- Tapped while already on: off.
      if (h.used and not h.was) or (not h.used and h.was) then
        St.d.mods[g] = nil
        Kb.show({ id .. " OFF", K.MOD_INFO[id] or "", mods_line() })
      else
        Kb.show({ id .. " ON", K.MOD_INFO[id] or "", mods_line() })
      end
      Kb.mod_hold = nil
    end
  end
end

-- everything up (a mode change, a track change)
function Kb.release_all()
  for _, p in ipairs(Kb.pads) do stop(p.sent) end
  arp_stop()
  Kb.pads = {}
  Kb.mod_hold = nil
end

function Kb.set_mode(m)
  if m ~= Kb.mode then Kb.release_all() end
  Kb.mode = m
end

return Kb
