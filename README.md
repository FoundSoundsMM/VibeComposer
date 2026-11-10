# vibe composer

An eight-track sequencer for norns and a grid 128, with an eight-voice drum
machine (drumdrum, ported in) running alongside it. Each melodic track plays
its own wavetable synth voice or sends MIDI. The sequencer has an isomorphic
keyboard and a chord keyboard, trig conditions, Metropolix-style stages,
clips and snapshots. Track 8 transposes or harmonises the other seven. The
synths and the drums all go through one master COLOUR stage.

## Install

In maiden's REPL:

```
;install https://github.com/FoundSoundsMM/VibeComposer
```

Then **restart norns** (SYSTEM > RESTART) so it compiles the engine, and
pick VIBECOMPOSER from the norns SELECT menu. Restart again after any update
that changes `lib/Engine_VibeComposer.sc`. If the drum screen says RESTART
NORNS, the engine running is out of date. vibe composer and drumdrum can be
installed side by side.

## Scenes

**K2 and K3** step through three scenes, round and round:

- **MELODIC:** the eight-track sequencer.
- **DRUMS:** the drum machine.
- **COLOUR:** the master output effects, with the punch-in effects on the
  grid.

A scene only decides what the grid and the screen show. Both sequencers
always play together, from one PLAY and STOP, one tempo, one swing and one
song position. The two grids put the things they share in the same places:

- steps on rows A-D
- the tracks on row G, columns 1-8
- PLAY, STOP and SET on row H
- COND / PROB on F1, PULSES / MODE on F4 and RAIN on F8

STOP held is the clear modifier on both grids, and SET held is the other
modifier.

## Grid

```
       1    2    3    4    5    6    7    8    9   10   11 ...... 16
  A  [ steps 1-8                          ]  .    M    [           ]
  B  [ steps 9-16                         ]  .    C    [ keyboard  ]
  C  [ steps 17-24                        ]  .    .    [    or     ]
  D  [ steps 25-32                        ]  .    .    [  chords   ]
  E  [ step pages                         ]  .    .    [           ]
  F    TC1  TC2  .    TC3  TC4  .    GEN  RAIN .    .    [           ]
  G    T1   T2   T3   T4   T5   T6   T7   T8   .    OCT+ [           ]
  H    PLAY STOP REC  .    .    .    SYN  SET  .    OCT- [ root      ]
```

### Steps

There are three ways to put notes in:

- Play a key, then press a step. The step takes the last key or chord you
  played.
- Hold a step and play keys. Every key you play while the step is held
  goes into it.
- Hold keys and press steps. The held keys go into each step you press.

A step holds whatever you gave it: one note, or a chord. There's no
mono/poly setting. A chord from chord mode also keeps its strum or its
arpeggio.

A quick tap on a full step empties it. A longer hold does not, so you can
hold a step and edit it on a TC page.

**Note length:** hold a step and press a later one. The first step's note
lasts up to and including the second, and the steps it covers glow dimly.
Press the same pair again to set it back to one step. Turning GATE on TC1
also sets it back.

A track can be up to 512 steps long. The grid shows 32 at a time, and row
E picks which 32. Each pad is a page, lit as far as the clip goes. The page
showing is bright and the page playing is a little brighter than the rest.
Past eight pages each pad covers two: press it again for the second. Dim pads mark the beats and bars of the time
signature. A brighter step has trig settings, and a very dim one is
skipped.

### Buttons

- **T1-T8** select a track and open its TRACK page.
- **M** switches to the keyboard and opens KEYS. **C** switches to chords
  and opens CHORD.
- **TC1-TC4** open the trig-condition pages.
- **GEN** opens GENERATE. Press it again to generate a pattern.
- **RAIN** opens RAIN. Press it again to stop or start the rain on the
  selected track, keeping its amount. The button glows when the track has
  rain on.
- **PLAY** plays, and pressing it again pauses. A paused song carries on from
  where it stopped. Hold PLAY while the song is playing for **FILL**.
