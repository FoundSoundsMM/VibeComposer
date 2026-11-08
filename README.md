# vibe composer

An eight-track MIDI sequencer for norns and a grid 128. It has an isomorphic
keyboard and a chord keyboard, trig conditions, Metropolix-style stages,
clips and snapshots. Track 8 transposes or harmonises the other seven.

## Install

In maiden's REPL:

```
;install https://github.com/FoundSoundsMM/VibeComposer
```

Then pick VIBECOMPOSER from the norns SELECT menu.

## Grid

```
       1    2    3    4    5    6    7    8    9   10   11 ...... 16
  A  [ steps 1-8                          ]  .    M    [           ]
  B  [ steps 9-16                         ]  .    C    [ keyboard  ]
  C  [ steps 17-24                        ]  .    .    [    or     ]
  D  [ steps 25-32   (K2: 33-64)          ]  .    .    [  chords   ]
  E    .    .    .    .    .    .    .    .    .    .    [           ]
  F    TC1  TC2  .    TC3  TC4  .    GEN  MUT  .    .    [           ]
  G    T1   T2   T3   T4   T5   T6   T7   T8   .    .    [           ]
  H    PLAY STOP .    .    .    .    .    SET  .    .    [ root      ]
```

### Steps

There are three ways to put notes in:

- Play a key, then press a step. The step takes the last key or chord you
  played.
- Hold a step and play keys. On a poly track, every key you play while the
  step is held goes into it.
- Hold keys and press steps. The held keys go into each step you press.

A quick tap on a full step empties it. A longer hold does not, so you can
hold a step and edit it on a TC page. Dim pads mark the beats and bars of
the time signature. A brighter step has trig settings, and a very dim one
is skipped.

### Buttons

- **T1-T8** select a track and open its TRACK page.
- **M** switches to the keyboard and opens KEYS. **C** switches to chords
  and opens CHORD.
- **TC1-TC4** open the trig-condition pages.
- **GEN** opens GENERATE. Press it again to generate a pattern. **MUT**
  works the same way for MUTATE.
- **PLAY** plays, and pressing it again pauses. A paused song carries on from
  where it stopped. Hold PLAY while the song is playing for **FILL**.
- **STOP** stops and goes back to the start. It also clears track 8's
  transposition.
- **SET** switches the grid to the session view and back.
- **SET + a track** opens that track's settings.

Pressing a page's button again goes back to HOME.

## Screen

E1 picks the lane, and E2 and E3 change its left and right parameters. K2
switches the step view between steps 1-32 and 33-64. K3 switches between
HOME and the last page you had open.

| page | lane 1 | lane 2 | lane 3 |
|---|---|---|---|
| TRACK | TYPE (mono / poly), SWING (offset on the global swing) | LENGTH 1-64, SPEED (1/16 to 1/1) | |
| TC1 | COND, PROB | VEL, GATE | |
| TC2 | MICRO, OCT | RATCHET, R.FADE | |
| TC3 | PULSES 1-8, MODE (repeat / hold / single / rest) | SKIP, RAMP | |
| TC4 | ACCUM, LIMIT | SLIDE, NOTE | |
| GEN | STYLE, DENSITY | RANGE, POOL (scale / last played) | |
| MUT | AMOUNT, TARGET | ROTATE, SHIFT (these act as you turn) | |
| KEYS | LAYOUT (4ths, 3rds, 5ths, seq), ROOT | IN-KEY, VELOCITY | |
| CHORD | ROOT, VELOCITY | STRUM (ms), V.LEAD | |
| SETTINGS | SCALE, TEMPO | SWING, SIGNATURE | TRANSPOSE (chromatic / in key) |
| TRACK SETTINGS | DEVICE, CHANNEL | FOLLOW, MUTE | OCTAVE, PROGRAM |

On a TC page, E2 and E3 change the steps you are holding. With no steps
held, they set what new steps start with.

HOME shows a row for each track: its steps, where the playhead is, and the
last note it sent. The track's number blinks while a clip launch is waiting
for its bar. On HOME, E1 selects the track, E2 sets the tempo and E3 sets the
global swing.

### Trig conditions

- **COND**: `--`, FILL, !FILL, PRE, !PRE, NEI, !NEI, 1ST, !1ST, or A:B from
  1:2 to 8:8. PRE checks this track's last condition. NEI checks the track
  to the left, and track 1's neighbour is track 8.
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

## Keyboard (M)

The bottom-left pad is the ROOT, and root notes are dim lit. Each pad to the
right is a semitone higher, or a scale step higher with IN-KEY on. Each row
up is a 4th, 3rd or 5th higher, depending on LAYOUT. With SEQ, each row
carries on from where the row below ended. VELOCITY is used for live playing
and for new steps.

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

## Track 8

Track 8 is the master track. Whatever it plays, from its sequence or from
the keyboard while track 8 is selected, controls the other tracks:

- **mono**: every following track is transposed by how far track 8's note
  is from ROOT. This is chromatic, or in key if SETTINGS > TRANSPOSE is set
  to IN KEY.
- **poly**: every following track's notes move to the nearest note of
  track 8's chord. A line stays in its register and follows the harmony.

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
- **Snapshots** are the keyboard's 48 pads. A snapshot holds the whole
  project: every clip, every setting, the key, swing, signature and tempo.
  - Hold a pad until it fills to save.
  - Tap a pad to load it. While playing, it loads on the next bar and every
    track restarts from step 1.
  - Hold STOP and hold a pad to delete it.

In the session view, STOP acts when you let go of it. This lets you hold it
as a modifier without stopping the song.

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

`lua lib/tools/check.lua` runs the script on a desktop against a fake norns
clock and MIDI ports, and checks note timing, sync messages, transposition,
conditions, clips, snapshots and that no text on any screen overlaps.
