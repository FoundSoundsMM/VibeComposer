-- vibecomposer / const
--
-- The fixed tables: the grid layout, scales, time signatures, conditions,
-- and the chord modifiers.

local K = {}

K.NTRACKS = 8
K.MASTER = 8          -- track 8 transposes or harmonises the others
K.NCLIPS = 4
K.NSNAPS = 48
K.MAXLEN = 512        -- 16 pages of 32
K.PAGE_STEPS = 32     -- rows A-D x columns 1-8
K.PPQ = 24            -- MIDI clock ticks per beat; everything runs on them
K.T16 = 6             -- ticks in a sixteenth

-- ------------------------------------------------------------------ grid

K.KEY_X0 = 11         -- the keyboard: columns 11-16, rows 1-8
K.KEY_W = 6
K.TRACK_ROW = 7       -- row G
K.BTN = {
  M    = { 10, 1 },
  C    = { 10, 2 },
  TC1  = { 1, 6 },
  TC2  = { 2, 6 },
  TC3  = { 4, 6 },
  TC4  = { 5, 6 },
  GEN  = { 7, 6 },
  MUT  = { 8, 6 },
  PLAY = { 1, 8 },
  STOP = { 2, 8 },
  REC  = { 3, 8 },
  OCTUP = { 10, 7 },
  OCTDN = { 10, 8 },
  SET  = { 8, 8 },
}

-- ---------------------------------------------------------------- scales

K.SCALES = {
  { name = "MAJOR",    iv = { 0, 2, 4, 5, 7, 9, 11 } },
  { name = "MINOR",    iv = { 0, 2, 3, 5, 7, 8, 10 } },
  { name = "DORIAN",   iv = { 0, 2, 3, 5, 7, 9, 10 } },
  { name = "PHRYGIAN", iv = { 0, 1, 3, 5, 7, 8, 10 } },
  { name = "LYDIAN",   iv = { 0, 2, 4, 6, 7, 9, 11 } },
  { name = "MIXOLYD",  iv = { 0, 2, 4, 5, 7, 9, 10 } },
  { name = "LOCRIAN",  iv = { 0, 1, 3, 5, 6, 8, 10 } },
  { name = "HARM MIN", iv = { 0, 2, 3, 5, 7, 8, 11 } },
  { name = "MEL MIN",  iv = { 0, 2, 3, 5, 7, 9, 11 } },
  { name = "PHRYG DOM", iv = { 0, 1, 4, 5, 7, 8, 10 } },
  { name = "HUNG MIN", iv = { 0, 2, 3, 6, 7, 8, 11 } },
  { name = "MAJ PENT", iv = { 0, 2, 4, 7, 9 } },
  { name = "MIN PENT", iv = { 0, 3, 5, 7, 10 } },
  { name = "BLUES",    iv = { 0, 3, 5, 6, 7, 10 } },
  { name = "WHOLE",    iv = { 0, 2, 4, 6, 8, 10 } },
  { name = "CHROMATIC", iv = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 } },
}

K.NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

function K.note_name(n)
  if not n then return "--" end
  return K.NOTE_NAMES[(n % 12) + 1] .. tostring(math.floor(n / 12) - 1)
end

-- ------------------------------------------------------- time signatures
--
-- A bar is the sum of its groups, in sixteenths. The groups are where the
-- grid's dim beat markers fall.

K.SIGS = {
  { name = "4/4",  g = { 4, 4, 4, 4 } },
  { name = "3/4",  g = { 4, 4, 4 } },
  { name = "2/4",  g = { 4, 4 } },
  { name = "5/4",  g = { 4, 4, 4, 4, 4 } },
  { name = "6/4",  g = { 4, 4, 4, 4, 4, 4 } },
  { name = "7/4",  g = { 4, 4, 4, 4, 4, 4, 4 } },
  { name = "5/8",  g = { 6, 4 } },
  { name = "6/8",  g = { 6, 6 } },
  { name = "7/8",  g = { 4, 4, 6 } },
  { name = "9/8",  g = { 6, 6, 6 } },
  { name = "11/8", g = { 4, 4, 4, 4, 6 } },
  { name = "12/8", g = { 6, 6, 6, 6 } },
  { name = "13/8", g = { 4, 4, 4, 4, 4, 6 } },
  { name = "15/8", g = { 6, 6, 6, 6, 6 } },
}

function K.bar_steps(si)
  local n = 0
  for _, v in ipairs((K.SIGS[si] or K.SIGS[1]).g) do n = n + v end
  return n
end

-- step i (1-based) -> 2 on a bar line, 1 on a beat, 0 otherwise
function K.marker(si, i)
  local sig = K.SIGS[si] or K.SIGS[1]
  local bar = K.bar_steps(si)
  local p = (i - 1) % bar
  if p == 0 then return 2 end
  local acc = 0
  for _, v in ipairs(sig.g) do
    acc = acc + v
    if p == acc then return 1 end
  end
  return 0
