-- vibecomposer / midiout
--
-- Notes out, MIDI clock out, transport out.
--
-- SYNTH. A track whose OUTPUT is SYNTH plays the engine's wavetable voice. Its
-- notes go through here all the same, on port 0 with the track as the
-- channel (O.dest), so the token bookkeeping below covers them too.
--
-- NOTES. Every note on is remembered by port, channel and note, with a
-- token. Its note off only goes out while that token is still the one
-- sounding, so a note retriggered before its old note off (a slide, a
-- ratchet onto itself) is not cut short by the older note's off. A stop
-- sends a note off for everything still sounding.
--
-- CLOCK. norns' own MIDI clock out (SYSTEM > CLOCK > midi clock out) sends
-- 0xF8 ticks but never Start, Stop, Continue or a song position. A slave
-- needs those to land its beat 1 on ours, so this script sends the clock
-- itself, from the same 1/24-beat coroutine that runs the sequencer: the
-- Start goes out immediately before the tick that is our beat 1, and the
-- slave counts its beat 1 from exactly that tick. Turning a port on here
-- turns norns' clock out off on that port, so it never gets two clocks; the
-- norns setting comes back when the script exits.

local O = {}

O.ports = {}        -- vport n -> midi.connect(n)
O.active = {}       -- key -> token
O.clock_out = {}    -- vport n -> true
O.SYNTH = 0         -- the port a synth track's notes go to
O.synth = nil       -- set by the script: { on = f(t, note, vel), off = f(t, note) }
local tok = 0
local borrowed = {} -- norns clock_midi_out_n we turned off, to give back

function O.init()
  for n = 1, 16 do O.ports[n] = midi.connect(n) end
end

function O.name(n)
  local v = midi.vports and midi.vports[n]
  local s = (v and v.name) or ""
  if s == "" or s == "none" then return n .. ": --" end
  return n .. ": " .. s
end

local function call(port, f, ...)
  local d = O.ports[port]
  if d and d[f] then pcall(d[f], d, ...) end
end

-- where track t's notes go: port and channel
function O.dest(tr, t)
  if (tr.out or 1) == 1 then return O.SYNTH, t end
  return tr.dev, tr.ch
end

local function note_on(port, ch, note, vel)
  if port == O.SYNTH then
    if O.synth then O.synth.on(ch, note, vel) end
  else
    call(port, "note_on", note, vel, ch)
  end
end

local function note_off(port, ch, note)
  if port == O.SYNTH then
    if O.synth then O.synth.off(ch, note) end
  else
    call(port, "note_off", note, 0, ch)
  end
end

local function key(port, ch, note) return (port * 4096) + (ch * 128) + note end

function O.on(port, ch, note, vel)
  local k = key(port, ch, note)
  if O.active[k] then note_off(port, ch, note) end
  tok = tok + 1
  O.active[k] = tok
  note_on(port, ch, note, vel)
  return k, tok
end

function O.off(k, token)
  if O.active[k] ~= token then return end
  O.active[k] = nil
  local port = math.floor(k / 4096)
  local ch = math.floor((k % 4096) / 128)
  note_off(port, ch, k % 128)
end

function O.all_off()
  local list = {}
  for k, t in pairs(O.active) do list[#list + 1] = { k, t } end
  for _, e in ipairs(list) do O.off(e[1], e[2]) end
  O.active = {}
end

function O.program(port, ch, p)
  if p and p >= 0 then call(port, "program_change", p, ch) end
end

-- ----------------------------------------------------------------- clock

local function norns_out_id(n) return "clock_midi_out_" .. n end

local function has_param(id)
  if params.lookup then return params.lookup[id] ~= nil end
  return pcall(function() return params:get(id) end)
end

function O.set_clock_out(n, on)
  O.clock_out[n] = on or nil
  local id = norns_out_id(n)
  if on and has_param(id) and params:get(id) == 1 then
    params:set(id, 0)
    borrowed[n] = true
  end
end

-- a port norns was already clocking: take it over, so it gets transport too
function O.adopt_norns_clock()
  for n = 1, 16 do
    local id = norns_out_id(n)
    if has_param(id) and params:get(id) == 1 then
      -- the param's action calls O.set_clock_out
      params:set("vc_clock_out_" .. n, 2)
    end
  end
end

function O.restore_norns_clock()
  for n in pairs(borrowed) do
    pcall(function() params:set(norns_out_id(n), 1) end)
  end
  borrowed = {}
end

local function each(f, ...)
  for n in pairs(O.clock_out) do call(n, f, ...) end
end

function O.any_clock() return next(O.clock_out) ~= nil end
function O.tick() each("clock") end
function O.start() each("start") end
function O.stop() each("stop") end
function O.continue() each("continue") end

-- position in sixteenths, sent while stopped
function O.song_position(spp)
  spp = math.max(0, math.min(spp, 16383))
  each("song_position", spp % 128, math.floor(spp / 128))
end

return O
