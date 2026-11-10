-- vibecomposer / dd / grid
--
-- The drum machine's faces (ported from drumdrum, laid out to match the
-- melodic grid; the layout is drawn in lib/dd/spec):
--
--   MAIN     rows A-D the selected track's 64 steps, rows E-F its
--            controls, row G the tracks
--   SESSION  (SET) rows A-D under each track: its four clips. The 48 pads
--            on the right, columns 11-16: the song's snapshots, the same
--            ones the melodic session view has (lib/snap). Row E, columns
--            1-4: the kits WARM WOOD FM ADD: tap one for every track, or
--            hold one and press track buttons to move only those
--   MIX      a fader with a meter over each track's button (rows A-F),
--            pan on rows A-D, columns 10-12 (tracks 1-4) and 14-16 (5-8)
--   COLOUR   the COLOUR scene's grid: lib/dd/colourgrid
--
-- Row H is shared with the melodic grid: PLAY, STOP and SET work the same
-- (the scene router hands them to lib/gridui). STOP held is CLEAR and SET
-- held is SHIFT, the drum machine's two modifiers.
--
-- CLEAR (STOP held) takes things away. + step: back to a plain hit. +
-- track: the track's pattern gone. + control: that control reset (or its
-- locks off the held steps). + clip slot: emptied. + snapshot (hold):
-- deleted.
--
-- SHIFT (SET held). + step: the track's length. + control: keep it open
-- (the same again, or another, closes it). + track: hear the track. + E2 /
-- E3: every track. + COLOUR held: the hidden TAPE.
--
-- SAMPLER: hold S1 and SET and the steps are a record length (lib/dd/sampler).
-- Tap one to arm the selected track for that many steps, the same one again
-- to disarm. A take recording fills the steps as it goes.
--
-- Steps: a press on an empty step places one at once. A press on a placed
-- step holds it; let go quickly without having turned anything and it is
-- removed. While steps are held, any control you open edits THOSE steps --
-- TONE / SAMPLE / NOISE / COLOUR become parameter locks, TRIG and PULSE edit
-- the steps' own conditions.
--
-- Controls are momentary: the screen is open while the button is held.
-- Hold an LFO and a sound control together and E2 / E3 patch it.

local S = include("lib/dd/spec")

local G = {}
local g, St, Q, L, C, R, VS   -- VS: vibe composer's snapshots (lib/snap)

G.M = nil          -- vibe composer's grid (lib/gridui): its STOP and SET holds
G.held = {}        -- held steps, oldest first: { i, t0, new, edited }
G.stack = {}       -- control buttons physically held, oldest first
G.latched = nil
G.lock = nil       -- a sound control opened over held steps, kept open on
                   -- those steps after letting go: { btn, steps = { i... } }
G.swallow = {}     -- steps whose press closed the lock: their release does nothing
G.patch = nil      -- an LFO and a sound control held together: { lfo, btn }
G.on_clear_ctrl = nil  -- CLEAR + control (lib/dd/drum: reset that control)
G.swing = false
G.rain = false
G.tape = false     -- the hidden TAPE: SET + COLOUR, on while COLOUR is held
G.kit = nil        -- SESSION: a kit button held, { k, used }: let go unused, it is every track
G.on_colour = nil  -- COLOUR pressed: the scene router goes to the COLOUR scene

-- pan: three buttons a track, nudge left, centre, nudge right
local PAN_STEP = 0.1

local KEY_X0, KEY_W = 11, 6   -- the snapshots, where the melodic keyboard is

function G.init(state, seq, lfo, clips, sampler, vsnap)
  St, Q, L, C, R, VS = state, seq, lfo, clips, sampler, vsnap
end

function G.set_grid(dev) g = dev end

-- the modifiers live on the melodic grid's STOP and SET
local function clear() return G.M and G.M.stop_held end
local function cleared() if G.M then G.M.stop_used = true end end
local function shift() return G.M and G.M.s_held end
local function shifted() if G.M then G.M.s_used = true end end
G.shift_held = shift

-- ------------------------------------------------------------------ queries