- **STOP** stops and goes back to the start when you let go of it. It also
  clears track 8's transposition. Because it acts on release, you can hold
  it as a modifier without stopping the song.
- **STOP + a track** empties the clip that track is playing. The clip keeps
  its length, speed and direction, and the song keeps playing.
- **REC** records what you play on the keyboard or chord pads into the
  selected track (see Recording).
- **OCT+ / OCT-** move the keyboard and the chord pads up or down an
  octave, up to three each way. Press both together to reset.
- **SET** switches the grid to the session view and back.
- **SET + a track** opens that track's settings.
- **SET + a step** sets the clip's length: it ends on that step.
- **SYN** opens the selected track's SYNTH page.

Pressing a page's button again goes back to HOME.

## Screen

E1 picks the lane, and E2 and E3 change its left and right parameters. A
page with more than three lanes scrolls as E1 moves. K1 switches between
HOME and the last page you had open. K2 and K3 change scene.

| page | lane 1 | lane 2 | lane 3 |
|---|---|---|---|
| TRACK | DIRECTION (fwd, bwd, pendulum, walk, random), SWING (offset on the global swing) | LENGTH 1-512, SPEED (x1 is a step every 16th; turn left for /2, /4, /8, /16, /32, /64) | |
| TC1 | COND, PROB | VEL, GATE | |
| TC2 | MICRO, OCT | RATCHET, R.FADE | |
| TC3 | PULSES 1-8, MODE (repeat / hold / single / rest) | SKIP, RAMP | |
| TC4 | ACCUM, LIMIT | SLIDE, NOTE | |
| GEN | STYLE, DENSITY | RANGE, POOL (scale / last played / chords) | ROTATE, SHIFT (these act as you turn) |
| RAIN | AMOUNT, SPREAD (scale steps either side) | CENTRE (AUTO or a note) | |
| KEYS | LAYOUT (4ths, 3rds, 5ths, seq), ROOT | IN-KEY, VELOCITY | VOICE of the selected track (POLY / MONO) |
| CHORD | ROOT, VELOCITY | STRUM (ms), V.LEAD | ARP (off, up, down, up-down, random), RATE (1/32 to 1/4, with triplets) |
| SETTINGS | SCALE, TEMPO | SWING, SIGNATURE | TRANSPOSE (chromatic / in key) |
| TRACK SETTINGS | OUTPUT (SYNTH / MIDI), MUTE | DEVICE, CHANNEL (MIDI) | FOLLOW, OCTAVE; then PROGRAM (MIDI) |
| SYNTH | see Synth | | |

On a TC page, E2 and E3 change the steps you are holding. With no steps
held, they set what new steps start with.

**Readout:** when you play keys, a chord or a modifier, the screen shows
what happened in place of the page's parameters. It stays while you hold
the pad and for a moment after you let go.

- **Keys:** the notes you're holding, and the chord they make (C, Dm7,
  C/E, and so on).
- **Chord pads:** the chord's name, its notes, and every modifier that's
  on.
- **Modifiers:** the modifier, what it does ("3rd becomes a 4th"), and its
  group. When you let go, it says whether it's now on or off.

Setting a note's length, arming REC, changing octave and paging the steps
also show here.

HOME shows a row for each track: its steps, where the playhead is, and the
last note it sent. The track's number blinks while a clip launch is waiting
for its bar. On HOME, E1 selects the track, E2 sets the tempo and E3 sets the
global swing.

### Trig conditions

- **COND**: `--`, FILL, !FILL, PRE, !PRE, NEI, !NEI, 1ST, !1ST, or A:B from
  1:2 to 8:8. PRE checks this track's last condition. NEI checks the track
  to the left, and track 1's neighbour is track 8.
- **PROB** is the step's chance of playing. With no step held and the
  new-step COND at `--`, PROB is the whole track's chance instead (shown as
  "ALL"). Every step on the track then plays only that often, on top of its
  own PROB. Set a COND for new steps and PROB goes back to setting new
  steps' chance.
