-- vibecomposer / gen
--
-- Pattern generation (G, row F column 7) and mutation (G, column 8).
-- Both work on the selected track's playing clip and keep its length.
--
-- GENERATE writes a new pattern. STYLE is where the hits go and how the
-- notes move; DENSITY how many steps play; RANGE how many octaves up from
-- the root the notes can reach; POOL whether they come from the scale,
-- from the notes played last on the keyboard, or are the key's chords.
--
-- MUTATE changes what is there: AMOUNT of the steps move a note a scale
-- step or two (NOTES), slide to a neighbouring empty step (RHYTHM), or
-- either (BOTH). ROTATE and SHIFT act as you turn them: the pattern turns
-- round a step, or every note moves a scale step.

local K = include("lib/const")
local T = include("lib/theory")

local Gn = {}
local St, Kb

function Gn.init(state, keys) St, Kb = state, keys end

local function pool()
  local d = St.d
  local g = d.gen
  local out = {}
  if g.pool == 2 and Kb.last and #Kb.last.notes > 0 then
    for o = 0, g.range - 1 do
      for _, n in ipairs(Kb.last.notes) do out[#out + 1] = n + (o * 12) end
    end
    table.sort(out)
    return out
  end
  local nd = #T.iv(d.scale)
  for i = 0, (nd * g.range) do out[#out + 1] = T.degree_note(d.root, d.scale, i) end
  return out
end

local function hits(style, len, density)
  local on = {}
  local p = density / 100
  if style == 1 then
    local k = math.max(1, math.floor((len * p) + 0.5))
    for i = 0, len - 1 do on[i + 1] = ((i * k) % len) < k end
  elseif style == 6 then
    for i = 1, len do
      on[i] = ((i - 1) % 4 == 0) or (math.random() < p * 0.5)
    end
  else
    for i = 1, len do on[i] = math.random() < p end
  end
  return on
end

function Gn.generate(t)
  local g = St.d.gen
  local c = St.clip(t)
  local pl = pool()
  local on = hits(g.style, c.len, g.density)
  local steps = {}
  local idx = math.random(#pl)
  local n_on = 0
  for i = 1, c.len do
    if on[i] then
      n_on = n_on + 1
      local note
      if g.style == 3 then
        note = pl[((n_on - 1) % #pl) + 1]
      elseif g.style == 5 then
        idx = math.min(math.max(idx + math.random(-2, 2), 1), #pl)
        note = pl[idx]
      elseif g.style == 6 then
        -- root, fifth, octave, mostly the root
        local r = St.d.root
        local choices = { r, r, r, r + 7, r + 12, pl[math.random(#pl)] }
        note = choices[math.random(#choices)]
      else
        note = pl[math.random(#pl)]
      end
      local notes = { note }
      if g.pool == 3 then
        local d, _ = T.note_degree(note, St.d.root, St.d.scale)
        notes = T.chord({ base = St.d.root, scale = St.d.scale, deg = d, mods = {} })
      end
      steps[i] = St.new_step(t, notes)
    end
  end
  c.steps = steps
end

local function shift_notes(st, n)
  St.bake(st)
  for i, v in ipairs(st.notes) do
    st.notes[i] = math.min(math.max(T.shift_degrees(v, St.d.root, St.d.scale, n), 0), 127)
  end
end
Gn.shift_notes = shift_notes

function Gn.mutate(t)
  local m = St.d.mut
  local c = St.clip(t)
  local p = m.amount / 100
  local moved = {}
  for i = 1, c.len do
    local st = c.steps[i]
    if St.has_notes(st) and not moved[i] and math.random() < p then
      local what = m.target
      if what == 3 then what = math.random(2) end
      if what == 1 then
        local d = math.random(1, 2) * ((math.random() < 0.5) and -1 or 1)
        shift_notes(st, d)
      else
        local j = i + ((math.random() < 0.5) and -1 or 1)
        if j < 1 then j = c.len elseif j > c.len then j = 1 end
        if not St.has_notes(c.steps[j]) then
          c.steps[j], c.steps[i] = st, nil
          moved[j] = true
        end
      end
    end
  end
end

-- turn the pattern round by d steps within its length
function Gn.rotate(t, d)
  local c = St.clip(t)
  local len = c.len
  local new = {}
  for i = 1, K.MAXLEN do
    if i <= len then
      local j = ((i - 1 + d) % len) + 1
      new[j] = c.steps[i]
    else
      new[i] = c.steps[i]
    end
  end
  c.steps = new
end

-- every note of the clip d scale steps up or down
function Gn.shift(t, d)
  local c = St.clip(t)
  for _, st in pairs(c.steps) do
    if St.has_notes(st) then shift_notes(st, d) end
  end
end

return Gn