-- what the screen should show over the page, if anything
function G.overlay()
  if G.tape then return "tape" end
  local top = G.stack[#G.stack]
  if top then return "ctrl", top end
  if G.swing then return "swing" end
  if G.rain then return "rain" end
  if G.lock then return "ctrl", G.lock.btn end
  if G.latched then return "ctrl", G.latched end
  if R and R.active() and St.page == "main" then return "rec" end
  return nil
end

-- the steps a control edits: the ones under a finger, plus a lock's
function G.held_steps()
  local out, seen = {}, {}
  for _, h in ipairs(G.held) do out[#out + 1] = h.i; seen[h.i] = true end
  if G.lock then
    for _, i in ipairs(G.lock.steps) do
      if not seen[i] then out[#out + 1] = i end
    end
  end
  return out
end

function G.drop_held()
  G.held, G.lock, G.swallow = {}, nil, {}
end

-- the LFO a finger is on, if any: patching only happens while held
function G.held_lfo()
  for k = #G.stack, 1, -1 do
    local b = S.BTN[G.stack[k]]
    if b.kind == "lfo" then return b.lfo end
  end
  return nil
end

function G.mark_edited()
  for _, h in ipairs(G.held) do h.edited = true end
end

function G.release_all()
  G.held, G.stack, G.kit = {}, {}, nil
  G.patch = nil
  G.lock, G.swallow = nil, {}
  G.swing, G.rain = false, false
  C.hold = nil
end

local function remove(list, pred)
  for k = #list, 1, -1 do
    if pred(list[k]) then return table.remove(list, k) end
  end
end

-- -------------------------------------------------------------------- keys

-- the tracks on row G
local function track_key(t, z)
  if z ~= 1 then return end
  if clear() then
    -- CLEAR + track: the playing clip's steps gone, as on the melodic grid
    cleared()
    C.clear_slot(t, St.tracks[t].clip)
    if t == St.sel then G.drop_held() end
  elseif G.kit then
    -- holding a kit in SESSION: this track to it, the rest left alone
    St.set_kit(t, G.kit.k)
    G.kit.used = true
  elseif shift() then
    shifted()
    St.audition(t)
  elseif St.page == "mix" then
    St.toggle_mute(t)
  elseif t ~= St.sel then
    G.drop_held()
    St.select(t)
  else
    -- the selected track again: hear it
    St.audition(t)
  end
end

-- row H: SWING, MIX, COLOUR and SET (PLAY and STOP are the router's)
local function rowh(x, z)
  local H = S.ROWH
  if x == H.set then
    if z == 1 then
      G.M.s_held, G.M.s_used = true, false
    else
      G.M.s_held = false
      if not G.M.s_used then
        -- SET on its own: the session view and back
        St.page = (St.page == "session") and "main" or "session"
        G.release_all()
      end
    end
  elseif x == H.swing then
    G.swing = (z == 1)
  elseif x == H.colour and (G.tape or (shift() and z == 1)) then
    -- the hidden TAPE: on with SET, off with COLOUR, whatever SET does
    shifted()
    G.tape = (z == 1)
    if G.tape then G.F.tape_on() else G.F.tape_off() end
  elseif x == H.colour then
    if z == 1 and G.on_colour then G.on_colour() end
  elseif x == H.mix then
    if z == 1 then
      St.page = (St.page == "mix") and "main" or "mix"
      G.release_all()
    end
  end
end

-- S1 and SET held, no steps: the steps are the sampler's lengths.
-- SET + step is always a length: the track's, or with S1 the take's.
local function rec_pick()
  return R and shift() and G.stack[#G.stack] == "S1" and #G.held == 0
end

local function step_key(x, y, z)
  local i = ((y - 1) * 16) + x
  local tr = St.track()
  if z == 1 and rec_pick() then
    shifted()
    R.arm(St.sel, i)
    return
  end
  if z == 1 then
    if clear() then
      -- the step back to a plain hit: no locks, conditions or pulses
      cleared()
      if tr.steps[i] then tr.steps[i] = S.new_step() end
      G.swallow[i] = true
      return
    end
    if shift() then
      shifted()
      tr.len = i
      G.swallow[i] = true
      return
    end
    -- a lock open and no step under a finger: this press only closes it
    if G.lock and #G.held == 0 then
      G.lock = nil
      G.swallow[i] = true
      return
    end
    local st = tr.steps[i]
    if st and st.on then
      G.held[#G.held + 1] = { i = i, t0 = util.time(), new = false, edited = false }
    else
      tr.steps[i] = S.new_step(tr.tpl)
      G.held[#G.held + 1] = { i = i, t0 = util.time(), new = true, edited = false }
    end
    -- another step joining the ones a lock is open on
    if G.lock then
      G.lock.steps[#G.lock.steps + 1] = i
      G.held[#G.held].edited = true
    end
  else
    if G.swallow[i] then
      G.swallow[i] = nil
      return
    end
    local h = remove(G.held, function(e) return e.i == i end)
    if h and not h.new and not h.edited and (util.time() - h.t0) < 0.4 then
      tr.steps[i] = nil
    end
  end
end

local function ctrl_key(x, y, z)
  local id = S.btn_at(x, y)
  if not id then return end
  local b = S.BTN[id]
  if z == 1 then
    if clear() then
      cleared()
      if G.on_clear_ctrl then G.on_clear_ctrl(id) end
      return
    end
    local li = G.held_lfo()
    if li and S.SOUND_KIND[b.kind] then
      -- E2 / E3 patch it while both are held
      G.patch = { lfo = li, btn = id }
      return
    end
    if b.kind == "lfo" then
      -- the other way round: a sound control already down
      for k = #G.stack, 1, -1 do
        if S.SOUND_KIND[S.BTN[G.stack[k]].kind] then
          G.patch = { lfo = b.lfo, btn = G.stack[k] }
          break
        end
      end
    end
    if shift() then
      shifted()
      G.latched = (G.latched ~= id) and id or nil
      return
    end
    if S.SOUND_KIND[b.kind] then
      if G.lock and G.lock.btn == id and #G.held == 0 then
        -- the open lock's own button again: close it
        G.lock = nil
        return
      end
      if #G.held > 0 or G.lock then
        -- over held steps: stays open on them once the fingers come off
        G.lock = { btn = id, steps = G.held_steps() }
        G.mark_edited()
        return
      end
    end
    G.stack[#G.stack + 1] = id
  else
    remove(G.stack, function(e) return e == id end)
    if G.patch and (G.patch.btn == id or (b.kind == "lfo" and G.patch.lfo == b.lfo)) then
      G.patch = nil
    end
  end
end

-- MIX: a fader column over each track (rows A-F), pan on the right
local function mix_key(x, y, z)
  if z == 0 then return end
  if x <= S.NTRACKS and y <= 6 then
    local t = x
    if clear() then
      cleared()
      St.reset(St.pid(t, "level"))
    else
      params:set(St.pid(t, "level"), (7 - y) / 6)
    end
    St.select(t)
    return
  end
  if y > 4 then return end
  local t, slot
  if x >= 10 and x <= 12 then t, slot = y, x - 9
  elseif x >= 14 then t, slot = y + 4, x - 13 end
  if not t then return end
  local id = St.pid(t, "pan")
  if clear() then
    cleared()
    St.reset(id)
  elseif slot == 2 then
    params:set(id, 0)
  else
    local d = (slot == 1) and -PAN_STEP or PAN_STEP
    -- land on the increments, so ten presses from centre is hard over
    local v = (math.floor((params:get(id) / PAN_STEP) + 0.5) * PAN_STEP) + d
    params:set(id, util.clamp(v, -1, 1))
  end
  St.select(t)
end

-- SESSION: clips, kits and the song's snapshots
local function session_key(x, y, z)
  if y == 5 and x <= #S.KITS then
    -- decided on release: a track pressed meanwhile means only those
    if z == 1 then
      G.kit = { k = x, used = false }
    elseif G.kit and G.kit.k == x then
      if not G.kit.used then St.set_kit_all(x) end
      G.kit = nil
    end
    return
  end
  if x >= KEY_X0 then
    local i = ((y - 1) * KEY_W) + (x - KEY_X0) + 1
    if z == 1 then
      if clear() then cleared() end
      VS.hold_start(i, clear() and "delete" or "save")
    else
      VS.hold_end(i)
    end
    return
  end
  local t, c = C.at(x, y)
  if not t then return end
  if z == 0 then
    C.release(t, c)
  elseif clear() then
    cleared()
    C.press(t, c, true)
  else
    C.press(t, c)
  end
end

function G.key(x, y, z)
  if St.page == "session" and y == 8 and x >= KEY_X0 then
    -- the snapshots' bottom row, where SWING MIX COLOUR are otherwise
    session_key(x, y, z)
  elseif y == 8 then
    rowh(x, z)
  elseif y == S.TRACK_ROW and x <= S.NTRACKS then
    track_key(x, z)
  elseif St.page == "mix" then
    mix_key(x, y, z)
  elseif St.page == "session" then
    session_key(x, y, z)
  elseif y <= S.SEQ_ROWS then
    step_key(x, y, z)
  elseif x == S.RAIN.x and y == S.RAIN.y then
    G.rain = (z == 1)
  elseif S.CTRL_ROWS[y] then
    ctrl_key(x, y, z)
  end
  St.dirty = true
end

-- ------------------------------------------------------------------ redraw

local function has_extras(st)
  if st.locks and next(st.locks) then return true end
  return (st.cond or 1) ~= 1 or (st.prob or 100) < 100 or (st.pulses or 1) > 1
    or (st.flam or 0) > 0 or (st.nudge or 0) ~= 0
end

local draw_ctrls   -- the two control rows, below

-- S1 held: every length that fits in 20 s, beats brighter, the armed
-- length blinking. A take recording: the steps fill as it goes.
local function draw_rec()
  local blink = (math.floor(util.time() * 4) % 2) == 0
  local rec = R.t and R.eng >= 3
  local n = rec and R.steps or R.max_steps(St.sel)
  local done = rec and math.floor((R.prog * R.steps) + 0.5) or 0
  for i = 1, n do
    local x, y = ((i - 1) % 16) + 1, math.floor((i - 1) / 16) + 1
    local lv = ((i - 1) % 4 == 0) and 3 or 1
    if rec then lv = (i <= done) and 12 or 2
    elseif R.t == St.sel and i == R.steps then lv = blink and 15 or 6 end
    g:led(x, y, lv)
  end
end

local function draw_main()
  if rec_pick() or (R and R.t and R.eng >= 3) then
    draw_rec()
    draw_ctrls()
    return
  end
  local tr = St.track()
  local heldset = {}
  -- SET on its own flashes the last step, where SET + step would move it
  local show_len = shift() and #G.held == 0 and #G.stack == 0
  local flash = (math.floor(util.time() * 6) % 2) == 0
  for _, h in ipairs(G.held) do heldset[h.i] = true end
  local lockset = {}
  if G.lock then for _, i in ipairs(G.lock.steps) do lockset[i] = true end end

  for i = 1, S.NSTEPS do
    local x, y = ((i - 1) % 16) + 1, math.floor((i - 1) / 16) + 1
    local lv = 0
    local st = tr.steps[i]
    local on = st and st.on
    if i <= tr.len then
      -- every beat (four steps) dimly, the first of each bar a touch
      -- brighter, so the grid has somewhere to count from
      if (i - 1) % 16 == 0 then lv = 3
      elseif (i - 1) % 4 == 0 then lv = 2 end
      if on then lv = has_extras(st) and 11 or 7 end
      if St.playing and tr.ph == i then lv = on and 15 or 4 end
    end
    if lockset[i] then lv = flash and 15 or 4 end
    if heldset[i] then lv = 15 end
    if show_len and i == tr.len then lv = flash and 15 or 5 end
    if lv > 0 then g:led(x, y, lv) end
  end

  draw_ctrls()
  -- RAIN glows with the amount
  local r = params:get("rain")
  g:led(S.RAIN.x, S.RAIN.y, G.rain and 15 or ((r > 0) and (5 + math.floor(r * 6)) or 2))
end

draw_ctrls = function()
  local tr = St.track()
  local _, open = G.overlay()
  local li = G.held_lfo()
  -- which buttons have a lock on any held step
  local locked = {}
  for _, i in ipairs(G.held_steps()) do
    local st = tr.steps[i]
    if st and st.locks then
      for k in pairs(st.locks) do locked[k:sub(1, -2)] = true end
    end
  end

  for id, b in pairs(S.BTN) do
    local lv = 3
    -- TC and P a touch brighter while new steps would not be plain
    if S.STEP_KIND[b.kind] then
      local pair = S.pair(St.sel, id)
      if (tr.tpl[pair.a.key] or pair.a.def) ~= pair.a.def
        or (tr.tpl[pair.b.key] or pair.b.def) ~= pair.b.def then lv = 6 end
    end
    if b.kind == "lfo" then
      local o = L.st[St.sel][b.lfo]
      if o.target then
        lv = 4 + math.floor((o.val + 1) * 4 + 0.5)
      end
    end
    if locked[id] then lv = 9 end
    if li and L.side_on(St.sel, li, id) then lv = 13 end
    if G.latched == id then lv = 11 end
    if open == id and G.stack[#G.stack] == id then lv = 15 end
    if G.lock and G.lock.btn == id and not G.stack[1] then lv = 15 end
    if G.patch and G.patch.btn == id then lv = 15 end
    -- S1 pulses while a take is armed or recording on this track
    if id == "S1" and R and R.t == St.sel and lv < 15 then
      lv = 6 + math.floor((math.sin(util.time() * 6) + 1) * 4 + 0.5)
    end
    g:led(b.x, b.y, lv)
  end
end

local function draw_mix()
  for t = 1, S.NTRACKS do
    local lvl = params:get(St.pid(t, "level"))
    local top = util.clamp(7 - math.floor((lvl * 6) + 0.5), 1, 6)
    local m = St.meter[t] or 0
    local db = (m > 0.00001) and (20 * math.log(m, 10)) or -96
    local mrows = util.clamp(math.floor(((db + 42) / 42) * 6 + 0.5), 0, 6)
    local sel = (t == St.sel)
    for y = 1, 6 do
      local lv = 0
      if y >= top then lv = sel and 4 or 2 end
      if y == top then lv = sel and 8 or 6 end
      if (7 - y) <= mrows then
        lv = math.max(lv, (y <= 1) and 15 or 11)
      end
      if lv > 0 then g:led(t, y, lv) end
    end
  end
  -- pan: tracks 1-4 in columns 10-12, 5-8 in 14-16, three buttons a row.
  -- The centre is bright at centre; each side lights as far as it is over.
  for t = 1, S.NTRACKS do
    local pan = params:get(St.pid(t, "pan"))
    local y = (t <= 4) and t or (t - 4)
    local x0 = (t <= 4) and 9 or 13
    local sel = (t == St.sel)
    local top, floor = sel and 15 or 9, sel and 3 or 1
    local function lv(a) return floor + math.floor((a * (top - floor)) + 0.5) end
    g:led(x0 + 1, y, lv(math.max(-pan, 0)))
    g:led(x0 + 2, y, lv(1 - math.abs(pan)))
    g:led(x0 + 3, y, lv(math.max(pan, 0)))
  end
end

-- SESSION: the clips over each track, a launch waiting for its bar
-- blinking; the kits; the song's snapshots, drawn by lib/gridui
local function draw_session()
  local now = util.time()
  local blink = (math.floor(now * 8) % 2) == 0
  for t = 1, S.NTRACKS do
    local tr = St.tracks[t]
    local nc = tr.next_clip and tr.next_clip.c
    for c = 1, C.COUNT do
      local lv = C.has(t, c) and 5 or 1
      if c == tr.clip then
        lv = tr.mute and 6 or (10 + math.floor(tr.flash * 5 + 0.5))
      end
      if c == nc then lv = blink and 15 or 3 end
      if C.hold and C.hold.t == t and C.hold.c == c then lv = 15 end
      g:led(t, c, lv)
    end
  end
  -- the kits: bright when every track is on it, half when some are
  for k = 1, #S.KITS do
    local n = 0
    for t = 1, S.NTRACKS do if S.kit_of(t) == k then n = n + 1 end end
    local lv = (n == S.NTRACKS) and 12 or ((n > 0) and 6 or 2)
    if G.kit and G.kit.k == k then lv = 15 end
    g:led(k, 5, lv)
  end
  if G.draw_snaps then G.draw_snaps(function(x, y, l) g:led(x, y, l) end) end
end

local function draw_tracks()
  local blink = (math.floor(util.time() * 4) % 2) == 0
  for t = 1, S.NTRACKS do
    local tr = St.tracks[t]
    local lv
    if G.kit then lv = (S.kit_of(t) == G.kit.k) and 15 or 2
    -- on MIX these buttons are the mutes, so a mute shows even selected
    elseif (tr.mute or St.pmute[t]) and (St.page == "mix" or t ~= St.sel) then lv = 1
    elseif t == St.sel then lv = 15
    else lv = 4 + math.floor(tr.flash * 7 + 0.5) end
    if tr.next_clip and blink and t ~= St.sel then lv = 0 end
    g:led(t, S.TRACK_ROW, lv)
  end
  local H = S.ROWH
  g:led(H.set, 8, (St.page == "session") and 15 or (shift() and 10 or 4))
  -- in SESSION the snapshots have the right of row H
  if St.page == "session" then return end
  g:led(H.swing, 8, G.swing and 15 or 4)
  g:led(H.mix, 8, (St.page == "mix") and 15 or 4)
  g:led(H.colour, 8, G.tape and 15 or 4)
end

-- the face; row H's PLAY and STOP are drawn by the router
function G.draw()
  if St.page == "mix" then draw_mix()
  elseif St.page == "session" then draw_session()
  else draw_main() end
  draw_tracks()
end

return G
