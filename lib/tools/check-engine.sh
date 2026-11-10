#!/usr/bin/env bash
# Offline check for lib/Engine_VibeComposer.sc: compiles the class against
# the real SuperCollider class library and builds every SynthDef graph, with
# no norns and no server. Catches UGen-level mistakes, not just syntax. It
# reads no Lua: everything it plays is written out below. The synth voice
# reads lib/wavetables/vc_wavetables.wav.
#
#   check-engine.sh            build: count the vc_ defs (want 95: drumdrum's
#                              91, vc_wt_ad / _asr / _cyc and vc_lfo), fail on
#                              any error
#   check-engine.sh --render   then play the wavetable voice through vc_lfo
#                              and vc_strip in scsynth NRT and measure it:
#                                a note in every bank
#                                a slow full WAVE sweep on a held note in each
#                                  bank: the RMS swing across it (want < 1.5
#                                  dB) and its biggest sample-to-sample jump
#                                  against the same note held still at each
#                                  end (a click would stand out)
#                                C7 at its own table level against the same
#                                  note forced onto the richest table: the
#                                  energy between the harmonics (aliasing)
#                                filter sweeps by FG2, AD / ASR / CYCLE, a
#                                  mono glide, a steal, a chord, the SUB
#                              then peak, RMS, DC, NaN, the tail, and whether
#                              every voice freed itself
#   check-engine.sh --live     boot a real scsynth, run the engine's alloc and
#                              drive its synth commands (poly steal, mono
#                              stack, AD / CYCLE freeing, panic), counting nodes
#
# VC_KEEP=file.wav keeps the render.
set -euo pipefail
SC=${SC:-/Applications/SuperCollider.app/Contents/MacOS/sclang}
SCSYNTH=${SCSYNTH:-/Applications/SuperCollider.app/Contents/Resources/scsynth}
LIB=${LIB:-/Applications/SuperCollider.app/Contents/Resources/SCClassLibrary}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MODE=${1:-}
case "$MODE" in ""|--render|--live) ;; *) echo "usage: $0 [--render|--live]"; exit 2;; esac
mkdir -p "$WORK/classes"
cp "$ROOT/lib/Engine_VibeComposer.sc" "$WORK/classes/"
# the tables, where the engine looks for them (next to itself), and for NRT
mkdir -p "$WORK/classes/wavetables"
cp "$ROOT/lib/wavetables/vc_wavetables.wav" "$WORK/classes/wavetables/"
cp "$ROOT/lib/wavetables/vc_wavetables.wav" "$WORK/"
# norns' CroneEngine, as far as the engine uses it: commands and polls are
# kept so --live can call them
cat > "$WORK/classes/_stubs.sc" <<'STUB'
CroneEngine {
	var <context, <doneCallback, <cmds, <polls;
	*new { arg context, doneCallback; ^super.newCopyArgs(context, doneCallback).initStub }
	initStub { cmds = IdentityDictionary.new; polls = IdentityDictionary.new }
	addCommand { arg name, format, func; cmds[name.asSymbol] = func }
	addPoll { arg name, func; polls[name.asSymbol] = func }
	cmd { arg name ... a; ^cmds[name].value([name] ++ a) }
	alloc {} free {}
}
STUB
# deprecated/ is left out (it does not compile here), and with it this
# class; --live needs deprecated/ (the OSC responders live there)
[ "$MODE" = "--live" ] || echo 'QuartzComposerView { }' >> "$WORK/classes/_stubs.sc"
cat > "$WORK/conf.yaml" <<CONF
includePaths:
  - $LIB
  - $WORK/classes
excludePaths:
$( [ "$MODE" = "--live" ] || echo "  - $LIB/deprecated" )
  - $HOME/Library/Application Support/SuperCollider/Extensions
postInlineWarnings: false
CONF

cat > "$WORK/run.scd" <<'RUN'
var n = 0, bad = 0, dir = thisProcess.argv[0], mode = thisProcess.argv[1];
try { Engine_VibeComposer.buildDefs } { |err| bad = 1; "\n!! BUILD ERROR: %\n".postf(err.errorString) };
SynthDescLib.global.synthDescs.keysDo { |k|
	if(k.asString.beginsWith("vc_")) { n = n + 1 } };