end

-- ------------------------------------------------------------ conditions

K.CONDS = { "--", "FILL", "!FILL", "PRE", "!PRE", "NEI", "!NEI", "1ST", "!1ST" }
for b = 2, 8 do
  for a = 1, b do K.CONDS[#K.CONDS + 1] = a .. ":" .. b end
end

-- the order a track walks its steps in
K.DIRS = { "FWD", "BWD", "PEND", "WALK", "RND" }

-- Metropolix-style gate modes for a step that owns several pulses
K.MODES = { "REPEAT", "HOLD", "SINGLE", "REST" }

-- ------------------------------------------------------------- keyboard

K.LAYOUTS = {
  { name = "4THS", semi = 5, deg = 3 },
  { name = "3RDS", semi = 4, deg = 2 },
  { name = "5THS", semi = 7, deg = 4 },
  { name = "SEQ",  semi = 6, deg = 6 },
}

-- ----------------------------------------------------- chord modifiers
--
-- Rows A-F of the keyboard in chord mode. Each group is a radio: one of
-- its pads at most is on. Row F holds two groups, strum and omit.

K.MODS = {
  { g = "ext",  ids = { "7", "M7", "9", "11", "13", "6" } },
  { g = "type", ids = { "SUS2", "SUS4", "MAJ", "MIN", "DIM", "AUG" } },
  { g = "inv",  ids = { "INV1", "INV2", "INV3", "DROP2", "DROP3", "SPRD" } },
  { g = "oct",  ids = { "-2", "-1", "+1", "+2", "BASS", "TOP" } },
  { g = "bor",  ids = { "PAR", "V/", "vii/", "bII", "TT", "DOM7" } },
  { g = { "strum", "strum", "strum", "omit", "omit", "omit" },
    ids = { "UP", "DOWN", "RAND", "NO R", "NO 3", "NO 5" } },
}

-- row, column (1-6) -> group, id
function K.mod_at(row, col)
  local r = K.MODS[row]
  if not r then return nil end
  local g = (type(r.g) == "table") and r.g[col] or r.g
  return g, r.ids[col]
end

-- what each modifier does, for the screen
K.MOD_GROUPS = { ext = "EXTENSION", type = "QUALITY", inv = "VOICING", oct = "OCTAVE",
  bor = "BORROWED", strum = "STRUM", omit = "OMIT" }
K.MOD_INFO = {
  ["7"] = "adds the 7th", M7 = "adds a major 7th", ["9"] = "adds 7th and 9th",
  ["11"] = "adds 7th 9th 11th", ["13"] = "adds 7th 9th 13th", ["6"] = "adds the 6th",
  SUS2 = "3rd becomes a 2nd", SUS4 = "3rd becomes a 4th", MAJ = "forces major",
  MIN = "forces minor", DIM = "diminished", AUG = "augmented",
  INV1 = "1st inversion", INV2 = "2nd inversion", INV3 = "3rd inversion",
  DROP2 = "2nd from top drops", DROP3 = "3rd from top drops", SPRD = "open, spread out",
  ["-2"] = "two octaves down", ["-1"] = "an octave down", ["+1"] = "an octave up",
  ["+2"] = "two octaves up", BASS = "root an octave below", TOP = "root an octave above",
  PAR = "from the parallel key", ["V/"] = "its own dominant 7", ["vii/"] = "its leading dim7",
  bII = "major, a semitone up", TT = "tritone sub dom 7", DOM7 = "forced dominant 7",
  UP = "strums upward", DOWN = "strums downward", RAND = "strums shuffled",
  ["NO R"] = "leaves out the root", ["NO 3"] = "leaves out the 3rd", ["NO 5"] = "leaves out the 5th",
}

-- ------------------------------------------------------------ arpeggio

K.ARPS = { "OFF", "UP", "DOWN", "UPDN", "RAND" }
K.ARP_RATES = {
  { name = "1/32", t = 3 }, { name = "1/16T", t = 4 }, { name = "1/16", t = 6 },
  { name = "1/8T", t = 8 }, { name = "1/8", t = 12 }, { name = "1/4", t = 24 },
}

-- ------------------------------------------------------------ generator

K.GEN_STYLES = { "EUCLID", "RANDOM", "ARP UP", "ARP RND", "WALK", "BASS" }
K.GEN_POOLS = { "SCALE", "LAST", "CHORDS" }
K.MUT_TARGETS = { "NOTES", "RHYTHM", "BOTH" }

-- --------------------------------------------------------- step defaults

K.STEP_DEF = {
  vel = 100, gate = 75, cond = 1, prob = 100,
  micro = 0, oct = 0, ratchet = 1, rfade = 0,
  pulses = 1, mode = 1, skip = 0, ramp = 0,
  acc = 0, limit = 4, slide = 0,
}

return K
