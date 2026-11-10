-- vibecomposer / dd / drum
--
-- The drum machine, ported from drumdrum: eight voices, each a synth with
-- a sample under it, four kits, per-step locks and conditions, clips, a
-- sampler, punch-in effects and the master COLOUR. This is what
-- drumdrum.lua was (the encoders, the control edits, the polls), wired to
-- vibe composer's clock, grid, snapshots and screen by vibecomposer.lua.
--
-- norns keys on the DRUM and COLOUR scenes: K2 and K3 change scene (as
-- everywhere), K1 held is fine adjust. With a control's screen open (a
-- control held), K3 is that control's extra: an LFO's next SHAPE, or the
-- sampler's take NOW / STOP.

local S  = include("lib/dd/spec")
local St = include("lib/dd/state")
local Q  = include("lib/dd/seq")
local L  = include("lib/dd/lfo")
local G  = include("lib/dd/gridui")
local CG = include("lib/dd/colourgrid")
local N  = include("lib/dd/snap")
local F  = include("lib/dd/perform")
local C  = include("lib/dd/clips")
local R  = include("lib/dd/sampler")
local U  = include("lib/dd/ui")

local D = { S = S, St = St, Q = Q, L = L, G = G, CG = CG, N = N, F = F, C = C, R = R, U = U }

D.k1 = false
local polls = {}

-- -------------------------------------------------------------------- edits

