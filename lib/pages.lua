-- vibecomposer / pages
--
-- The norns screen. Every page but HOME is up to three lanes of two
-- parameters: E1 picks the lane, E2 turns the left one, E3 the right.
--
--   HOME      every track at a glance (when no page is open)
--   TRACK     DIRECTION | SWING, LENGTH | SPEED
--   TC1, TC2  trig conditions, Elektron-style
--   TC3, TC4  Metropolix stages: pulses, gate modes, skip, ramp,
--             accumulator, slide
--   GEN       pattern generation, ROTATE and SHIFT
--   RAIN      in-scale notes falling into a track's silent steps
--   KEYS      LAYOUT | ROOT, IN-KEY | VELOCITY
--   CHORD     ROOT | VELOCITY, STRUM | V.LEAD, ARP | RATE
--   SETTINGS  SCALE | TEMPO, SWING | SIGNATURE, TRANSPOSE
--   TRACK SETTINGS  DEVICE | CHANNEL, FOLLOW | MUTE, OCTAVE | PROGRAM
--
-- On the TC pages, with steps held, E2 and E3 change those steps. With
-- none held they change what a NEW step starts with.
--
-- THE READOUT. Playing the keyboard, a chord or a modifier, setting a
-- note's length or arming RECORD shows what it did in place of the lanes:
-- the notes and the chord they make, the chord's name, notes and
-- modifiers, or what a modifier does. It stays while pads are held and a
-- moment after.

local K = include("lib/const")
local T = include("lib/theory")

local P = {}
local St, Q, Kb, G, Gn, O

P.page = "home"
P.lane = {}
P.rot, P.shf = 0, 0

function P.init(state, seq, keys, grid, gen, out)
  St, Q, Kb, G, Gn, O = state, seq, keys, grid, gen, out
end

local function clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end
local function sgn(d) return (d > 0) and 1 or ((d < 0) and -1 or 0) end
local function onoff(b) return b and "ON" or "OFF" end
local function signed(v) return (v > 0) and ("+" .. v) or tostring(v) end
local function sel() return G.sel end
local function tr() return St.track(G.sel) end
local function clip() return St.clip(G.sel) end

-- SPEED: x1 is a step every sixteenth; turning left divides it down.
-- clip.speed is how many sixteenths a step lasts.
local SPEEDS = { 1, 2, 4, 8, 16, 32, 64 }

local function speed_name(n)
  if n <= 1 then return "x1" end
  return "/" .. n
end

