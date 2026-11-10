# wavetables

`vc_wavetables.wav` is the synth tracks' wavetable bank: 8 banks of 32
frames each, with 6 band-limited copies (mipmaps) of each frame. It is built
by `lib/tools/build-wavetables.py` (its docstring describes the layout)
from single-cycle waveforms in **AKWF: Adventure Kid Waveforms** by
Kristoffer Ekstrand, released under CC0 1.0 (public domain):
https://github.com/KristofferKarlAxelEkstrand/AKWF-FREE

| bank | AKWF family |
|---|---|
| BASIC | bw_perfectwaves, bw_blended |
| HARMONIC | sinharm |
| OVERTONE | overtone |
| VOICE | hvoice |
| ORGAN | eorgan |
| FM | fmsynth |
| CHIP | oscchip |
| DIGITAL | bitreduced |

`manifest.json` lists the eight key waveforms behind each bank, dark to
bright. To rebuild it, download those AKWF folders and run:

```
python3 -I lib/tools/build-wavetables.py <AKWF folder> lib/wavetables
```
