# Pills design playground

Open `index.html` in a browser. A faithful HTML/CSS recreation of the HUD
pills for fast design iteration — every tunable value is a slider, and
**Copy Swift values** emits the constants mapped back to their homes in
`HUDContentView.swift` and `AudioCapture.swift`.

What it mirrors 1:1:

- **Session pill** — recording ↔ transcribing ↔ cleaning-up as states within
  one pill; unanchored (top or bottom center, matching the app's "Saved-note
  position" setting) vs. field-anchored variants; pointer / pointerBelow
  corners; hover-revealed stop button.
- **Dot equalizer** — exact profile + shimmer math, bone tint.
- **Bone accent** — rim gradient + halo that breathes with the live level.
- **Level pipeline** — RMS → dB → floor/ceiling → asymmetric EMA → gate, with a
  raw-vs-smoothed scope. Sources: simulated speech, real microphone, manual.
- **Capture card and notice** pills, spring motion via CSS `linear()` easing,
  backgrounds for shadow testing, zoom to 4×.