-- one detent: right is faster, left slower (a speed between the steps, from
-- an older project, goes to the next one along)
local function speed_step(n, d)
  local i = 1
  for k, v in ipairs(SPEEDS) do
    if v <= n then i = k end
  end
  if d < 0 then return SPEEDS[math.min(i + 1, #SPEEDS)] end
  if SPEEDS[i] < n then return SPEEDS[i] end
  return SPEEDS[math.max(i - 1, 1)]
end

-- ------------------------------------------------------------------ steps

-- what the TC pages edit: the held steps that have notes, or the template
local function targets()
  local held = G.held_steps()
  if #held == 0 then return { tr().tpl }, false end
  local out = {}
  local c = clip()
  for _, i in ipairs(held) do
    if St.has_notes(c.steps[i]) then out[#out + 1] = c.steps[i] end
  end
  return out, true
end

local function sp(name, key, lo, hi, fmt, mul)
  return {
    name = name,
    get = function()
      local ts = targets()
      if not ts[1] then return "--" end
      return fmt(St.get(ts[1], key))
    end,
    delta = function(d)
      local ts, held = targets()
      for _, st in ipairs(ts) do
        st[key] = clamp(St.get(st, key) + (d * (mul or 1)), lo, hi)
      end
      if held then G.mark_used() end
    end,
  }
end

local function pct(v) return v .. "%" end
local function plain(v) return tostring(v) end
local function bool(v) return onoff(v == 1) end

local STEP_NOTE = {
  name = "NOTE",
  get = function()
    local ts, held = targets()
    if not held or not ts[1] then return "--" end
    return T.notes_name(St.notes(ts[1]))
  end,
  delta = function(d)
    local ts, held = targets()
    if not held then return end
    for _, st in ipairs(ts) do
      St.bake(st)
      if St.d.inkey then Gn.shift_notes(st, sgn(d))
      else
        for i, n in ipairs(st.notes) do st.notes[i] = clamp(n + sgn(d), 0, 127) end
      end
    end
    G.mark_used()
  end,
}

-- ------------------------------------------------------------------- pages

local DEFS = {}

DEFS.track = {
  title = function() return "TRACK " .. sel() end,
  info = function()
    local s = (sel() == K.MASTER) and "MASTER" or ("CLIP " .. tr().clip)
    if G.pages() > 1 then s = s .. " P" .. G.steppage .. "/" .. G.pages() end
    return s
  end,
  lanes = {
    {
      { name = "DIRECTION", get = function() return K.DIRS[clip().dir or 1] end,
        delta = function(d) clip().dir = clamp((clip().dir or 1) + sgn(d), 1, #K.DIRS) end },
      { name = "SWING",
        get = function()
          local e = clamp(St.d.swing + tr().swing, 50, 75)
          return e .. "% " .. signed(tr().swing)
        end,
        delta = function(d) tr().swing = clamp(tr().swing + d, -25, 25) end },
    },
    {
      { name = "LENGTH", get = function() return tostring(clip().len) end,
        delta = function(d) clip().len = clamp(clip().len + d, 1, K.MAXLEN) end },
      { name = "SPEED", get = function() return speed_name(clip().speed) end,
        delta = function(d) clip().speed = speed_step(clip().speed, sgn(d)) end },
    },
  },
}

local function tc_info()
  local held = G.held_steps()
  if #held == 0 then
    if P.page == "tc1" and St.get(tr().tpl, "cond") == 1 then return "NEW STEPS +ALL" end
    return "NEW STEPS"
  end
  return "STEP " .. held[1] .. ((#held > 1) and ("+" .. (#held - 1)) or "")
end

-- PROB. With nothing held and the new-step COND at --, it is the whole
-- track's probability: every step plays only that often, on top of its own.
local function whole_track()
  return #G.held_steps() == 0 and St.get(tr().tpl, "cond") == 1
end

local STEP_PROB = sp("PROB", "prob", 0, 100, pct)
local TRACK_PROB = {
  name = "PROB",
  get = function()
    if whole_track() then return (tr().prob or 100) .. "% ALL" end
    return STEP_PROB.get()
  end,
  delta = function(d)
    if whole_track() then tr().prob = clamp((tr().prob or 100) + d, 0, 100)
    else STEP_PROB.delta(d) end
  end,
}

DEFS.tc1 = {
  title = function() return "TC1 T" .. sel() end, info = tc_info,
  lanes = {
    { sp("COND", "cond", 1, #K.CONDS, function(v) return K.CONDS[v] end),
      TRACK_PROB },
    { sp("VEL", "vel", 1, 127, plain),
      { name = "GATE",
        get = function()
          local ts = targets()
          if not ts[1] then return "--" end
          if (ts[1].len or 1) > 1 then return ts[1].len .. " STEPS" end
          return St.get(ts[1], "gate") .. "%"
        end,
        delta = function(d)
          local ts, held = targets()
          for _, st in ipairs(ts) do
            -- turning the gate is back to a one-step note
            st.len = nil
            st.gate = clamp(St.get(st, "gate") + d, 1, 100)
          end
          if held then G.mark_used() end
        end } },
  },
}

DEFS.tc2 = {
  title = function() return "TC2 T" .. sel() end, info = tc_info,
  lanes = {
    { sp("MICRO", "micro", -50, 50, function(v) return signed(v) .. "%" end),
      sp("OCT", "oct", -3, 3, signed) },
    { sp("RATCHET", "ratchet", 1, 8, function(v) return "x" .. v end),
      sp("R.FADE", "rfade", -100, 100, signed) },
  },
}

DEFS.tc3 = {
  title = function() return "TC3 T" .. sel() end, info = tc_info,
  lanes = {
    { sp("PULSES", "pulses", 1, 8, plain),
      sp("MODE", "mode", 1, #K.MODES, function(v) return K.MODES[v] end) },
    { sp("SKIP", "skip", 0, 1, bool), sp("RAMP", "ramp", -100, 100, signed) },
  },
}

DEFS.tc4 = {
  title = function() return "TC4 T" .. sel() end, info = tc_info,
  lanes = {
    { sp("ACCUM", "acc", -12, 12, signed), sp("LIMIT", "limit", 1, 16, function(v) return "x" .. v end) },
    { sp("SLIDE", "slide", 0, 1, bool), STEP_NOTE },
  },
}

DEFS.gen = {
  title = function() return "GENERATE T" .. sel() end,
  info = function() return "G AGAIN: GO" end,
  lanes = {
    {
      { name = "STYLE", get = function() return K.GEN_STYLES[St.d.gen.style] end,
        delta = function(d) St.d.gen.style = clamp(St.d.gen.style + sgn(d), 1, #K.GEN_STYLES) end },
      { name = "DENSITY", get = function() return St.d.gen.density .. "%" end,
        delta = function(d) St.d.gen.density = clamp(St.d.gen.density + d, 5, 100) end },
    },
    {
      { name = "RANGE", get = function() return St.d.gen.range .. " OCT" end,
        delta = function(d) St.d.gen.range = clamp(St.d.gen.range + sgn(d), 1, 4) end },
      { name = "POOL", get = function() return K.GEN_POOLS[St.d.gen.pool] end,
        delta = function(d) St.d.gen.pool = clamp(St.d.gen.pool + sgn(d), 1, #K.GEN_POOLS) end },
    },
    {
      { name = "ROTATE", get = function() return signed(P.rot) end,
        delta = function(d)
          d = sgn(d)
          Gn.rotate(sel(), d)
          P.rot = P.rot + d
        end },
      { name = "SHIFT", get = function() return signed(P.shf) end,
        delta = function(d)
          d = sgn(d)
          Gn.shift(sel(), d)
          P.shf = P.shf + d
        end },
    },
  },
}

DEFS.rain = {
  title = function() return "RAIN T" .. sel() end,
  info = function()
    if (tr().rain or 0) == 0 then return "DRY" end
    return tr().rain_off and "RAIN AGAIN: ON" or "RAIN AGAIN: OFF"
  end,
  lanes = {
    {
      { name = "AMOUNT",
        get = function()
          local s = (tr().rain or 0) .. "%"
          if tr().rain_off then s = s .. " OFF" end
          return s
        end,
        delta = function(d) tr().rain = clamp((tr().rain or 0) + d, 0, 100) end },
      { name = "SPREAD", get = function() return "+-" .. (tr().rain_spread or 7) end,
        delta = function(d) tr().rain_spread = clamp((tr().rain_spread or 7) + sgn(d), 1, 21) end },
    },
    {
      { name = "CENTRE",
        get = function()
          if (tr().rain_centre or -1) < 0 then return "AUTO " .. K.note_name(Q.rain_centre(sel())) end
          return K.note_name(tr().rain_centre)
        end,
        delta = function(d)
          local v = tr().rain_centre or -1
          if v < 0 then v = (d > 0) and Q.rain_centre(sel()) or -1
          else v = v + d end
          -- turned down past the lowest note: back to AUTO
          if v < 12 then v = -1 end
          tr().rain_centre = math.min(v, 108)
        end },
      nil,
    },
  },
}

local ROOT = {
  name = "ROOT", get = function() return K.note_name(St.d.root) end,
  delta = function(d)
    Kb.release_all()
    St.d.root = clamp(St.d.root + d, 24, 84)
  end,
}

local function oct_info()
  local o = St.d.koct or 0
  if o == 0 then return "" end
  return "OCT " .. signed(o) .. " "
end

DEFS.keys = {
  title = function() return "KEYS" end,
  info = function() return oct_info() .. K.SCALES[St.d.scale].name end,
  lanes = {
    {
      { name = "LAYOUT", get = function() return K.LAYOUTS[St.d.layout].name end,
        delta = function(d)
          Kb.release_all()
          St.d.layout = clamp(St.d.layout + sgn(d), 1, #K.LAYOUTS)
        end },
      ROOT,
    },
    {
      { name = "IN-KEY", get = function() return onoff(St.d.inkey) end,
        delta = function(d)
          Kb.release_all()
          St.d.inkey = d > 0
        end },
      { name = "VELOCITY", get = function() return tostring(St.d.vel) end,
        delta = function(d) St.d.vel = clamp(St.d.vel + d, 1, 127) end },
    },
  },
}

DEFS.chord = {
  title = function() return "CHORD" end,
  info = function() return oct_info() .. (Kb.chord_name or K.SCALES[St.d.scale].name) end,
  lanes = {
    {
      ROOT,
      { name = "VELOCITY", get = function() return tostring(St.d.cvel) end,
        delta = function(d) St.d.cvel = clamp(St.d.cvel + d, 1, 127) end },
    },
    {
      { name = "STRUM",
        get = function()
          if (St.d.arp or 1) > 1 then return "ARP" end
          return (St.d.strum == 0) and "OFF" or (St.d.strum .. "ms")
        end,
        delta = function(d) St.d.strum = clamp(St.d.strum + (d * 5), 0, 250) end },
      { name = "V.LEAD", get = function() return onoff(St.d.vlead) end,
        delta = function(d) St.d.vlead = d > 0 end },
    },
    {
      { name = "ARP", get = function() return K.ARPS[St.d.arp or 1] end,
        delta = function(d)
          Kb.release_all()
          St.d.arp = clamp((St.d.arp or 1) + sgn(d), 1, #K.ARPS)
        end },
      { name = "RATE", get = function() return K.ARP_RATES[St.d.arp_rate or 3].name end,
        delta = function(d) St.d.arp_rate = clamp((St.d.arp_rate or 3) + sgn(d), 1, #K.ARP_RATES) end },
    },
  },
}

DEFS.settings = {
  title = function() return "SETTINGS" end,
  info = function() return Q.position() end,
  lanes = {
    {
      { name = "SCALE", get = function() return K.SCALES[St.d.scale].name end,
        delta = function(d) St.d.scale = clamp(St.d.scale + sgn(d), 1, #K.SCALES) end },
      { name = "TEMPO",
        get = function()
          local s = string.format("%.0f", params:get("clock_tempo"))
          if Q.source() ~= 1 then s = s .. " EXT" end
          return s
        end,
        delta = function(d)
          if Q.source() == 1 then params:delta("clock_tempo", d) end
        end },
    },
    {
      { name = "SWING", get = function() return St.d.swing .. "%" end,
        delta = function(d) St.d.swing = clamp(St.d.swing + d, 50, 75) end },
      { name = "SIGNATURE", get = function() return K.SIGS[St.d.sig].name end,
        delta = function(d) St.d.sig = clamp(St.d.sig + sgn(d), 1, #K.SIGS) end },
    },
    {
      { name = "TRANSPOSE", get = function() return (St.d.transpose == 2) and "IN KEY" or "CHROM" end,
        delta = function(d) St.d.transpose = clamp(St.d.transpose + sgn(d), 1, 2) end },
      nil,
    },
  },
}

local function ts() return St.track(P.tset_track or G.sel) end

DEFS.tset = {
  title = function() return "T" .. (P.tset_track or G.sel) .. " SETTINGS" end,
  info = function() return "" end,
  lanes = {
    {
      { name = "DEVICE", get = function() return O.name(ts().dev) end,
        delta = function(d)
          O.all_off()
          ts().dev = clamp(ts().dev + sgn(d), 1, 16)
        end },
      { name = "CHANNEL", get = function() return tostring(ts().ch) end,
        delta = function(d)
          O.all_off()
          ts().ch = clamp(ts().ch + sgn(d), 1, 16)
        end },
    },
    {
      { name = "FOLLOW",
        get = function()
          if (P.tset_track or G.sel) == K.MASTER then return "MASTER" end
          return onoff(ts().follow)
        end,
        delta = function(d)
          if (P.tset_track or G.sel) ~= K.MASTER then ts().follow = d > 0 end
        end },
      { name = "MUTE", get = function() return onoff(ts().mute) end,
        delta = function(d) ts().mute = d > 0 end },
    },
    {
      { name = "OCTAVE", get = function() return signed(ts().oct) end,
        delta = function(d) ts().oct = clamp(ts().oct + sgn(d), -4, 4) end },
      { name = "PROGRAM", get = function() return (ts().prog < 0) and "--" or tostring(ts().prog + 1) end,
        delta = function(d)
          local t = ts()
          t.prog = clamp(t.prog + d, -1, 127)
          O.program(t.dev, t.ch, t.prog)
        end },
    },
  },
}

P.DEFS = DEFS

-- -------------------------------------------------------------- navigation

function P.open(page)
  if page ~= "gen" then P.rot, P.shf = 0, 0 end
  P.page = page
  if page ~= "home" and page ~= "settings" then P.last = page end
  Q.dirty = true
end

function P.lane_of(page)
  local def = DEFS[page]
  local n = def and #def.lanes or 1
  return clamp(P.lane[page] or 1, 1, n)
end

function P.enc(n, d)
  local page = P.page
  if page == "home" then
    if n == 1 then G.select(clamp(G.sel + sgn(d), 1, K.NTRACKS))
    elseif n == 2 then
      if Q.source() == 1 then params:delta("clock_tempo", d) end
    else St.d.swing = clamp(St.d.swing + d, 50, 75) end
    Q.dirty = true
    return
  end
  local def = DEFS[page]
  if not def then return end
  if n == 1 then
    P.lane[page] = clamp(P.lane_of(page) + sgn(d), 1, #def.lanes)
  else
    local lane = def.lanes[P.lane_of(page)]
    local p = lane[n - 1]
    if p then p.delta(d) end
  end
  Q.dirty = true
end

-- the readout: lines = { big, second, third, hold = still held }, or nil
-- when what was held comes up (it then fades after a moment)
P.toast = nil
local TOAST = 1.5

function P.show(lines)
  if lines then
    P.toast = { lines = lines, hold = lines.hold, t = util.time() }
  elseif P.toast then
    P.toast.hold = false
    P.toast.t = util.time()
  end
  Q.dirty = true
end

local function toast_live()
  local t = P.toast
  if not t then return false end
  if t.hold or (util.time() - t.t) < TOAST then return true end
  P.toast = nil
  return false
end

-- K1: home and back
function P.home_toggle()
  if P.page == "home" then
    if G.settings then P.open("settings") else P.open(P.last or "track") end
  else
    P.open("home")
  end
end

-- ------------------------------------------------------------------ draw

local function txt(x, y, s, lvl, size)
  screen.font_size(size or 8)
  screen.level(lvl)
  screen.move(x, y)
  screen.text(s)
end

local function txt_r(x, y, s, lvl)
  screen.font_size(8)
  screen.level(lvl)
  screen.move(x, y)
  screen.text_right(s)
end

local function header(title, info)
  txt(0, 7, title, 15)
  if info and info ~= "" then txt_r(127, 7, info, 4) end
  screen.level(2)
  screen.move(0, 10)
  screen.line(128, 10)
  screen.stroke()
end

local function draw_param(x, y0, h, p, on)
  if not p then return end
  local v = p.get()
  local lvl = on and 15 or 3
  if h >= 24 then
    txt(x, y0 + 8, p.name, on and 6 or 2)
    if #v <= 5 then txt(x, y0 + 22, v, lvl, 16)
    else txt(x, y0 + 20, v, lvl) end
  else
    txt(x, y0 + 7, p.name, on and 6 or 2)
    txt(x, y0 + 15, v, lvl)
  end
end

local function draw_page(def, page)
  header(def.title(), def.info and def.info())
  local nl = #def.lanes
  local h = (nl <= 2) and 26 or 17
  local cur = P.lane_of(page)
  for i, lane in ipairs(def.lanes) do
    local y0 = 11 + ((i - 1) * h)
    local on = (i == cur)
    if on then
      screen.level(15)
      screen.rect(0, y0 + 2, 1, h - 4)
      screen.fill()
    end
    draw_param(4, y0, h, lane[1], on)
    draw_param(68, y0, h, lane[2], on)
  end
end

-- HOME: a row per track, its steps and where it is, and what it last played
local function draw_home()
  local d = St.d
  local state = Q.playing and ">" or (Q.paused and "||" or "[]")
  if Q.join_abs then state = "..." end
  txt(0, 7, state, 15)
  local tempo = string.format("%.0f", params:get("clock_tempo"))
  txt(14, 7, tempo .. " " .. K.SIGS[d.sig].name, 6)
  txt(52, 7, K.NOTE_NAMES[(d.root % 12) + 1] .. " " .. K.SCALES[d.scale].name:sub(1, 5), 4)
  txt_r(127, 7, Q.position(), 6)
  local now = util.time()
  for t = 1, K.NTRACKS do
    local y = 9 + ((t - 1) * 7)
    local trk, rt, c = St.track(t), Q.rt[t], St.clip(t)
    local lbl = (t == K.MASTER) and "M" or tostring(t)
    local lvl = (t == G.sel) and 15 or (trk.mute and 1 or 4)
    -- a clip waiting for its bar: the label blinks
    if rt.queued and (math.floor(now * 6) % 2 == 0) then lvl = 0 end
    txt(0, y + 6, lbl, lvl)
    -- the steps: a dot per note step, high or low with its pitch
    local x0, w = 8, 90 / c.len
    local lo, hi = 127, 0
    for i = 1, c.len do
      local st = c.steps[i]
      if St.has_notes(st) then
        lo = math.min(lo, st.notes[1])
        hi = math.max(hi, st.notes[1])
      end
    end
    local range = math.max(hi - lo, 1)
    -- a long clip: one mark per pixel column is plenty
    local drawn = -1
    for i = 1, c.len do
      local st = c.steps[i]
      local x = x0 + ((i - 1) * w)
      local px = math.floor(x)
      if px == drawn and rt.ph ~= i then st = nil end
      if (Q.playing or Q.paused) and rt.ph == i then
        screen.level(3)
        screen.rect(math.floor(x), y, math.max(1, math.floor(w)), 6)
        screen.fill()
      end
      if St.has_notes(st) then
        local yy = y + 5 - math.floor(((st.notes[1] - lo) / range) * 4 + 0.5)
        screen.level((rt.ph == i and Q.playing) and 15 or (trk.mute and 2 or 7))
        screen.rect(px, yy, math.max(1, math.floor(w) - 1), 1)
        screen.fill()
        drawn = px
      end
    end
    if rt.last and #rt.last > 0 then
      local s = K.note_name(rt.last[1])
      if #rt.last > 1 then s = s .. "+" end
      local fl = ((now - (rt.flash or 0)) < 0.15) and 15 or 4
      txt_r(127, y + 6, s, fl)
    end
  end
end

-- the readout over the page: the page's title stays, the rest is the news
local function draw_toast()
  local def = DEFS[P.page]
  if P.page == "home" or not def then header("VIBE COMPOSER", "T" .. G.sel)
  else header(def.title(), "") end
  local l = P.toast.lines
  local big = l[1] or ""
  if #big <= 12 then txt(0, 32, big, 15, 16) else txt(0, 28, big, 15) end
  if l[2] and l[2] ~= "" then txt(0, 46, l[2], 8) end
  if l[3] and l[3] ~= "" then txt(0, 58, l[3], 4) end
end

function P.redraw()
  screen.clear()
  screen.aa(0)
  screen.line_width(1)
  local def = DEFS[P.page]
  if toast_live() then draw_toast()
  elseif P.page == "home" or not def then draw_home()
  else draw_page(def, P.page) end
  screen.update()
end

return P