// drumdrum's 91 (every voice twice, full and lean, the strip, fx, sampler,
// punch-ins and COLOUR's stages), then the synth: a wavetable voice per FG1
// mode and the LFO
"\n== synthdefs built: % (want 95)  errors: %\n".postf(n, bad);
if(n != 95) { bad = bad + 1 };
[\vc_wt_ad, \vc_wt_asr, \vc_wt_cyc, \vc_lfo].do { |d|
	if(SynthDescLib.global[d].isNil) { "!! missing %\n".postf(d); bad = bad + 1 } };

if(mode == "render" and: { bad == 0 }) {
	// what lua sends a synth track by default
	var base = (bank: 0, wave: 0.3, sub: 0, fine: 0, cut: 18000, res: 0,
		f1r: 0.003, f1f: 0.6, f1c: 4, f2r: 0.001, f2f: 0.4, f2c: 4, f2m: 0, f2w: 0, f2k: 0,
		lfd: 0, lft: 0, glide: 0);
	// buses: the voice on audio 16, its strip to 0-1; the raw voice bus
	// copied to output 2 so the WAV's third channel is the pre-strip level.
	// Control: LFO 10, drift 11, meter 12, sidechain 13, duck 14-16 (no
	// one writes them: no duck). hbus 20 and the sends 22 / 24 go nowhere.
	// The tables in buffers 0-47, as the engine loads them.
	var vb = 16, ev = List.new, notes = List.new, wins = List.new, id = 1000;
	var path = dir ++ "/vc_wavetables.wav", n = 32 * 1025;
	var sweepLen = 2.0, steps = 100;
	// a note: FG1 mode, start, note, vel, off (nil: never), changes,
	// [[time, key, value]...]. Returns its id.
	var play = { |label, mode, at, note, vel, off, ch, sets|
		var a = base.copy.put(\tbase, 0)
			.put(\lvl, Engine_VibeComposer.synLevel(note.midicps)).putAll(ch ? ());
		notes.add([id, at, (off ? at) + 0.05, label]);
		ev.add([at, ['/s_new', Engine_VibeComposer.wtDefs[mode], id, 1, 101] ++ a.asKeyValuePairs
			++ [\out, vb, \gate, 1, \alive, 1, \note, note, \vel, vel, \lfo, 10, \drift, 11,
				\an, a[\an] ? 0.5]]);
		if(off.notNil) { ev.add([off, ['/n_set', id, \gate, 0]]) };
		(sets ? []).do { |c| ev.add([c[0], ['/n_set', id, c[1], c[2]]]) };
		id = id + 1;
		id - 1
	};
	var t = 0.1, endt;
	SynthDef(\chk_mon, { Out.ar(2, In.ar(\in.kr(16))) }).add;
	(Engine_VibeComposer.wtDefs ++ [\vc_lfo, \vc_strip, \chk_mon]).do { |d|
		ev.add([0.0, ['/d_recv', SynthDescLib.global[d].def.asBytes]]) };
	48.do { |i| ev.add([0.0, ['/b_allocRead', i, path, i * n, n]]) };
	ev.add([0.0, ['/g_new', 100, 0, 0]]);
	ev.add([0.0, ['/g_new', 101, 3, 100]]);
	ev.add([0.0, ['/g_new', 102, 3, 101]]);
	ev.add([0.0, ['/s_new', \vc_lfo, 900, 0, 100, \out, 10, \rate, 5, \shape, 0]]);
	ev.add([0.0, ['/s_new', \vc_strip, 901, 0, 102, \in, vb, \out, 0, \meter, 12, \sc, 13,
		\duck, 14, \drift, 11, \hbus, 20, \dbus, 22, \sbus, 24, \idx, 9,
		\level, 0.8, \pan, 0, \warmth, 0]]);
	ev.add([0.0, ['/s_new', \chk_mon, 902, 3, 102, \in, vb]]);

	// a note in every bank, mid-table
	8.do { |b| play.("bank % wave .5".format(b), 1, t, 48 + (b * 2), 1, t + 0.3, (bank: b, wave: 0.5, f1f: 0.1));
		t = t + 0.45 };
	// a slow full sweep in each bank: still at 0, 0 to 1 over sweepLen in
	// 100 steps (lua sends no finer), still at 1
	t = t + 0.2;
	8.do { |b|
		var s0 = t + 0.4;
		play.("sweep bank %".format(b), 1, t, 48, 1, s0 + sweepLen + 0.45, (bank: b, wave: 0, an: 0, f1f: 0.15),
			(1..steps).collect { |k| [s0 + (k * sweepLen / steps), \wave, k / steps] });
		wins.add(["sweep", b, t + 0.1, s0, s0 + 0.05, s0 + sweepLen, s0 + sweepLen + 0.1, s0 + sweepLen + 0.4]);
		t = s0 + sweepLen + 0.7;
	};
	t = t + 0.5;
	// C7, the brightest frames, at its own table level and forced onto
	// the richest (aliasing) one, no drift or detune so the harmonics are
	// exactly where they should be
	[[0, nil], [0, 0], [7, nil], [7, 0]].do { |c|
		var ch = (bank: c[0], wave: 1, an: 0, f1f: 0.1);
		if(c[1].notNil) { ch[\lvl] = c[1] };
		play.("C7 bank % lvl %".format(c[0], ch[\lvl] ? Engine_VibeComposer.synLevel(96.midicps)), 1, t, 96, 1, t + 0.4, ch);
		wins.add(["alias", "C7 bank % %".format(c[0], if(c[1].isNil) { "own level" } { "level 0" }), t + 0.1]);
		t = t + 0.8;
	};
	play.("filter FG2 AD up, res .6", 1, t, 36, 1, t + 1.0,
		(bank: 1, wave: 0.8, cut: 300, res: 0.6, f2k: 0.8, f2m: 0, f2r: 0.02, f2f: 0.8)); t = t + 1.3;
	play.("filter FG2 CYCLE down", 1, t, 43, 1, t + 1.2,
		(bank: 5, wave: 0.7, cut: 8000, res: 0.4, f2k: -0.6, f2m: 2, f2r: 0.15, f2f: 0.15)); t = t + 1.5;
	play.("AD (gate ignored)", 0, t, 72, 1, t + 0.05, (bank: 6, wave: 0.4, f1f: 0.4)); t = t + 0.6;
	play.("CYCLE + LFO wave", 2, t, 64, 0.9, t + 1.2, (bank: 3, f1r: 0.05, f1f: 0.12, lfd: 0.5, lft: 1)); t = t + 1.5;
	play.("mono glide, FG2 wave", 1, t, 50, 1, t + 1.0, (bank: 2, glide: 0.08, f2m: 2, f2r: 0.1, f2f: 0.1, f2w: 0.5),
		[[t + 0.3, \note, 53], [t + 0.6, \note, 57]]); t = t + 1.3;
	play.("stolen (alive 0)", 1, t, 62, 1, nil, (), [[t + 0.3, \alive, 0]]); t = t + 0.5;
	// a note-off, and a steal, in the same block as the note-on: the gate
	// never rises, and the voice must still let go
	play.("zero-length note", 1, t, 65, 1, t, ()); t = t + 0.7;
	play.("stolen at birth", 1, t, 66, 1, nil, (), [[t, \alive, 0]]); t = t + 0.2;
	[60, 64, 67].do { |k| play.("chord %".format(k), 1, t, k, 0.9, t + 0.8, (bank: 4, wave: 0.6, sub: 0.5)) };
	t = t + 1.1;
	play.("LFO cutoff, res .5", 1, t, 55, 1, t + 0.8, (bank: 7, wave: 0.5, cut: 2000, res: 0.5, lfd: 0.7, lft: 2));
	t = t + 1.1;
	play.("LFO tremolo", 1, t, 57, 1, t + 0.8, (bank: 0, wave: 0.9, lfd: 0.8, lft: 3)); t = t + 1.1;
	play.("low note, full sub, slow fall", 1, t, 28, 1, t + 0.3, (bank: 0, wave: 1, sub: 1, f1f: 1.0));
	t = t + 2.0;
	endt = t + 1.0;
	// every voice should be gone by now: a query on each one that is still
	// there succeeds silently, on one that freed itself it fails in the log
	notes.do { |nt| ev.add([endt - 0.5, ['/n_query', nt[0]]]) };
	ev.add([endt, ['/c_set', 0, 0]]);
	// in time order, and in the order written at the same time (a note-off
	// at the note-on's own time must come after it)
	ev = ev.collect { |e, i| [e[0], i, e[1]] }
		.sort { |a, b| (a[0] < b[0]) or: { (a[0] == b[0]) and: { a[1] < b[1] } } }
		.collect { |e| [e[0], e[2]] };
	Score(ev).write(dir ++ "/wt.osc");
	File.use(dir ++ "/notes.txt", "w", { |f|
		notes.do { |nt| f.write("note\t%\t%\t%\t%\n".format(nt[0], nt[1], nt[2], nt[3])) };
		wins.do { |w| f.write(w.join("\t") ++ "\n") };
		f.write("end\t%\n".format(endt));
	});
};

