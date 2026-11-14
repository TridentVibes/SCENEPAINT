> This changelog describes the public creator binary release. The MIT source archive omits its demo artwork and branding; source builds can provide their own optional assets.

# ScenePaint v0.2 — update breakdown

## What's new in v0.2

- **ScenePaint Motion:** line boil with redrawn and jitter modes, blink/flash, irregular flicker, repeating sequences, segmented glitch, RGB offsets, emission, glow, and linked light spill.
- **Animate a whole drawing:** artwork layers and synchronized stroke groups share effects. Your original strokes remain editable underneath.
- **Performance controls:** cached animation variations, bounded preview caches, adjustable preview size, and adaptive playback. Drawing pauses playback to prioritize your brush.
- **Freeze and restore:** freeze static artwork for smoother editing. Bake Current Frame temporarily turns a Motion composition into a still. Unfreeze or **Unfreeze All** restores retained originals, including strokes, surface data, and Motion settings.
- **Surface-aware painting:** Wrap Brush, inside/outside surface controls, mesh overlay guides, and options to preserve your drawn shape or reuse a layer's surface target.
- **Photo shading:** paint and bucket fills can retain the photograph's shadows and object detail. Albedo, Shading, and Light controls support further adjustments.
- **Drawing tools:** smoother brush paths, straight lines, curve assist, and hollow or filled basic shapes.
- **Smart bucket fill, layer fixes, drag-and-drop import, and local model upgrades:** SAM 2.1 BasePlus selection and MoGe-2 Base geometry are included alongside the depth model.
- **Portable `.scenepaint` projects:** save your layers, original artwork, referenced images, analysis, and Motion settings together.
- **Export:** PNG stills, animated GIF, and MP4 using the system H.264 encoder. PNG and GIF can retain an empty transparent background; the current MP4 export fills empty areas with black. GIF has a limited palette and on/off transparency.

## Release setup

- The current pumpkin artwork is included as a clean vector-only demo. It opens paused in Motion, ready for Play.
- No private photographs, unrelated projects, development logs, settings, credentials, or account identifiers are included. Third-party authorship and license notices are preserved.
- The app is self-contained for local inference, uses per-user Application Support for working files, and keeps its bundled example read-only.
- Saves use `.scenepaint`.
- A startup redraw feedback loop was corrected so idle Motion does not continually republish state.
