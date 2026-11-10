-- vibe composer
--
-- 8 track sequencer, wavetable synth
-- or MIDI on every track, and
-- an 8 voice drum machine
-- for norns + grid 128
--
-- isomorphic and chord
-- keyboards, trig conditions,
-- Metropolix stages, clips,
-- snapshots. track 8 transposes
-- or harmonises the rest.
--
-- K2 / K3 scene: MELODIC,
--   DRUMS, COLOUR
-- E1 lane / track
-- E2 E3 left / right value
-- K1 home and back (melodic),
--   fine adjust held (drums)
--
-- see README

engine.name = "VibeComposer"

local K  = include("lib/const")
local St = include("lib/state")
local O  = include("lib/midiout")
local Q  = include("lib/seq")
local Kb = include("lib/keys")
local Gn = include("lib/gen")
local N  = include("lib/snap")
local P  = include("lib/pages")
local G  = include("lib/gridui")
local Syn = include("lib/synth")
local D  = include("lib/dd/drum")

local screen_metro, grid_metro, lfo_metro
local clock_id
local g   -- the grid

-- the live modules, for the maiden repl
vibecomposer = { state = St, seq = Q, keys = Kb, grid = G, pages = P, snap = N, gen = Gn, out = O,
  synth = Syn, drum = D }

-- -------------------------------------------------------------- scenes
--
-- K2 and K3 step through the scenes, round and round: the MELODIC
-- sequencer (lib/gridui, lib/pages), the DRUMS (lib/dd) and the master
-- COLOUR (the drums' COLOUR page and the punch-in effects, which every
-- track, synth or drum, goes through). The sequencers play on whatever is
-- showing: a scene is only what the grid and the screen are for.

local MELODIC, DRUMS, COLOUR = 1, 2, 3
local scene = MELODIC
vibecomposer.scene = function() return scene end

local function set_scene(i)
  if i == scene then return end
  -- whatever the old face had held is let go of
  Kb.release_all()
  G.drop_held()
  D.G.release_all()
  scene = i
  if i == COLOUR then D.St.page = "colour"
  elseif D.St.page == "colour" then D.St.page = "main" end
  Q.dirty = true
  D.St.dirty = true
end
vibecomposer.set_scene = set_scene

-- the drum and COLOUR faces draw into this, then it goes to the grid
local gbuf = {}
local adapter = {
  led = function(_, x, y, l)
    gbuf[((y - 1) * 16) + x] = math.floor(math.min(math.max(l, 0), 15))
  end,
  all = function(_, l) for i = 1, 128 do gbuf[i] = l end end,
  refresh = function() end,
}

local function grid_redraw()
  if scene == MELODIC then
    G.redraw()
    return
  end
  if not g then return end
  G.fill_tick()
  for i = 1, 128 do gbuf[i] = 0 end
  if scene == DRUMS then D.G.draw() else D.CG.draw() end
  -- PLAY and STOP are the same pads, lit the same way, everywhere
  G.draw_transport(function(x, y, l) gbuf[((y - 1) * 16) + x] = l end)
  for y = 1, 8 do
    for x = 1, 16 do g:led(x, y, gbuf[((y - 1) * 16) + x]) end
  end
  g:refresh()
end

local function grid_key(x, y, z)
  local b1, b2 = K.BTN.PLAY, K.BTN.STOP
  if (x == b1[1] and y == b1[2]) or (x == b2[1] and y == b2[2]) then
    G.key(x, y, z)
  elseif scene == MELODIC then G.key(x, y, z)
  elseif scene == DRUMS then D.G.key(x, y, z)
  else D.CG.key(x, y, z) end
end
vibecomposer.grid_key = grid_key
vibecomposer.grid_redraw = grid_redraw

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
    Syn.panic()
    for t = 1, K.NTRACKS do
      local tr = St.track(t)
      if tr.out == 2 then O.ports[tr.dev]:cc(123, 0, tr.ch) end
    end
  end)
  params:add_separator("vc_dd_sep", "DRUMS + COLOUR")
  D.add_params()
end

-- a MIDI track's program change
local function programs()
  for t = 1, K.NTRACKS do
    local tr = St.track(t)
    if tr.out == 2 then O.program(tr.dev, tr.ch, tr.prog) end
  end
end

-- ------------------------------------------------------------- ui state
--
-- What a snapshot and the saved project carry besides St.d's own settings:
-- which keyboard is up, the selected track, the notes a step press takes,
-- and the transposition track 8 was last given live.