if(mode == "live" and: { bad == 0 }) {
	var s = Server.default, fails = 0;
	var ok = { |what, cond| if(cond) { "   ok   %\n".postf(what) } { fails = fails + 1; "!! FAIL %\n".postf(what) } };
	s.options.numInputBusChannels = 0;
	s.options.numOutputBusChannels = 2;
	s.waitForBoot {
		var ctx, e, nv, total, held, base;
		// the engine's out is a private bus: nothing reaches the speakers
		ctx = (server: s, xg: Group.new(s), out_b: Bus.audio(s, 2), in_b: [Bus.audio(s, 1), Bus.audio(s, 1)]);
		s.queryAllNodes; 0.3.wait;
		e = Engine_VibeComposer.new(ctx);
		e.alloc;
		s.sync;
		ok.("48 wavetable buffers loaded", e.tables.size == 48);
		// the server's own count, not the engine's lists: a voice the
		// engine forgot but the server kept would show here at the end
		1.5.wait;
		base = s.numSynths;
		nv = { |t| e.synVoices[t].size };
		total = { (0..7).sum { |t| nv.(t) } };
		held = { |t| e.synVoices[t].select { |v| v[\gated] } };

		"\n-- poly: ten notes on track 0, eight voices\n".post;
		(60..69).do { |k| e.cmd(\synOn, 0, k, 0.8) };
		0.2.wait;
		ok.("8 voices after 10 notes (got %)".format(nv.(0)), nv.(0) == 8);
		ok.("oldest two stolen: 62..69 left (got %)".format(e.synVoices[0].collect(_[\note]).asArray),
			e.synVoices[0].collect(_[\note]).asArray == (62..69));
		e.cmd(\synSet, 0, \mod, 0.6);   // held notes follow; nothing breaks
		e.cmd(\synOff, 0, 99);            // not sounding: nothing
		ok.("off for a silent note does nothing", held.(0).size == 8);
		(60..69).do { |k| e.cmd(\synOff, 0, k) };
		ok.("all released", held.(0).size == 0);
		1.0.wait;
		ok.("released ASR voices freed (left %)".format(nv.(0)), nv.(0) == 0);

		"\n-- poly: duplicate notes release oldest first\n".post;
		e.cmd(\synOn, 0, 60, 1); 0.05.wait; e.cmd(\synOn, 0, 60, 1);
		e.cmd(\synOff, 0, 60);
		ok.("first 60 released, second still gated",
			(e.synVoices[0][0][\gated] == false) and: { e.synVoices[0][1][\gated] });
		e.cmd(\synOff, 0, 60);
		1.0.wait;
		ok.("both freed", nv.(0) == 0);

		"\n-- mono: held-note stack on track 1\n".post;
		e.cmd(\synMono, 1, 1);
		e.cmd(\synSet, 1, \glide, 0.05);
		e.cmd(\synOn, 1, 60, 1); 0.05.wait;
		e.cmd(\synOn, 1, 64, 1); e.cmd(\synOn, 1, 67, 1);
		0.1.wait;
		ok.("one voice (got %)".format(nv.(1)), nv.(1) == 1);
		ok.("sounding 67", held.(1)[0][\note] == 67);
		e.cmd(\synOff, 1, 67);
		ok.("let go of 67: back to 64", held.(1)[0][\note] == 64);
		e.cmd(\synOff, 1, 50);
		ok.("off for an unheld note does nothing", held.(1).size == 1 and: { held.(1)[0][\note] == 64 });
		e.cmd(\synOff, 1, 60);
		ok.("let go of 60 (not sounding): still 64", held.(1)[0][\note] == 64);
		e.cmd(\synOn, 1, 70, 1);
		ok.("legato to 70, same voice", nv.(1) == 1 and: { held.(1)[0][\note] == 70 });
		e.cmd(\synOff, 1, 70);
		ok.("let go of 70: back to 64", held.(1)[0][\note] == 64);
		e.cmd(\synOff, 1, 64);
		ok.("stack empty: gated off", held.(1).size == 0);
		e.cmd(\synOn, 1, 72, 1);
		0.05.wait;
		ok.("new note while the old rings out: one voice (got %)".format(nv.(1)), nv.(1) == 1);
		e.cmd(\synOff, 1, 72);
		1.0.wait;
		ok.("mono voice freed (left %)".format(nv.(1)), nv.(1) == 0);
		e.cmd(\synMono, 1, 0);

		"\n-- AD ignores the gate and frees itself\n".post;
		e.cmd(\synSet, 2, \f1m, 0); e.cmd(\synSet, 2, \f1f, 0.2);
		e.cmd(\synOn, 2, 60, 1);
		0.6.wait;
		ok.("AD voice freed with no note-off (left %)".format(nv.(2)), nv.(2) == 0);

		"\n-- CYCLE holds while gated, finishes on release\n".post;
		e.cmd(\synSet, 3, \f1m, 2); e.cmd(\synSet, 3, \f1r, 0.05); e.cmd(\synSet, 3, \f1f, 0.1);
		e.cmd(\synOn, 3, 60, 1);
		0.8.wait;
		ok.("still cycling after 0.8 s", nv.(3) == 1);
		e.cmd(\synOff, 3, 60);
		0.5.wait;
		ok.("freed after release (left %)".format(nv.(3)), nv.(3) == 0);

		"\n-- LFO, strip, spring wake\n".post;
		e.cmd(\synLfo, 4, \rate, 3); e.cmd(\synLfo, 4, \shape, 5);
		e.cmd(\synStrip, 4, \ssend, 0.5);
		0.1.wait;
		ok.("a synth strip's spring send wakes the spring", e.slotAt(\naps)[e.springS][0]);
		e.cmd(\synStrip, 4, \ssend, 0);
		e.cmd(\synStrip, 4, \level, 0.5);
		e.cmd(\synOn, 4, 60, 1);
		0.15.wait;
		ok.("synmeter5 moves (%)".format(e.polls[\synmeter5].value.round(0.001)), e.polls[\synmeter5].value > 0.001);
		ok.("drum meter1 does not, beyond its hiss (%)".format(e.polls[\meter1].value), e.polls[\meter1].value < 0.001);

		"\n-- synPanic and panic\n".post;
		[5, 6].do { |t| [60, 64, 67].do { |k| e.cmd(\synOn, t, k, 1) } };
		e.cmd(\synPanic, 5);
		ok.("synPanic(5) empties track 5 at once", nv.(5) == 0 and: { nv.(6) == 3 });
		e.cmd(\synPanic, -1);
		0.2.wait;
		ok.("synPanic(-1): nothing left (left %)".format(total.()), total.() == 0);
		[0, 7].do { |t| e.cmd(\synOn, t, 60, 1) };
		e.cmd(\trig, 0, 1, 0, 1, 0);
		e.cmd(\panic);
		0.3.wait;
		ok.("panic takes the synths too (left %)".format(total.()), total.() == 0);
		1.5.wait;
		ok.("server synth count back to where it started (% vs %)".format(s.numSynths, base), s.numSynths == base);

		e.free;
		0.3.wait;
		s.queryAllNodes;
		0.3.wait;
		"\n== live failures: %\n".postf(fails);
		s.quit;
		0.5.wait;
		if(fails > 0) { 1.exit } { 0.exit };
	};
} {
	"\n== errors: %\n".postf(bad);
	if(bad > 0) { 1.exit } { 0.exit };
};
RUN