-- one encoder turn on an open control
local function ctrl_enc(btn, side, d)
  local k1 = D.k1
  local t = St.sel
  local tr = St.track()
  local b = S.BTN[btn]
  local p = S.pair(t, btn)[side]
  local held = G.held_steps()
  local shift = G.shift_held()

  if S.STEP_KIND[b.kind] then
    local targets = {}
    if #held > 0 then
      for _, i in ipairs(held) do
        if tr.steps[i] then targets[#targets + 1] = tr.steps[i] end
      end
      G.mark_edited()
    else
      targets[1] = tr.tpl
    end
    for _, st in ipairs(targets) do
      local v = (st[p.key] or p.def) + d
      st[p.key] = util.clamp(math.floor(v + 0.5), p.lo, p.hi)
    end
    return
  end

  if p.special == "sample" and not (shift and #held == 0) then
    St.sample_delta(t, d)
    return
  end

  local key = btn .. side
  local id = St.pid(t, key)
  -- SET held, no steps: the same control on every track, each in its own
  -- range (a voice's PITCH spans differ, and so do kits' T params)
  if shift and #held == 0 then
    G.M.s_used = true
    for u = 1, S.NTRACKS do
      if p.special == "sample" then St.sample_delta(u, d)
      else St.delta(St.pid(u, key), d, k1) end
    end
    return
  end
  if #held > 0 then
    local q = St.raw_step(id, k1)
    for _, i in ipairs(held) do
      local st = tr.steps[i]
      if st then
        st.locks = st.locks or {}
        local base = st.locks[key] or params:get_raw(id)
        st.locks[key] = util.clamp(base + (d * q), 0, 1)
      end
    end
    G.mark_edited()
  else
    St.delta(id, d, k1)
  end
end

-- STOP (CLEAR) on a control with steps held: drop that button's locks
local function clear_locks(btn)
  local tr = St.track()
  for _, i in ipairs(G.held_steps()) do
    local st = tr.steps[i]
    if st and st.locks then
      st.locks[btn .. "a"] = nil
      st.locks[btn .. "b"] = nil
      if next(st.locks) == nil then st.locks = nil end
    end
  end
  G.mark_edited()
end

-- the tracks an encoder turn moves: the selected one, or with SET all
local function enc_tracks()
  if not G.shift_held() then return { St.sel } end
  G.M.s_used = true
  local out = {}
  for t = 1, S.NTRACKS do out[t] = t end
  return out
end

-- MAIN's LENGTH / TIMING / DIRECTION / DILLA: the selected track, or with
-- SET held every track, all set to the selected track's new value
local function main_set(field, v)
  if G.shift_held() then
    G.M.s_used = true
    for t = 1, S.NTRACKS do St.tracks[t][field] = v end
  else
    St.track()[field] = v
  end
end

-- STOP + control: back to where the script starts it. Over held steps a
-- sound control loses its locks; TC and P go back to a plain step. With
-- none held, TC and P reset the template.
local function reset_ctrl(btn)
  local t = St.sel
  local b = S.BTN[btn]
  if b.kind == "lfo" then
    local pre = St.pid(t, "l" .. b.lfo .. "_")
    for _, k in ipairs({ "rate", "depth", "shape" }) do St.reset(pre .. k) end
    L.unpatch(t, b.lfo)
    return
  end
  local pair = S.pair(t, btn)
  local held = G.held_steps()
  local tr = St.track()
  if S.STEP_KIND[b.kind] then
    local targets = {}
    if #held > 0 then
      for _, i in ipairs(held) do targets[#targets + 1] = tr.steps[i] end
      G.mark_edited()
    else
      targets[1] = tr.tpl
    end
    for _, st in ipairs(targets) do
      st[pair.a.key] = pair.a.def
      st[pair.b.key] = pair.b.def
    end
  elseif #held > 0 then
    clear_locks(btn)
  else
    for _, side in ipairs({ "a", "b" }) do
      if not pair[side].special then St.reset(St.pid(t, btn .. side)) end
    end
  end
end

-- ---------------------------------------------------------------------- init

-- vq: lib/seq, vst: lib/state, vsnap: lib/snap, vgrid: lib/gridui
function D.init(vq, vst, vsnap, vgrid, synth)
  St.init()
  -- the engine class only compiles when norns starts: one from before
  -- this script's has no synth command
  St.old_engine = type(engine.commands) == "table" and engine.commands.synOn == nil
  if St.old_engine then print("vibecomposer: the engine is out of date -- SYSTEM > RESTART") end
  L.init()
  St.lfo = L
  Q.init(St, vq)
  Q.swing_amt = function() return vst.d.swing end
  U.swing_amt = Q.swing_amt
  U.vsnap = vsnap
  C.init(St, Q)
  St.clips = C
  N.init_mod(St, Q, L, C)
  F.init(St)
  F.now_beats = Q.now_beats
  F.wait_line = Q.wait_line
  Q.on_tick = C.on_tick
  Q.on_halt = C.on_stop
  R.init(St, Q)
  Q.on_begin = R.on_begin
  Q.rain = C.rain
  Q.on_rain = C.splash
  G.init(St, Q, L, C, R, vsnap)
  G.M = vgrid
  G.F = F
  G.on_clear_ctrl = function(btn) reset_ctrl(btn) St.dirty = true end
  CG.init(St, F, vst, synth)
  CG.M = vgrid
  U.init(St, G, L, N, F, C, R)
  St.on_hit = function(t, vel) U.ripple(t, vel) end
  vq.follow = Q
end

function D.add_params()
  St.build_params()
  F.add_params()
  R.add_params()
end

-- after params exist and before anything is loaded over them: the INIT
-- patch, what a blank snapshot gives the drums
function D.capture_init() N.capture_init() end

function D.start_polls()
  for i = 1, S.NTRACKS do
    local p = poll.set("meter" .. i, function(v) St.meter[i] = v or 0 end)
    if p then
      p.time = 1 / 20
      p:start()
      polls[#polls + 1] = p
    end
  end
  local po = poll.set("outamp", function(v) St.outamp = v or 0 end)
  if po then
    po.time = 1 / 30
    po:start()
    polls[#polls + 1] = po
  end
  for name, f in pairs(R.POLLS) do
    local ps = poll.set(name, f)
    if ps then
      ps.time = 1 / 30
      ps:start()
      polls[#polls + 1] = ps
    end
  end
end

function D.cleanup()
  for _, p in ipairs(polls) do p:stop() end
  polls = {}
end

-- every screen frame (1/15 s, the screen's own metro)
function D.frame(dt, colour_visible)
  for _, tr in ipairs(St.tracks) do
    if tr.flash > 0 then tr.flash = math.max(tr.flash - (dt * 4), 0) end
  end
  if colour_visible then U.vis_update(dt) end
end

-- every LFO frame (1/30 s)
function D.lfo_tick(dt)
  L.step(dt)
  St.push_modulated()
  St.follow_tempo()
end

-- --------------------------------------------------------------- keys / encs

-- K3 on the DRUM or COLOUR scene: true if a control's screen took it
function D.k3()
  local kind, btn = G.overlay()
  if kind == "rec" then
    R.now()
    return true
  end
  if kind == "ctrl" and G.stack[#G.stack] == btn then
    local b = S.BTN[btn]
    if b.kind == "lfo" then
      local id = St.pid(St.sel, "l" .. b.lfo .. "_shape")
      local cur = math.floor(params:get(id) + 0.5)
      params:set(id, (cur % #S.LFO_SHAPES) + 1)
      return true
    end
  end
  return false
end

-- hold an LFO and a sound control: the first turn of E2 or E3 patches
-- that side, turning on is the depth
local function patch_enc(n, d)
  local pt = G.patch
  local t = St.sel
  local side = (n == 2) and "a" or "b"
  if L.side_on(t, pt.lfo, pt.btn) == side then
    St.delta(St.pid(t, "l" .. pt.lfo .. "_depth"), d, D.k1)
  else
    L.set_target(t, pt.lfo, pt.btn, side)
  end
end

-- swing is vibe composer's (St.d.swing), turned from here too
D.swing_delta = function() end

function D.enc(n, d)
  local k1 = D.k1
  local kind, btn = G.overlay()

  if n == 1 then
    if kind == "rec" then
      params:delta("rec_mode", d)
    elseif kind == "swing" or kind == "rain" then
      St.delta("rain", d, k1)
    elseif St.page == "colour" and not kind then
      St.col_sel = util.clamp(St.col_sel + d, 1, #S.COLOUR)
    elseif St.page == "main" and not kind then
      St.main_pair = util.clamp(St.main_pair + d, 1, #S.MAIN_PAIRS)
    else
      local t = util.clamp(St.sel + d, 1, S.NTRACKS)
      if t ~= St.sel then
        G.drop_held()
        St.select(t)
      end
    end
    St.dirty = true
    return
  end

  if kind == "rec" then
    if n == 2 then St.delta("rec_thresh", d, k1)
    else params:delta("rec_src", d) end
  elseif kind == "tape" or (St.page == "colour" and CG.tape) then
    if n == 2 then St.delta("tape_pitch", d, k1)
    else params:delta("tape_len", d) end
  elseif kind == "ctrl" then
    local b = S.BTN[btn]
    if b.kind == "lfo" and G.patch then
      patch_enc(n, d)
    elseif b.kind == "lfo" then
      local k = (n == 2) and "rate" or "depth"
      for _, t in ipairs(enc_tracks()) do
        St.delta(St.pid(t, "l" .. b.lfo .. "_" .. k), d, k1)
      end
    else
      ctrl_enc(btn, (n == 2) and "a" or "b", d)
    end
  elseif kind == "swing" then
    if n == 2 then D.swing_delta(d)
    else params:delta("swing_grid", d) end
  elseif kind == "rain" then
    if n == 2 then St.delta("rain", d, k1) end
  elseif St.page == "mix" then
    local k = (n == 2) and "pan" or "tilt"
    for _, t in ipairs(enc_tracks()) do St.delta(St.pid(t, k), d, k1) end
  elseif St.page == "colour" then
    local cell = S.COLOUR[St.col_sel]
    local p = (n == 2) and cell.a or cell.b
    St.delta("col_" .. p.arg, d, k1)
  elseif St.page == "main" then
    local tr = St.track()
    if St.main_pair == 1 then
      if n == 2 then main_set("len", util.clamp(tr.len + d, 1, S.NSTEPS))
      else main_set("speed", util.clamp(tr.speed + d, 1, #S.SPEEDS)) end
    else
      if n == 2 then main_set("dir", util.clamp(tr.dir + d, 1, #S.DIRS))
      else main_set("dilla", util.clamp(tr.dilla + d, 0, 100)) end
    end
  else
    -- SESSION: the tempo
    if n == 2 then params:delta("clock_tempo", d) end
  end
  St.dirty = true
end

function D.redraw() U.redraw() end

-- ------------------------------------------------------------- the project

-- the drums, for the project file and snapshots
function D.capture() return N.capture() end
function D.apply(snap) N.apply(snap) end

return D
