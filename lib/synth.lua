-- vibecomposer / synth
--
-- Each track can play the engine's wavetable voice instead of MIDI (TRACK
-- SETTINGS > OUTPUT). The voice morphs through a bank of single-cycle
-- waves the way the Synthesis Technology E350 does: every wave in a bank
-- shares its harmonics' phases and its loudness, and the voice crossfades
-- between neighbouring waves sample by sample, so turning WAVE slides the
-- timbre with nothing thinning, pumping or stepping on the way (the tables
-- are lib/wavetables, from Adventure Kid's AKWF, CC0).
--
--   OSC      BANK (BASIC HARMONIC OVERTONE VOICE ORGAN FM CHIP DIGITAL,
--            each 32 waves dark to bright), WAVE (where in the bank), SUB
--            (a sine an octave down) and FINE tune
--   FILTER   a lowpass: CUTOFF and RES
--   FG1      the function generator on the AMP: RISE and FALL, with an
--            exponential CURVE, as AD (one shot), ASR (held while the note
--            is) or CYCLE (rising and falling for as long as it is held)
--   FG2      the same, on the MODULATION: by TO WAVE onto the WAVE and by
--            TO CUT onto the CUTOFF, either way
--   LFO      RATE, SHAPE, DEPTH and where it goes: PITCH, WAVE, CUTOFF, AMP
--   MIX      the track's strip into the master COLOUR: LEVEL, PAN, the
--            DELAY and SPRING sends, DRIVE, and GLIDE for MONO tracks
--
-- tr.syn holds the values as the page shows them (plain numbers, so they
-- copy into snapshots and save with the project); Syn.send turns one into
-- what the engine takes.

local Syn = {}
local St

Syn.mono_sent = {}   -- per track: the MONO the engine has

Syn.BANKS = { "BASIC", "HARMONIC", "OVERTONE", "VOICE", "ORGAN", "FM", "CHIP", "DIGITAL" }
Syn.MODES = { "AD", "ASR", "CYCLE" }
Syn.LFO_SHAPES = { "SINE", "TRI", "SAW", "RAMP", "SQUARE", "S+H" }
Syn.LFO_DEST = { "PITCH", "WAVE", "CUTOFF", "AMP" }

-- 0-100 -> 1 ms .. 10 s, 0.02 .. 40 Hz, 20 Hz .. 20 kHz, exponentially
local function secs(v) return 0.001 * (10000 ^ (v / 100)) end
local function hz(v) return 0.02 * (2000 ^ (v / 100)) end
local function cut(v) return 20 * (1000 ^ (v / 100)) end

local function fmt_secs(v)
  local s = secs(v)
  if s < 1 then return string.format("%dms", math.floor((s * 1000) + 0.5)) end
  return string.format("%.2fs", s)
end
local function fmt_hz(v)
  local h = hz(v)
  if h < 1 then return string.format("%.2fHz", h) end
  return string.format("%.1fHz", h)
end
local function fmt_cut(v)
  local h = cut(v)
  if v >= 100 then return "OPEN" end
  if h >= 1000 then return string.format("%.1fk", h / 1000) end
  return string.format("%dHz", math.floor(h + 0.5))
end
local function signed(v) return (v > 0) and ("+" .. v) or tostring(v) end
local function pct(v) return v .. "%" end

-- key = { name, lo, hi, def, fmt, to = engine command, arg, map }
Syn.SPEC = {
  bank = { "BANK", 1, #Syn.BANKS, 1, function(v) return Syn.BANKS[v] end, "set", "bank", function(v) return v - 1 end },
  wave = { "WAVE", 0, 100, 25, tostring, "set", "wave", function(v) return v / 100 end },
  sub = { "SUB", 0, 100, 0, pct, "set", "sub", function(v) return v / 100 end },
  fine = { "FINE", -100, 100, 0, function(v) return signed(v) .. "c" end, "set", "fine", function(v) return v end },
  cut = { "CUTOFF", 0, 100, 100, fmt_cut, "set", "cut", cut },
  res = { "RES", 0, 100, 0, pct, "set", "res", function(v) return v / 100 end },
  f1r = { "RISE", 0, 100, 5, fmt_secs, "set", "f1r", secs },
  f1f = { "FALL", 0, 100, 60, fmt_secs, "set", "f1f", secs },
  f1c = { "CURVE", 0, 100, 50, pct, "set", "f1c", function(v) return v * 0.08 end },
  f1m = { "MODE", 1, 3, 2, function(v) return Syn.MODES[v] end, "set", "f1m", function(v) return v - 1 end },
  f2r = { "RISE", 0, 100, 0, fmt_secs, "set", "f2r", secs },
  f2f = { "FALL", 0, 100, 55, fmt_secs, "set", "f2f", secs },
  f2c = { "CURVE", 0, 100, 50, pct, "set", "f2c", function(v) return v * 0.08 end },
  f2m = { "MODE", 1, 3, 1, function(v) return Syn.MODES[v] end, "set", "f2m", function(v) return v - 1 end },
  f2w = { "TO WAVE", -100, 100, 30, signed, "set", "f2w", function(v) return v / 100 end },
  f2k = { "TO CUT", -100, 100, 0, signed, "set", "f2k", function(v) return v / 100 end },
  lfr = { "RATE", 0, 100, 70, fmt_hz, "lfo", "rate", hz },
  lfs = { "SHAPE", 1, #Syn.LFO_SHAPES, 1, function(v) return Syn.LFO_SHAPES[v] end, "lfo", "shape", function(v) return v - 1 end },
  lfd = { "DEPTH", 0, 100, 0, pct, "set", "lfd", function(v) return v / 100 end },
  lft = { "DEST", 1, #Syn.LFO_DEST, 1, function(v) return Syn.LFO_DEST[v] end, "set", "lft", function(v) return v - 1 end },
  level = { "LEVEL", 0, 100, 80, pct, "strip", "level", function(v) return v / 100 end },
  pan = { "PAN", -50, 50, 0, function(v)
      if v == 0 then return "C" end
      return ((v < 0) and "L" or "R") .. math.abs(v)
    end, "strip", "pan", function(v) return v / 50 end },
  dsend = { "DELAY", 0, 100, 0, pct, "strip", "dsend", function(v) return v / 100 end },
  ssend = { "SPRING", 0, 100, 0, pct, "strip", "ssend", function(v) return v / 100 end },
  drive = { "DRIVE", 0, 100, 0, pct, "strip", "drive", function(v) return v / 100 end },
  glide = { "GLIDE", 0, 100, 0, function(v)
      if v == 0 then return "OFF" end
      return string.format("%dms", math.floor(((v / 100) ^ 2) * 1000 + 0.5))
    end, "set", "glide", function(v) return (v / 100) ^ 2 end },
}

-- the SYNTH page, a lane at a time: { section, left key, right key }
Syn.LANES = {
  { "OSC", "bank", "wave" },
  { "OSC", "sub", "fine" },
  { "FILTER", "cut", "res" },
  { "FG1 AMP", "f1r", "f1f" },
  { "FG1 AMP", "f1c", "f1m" },
  { "FG2 MOD", "f2r", "f2f" },
  { "FG2 MOD", "f2c", "f2m" },
  { "FG2 MOD", "f2w", "f2k" },
  { "LFO", "lfr", "lfs" },
  { "LFO", "lfd", "lft" },
  { "MIX", "level", "pan" },
  { "MIX", "dsend", "ssend" },
  { "MIX", "drive", "glide" },
}

-- what a new track starts with
function Syn.new()
  local s = {}
  for k, p in pairs(Syn.SPEC) do s[k] = p[4] end
  return s
end

-- an older project or snapshot: anything missing at its default
function Syn.fill(s)
  s = (type(s) == "table") and s or {}
  -- anything that is no longer a setting goes (the FM voice's, say)
  for k in pairs(s) do
    if not Syn.SPEC[k] then s[k] = nil end
  end
  for k, p in pairs(Syn.SPEC) do
    if type(s[k]) ~= "number" then s[k] = p[4] end
  end
  return s
end

function Syn.init(state) St = state end

local function eng(cmd, ...)
  local f = engine and engine[cmd]
  if f then pcall(f, ...) end
end

-- one value of track t to the engine
function Syn.send(t, key)
  local tr = St.track(t)
  local p = Syn.SPEC[key]
  if not (tr and p) then return end
  local v = p[8](tr.syn[key])
  if p[6] == "set" then eng("synSet", t - 1, p[7], v)
  elseif p[6] == "lfo" then eng("synLfo", t - 1, p[7], v)
  else eng("synStrip", t - 1, p[7], v) end
end

-- everything a track's voice needs: its values, MONO, and whether it is
-- heard at all (a MIDI track's strip is muted so nothing rings on)
function Syn.push(t)
  local tr = St.track(t)
  tr.syn = Syn.fill(tr.syn)
  for k in pairs(Syn.SPEC) do Syn.send(t, k) end
  -- MONO only when it changes: the engine lets go of the track's notes
  -- when it does
  local m = tr.mono and 1 or 0
  if Syn.mono_sent[t] ~= m then
    Syn.mono_sent[t] = m
    eng("synMono", t - 1, m)
  end
  eng("synStrip", t - 1, "mute", (Syn.is_synth(t) and not tr.mute) and 0 or 1)
end

function Syn.push_all()
  for t = 1, #St.d.tracks do Syn.push(t) end
end

function Syn.is_synth(t)
  local tr = St.track(t)
  return tr ~= nil and (tr.out or 1) == 1
end

function Syn.on(t, note, vel) eng("synOn", t - 1, note, vel / 127) end
function Syn.off(t, note) eng("synOff", t - 1, note) end
function Syn.panic() eng("synPanic", -1) end

-- turn one value by encoder detents
function Syn.delta(t, key, d)
  local tr = St.track(t)
  local p = Syn.SPEC[key]
  tr.syn = Syn.fill(tr.syn)
  local v = math.min(math.max(tr.syn[key] + d, p[2]), p[3])
  if v ~= tr.syn[key] then
    tr.syn[key] = v
    Syn.send(t, key)
  end
end

function Syn.name(key) return Syn.SPEC[key][1] end
function Syn.fmt(t, key)
  local tr = St.track(t)
  tr.syn = Syn.fill(tr.syn)
  return Syn.SPEC[key][5](tr.syn[key])
end

return Syn