local function ui_out()
  -- the drums are part of the song
  St.d.drums = D.capture()
  St.d.ui = {
    mode = Kb.mode,
    sel = G.sel,
    last = St.copy(Kb.last),
    last_chord = St.copy(Kb.last_chord),
    chord_name = Kb.chord_name,
    master = St.copy(Q.master_now()),
  }
end

local function ui_in()
  local u = St.d.ui
  if type(u) ~= "table" then return end
  if u.mode then Kb.set_mode(u.mode) end
  if u.sel then
    G.select(u.sel)
    P.tset_track = nil
  end
  if u.last and u.last.notes then Kb.last = St.copy(u.last) end
  Kb.last_chord = St.copy(u.last_chord)
  Kb.chord_name = u.chord_name
  -- no transposition saved: none from here on
  Q.live_master(u.master and St.copy(u.master) or nil)
end

-- ---------------------------------------------------------------- init

function init()
  St.load()
  O.init()
  Syn.init(St)
  O.synth = { on = Syn.on, off = Syn.off }
  Q.init(St, O)
  Kb.init(St, Q, O)
  Gn.init(St, Kb)
  N.init(St, Q)
  N.load_file()
  P.init(St, Q, Kb, G, Gn, O, Syn)
  P.build_synth()
  G.init(St, Q, Kb, N, Gn, P)
  D.init(Q, St, N, G, Syn)
  D.G.draw_snaps = G.draw_snaps
  D.G.on_colour = function() set_scene(COLOUR) end
  D.swing_delta = function(d)
    St.d.swing = math.min(math.max(St.d.swing + d, 50), 75)
  end
  N.before_capture = ui_out
  N.on_load = function()
    Kb.release_all()
    D.G.release_all()
    ui_in()
    programs()
    Syn.push_all()
    D.apply(St.d.drums)
    -- stopped: the drums from the top as well
    if not Q.playing and not Q.paused then D.Q.reset(0) end
  end
  Kb.show = P.show
  ui_in()
  Q.on_tick = Kb.arp_tick

  add_params()
  load_config()
  O.adopt_norns_clock()
  -- the drums as the script starts them, then the project's over them
  D.capture_init()
  if St.d.drums then D.apply(St.d.drums) end

  if Q.source() == 1 and St.d.tempo then params:set("clock_tempo", St.d.tempo) end
  programs()

  for n = 1, 16 do
    O.ports[n].event = function(data)
      local msg = midi.to_msg(data)
      if msg then Q.midi_in(msg) end
    end
  end

  clock.transport.start = function() Q.ext_start() end
  clock.transport.stop = function() Q.ext_stop() end

  g = grid.connect()
  G.g = g
  D.G.set_grid(adapter)
  D.CG.set_grid(adapter)
  g.key = grid_key

  clock_id = clock.run(Q.run)

  -- give the engine a moment to finish alloc, then every value at it
  clock.run(function()
    clock.sleep(0.3)
    params:bang()
    Syn.push_all()
    D.start_polls()
  end)

  screen_metro = metro.init(function()
    D.frame(1 / 15, scene == COLOUR)
    redraw()
  end, 1 / 15)
  screen_metro:start()

  grid_metro = metro.init(function()
    N.tick(1 / 30)
    grid_redraw()
  end, 1 / 30)
  grid_metro:start()

  lfo_metro = metro.init(function()
    D.lfo_tick(1 / 30)
  end, 1 / 30)
  lfo_metro:start()
end

function cleanup()
  Q.stop()
  if clock_id then clock.cancel(clock_id) end
  for _, m in ipairs({ screen_metro, grid_metro, lfo_metro }) do
    if m then m:stop() end
  end
  D.cleanup()
  St.d.tempo = params:get("clock_tempo")
  ui_out()
  St.save()
  N.save_file()
  O.restore_norns_clock()
end

-- ---------------------------------------------------------------- norns

-- K1: melodic, HOME and back; drums and COLOUR, fine adjust while held.
-- K2 / K3: the scene back and on (K3 with a drum control's screen open is
-- that control's extra, see lib/dd/drum).
function key(n, z)
  if n == 1 then
    if scene == MELODIC then
      if z == 1 then P.home_toggle() end
    else
      D.k1 = (z == 1)
    end
  elseif z == 1 then
    if n == 3 and scene ~= MELODIC and D.k3() then
      D.St.dirty = true
      return
    end
    set_scene(((scene - 1 + ((n == 2) and -1 or 1)) % 3) + 1)
  end
  Q.dirty = true
end

function enc(n, d)
  if scene == MELODIC then P.enc(n, d) else D.enc(n, d) end
end

function redraw()
  if scene == MELODIC then P.redraw() else D.redraw() end
end