- **MICRO** moves the step up to half a step early or late.
- **RATCHET** splits each hit into 1-8 evenly spaced notes. **R.FADE**
  fades them out (positive) or in (negative).
- **PULSES** is how many clock steps the stage lasts, like the Metropolix.
  **MODE** sets what plays during those pulses:
  - REPEAT plays a note on every pulse.
  - HOLD plays one note held across all the pulses.
  - SINGLE plays one note on the first pulse.
  - REST plays nothing.

  **RAMP** shapes the velocity across the pulses.
- **SKIP** removes the stage from the pattern without stopping the pattern
  in time.
- **ACCUM** transposes the stage by this many semitones each time it plays.
  After **LIMIT** passes it starts again.
- **SLIDE** holds the note into the next one (legato), which makes a mono
  synth glide.
- **NOTE** moves the held steps' notes by a semitone, or by a scale step
  when IN-KEY is on.

## Synth

Every track plays the engine's wavetable voice unless TRACK SETTINGS >
OUTPUT is set to MIDI. It morphs through a bank of single-cycle waves the
way the Synthesis Technology E350 Morphing Terrarium does. Every wave in a
bank shares its harmonics' phases and its loudness, and the voice
crossfades between neighbouring waves sample by sample. Turning WAVE slides
the timbre without thinning, pumping or stepping. Each wave has a
band-limited copy per octave, so high notes don't alias.

There are eight banks of 32 waves, each running dark to bright, built from
Adventure Kid's AKWF single-cycle waveforms (CC0; see
`lib/wavetables/README.md`): BASIC, HARMONIC, OVERTONE, VOICE, ORGAN, FM,
CHIP and DIGITAL.

The SYNTH page (SYN, H7) has thirteen lanes. E1 scrolls through them, and
the header names the group:

| group | left | right |
|---|---|---|
| OSC | BANK | WAVE: where in the bank, 0-100 |
| OSC | SUB: a sine an octave down | FINE: cents |
| FILTER | CUTOFF (OPEN at the top) | RES |
| FG1 AMP | RISE | FALL |
| FG1 AMP | CURVE: linear to exponential | MODE |
| FG2 MOD | RISE | FALL |
| FG2 MOD | CURVE | MODE |
| FG2 MOD | TO WAVE: how far FG2 moves WAVE, either way | TO CUT: how far it moves CUTOFF |
| LFO | RATE | SHAPE (SINE TRI SAW RAMP SQUARE S+H) |
| LFO | DEPTH | DEST: PITCH, WAVE, CUTOFF or AMP |
| MIX | LEVEL | PAN |
| MIX | DELAY send | SPRING send |
| MIX | DRIVE | GLIDE (MONO tracks) |

The two function generators rise and fall on exponential curves. **FG1**
shapes the volume and **FG2** the modulation. Each has a MODE:

- **AD** rises and falls once, however long the note is.
- **ASR** rises, holds while the note does, and falls when it ends.
- **CYCLE** rises and falls over and over while the note is held.

FG1's MODE takes effect from the next note.

KEYS > VOICE set to MONO makes the voice monophonic. Legato notes, from
SLIDE steps or keys held over each other, glide over GLIDE without
retriggering. A poly track plays up to eight notes, and a ninth takes the
oldest one's place.

Each synth track has its own channel strip into the master COLOUR, with
the delay and spring sends. A drum track picked as the DUCK source pumps
the synths too. The SYNTH settings are part of the track, so they save with
the project and go into snapshots. A project from before the synth keeps
every track on MIDI.

## Drums

The drum machine is drumdrum's, so it has the same eight voices (BD1 BD2
CLP SNR PRC1 PRC2 HAT CYM), four kits (WARM, WOOD, FM and ADD), a sample
under every voice, per-step locks and conditions, four clips a track and
the sampler. Its grid is laid out to match the melodic one:

```
       1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
  A-D  [ the selected track's 64 steps, 16 a row                                    ]
  E    T1   T2   T3   T4   S1   S2   S3   S4   N1   N2   L1   L2   C1   C2   .    .
  F    TC1  TC2  TC3  P1   P2   TC4  .    RAIN .    .    .    .    .    .    .    .
  G    TR1  TR2  TR3  TR4  TR5  TR6  TR7  TR8  .    .    .    .    .    .    .    .
  H    PLAY STOP .    .    .    .    .    SET  .    .    .    .    .    SWING MIX  COLOUR
```

- **Steps:** tap to add or remove a step. Hold steps and turn a control to
  lock values to those steps.
- **Controls:** hold one and turn E2 / E3. T is the voice, S the sample, N
  noise, L the LFOs and C drive and sends. TC1 is COND / PROB, TC2 VEL /
  NUDGE, TC3 PITCH / MIX and TC4 FLAM / DECAY. P1 is PULSES / MODE and P2
  RAMP / BEND.
- **LFO:** hold L1 or L2 together with a control, then turn E2 or E3 to
  patch it to that side. Keep turning to set the depth. With an LFO held,
  K3 changes its shape.
- **Tracks** (row G): tap to select. Tap the selected track again to hear
  it.
- **RAIN** (held): E2 sets how much random hits rain across the voices.
- **SWING** (held): E2 sets the swing, which is the melodic side's swing as
  well. E3 sets the drums' swing grid.
- **MIX** shows a fader and meter over each track and pan on the right.
  The track pads mute.
- **COLOUR** goes to the COLOUR scene.
- **SET on its own** opens the drum session view: four clips over each
  track, the kits on E1-E4 (tap one for every track, or hold one and press
  tracks), and the song's snapshots on the right, the same 48 pads as the
  melodic session view.

| STOP (held) + | |
|---|---|
| step | back to a plain hit |
| track | the playing clip emptied |
| control | reset, or its locks taken off the held steps |
| clip | emptied |
| snapshot (hold) | deleted |

| SET (held) + | |
|---|---|
| step | the track's length |
| S1 + step | record a sample that many steps long |
| control | keep it open |
| track | hear the track |
| E2 / E3 | change every track |
| COLOUR (held) | the hidden TAPE loop |

On the screen, E1 picks the track, or LENGTH / TIMING and DIRECTION / DILLA
on the main page. E2 and E3 set the two values shown. K1 held is fine
adjust.

Under Link or MIDI clock, the drums and the synth tracks are sent early by
`PARAMS > SYNC > sync lead` (30 ms by default). This makes up for the delay
in norns' audio output. To set it, record a kick into your DAW. If it lands
late, raise the lead by that many milliseconds; if early, lower it.

## COLOUR

The COLOUR scene is the master output. Every synth track and every drum
goes through it. The screen is drumdrum's COLOUR page: the drum buss,
ducker, texture, delay and spring reverb. E1 picks a setting, and E2 / E3
change it.

```
       1     2     3 ..................................... 15    16
  A-D  [ PERFORM: 64 punch-in effects, eight strips of eight          ]
  F    BANK< BANK> .                                         .     BYPASS
  G    [ melodic tracks 1-8: mute  ] [ drum tracks 1-8: mute          ]
  H    PLAY  STOP  .    .    .    .    .    SET  .   ...      .     TAPE
```

- **PERFORM:** hold a pad to play it, and SET + pad to latch it. STOP + pad
  lets go of its strip's latch. While playing, a press waits for the next
  beat (PARAMS > PERFORM > quantize). The screen shows the effects while a
  pad is held.
- **BANK** steps through the COLOUR banks (BUSS, DUCK, TEXTURE, SPACE).
- **Row G** mutes: lit is heard.
- **TAPE** (held) loops the last stretch of the mix. E2 sets its pitch and
  E3 its length.

## Rain

Rain works the way it does in drumdrum. Each track has its own amount.
Whenever one of its steps would play nothing, a note may fall into it
instead. That covers an empty step, a step whose condition failed, and a
REST pulse.