# the engine caches its defs under ~/dust: keep that in the scratch dir
HOME="$WORK" "$SC" -l "$WORK/conf.yaml" "$WORK/run.scd" "$WORK" "${MODE#--}" 2>&1 \
  | grep -viE "^\s*(Found |Compiling director|NumPrimitives|Number of|Class tree|compile done|init_OSC|Cleaning|sclang|Requested|compiling class|numentries|[0-9]+ method|method table|Byte Code|compiled [0-9]+ files|localhost :|internal :|\*\*\* Welcome)" \
  | grep -v '^$' | tee "$WORK/sclang.log"
if grep -qE "^!! |ERROR|FAILURE IN SERVER" "$WORK/sclang.log"; then echo "FAILED"; exit 1; fi

if [ "$MODE" = "--render" ]; then
  OUT="$WORK/wt.wav"
  ok=1
  "$SCSYNTH" -N "$WORK/wt.osc" _ "$OUT" 48000 WAV float -o 3 > "$WORK/wt.log" 2>&1 || ok=0
  # scsynth on macOS can crash tearing NRT down after the file is written,
  # so a crash only counts if it left no audio behind
  if [ $ok = 0 ] && [ ! -s "$OUT" ]; then echo "render failed"; tail -20 "$WORK/wt.log"; exit 1; fi
  if grep -iE "exceed|error|fail" "$WORK/wt.log" | grep -v "not found"; then echo "render log has errors"; exit 1; fi
  if [ -n "${VC_KEEP:-}" ]; then cp "$OUT" "$VC_KEEP"; echo "kept $VC_KEEP"; fi
  # voices that freed themselves: the end-of-score set fails on them
  grep -oE "/n_query Node [0-9]+ not found" "$WORK/wt.log" | awk '{print $3}' | sort -u > "$WORK/freed.txt" || true
  python3 - "$OUT" "$WORK/notes.txt" "$WORK/freed.txt" <<'PY'
