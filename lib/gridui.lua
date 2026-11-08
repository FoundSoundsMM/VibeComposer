-- vibecomposer / gridui
--
-- The grid 128.
--
--        1    2    3    4    5    6    7    8    9    10   11 ........ 16
--   A  [ steps 1-8 . . . . . . . . . . . . . ]  .    M    [            ]
--   B  [ steps 9-16                          ]  .    C    [  keyboard  ]
--   C  [ steps 17-24                         ]  .    .    [     or     ]
--   D  [ steps 25-32 (K2 / K3: other pages)  ]  .    .    [   chords   ]
--   E    .    .    .    .    .    .    .    .    .    .    [            ]
--   F    TC1  TC2  .    TC3  TC4  .    GEN  RAIN .    .    [            ]
--   G    T1   T2   T3   T4   T5   T6   T7   T8   .    OCT+ [            ]
--   H    PLAY STOP REC  .    .    .    .    SET  .    OCT- [ root ...   ]
--
-- STEPS. Press an empty step and it takes the keys held right now, or the
-- last ones played. Hold a step and play keys: they go into it, every key
-- played while it is held. Hold keys and press steps: the keys go into
-- each. A quick tap on a full step empties it; holding it (to edit it on a
-- TC page) does not. Hold a step and press a later one: the first step's
-- note lasts up to it.
--
-- PLAY plays and pauses. Held while playing it is FILL. STOP stops and goes
-- back to the top. SET toggles the session view (clips and snapshots, see
-- lib/snap). Hold SET and press a track: that track's settings.

local K = include("lib/const")
local T = include("lib/theory")

local G = {}
local St, Q, Kb, N, Gn, P

G.g = nil
G.sel = 1
G.settings = false
G.steppage = 1          -- which 32 steps the grid shows (K2 / K3)
G.held = {}             -- held steps: { i, t0, used, got }
G.s_held, G.s_used = false, false
G.stop_held, G.stop_used = false, false
G.play_t0 = nil
G.flash = {}            -- button -> time of a flash
G.ignore = {}           -- step presses that set a length or the cursor
G.rec = false
G.cursor = 1            -- where step recording writes next
G.rec_last = nil
G.oct_held = {}

local TAP = 0.35
local FILL_HOLD = 0.3

function G.init(state, seq, keys, snap, gen, pages)
  St, Q, Kb, N, Gn, P = state, seq, keys, snap, gen, pages
  Kb.sel = function() return G.sel end
end

local function now() return util.time() end
local function is(btn, x, y) local b = K.BTN[btn] return b[1] == x and b[2] == y end

-- ------------------------------------------------------------ held steps

