-- vibecomposer / theory
--
-- Scales, degrees, chords, and how a track follows track 8.

local K = include("lib/const")

local T = {}

local function clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end

function T.iv(si) return (K.SCALES[si] or K.SCALES[1]).iv end

function T.in_scale(note, root, si)
  local pc = (note - root) % 12
  for _, v in ipairs(T.iv(si)) do
    if v == pc then return true end
  end
  return false
end

-- scale degree d (0-based, any integer) above base -> note
function T.degree_note(base, si, d)
  local iv = T.iv(si)
  local n = #iv
  local oct = math.floor(d / n)
  return base + (oct * 12) + iv[(d % n) + 1]
end

-- note -> the scale degree at or below it, and how many semitones above
-- that degree it sits (0 for a note in the scale)
function T.note_degree(note, base, si)
  local iv = T.iv(si)
  local rel = note - base
  local oct = math.floor(rel / 12)
  local pc = rel % 12
  local best = 1
  for i, v in ipairs(iv) do
    if v <= pc then best = i end
  end
  return (oct * #iv) + (best - 1), pc - iv[best]
end

-- move a note n scale steps (chromatic notes keep their offset)
function T.shift_degrees(note, base, si, n)
  local d, rem = T.note_degree(note, base, si)
  return T.degree_note(base, si, d + n) + rem
end

-- the scale's parallel: a major-third scale borrows from minor, and back
function T.parallel(si)
  for _, v in ipairs(T.iv(si)) do
    if v == 4 then return 2 end
  end
  return 1
end

-- ----------------------------------------------------------------- follow
--
-- m is what track 8 last played: { kind = 1 (mono) or 2 (poly), notes }.
-- MONO transposes by how far track 8's note sits from the keyboard root,
-- chromatically or by scale steps. POLY pulls each note to the nearest tone
-- of track 8's chord, keeping its register, so the line moves with the
-- harmony instead of jumping.

function T.follow(note, m, d)
  if not (m and m.notes and m.notes[1]) then return note end
  if m.kind == 2 then
    local best, bd = note, 99
    for _, cn in ipairs(m.notes) do
      local pc = cn % 12
      -- the nearest copy of this pitch class, ties go down
      local diff = (pc - (note % 12)) % 12
      if diff > 6 then diff = diff - 12 end
      if diff == 6 then diff = -6 end
      local ad = math.abs(diff)
      if ad < bd or (ad == bd and diff < (best - note)) then
        best, bd = note + diff, ad
      end
    end
    return best
  end
  local mn = m.notes[1]
  if d.transpose == 2 then
    local dm = T.note_degree(mn, d.root, d.scale)
    return T.shift_degrees(note, d.root, d.scale, dm)
  end
  return note + (mn - d.root)
end

-- ----------------------------------------------------------------- chords

local function sorted(t)
  table.sort(t, function(a, b) return a.n < b.n end)
  return t
end

-- a chord on scale degree deg (0-based) of the key, with the modifiers
-- in mods (group -> id). o = { base, scale, deg, mods, prev, lead }.
-- Returns notes (low to high) and a name.
function T.chord(o)
  local mods = o.mods or {}
  local si = o.scale
  if mods.bor == "PAR" then si = T.parallel(si) end
  local base = o.base
  local deg = o.deg
  local r = T.degree_note(base, si, deg)
  local function dn(k) return T.degree_note(base, si, deg + k) end

  local tones
  local tmpl = ({ ["V/"] = { 7, { 0, 4, 7, 10 } }, ["vii/"] = { -1, { 0, 3, 6, 9 } },
    ["bII"] = { 1, { 0, 4, 7 } }, ["TT"] = { 6, { 0, 4, 7, 10 } },
    ["DOM7"] = { 0, { 0, 4, 7, 10 } } })[mods.bor]
  if tmpl then
    r = r + tmpl[1]
    local roles = { "R", "3", "5", "7" }
    tones = {}
    for i, v in ipairs(tmpl[2]) do tones[#tones + 1] = { n = r + v, role = roles[i] } end
    if mods.ext == "9" or mods.ext == "11" or mods.ext == "13" then
      tones[#tones + 1] = { n = r + 14, role = "9" }
    end
  else
    tones = { { n = r, role = "R" }, { n = dn(2), role = "3" }, { n = dn(4), role = "5" } }
    local e = mods.ext
    if e == "7" or e == "9" or e == "11" or e == "13" then
      tones[#tones + 1] = { n = dn(6), role = "7" }
    end
    if e == "M7" then tones[#tones + 1] = { n = r + 11, role = "7" } end
    if e == "9" or e == "11" or e == "13" then tones[#tones + 1] = { n = dn(8), role = "9" } end
    if e == "11" then tones[#tones + 1] = { n = dn(10), role = "11" } end
    if e == "13" then tones[#tones + 1] = { n = dn(12), role = "13" } end
    if e == "6" then tones[#tones + 1] = { n = dn(5), role = "6" } end

    local ty = mods.type
    local set3 = ({ SUS2 = 2, SUS4 = 5, MAJ = 4, MIN = 3, DIM = 3, AUG = 4 })[ty]
    local set5 = ({ MAJ = 7, MIN = 7, DIM = 6, AUG = 8 })[ty]
    for _, t in ipairs(tones) do
      if t.role == "3" and set3 then t.n = r + set3 end
      if t.role == "5" and set5 then t.n = r + set5 end
    end
  end

  -- omit
  local omit = ({ ["NO R"] = "R", ["NO 3"] = "3", ["NO 5"] = "5" })[mods.omit]
  if omit and #tones > 2 then
    for i = #tones, 1, -1 do
      if tones[i].role == omit then table.remove(tones, i) end
    end
  end

  sorted(tones)
  local inv = mods.inv
  if o.lead and o.prev and #o.prev > 0 then
    -- voice leading: the inversion and octave nearest the last chord
    local best, bs
    for k = 0, #tones - 1 do
      for sh = -12, 12, 12 do
        local cand = {}
        for i, t in ipairs(tones) do
          cand[i] = { n = t.n + sh + ((i <= k) and 12 or 0), role = t.role }
        end
        local s = 0
        for _, c in ipairs(cand) do
          local m = 99
          for _, p in ipairs(o.prev) do m = math.min(m, math.abs(c.n - p)) end
          s = s + m
        end
        if not bs or s < bs then best, bs = cand, s end
      end
    end
    tones = sorted(best)
  elseif inv == "INV1" or inv == "INV2" or inv == "INV3" then
    local k = math.min(tonumber(inv:sub(4)), #tones - 1)
    for _ = 1, k do
      sorted(tones)
      tones[1].n = tones[1].n + 12
    end
    sorted(tones)
  elseif inv == "DROP2" and #tones >= 3 then
    tones[#tones - 1].n = tones[#tones - 1].n - 12
    sorted(tones)
  elseif inv == "DROP3" and #tones >= 4 then
    tones[#tones - 2].n = tones[#tones - 2].n - 12
    sorted(tones)
  elseif inv == "SPRD" then
    for i = 2, #tones, 2 do tones[i].n = tones[i].n + 12 end
    sorted(tones)
  end

  local oc = ({ ["-2"] = -24, ["-1"] = -12, ["+1"] = 12, ["+2"] = 24 })[mods.oct] or 0
  local out, seen = {}, {}
  local function add(n)
    n = clamp(n + oc, 0, 127)
    if not seen[n] then seen[n] = true out[#out + 1] = n end
  end
  for _, t in ipairs(tones) do add(t.n) end
  if mods.oct == "BASS" then add(r - 12) end
  if mods.oct == "TOP" then add(r + 12) end
  table.sort(out)
  return out, T.chord_name(r, tones), r + oc
end

-- a short name: root, quality and the top extension
function T.chord_name(r, tones)
  local has = {}
  for _, t in ipairs(tones) do has[t.role] = (t.n - r) % 12 end
  local q = ""
  local third, fifth = has["3"], has["5"]
  if third == 3 and fifth == 6 then q = "dim"
  elseif third == 4 and fifth == 8 then q = "aug"
  elseif third == 3 then q = "m"
  elseif third == 2 then q = "sus2"
  elseif third == 5 then q = "sus4" end
  if has["13"] then q = q .. "13"
  elseif has["11"] then q = q .. "11"
  elseif has["9"] then q = q .. ((has["7"] == 11) and "M9" or "9")
  elseif has["7"] then q = q .. ((has["7"] == 11) and "M7" or "7")
  elseif has["6"] then q = q .. "6" end
  return K.NOTE_NAMES[(r % 12) + 1] .. q
end

-- the name of a set of notes, for the screen: one note, or its chord
function T.notes_name(notes)
  if not notes or #notes == 0 then return "--" end
  if #notes == 1 then return K.note_name(notes[1]) end
  local s = {}
  for i, n in ipairs(notes) do
    if i > 3 then s[#s + 1] = "+" break end
    s[#s + 1] = K.NOTE_NAMES[(n % 12) + 1]
  end
  return table.concat(s, " ")
end

return T
