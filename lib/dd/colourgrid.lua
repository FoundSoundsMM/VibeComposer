-- vibecomposer / dd / colourgrid
--
-- The COLOUR scene's grid: the master output, for everything (the synth
-- tracks and the drums both go through it).
--
--          1    2    3 ............................... 15   16
--   A-D  [ PERFORM: 64 punch-in effects, eight strips of eight  ]
--   E    .
--   F    BANK< BANK> .   .   .   .   .   .   .   .   .   .  .    BYPASS
--   G    [ melodic tracks 1-8: mute ] [ drum tracks 1-8: mute    ]
--   H    PLAY STOP .   .   .   .   .   SET .   .   .   .   .    .    TAPE
--
-- PERFORM: hold a pad to play it, SET + pad to latch it, STOP + pad to let
-- go of its strip's latch (lib/dd/perform). BANK steps through the COLOUR
-- banks the screen shows (BUSS DUCK TEXTURE SPACE). Row G mutes: lit is
-- heard. TAPE held is the hidden tape loop.

local S = include("lib/dd/spec")

local CG = {}
local g, St, F, VSt, Syn

CG.M = nil    -- vibe composer's grid: STOP and SET holds

local BACK, FWD, BYPASS = 1, 2, 16
local TAPE = 16

function CG.init(state, perform, vstate, synth)
  St, F, VSt, Syn = state, perform, vstate, synth
end

function CG.set_grid(dev) g = dev end

local function clear() return CG.M and CG.M.stop_held end
local function shift() return CG.M and CG.M.s_held end

function CG.key(x, y, z)
  local f, i = F.strip_at(x, y)
  if f then
    if z == 1 and clear() then
      CG.M.stop_used = true
      F.unlatch(f)
    elseif z == 1 then
      if shift() then CG.M.s_used = true end
      F.press(f, i, shift())
    else
      F.release(f, i)
    end
  elseif y == 6 and (x == BACK or x == FWD) then
    if z == 1 then
      local nb = #S.COLOUR_BANKS
      local b = S.COLOUR[St.col_sel].bank + ((x == FWD) and 1 or -1)
      St.col_sel = S.BANK_CELLS[((b - 1) % nb) + 1][1]
    end
  elseif y == 6 and x == BYPASS then
    if z == 1 then params:set("col_bypass", (params:get("col_bypass") == 2) and 1 or 2) end
  elseif y == 7 then
    if z == 1 then
      if x <= 8 then
        local tr = VSt.track(x)
        tr.mute = not tr.mute
        Syn.push(x)
      else
        St.toggle_mute(x - 8)
      end
    end
  elseif y == 8 and x == TAPE then
    if z == 1 and not CG.tape then
      CG.tape = true
      F.tape_on()
    elseif z == 0 and CG.tape then
      CG.tape = false
      F.tape_off()
    end
  elseif y == 8 and x == 8 then
    -- SET: only a modifier here (latching pads)
    if z == 1 then CG.M.s_held, CG.M.s_used = true, false
    else CG.M.s_held = false end
  end
  St.dirty = true
end

function CG.draw()
  local blink = (math.floor(util.time() * 8) % 2) == 0
  for f, s in ipairs(F.STRIPS) do
    local want = F.want(f)
    local held = {}
    for _, i in ipairs(F.held[f]) do held[i] = true end
    for i = 1, #s.pads do
      local x, y = F.pad_xy(f, i)
      local lv = (i == 1) and 4 or 2
      if held[i] then lv = 8 end
      if F.latched[f] == i then lv = 10 end
      if want == i then lv = held[i] and 15 or 12 end
      if F.waiting(f, i) then lv = blink and 15 or 4 end
      g:led(x, y, lv)
    end
  end
  g:led(BACK, 6, 6)
  g:led(FWD, 6, 6)
  g:led(BYPASS, 6, (params:get("col_bypass") == 2) and 15 or 4)
  for t = 1, 8 do
    local tr = VSt.track(t)
    g:led(t, 7, tr.mute and 1 or 9)
    local d = St.tracks[t]
    g:led(8 + t, 7, (d.mute or St.pmute[t]) and 1 or (6 + math.floor(d.flash * 6 + 0.5)))
  end
  g:led(8, 8, shift() and 10 or 4)
  g:led(TAPE, 8, CG.tape and 15 or 4)
end

return CG
