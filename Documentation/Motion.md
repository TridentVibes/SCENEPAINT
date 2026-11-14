# ScenePaint Motion (0.2 development)

Motion applies editable effect stacks to artwork layers, selected strokes, or synchronized stroke groups. Photograph content is excluded. Optional Codable fields preserve loading of older projects; animation edits participate in the existing document undo history.

## Workflow

1. Select a paint or text layer and open **Motion** in the inspector (or use **Animate selected artwork**).
2. Choose **Layer** to treat the drawing as one animation object. For partial drawings, check strokes in **Strokes**, or create/assign a **Group**.
3. Add Line Boil, Blink / Flash, Glitch, or Emission / Spill. Each effect has an enable switch, seed, settings, reorder, duplicate, and remove controls.
4. Play, pause, restart, or scrub the playhead. Loop duration and output FPS are separate from line-boil redraw rate. Timing is fitted to complete cycles at the loop boundary.
5. Use **Bake Current Frame** for a still composite at the playhead. The originals and animation remain retained; **Unfreeze** restores them. Ordinary **Freeze Visible** freezes contiguous static runs while preserving animation and layer order.
6. Export GIF or MP4 from Motion's **Bake & export** controls or the File menu. Files are staged beside the destination and installed only on successful completion. Cancellation preserves an existing export.

## Object processing and responsiveness

- The stroke records remain editable. Contiguous strokes with identical effect stacks are combined into one prepared animation object. A layer containing hundreds of strokes with one layer effect does not create hundreds of playback jobs.
- Object geometry variations and glow/spill images use a bounded 96 MiB cache. Cache entries can be evicted and regenerated.
- Static layer runs are composited once per prepared scene. Their photograph/lighting appearance is reused between frames.
- Geometry, effect processing, blur, and frame encoding execute outside the main actor. A bounded native document-snapshot step remains on the main actor so the existing renderer and caches can be reused safely.
- Only one preview frame is in flight. A slow frame reduces the following preview cadence rather than creating a queue. Time advancement is independent of dropped frames.
- Playback does not modify the painting or publish the whole document on each tick. It invalidates the native canvas directly. Drawing pauses playback; analysis, pending strokes, navigation, and export suspend live animation work.
- Export uses the same timestamp-based evaluator and retains a fixed prepared scene. Output resolution can exceed preview resolution. GIF palettes and H.264 compression can introduce differences from preview pixels.

## Surface behavior

Mesh strokes use copies of their original anchors and tangent directions. Line-boil offsets are based on a shared spatial field, so adjoining strokes in one object do not receive unrelated random warps. Existing mesh projection, depth visibility, saved surface masks, photo-material shading, and light-field gains are reused. No AI analysis runs on playback ticks.

For faces or uncertain inferred geometry, Wrap Brush offers **Preserve drawn shape** (keeps the captured gesture and applies photo shading/masking without mesh bending) and **Reuse this layer's surface target** (reuses the initial layer target instead of selecting anew for every gesture). These options affect new strokes and do not rewrite existing artwork.

Raster-backed bucket fills use conservative masked jitter. Text uses masked raster variations after its existing projection. Glitches remain within the original artwork footprint. Spill can use the stroke surface mask or a saved copy of the current manually refined surface mask. Spill is an artistic compositing approximation, not global illumination.

## Files

New source files: MotionModel.swift, MotionEditor.swift, MotionRenderer.swift, MotionInspector.swift, MotionExport.swift.

Integration: Document.swift, App.swift, Canvas.swift, InspectorViews.swift, FreezeLayers.swift, BrushTopography.swift, LayerRenderCache.swift.

Checks: motion-checks.command, MotionChecks.swift, MotionSurfaceChecks.swift; existing FreezeLayerChecks are included.

## Limits

- Groups synchronize strokes; they do not introduce a general nested layer-group hierarchy or a full animation timeline.
- Imported photographs cannot be assigned motion directly. Text and paint strokes are eligible; raster bucket fills support appearance effects and masked jitter.
- Boil on projected text and raster fills does not reconstruct vector geometry. Uncertain original photo geometry remains uncertain; Preserve drawn shape is the alternative for new strokes.
- MP4 contains one cycle. Repetition is controlled by the consuming player. GIF stores loop metadata.
- Output is bounded to 2048 pixels on the longest edge, 30 FPS, and 30 seconds by the model (the UI currently offers up to 12 seconds). There is no guarantee of sustained full frame rate on arbitrary projects or hardware.
- Transparent artwork-only export is not exposed. Still PNG export remains the existing static export; use Bake first for an animated frame.

