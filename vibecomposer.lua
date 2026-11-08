-- vibe composer
--
-- 8 track MIDI sequencer
-- for norns + grid 128
--
-- isomorphic and chord
-- keyboards, trig conditions,
-- Metropolix stages, clips,
-- snapshots. track 8 transposes
-- or harmonises the rest.
--
-- E1 lane / track
-- E2 E3 left / right value
-- K2 steps 1-32 / 33-64
-- K3 home and back
--
-- see README

local K  = include("lib/const")
local St = include("lib/state")
local O  = include("lib/midiout")
local Q  = include("lib/seq")
local Kb = include("lib/keys")
local Gn = include("lib/gen")
local N  = include("lib/snap")
local P  = include("lib/pages")
local G  = include("lib/gridui")

local screen_metro, grid_metro
local clock_id

-- the live modules, for the maiden repl
vibecomposer = { state = St, seq = Q, keys = Kb, grid = G, pages = P, snap = N, gen = Gn, out = O }

-- -------------------------------------------------------------- config
--
-- Which ports get our MIDI clock is the machine's, not the project's: it
-- lives in its own file.

local function config_path()
  return norns.state.data .. "config.data"
end

local function save_config()
  local c = { clock_out = {} }
  for n in pairs(O.clock_out) do c.clock_out[n] = true end
  if tab and tab.save then pcall(tab.save, c, config_path()) end
end

local function load_config()
  if not (util.file_exists(config_path()) and tab and tab.load) then return end
  local ok, c = pcall(tab.load, config_path())
  if ok and type(c) == "table" and c.clock_out then
    for n in pairs(c.clock_out) do params:set("vc_clock_out_" .. n, 2) end
  end
end

local function add_params()
  params:add_separator("vc_sep", "VIBE COMPOSER")
  params:add_group("vc_clock", "MIDI CLOCK OUT", 16)
  for n = 1, 16 do
    params:add_option("vc_clock_out_" .. n, "port " .. n, { "off", "clock+transport" }, 1)
    params:set_action("vc_clock_out_" .. n, function(v)
      O.set_clock_out(n, v == 2)
      save_config()
    end)
  end
  params:add_trigger("vc_panic", "all notes off")
  params:set_action("vc_panic", function()
    O.all_off()
    for t = 1, K.NTRACKS do
      local tr = St.track(t)
      O.ports[tr.dev]:cc(123, 0, tr.ch)
    end
  end)
end

-- ---------------------------------------------------------------- init

function init()
  St.load()
  O.init()
  Q.init(St, O)
  Kb.init(St, Q, O)
  Gn.init(St, Kb)
  N.init(St, Q)
  N.load_file()
  P.init(St, Q, Kb, G, Gn, O)
  G.init(St, Q, Kb, N, Gn, P)
  N.on_load = function() Kb.release_all() end

  add_params()
  load_config()
  O.adopt_norns_clock()

  if Q.source() == 1 and St.d.tempo then params:set("clock_tempo", St.d.tempo) end
  for t = 1, K.NTRACKS do
    local tr = St.track(t)
    O.program(tr.dev, tr.ch, tr.prog)
  end

  for n = 1, 16 do
    O.ports[n].event = function(data)
      local msg = midi.to_msg(data)
      if msg then Q.midi_in(msg) end
    end
  end

  clock.transport.start = function() Q.ext_start() end
  clock.transport.stop = function() Q.ext_stop() end

  G.g = grid.connect()
  G.g.key = function(x, y, z) G.key(x, y, z) end

  clock_id = clock.run(Q.run)

  screen_metro = metro.init(function()
    redraw()
  end, 1 / 15)
  screen_metro:start()

  grid_metro = metro.init(function()
    N.tick(1 / 30)
    G.redraw()
  end, 1 / 30)
  grid_metro:start()
end

function cleanup()
  Q.stop()
  if clock_id then clock.cancel(clock_id) end
  for _, m in ipairs({ screen_metro, grid_metro }) do
    if m then m:stop() end
  end
  St.d.tempo = params:get("clock_tempo")
  St.save()
  N.save_file()
  O.restore_norns_clock()
end

-- ---------------------------------------------------------------- norns

function key(n, z)
  if z ~= 1 then return end
  if n == 2 then
    G.steppage = (G.steppage == 1) and 2 or 1
  elseif n == 3 then
    P.home_toggle()
  end
  Q.dirty = true
end

function enc(n, d)
  P.enc(n, d)
end

function redraw()
  P.redraw()
end