function G.held_steps()
  local out = {}
  for _, h in ipairs(G.held) do out[#out + 1] = h.i end
  return out
end

function G.mark_used()
  for _, h in ipairs(G.held) do h.used = true end
end

function G.drop_held() G.held = {} end

function G.select(t)
  if t == G.sel then return end
  Kb.release_all()
  G.drop_held()
  G.sel = t
  Q.dirty = true
end

-- notes into step i of the selected track.
-- add: alongside what is there (keys played into a held step one by one).
local function imprint(i, notes, vel, strum, arp, add)
  local t = G.sel
  local c = St.clip(t)
  if not notes or #notes == 0 then return end
  local ns = {}
  for k, n in ipairs(notes) do ns[k] = n end
  local st = c.steps[i]
  if St.has_notes(st) then
    St.bake(st)
    if add then
      local seen = {}
      for _, n in ipairs(st.notes) do seen[n] = true end
      for _, n in ipairs(ns) do
        if not seen[n] then st.notes[#st.notes + 1] = n end
      end
      table.sort(st.notes)
      Q.dirty = true
      return st
    end
    st.notes = ns
  else
    st = St.new_step(t, ns)
    if vel and st.vel == nil and vel ~= K.STEP_DEF.vel then st.vel = vel end
    c.steps[i] = st
  end
  st.strum = (strum and #ns > 1) and { ms = strum.ms, dir = strum.dir } or nil
  st.arp = (arp and #ns > 1) and { mode = arp.mode, rate = arp.rate } or nil
  Q.dirty = true
  return st
end

-- a step held, another pressed: the first one's note lasts up to and
-- including the second. The same press again sets it back to one step.
local function set_length(h, j, c)
  local st = c.steps[h.i]
  local n = (j >= h.i) and (j - h.i + 1) or (j + c.len - h.i + 1)
  n = math.min(n, K.MAXLEN)
  if st.len == n then st.len = nil else st.len = n end
  h.used = true
  P.show({ "STEP " .. h.i, st.len and ("LASTS " .. n .. " STEPS") or "LASTS 1 STEP", "" })
  Q.dirty = true
end

local function step_key(x, y, z)
  local i = ((G.steppage - 1) * K.PAGE_STEPS) + ((y - 1) * 8) + x
  local c = St.clip(G.sel)
  if z == 1 then
    local first = G.held[1]
    if first and first.i ~= i and St.has_notes(c.steps[first.i]) then
      set_length(first, i, c)
      G.ignore[i] = true
      return
    end
    if G.rec and not Q.playing then
      -- step recording: the step to record into next
      G.cursor = i
      G.ignore[i] = true
      P.show({ "RECORD AT STEP " .. i, "play keys to write", "" })
      return
    end
    local h = { i = i, t0 = now(), used = false, got = false }
    G.held[#G.held + 1] = h
    if Kb.held_any() then
      imprint(i, Kb.held_notes(), Kb.last.vel, Kb.last.strum, Kb.last.arp)
      h.used, h.got = true, true
    elseif not St.has_notes(c.steps[i]) then
      local L = Kb.last
      imprint(i, L.notes, L.vel, L.strum, L.arp)
      h.used = true
    end
  else
    if G.ignore[i] then
      G.ignore[i] = nil
      return
    end
    for k, h in ipairs(G.held) do
      if h.i == i then
        table.remove(G.held, k)
        if not h.used and (now() - h.t0) < TAP then
          c.steps[i] = nil
          Q.dirty = true
        end
        break
      end
    end
  end
end

-- a key or chord played with steps held: into each of them
local function into_held(notes, strum, arp)
  for _, h in ipairs(G.held) do
    local add = h.got and Kb.mode == 1
    imprint(h.i, notes, Kb.last.vel, strum, arp, add)
    h.got, h.used = true, true
  end
end

-- RECORD. Playing: into the step that is playing (or the next, past its
-- middle); keys held down over several steps make the note that long.
-- Stopped: into the record cursor, which moves on once every key is up.
local function record(notes, strum, arp, pad)
  local t = G.sel
  local c = St.clip(t)
  local i = Q.playing and Q.rec_step(t) or G.cursor
  if i > c.len then i = 1 end
  local r = G.rec_last
  local add = r and r.i == i and r.t == t and r.g == Kb.gesture and Kb.mode == 1
  local st = imprint(i, notes, Kb.last.vel, strum, arp, add)
  if st and not add then st.len = nil end
  G.rec_last = { i = i, t = t, g = Kb.gesture }
  if pad and Q.playing then pad.rec = { t = t, i = i, t0 = Q.t } end
end

local function record_release(pad)
  if pad and pad.rec and Q.playing then
    local c = St.track(pad.rec.t).clips[St.track(pad.rec.t).clip]
    local st = c.steps[pad.rec.i]
    local n = math.floor(((Q.t - pad.rec.t0) / (c.speed * K.T16)) + 0.5)
    if st and n >= 2 then st.len = math.min(n, K.MAXLEN) end
  end
  if not Q.playing and #Kb.pads == 0 and G.rec_last and G.rec_last.g == Kb.gesture
    and G.rec_last.t == G.sel and not G.rec_last.moved then
    G.rec_last.moved = true
    G.cursor = (G.cursor % St.clip(G.sel).len) + 1
  end
end

-- ----------------------------------------------------------------- keys

local function key_main(x, y, z)
  if x <= 8 and y <= 4 then return step_key(x, y, z) end

  if Kb.in_area(x, y) then
    if z == 1 then
      local notes, strum, arp = Kb.press(x, y)
      if notes then
        if #G.held > 0 then into_held(notes, strum, arp)
        elseif G.rec then record(notes, strum, arp, Kb.pads[#Kb.pads]) end
      end
    else
      local pad = Kb.release(x, y)
      if G.rec then record_release(pad) end
    end
    Q.dirty = true
    return
  end

  if is("OCTUP", x, y) or is("OCTDN", x, y) then
    local up = is("OCTUP", x, y)
    G.oct_held[up and 1 or 2] = (z == 1) or nil
    if z == 1 then
      -- both together: back to the middle
      if G.oct_held[1] and G.oct_held[2] then Kb.octave(0)
      else Kb.octave(up and 1 or -1) end
    end
    Q.dirty = true
    return
  end

  if z ~= 1 then return end
  local function page_btn(id)
    if P.page == id then P.open("home") else P.open(id) end
  end
  if is("TC1", x, y) then page_btn("tc1")
  elseif is("TC2", x, y) then page_btn("tc2")
  elseif is("TC3", x, y) then page_btn("tc3")
  elseif is("TC4", x, y) then page_btn("tc4")
  elseif is("GEN", x, y) then
    if P.page == "gen" then
      Gn.generate(G.sel)
      G.flash.GEN = now()
    else P.open("gen") end
  elseif is("RAIN", x, y) then
    -- on its page, RAIN again stops and starts the rain (the amount stays)
    if P.page == "rain" then
      local tr = St.track(G.sel)
      tr.rain_off = not tr.rain_off
      P.show({ tr.rain_off and "RAIN OFF" or "RAIN ON", "track " .. G.sel .. ", " .. (tr.rain or 0) .. "%", "" })
    else P.open("rain") end
  elseif is("M", x, y) then
    Kb.set_mode(1)
    page_btn("keys")
  elseif is("C", x, y) then
    Kb.set_mode(2)
    page_btn("chord")
  end
end

local function key_settings(x, y, z)
  if x <= 8 and y <= 4 then
    if z == 1 then
      if G.stop_held then G.stop_used = true end
      N.clip_press(x, y, G.stop_held)
    else
      N.clip_release(x, y)
    end
    Q.dirty = true
    return
  end
  if Kb.in_area(x, y) then
    local i = ((y - 1) * K.KEY_W) + (x - K.KEY_X0) + 1
    if z == 1 then
      if G.stop_held then G.stop_used = true end
      N.hold_start(i, G.stop_held and "delete" or "save")
    else
      N.hold_end(i)
    end
    Q.dirty = true
  end
end

function G.key(x, y, z)
  -- the transport and tracks work the same in both modes
  if is("PLAY", x, y) then
    if z == 1 then
      if Q.playing then G.play_t0 = now() else Q.play() end
    elseif G.play_t0 then
      if not Q.fill then Q.play() end   -- a tap while playing: pause
      Q.fill = false
      G.play_t0 = nil
    end
    Q.dirty = true
    return
  end
  if is("STOP", x, y) then
    if z == 1 then
      G.stop_held, G.stop_used = true, false
      if not G.settings then Q.stop() end
    else
      if G.settings and not G.stop_used then Q.stop() end
      G.stop_held = false
    end
    G.flash.STOP = now()
    Q.dirty = true
    return
  end
  if is("REC", x, y) then
    if z == 1 then
      G.rec = not G.rec
      G.rec_last = nil
      if G.rec then
        P.show({ "RECORD ON", Q.playing and "live into the playing steps" or "step: keys write, then move on", "" })
      else
        P.show({ "RECORD OFF", "", "" })
      end
    end
    Q.dirty = true
    return
  end
  if is("SET", x, y) then
    if z == 1 then
      G.s_held, G.s_used = true, false
    else
      G.s_held = false
      if not G.s_used then
        G.settings = not G.settings
        Kb.release_all()
        G.drop_held()
        if G.settings then P.open("settings")
        else P.open(P.last or "home") end
      end
    end
    Q.dirty = true
    return
  end
  if y == K.TRACK_ROW and x <= K.NTRACKS then
    if z == 1 then
      if G.s_held then
        G.s_used = true
        G.select(x)
        P.tset_track = x
        P.open("tset")
      elseif G.settings then
        G.select(x)
      else
        local same = (x == G.sel) and P.page == "track"
        G.select(x)
        P.open(same and "home" or "track")
      end
    end
    Q.dirty = true
    return
  end
  if G.settings then key_settings(x, y, z) else key_main(x, y, z) end
end

-- ----------------------------------------------------------------- draw

local buf = {}
local function led(x, y, l)
  l = math.floor(math.min(math.max(l, 0), 15))
  buf[((y - 1) * 16) + x] = l
end

local function blink(rate) return (math.floor(now() * (rate or 4)) % 2) == 0 end

-- how many pages of 32 the selected clip has
function G.pages()
  return math.max(1, math.ceil(St.clip(G.sel).len / K.PAGE_STEPS))
end

function G.page(d)
  G.steppage = math.min(math.max(G.steppage + d, 1), G.pages())
  local a = ((G.steppage - 1) * K.PAGE_STEPS) + 1
  P.show({ "STEPS " .. a .. "-" .. (a + K.PAGE_STEPS - 1), "page " .. G.steppage .. " of " .. G.pages(), "" })
end

local function draw_steps()
  local t = G.sel
  local c, rt = St.clip(t), Q.rt[t]
  if G.steppage > G.pages() then G.steppage = G.pages() end
  local held = {}
  for _, h in ipairs(G.held) do held[h.i] = true end
  local running = Q.playing or Q.paused
  -- where long notes carry on
  local tail = {}
  for i = 1, c.len do
    local st = c.steps[i]
    if St.has_notes(st) and (st.len or 1) > 1 then
      for k = 1, st.len - 1 do tail[((i - 1 + k) % c.len) + 1] = true end
    end
  end
  for y = 1, 4 do
    for x = 1, 8 do
      local i = ((G.steppage - 1) * K.PAGE_STEPS) + ((y - 1) * 8) + x
      local st = c.steps[i]
      local l
      if i > c.len then
        l = St.has_notes(st) and 1 or 0
      else
        local mk = K.marker(St.d.sig, i)
        l = (mk == 2) and 3 or ((mk == 1) and 2 or 0)
        if tail[i] then l = 4 end
        if St.has_notes(st) then
          if St.get(st, "skip") == 1 then l = 4
          elseif St.has_params(st) then l = 10
          else l = 7 end
        end
        if running and rt.ph == i then l = St.has_notes(st) and 15 or 6 end
      end
      if held[i] then l = 13 end
      if G.rec and not Q.playing and i == G.cursor then l = blink(6) and 15 or 1 end
      led(x, y, l)
    end
  end
end

local function draw_keys()
  local t = G.sel
  local d = St.d
  local lit = {}
  -- the selected track's sounding notes, as they were written
  local tr, rt = St.track(t), Q.rt[t]
  for n in pairs(rt.sounding) do lit[n - (tr.oct * 12)] = 8 end
  -- the first held step's notes
  if G.held[1] then
    local st = St.clip(t).steps[G.held[1].i]
    if St.has_notes(st) then
      for _, n in ipairs(St.notes(st)) do lit[n] = 11 end
    end
  end
  for _, p in ipairs(Kb.pads) do
    for _, n in ipairs(p.notes) do lit[n] = 15 end
  end
  for y = 1, 8 do
    for x = K.KEY_X0, 16 do
      local n = Kb.note_at(x, y)
      local l
      if (n - d.root) % 12 == 0 then l = 5
      elseif d.inkey then l = 2
      else
        l = T.in_scale(n, d.root, d.scale) and 2 or 0
      end
      if lit[n] then l = lit[n] end
      led(x, y, l)
    end
  end
end

local function draw_chords()
  local nd = #(K.SCALES[St.d.scale] or K.SCALES[1]).iv
  for y = 7, 8 do
    for x = K.KEY_X0, 16 do
      local deg = Kb.degree_at(x, y)
      led(x, y, (deg % nd == 0) and 7 or 4)
    end
  end
  for y = 1, 6 do
    for col = 1, 6 do
      local g, id = K.mod_at(y, col)
      led(K.KEY_X0 + col - 1, y, (St.d.mods[g] == id) and 12 or 2)
    end
  end
  for _, p in ipairs(Kb.pads) do led(p.x, p.y, 15) end
end

local function draw_buttons()
  local function b(id, l) local p = K.BTN[id] led(p[1], p[2], l) end
  local function page(id, pg)
    local fl = G.flash[id] and (now() - G.flash[id]) < 0.15
    b(id, (fl or P.page == pg) and 15 or 4)
  end
  page("TC1", "tc1")
  page("TC2", "tc2")
  page("TC3", "tc3")
  page("TC4", "tc4")
  page("GEN", "gen")
  -- RAIN glows with the selected track's rain
  local tr = St.track(G.sel)
  local wet = ((tr.rain or 0) > 0) and not tr.rain_off
  b("RAIN", (P.page == "rain") and 15 or (wet and (5 + math.floor(tr.rain / 20)) or 2))
  b("M", (Kb.mode == 1) and ((P.page == "keys") and 15 or 9) or 3)
  b("C", (Kb.mode == 2) and ((P.page == "chord") and 15 or 9) or 3)
  local o = St.d.koct or 0
  b("OCTUP", (o > 0) and (5 + (3 * o)) or 3)
  b("OCTDN", (o < 0) and (5 - (3 * o)) or 3)
end

local function draw_transport()
  local p = K.BTN.PLAY
  local l = 4
  if Q.join_abs then l = blink(8) and 15 or 2
  elseif Q.playing then l = Q.fill and (blink(8) and 15 or 6) or 15
  elseif Q.paused then l = blink(2) and 12 or 3 end
  led(p[1], p[2], l)
  local s = K.BTN.STOP
  led(s[1], s[2], (G.flash.STOP and (now() - G.flash.STOP) < 0.15) and 15 or 4)
  local r = K.BTN.REC
  local rl = 4
  if G.rec then rl = Q.playing and 15 or (blink(2) and 12 or 5) end
  led(r[1], r[2], rl)
  local set = K.BTN.SET
  led(set[1], set[2], G.settings and 15 or (G.s_held and 10 or 4))
  for t = 1, K.NTRACKS do
    local tr, rt = St.track(t), Q.rt[t]
    local l2
    if t == G.sel then l2 = 15
    elseif tr.mute then l2 = 1
    else l2 = ((now() - (rt.flash or 0)) < 0.1) and 9 or 3 end
    if rt.queued and blink(6) then l2 = 0 end
    led(t, K.TRACK_ROW, l2)
  end
end

local function draw_clips()
  for t = 1, K.NTRACKS do
    local tr, rt = St.track(t), Q.rt[t]
    for c = 1, K.NCLIPS do
      local l
      if rt.queued and rt.queued.c == c then l = blink(6) and 15 or 4
      elseif tr.clip == c then l = (Q.playing and blink(2)) and 15 or 11
      elseif N.clip_has(t, c) then l = 6
      else l = 1 end
      if N.clip_hold and N.clip_hold.t == t and N.clip_hold.c == c then l = 15 end
      led(t, c, l)
    end
  end
end

local function draw_snaps()
  for i = 1, K.NSNAPS do
    local x = K.KEY_X0 + ((i - 1) % K.KEY_W)
    local y = math.floor((i - 1) / K.KEY_W) + 1
    local l
    if N.act and N.act.slot == i then
      local p = N.progress()
      l = (N.act.kind == "delete") and (15 - (13 * p)) or (3 + (12 * p))
    elseif N.pending == i then l = blink(6) and 15 or 3
    elseif N.last == i then l = 12
    elseif N.has(i) then l = 6
    else l = 1 end
    l = math.max(l, N.pulse[i] * 15)
    led(x, y, l)
  end
end

function G.redraw()
  if not G.g then return end
  -- FILL once PLAY has been held long enough
  if G.play_t0 and Q.playing and (now() - G.play_t0) >= FILL_HOLD then Q.fill = true end
  for i = 1, 128 do buf[i] = 0 end
  draw_transport()
  if G.settings then
    draw_clips()
    draw_snaps()
  else
    draw_steps()
    draw_buttons()
    if Kb.mode == 1 then draw_keys() else draw_chords() end
  end
  for y = 1, 8 do
    for x = 1, 16 do G.g:led(x, y, buf[((y - 1) * 16) + x]) end
  end
  G.g:refresh()
end

return G
