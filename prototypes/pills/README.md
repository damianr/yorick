# Pills design playground

Open `index.html` in a browser. A faithful HTML/CSS/WebGL recreation of the HUD
pills for fast design iteration — every tunable value is a slider, and
**Copy Swift values** emits the constants mapped back to their homes in
`HUDContentView.swift`, `AudioCapture.swift`, and `SkullGazeView.swift`.

What it mirrors 1:1:

- **Session pill** — recording ↔ summarizing as states within one pill;
  unanchored (observing) vs. field-anchored variants; pointer / pointerBelow
  corners; hover-revealed stop button.
- **Dot equalizer** — exact profile + shimmer math, bone tint.
- **Bone accent** — rim gradient + halo that breathes with the live level.
- **Level pipeline** — RMS → dB → floor/ceiling → asymmetric EMA → gate, with a
  raw-vs-smoothed scope. Sources: simulated speech, real microphone, manual.
- **3D gaze skull** — the real `skull.usdz`, decimated, rendered in raw WebGL
  with the `SkullGazeView.Coordinator.tick` math (reach / clamps / smoothing all
  tunable).
- **Receipt, capture card, notice** pills, spring motion via CSS `linear()`
  easing, backgrounds for shadow testing, zoom to 4×.

## skull-data.js (gitignored)

The gaze skull's mesh payload is derived from the private sculpt at
`~/Library/Application Support/Yorick/skull.usdz`, which is deliberately kept
out of the repo — so its derivative stays out too. Regenerate locally:

```sh
cd tools
swift usdz2obj.swift ~/Library/"Application Support"/Yorick/skull.usdz /tmp/skull.obj
python3 decimate.py /tmp/skull.obj ../skull-data.js 120   # grid res 120 ≈ lossless at pill size
```

Without the file, the playground falls back to the flat mark (leaning toward
the pointer), same as the app without the model.