import sys, struct, math, cmath
path, notes_path, freed_path = sys.argv[1:4]
raw = open(path, "rb").read()
assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE", "not a WAV"
i, fmt, data = 12, None, None
while i + 8 <= len(raw):
    cid, size = raw[i:i + 4], struct.unpack("<I", raw[i + 4:i + 8])[0]
    body = raw[i + 8:i + 8 + size]
    if cid == b"fmt ":
        tag, ch, sr, _, _, bits = struct.unpack("<HHIIHH", body[:16])
        fmt = (tag, ch, sr, bits)
    elif cid == b"data":
        data = body
    i += 8 + size + (size & 1)
tag, ch, sr, bits = fmt
assert bits == 32, "want 32-bit float, got %d bits" % bits
x = struct.unpack("<%df" % (len(data) // 4), data)
frames = len(x) // ch
L, R, V = x[0::ch], x[1::ch], x[2::ch]
db = lambda v: 20 * math.log10(v) if v > 0 else -999.0
def seg(c, a, b): return c[int(a * sr):int(b * sr)]
def rms(s): return math.sqrt(sum(v * v for v in s) / max(len(s), 1))
def jump(s): return max(abs(s[k] - s[k - 1]) for k in range(1, len(s)))
bad = sum(1 for v in x if math.isnan(v) or math.isinf(v))
fails = []
notes, sweeps, alias, endt = [], [], [], None
for line in open(notes_path):
    w = line.rstrip("\n").split("\t")
    if w[0] == "note": notes.append((w[1], float(w[2]), float(w[3]), w[4]))
    elif w[0] == "sweep": sweeps.append((w[1],) + tuple(float(v) for v in w[2:]))
    elif w[0] == "alias": alias.append((w[1], float(w[2])))
    elif w[0] == "end": endt = float(w[1])
peak = max(max(abs(v) for v in L), max(abs(v) for v in R))
dc = sum(L) / frames
tail = max(abs(v) for v in L[int((endt - 0.9) * sr):])
print("render: %d ch, %.2f s at %d Hz" % (ch, frames / sr, sr))
print("  out L/R  peak %6.1f dBFS   rms %6.1f dBFS   DC %+.5f" % (db(peak), db(rms(L)), dc))
print("  voice    peak %6.1f dBFS (pre-strip)            DC %+.5f" % (db(max(abs(v) for v in V)), sum(V) / frames))
print("  NaN/inf samples: %d   tail (last 0.9 s) peak %6.1f dBFS" % (bad, db(tail)))

print("\n  %-30s %8s %8s %8s %9s" % ("note (pre-strip voice, out L)", "voice pk", "voice rms", "out pk", "DC(win)"))
for nid, a, b, label in notes:
    b = max(b, a + 0.1)
    v, o = seg(V, a, b), seg(L, a, b)
    vp = max(abs(s) for s in v)
    wdc = sum(o) / len(o)
    print("  %-30s %8.1f %9.1f %8.1f %+9.4f" % (label[:30], db(vp), db(rms(seg(V, a + 0.01, min(b, a + 0.3)))),
          db(max(abs(s) for s in o)), wdc))
    if vp < 10 ** (-40 / 20): fails.append("silent: " + label)
    if abs(wdc) > 0.02: fails.append("DC in " + label)

print("\n  WAVE sweeps (C3, 0 -> 1 over 2 s): RMS of the voice in 20 ms windows; jumps are")
print("  the biggest sample-to-sample step, the sweep's against the note held still at 0 and 1")
print("  %-6s %9s %9s %9s %9s %9s %7s" % ("bank", "rms min", "rms max", "swing dB", "jump@0", "jump@1", "sweep/still"))
for b, s0a, s0b, swa, swb, s1a, s1b in sweeps:
    w = int(0.02 * sr)
    sw = seg(V, swa, swb)
    rr = [rms(sw[k:k + w]) for k in range(0, len(sw) - w, w)]
    still = max(jump(seg(V, s0a, s0b)), jump(seg(V, s1a, s1b)))
    js = jump(sw)
    swing = db(max(rr)) - db(min(rr))
    print("  %-6s %9.1f %9.1f %9.2f %9.4f %9.4f %7.2f" % (b, db(min(rr)), db(max(rr)), swing,
          jump(seg(V, s0a, s0b)), jump(seg(V, s1a, s1b)), js / still))
    if swing > 1.5: fails.append("bank %s sweep swings %.2f dB" % (b, swing))
    if js > still * 1.5: fails.append("bank %s sweep jumps %.2fx a still note" % (b, js / still))

# aliasing: a Hann-windowed FFT of 8192 samples; everything more than 4
# bins from a harmonic of C7 is what folded back (or leaked)
def fft(a):
    n = len(a)
    if n == 1: return a
    e, o = fft(a[0::2]), fft(a[1::2])
    t = [cmath.exp(-2j * math.pi * k / n) * o[k] for k in range(n // 2)]
    return [e[k] + t[k] for k in range(n // 2)] + [e[k] - t[k] for k in range(n // 2)]
f0 = 440 * 2 ** ((96 - 69) / 12)
print("\n  C7 (%.0f Hz): energy off the harmonics against the total" % f0)
for label, a in alias:
    s = V[int(a * sr):int(a * sr) + 8192]
    N = len(s)
    P = [abs(v) ** 2 for v in fft([s[k] * (0.5 - 0.5 * math.cos(2 * math.pi * k / N)) for k in range(N)])[:N // 2]]
    harm = set()
    for k in range(1, int(sr / 2 / f0) + 2):
        c0 = round(k * f0 * N / sr)
        harm.update(range(c0 - 4, c0 + 5))
    off = sum(P[i] for i in range(4, N // 2) if i not in harm)
    ratio = 10 * math.log10(max(off, 1e-30) / sum(P))
    print("  %-26s %7.1f dB" % (label, ratio))
    if "own" in label and ratio > -40: fails.append("%s aliases (%.1f dB)" % (label, ratio))

ids = [nid for nid, _, _, _ in notes]
freed = set(open(freed_path).read().split())
alive = [i for i in ids if i not in freed]
print("\n  voices freed themselves: %d of %d%s" % (len(ids) - len(alive), len(ids),
      "" if not alive else "  STILL RUNNING: " + " ".join(alive)))
if bad: fails.append("NaN/inf in the render")
if peak >= 10 ** (-0.5 / 20): fails.append("clipping: peak %.1f dBFS" % db(peak))
if peak < 10 ** (-40 / 20): fails.append("silent render")
if abs(dc) > 0.002: fails.append("DC %.4f" % dc)
if tail > 10 ** (-90 / 20): fails.append("tail not silent: %.1f dBFS" % db(tail))
if alive: fails.append("voices not freed: " + " ".join(alive))
for f in fails: print("!! " + f)
print("== render %s" % ("FAILED" if fails else "ok"))
sys.exit(1 if fails else 0)
PY
fi