- **Amount:** the chance of a drop and how loud it is both grow with the
  square of AMOUNT. A little rain is a stray note every few bars; a lot is a
  downpour.
- **Always in the scale:** every drop is a note of the key's scale, within
  SPREAD scale steps of CENTRE. CENTRE is either a note you pick or AUTO,
  the middle of the clip's own notes. Drops stay in the scale even when
  track 8 has transposed the track somewhere else.
- **Never over a held note:** rain doesn't fall while the track is still
  sounding a note, so long notes and ties are left alone.

Drops aren't written into the clip: each pass rains differently.

## Scale

Changing SETTINGS > SCALE moves every sequenced note into the new scale as
it plays. Between scales of the same size it goes scale step for scale
step, so C major's E becomes C minor's Eb. Otherwise each note goes to the
nearest note of the new scale. The notes you wrote are kept as they were,
so switching back gives you exactly what you had. Editing a step's notes
writes them down in the scale that's on at the time.

## Recording

Arm **REC** and play the keyboard or the chord pads.

- **While playing**, notes go into the selected track at the step that's
  playing. Past the middle of a step, they go into the next one and play on
  the next pass. Keys held together go into one step. A note held across
  several steps is recorded with that length.
- **While stopped**, it's step recording. Each key or chord goes into the
  record step (the blinking pad), which then moves on by one. Press a step
  to move the record step there.

REC lights while armed and blinks when stopped. Holding a step and playing
keys still writes into that step, whether REC is on or not.

## Keyboard (M)

The bottom-left pad is the ROOT, and root notes are dim lit. Each pad to the
right is a semitone higher, or a scale step higher with IN-KEY on. Each row
up is a 4th, 3rd or 5th higher, depending on LAYOUT. With SEQ, each row
carries on from where the row below ended. VELOCITY is used for live playing
and for new steps.

VOICE is set per track, and is saved with the track and in snapshots. Set it
to MONO for a monosynth, and the keyboard plays with new-note priority:
- a new key cuts the note that is sounding, with a note-off before the new
  note-on, so it works whatever note priority the synth itself uses
- let go of it and the newest key still held plays again
- keys held but cut light dimmer than the one sounding
- keys held together don't make a chord: a step, or a recording, takes the
  note that is sounding
- when recording live, a note that gets cut ends where it was cut

The chord pads always play chords. With ARP on, they suit a monosynth too.

## Chords (C)

Rows G-H are twelve chords from the key. Row H has degrees I-VI and row G
has VII, then I-V an octave up. Rows A-F are the modifiers:

```
  A  7     M7    9     11    13    6       extensions
  B  SUS2  SUS4  MAJ   MIN   DIM   AUG     third and fifth
  C  INV1  INV2  INV3  DROP2 DROP3 SPRD    voicing
  D  -2    -1    +1    +2    BASS  TOP     octave / doubled root
  E  PAR   V/    vii/  bII   TT    DOM7    borrowed chords
  F  UP    DOWN  RAND  NO R  NO 3  NO 5    strum direction | omit
```

Tap a modifier to latch it and tap it again to let go. Each row allows one
modifier, and row F allows one per half. If you hold a modifier while you
play a chord, it applies to that chord only.

V.LEAD picks the inversion that sits closest to the previous chord. STRUM
spaces the notes out, and a step remembers the strum it was recorded with.

**ARP** (CHORD page, lane 3) plays a held chord one note at a time at RATE,
locked to the clock, whether or not the song is playing. A step recorded
from it arpeggiates the chord across its length. If you give the step a
long note (hold it and press a later step), the arpeggio runs across all
of it. With ARP on there's no strum.

## Track 8

Track 8 is the master track. Whatever it plays, from its sequence or from
the keyboard while track 8 is selected, controls the other tracks:

- **A single note** transposes every following track by how far it is
  from ROOT. This is chromatic, or in key if SETTINGS > TRANSPOSE is set to
  IN KEY.
- **A chord** moves every following track's notes to the nearest note of
  that chord. A line stays in its register and follows the harmony.

A step on track 8 set to MODE REST still transposes but makes no sound. You
can also mute track 8 in its settings so it only steers the other tracks.
FOLLOW (in TRACK SETTINGS) turns following off for a track.

## Session view (SET)

- **Clips** are rows A-D under each track's column. There are four per
  track.
  - Tap a clip to launch it on the next bar. When the song is stopped, it
    launches straight away.
  - An empty slot launches as a new empty clip one bar long.
  - Hold a clip and tap another to copy it. This works between tracks too.
  - Hold STOP and tap a clip to empty it.
- **Snapshots** are the keyboard's 48 pads. They are the same pads in the
  drum session view. A snapshot holds every setting:
  - every track's clips and steps, and its settings: swing, direction,
    probability, rain, device, channel, follow, mute, octave and program
  - the key, scale, transpose mode, swing, signature and tempo. The tempo
    only loads on the internal clock.
  - the keyboard and chord settings, latched modifiers, arp and octave
  - which keyboard is up (keys or chords), the selected track, the notes
    you played last, and track 8's live transposition
  - every track's OUTPUT and SYNTH settings
  - the whole drum machine: every drum sound, kit, sample, mix and LFO,
    the patterns and their clips, and the master COLOUR

  Loading a snapshot resends every MIDI track's program change. The MIDI
  clock-out ports aren't in snapshots, because they belong to the norns,
  not the song. Neither is norns' clock source.
  - Hold a pad until it fills to save.
  - Tap a pad to load it. While playing, it loads on the next bar and every
    track restarts from step 1.
  - Tap an empty pad for a new snapshot with every setting at its default
    (empty clips, C major, 120 BPM, synth on every track, the drums as
    the script starts them). It loads like any other,
    so it's a blank song to start from.
  - Hold STOP and hold a pad to delete it.

STOP acts when you let go of it, so you can hold it as a modifier without
stopping the song.

## Sync

vibe composer follows norns' clock source: SYSTEM > CLOCK > source.

- **Clock master (internal)**: turn ports on in PARAMS > VIBE COMPOSER >
  MIDI CLOCK OUT. Those ports get the clock plus Start, Stop, Continue and
  Song Position. The MIDI Start goes out right before the tick that is our
  beat 1. On a resume the slave gets the song position and picks up on the
  next sixteenth. The clock comes from the same 1/24-beat coroutine that
  sends the notes. Any port norns was already clocking is taken over, and
  norns' own clock out on that port is turned off, so the port never gets
  two clocks. The norns setting comes back when you leave the script.
- **Clock slave (midi)**: the DAW's Start starts the song on its first
  tick. Its Stop pauses, and Continue with a Song Position carries on from
  that position. Pressing PLAY when you are not running waits for the next
  bar of the DAW's count.
- **link / crow**: PLAY waits for the next bar or quantum. With Link
  start/stop sync on, PLAY and STOP control the whole session.

PARAMS > VIBE COMPOSER > all notes off sends a note off for every sounding
note plus CC 123 on every track's channel.

## Files

The project saves itself when you leave the script and loads when you open
it. Snapshots are saved as you make them. Both live in
`~/dust/data/vibecomposer/`.

## Testing

`lib/tools/check-engine.sh` compiles the engine against SuperCollider on a
desktop and builds every SynthDef. With `--render` it also plays the synth
voice through scsynth offline and checks that every voice frees itself, and
with `--live` it drives the engine's commands on a running server.

`lua lib/tools/check.lua` runs the script on a desktop against a fake norns
clock and MIDI ports. It checks:

- note timing and sync messages
- transposition, the scale following, directions, note lengths,
  arpeggios and rain
- recording, conditions, clips and snapshots
- the synth: keys and steps reach it, the SYNTH page, OUTPUT
- the drums: grid layout and modifiers, drums and synth landing together
  on one clock, PLAY / pause / STOP, the session view, snapshots that carry
  the drums, the COLOUR scene
- that no text on any screen overlaps
