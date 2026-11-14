# Geometry completion

`analyze.py` runs the existing local model, then fits bounded geometry using the
photo's depth and independent normal field. No additional model or cloud call.

`object_completion.py` examines connected surface regions throughout each photo.
It fits planes, spheres and cylinders when position and normal agreement support
them. Supported spheres and cylinders gain unseen sides. Irregular patches get
small quadratic tangent extensions only when the fit is stable. Unsupported fits
are omitted. Processing is bounded to the 80 largest eligible regions.

`completion.py` adds wall-volume hypotheses for identified wall faces. Floor
contact estimates direction and support; the better-supported opposing wall can
supply a common height. Visible cap evidence supplies thickness where available;
otherwise thickness is an explicitly recorded proportional prior. Mixed wall
selections can split by normal direction. These estimates supplement the observed
raster rather than tilting or overwriting it.

The per-geometry `.completion.json` stores indexed triangles and fit metadata.
Native `GeometryCompletion.swift` loads separate connected surfaces, bins triangle
candidates spatially, and enables floor-to-wall transitions between independent
triangulations. Existing visibility depth hides covered paint. Generic hypotheses
replace observed hits only within a close depth tolerance; identified wall volumes
can also supply a nearer missing face. Orange geometry in the 3D inspector is
inferred. The Wrap Brush's Infer missing geometry switch applies on rebuild.

Confidence values are heuristics, not calibrated probabilities. A single photo
cannot establish arbitrary hidden topology, physical scale, hollow interiors or
object identity. Disconnected regions can belong to the same object; current
surface grouping does not prove that relationship. Completion supports general
surface types but does not guarantee a complete model of every object.

Checks: `Checks/completion-checks.py` validates partial sphere/cylinder recovery,
plane bounds, irregular rejection and immutable observations. Native
`Checks/CompletionMeshChecks.swift` validates continuous floor → inside wall → cap
→ outside travel, mesh loading and hit-query cost.

## Shared evidence fusion

`fusion.py` checks cached RGB against the EXIF-oriented source photograph before
accepting cached maps. It validates dimensions, inverse-depth values and mask
sizes, resamples all evidence into the model camera coordinates, and creates
boundary constraints shared by normal integration, planar fitting, general
completion, and the native mesh loader (`.spregion`). Color boundaries require
geometric support; a painted stripe or shadow alone does not become a crease.
The editor supplies masks from matching photo/analysis bindings, including masks
used by brush strokes and text. Semantic labels participate only when actually
available, rather than inventing classes from an empty segmentation field.

The neural network contract remains RGB plus token count. Depth, normals and
masks are combined in reconstruction after inference. `.fusion.json` records
actual inputs, their hashes, alignment scores and camera parameters. The albedo
and shading previews remain approximations, not independently measured geometry.
Normals from `.spnormal` also drive the relight field for the source photo and
associated edits; depth gradients provide the fallback. Geometry identity is part
of lighting cache keys, so a rebuild cannot reuse stale lighting.

`Checks/fusion-checks.py` checks alignment, mask boundaries and finite refinement.
`Checks/FusionLightingChecks.swift` checks independent-normal lighting, geometry
cache invalidation and preservation of region boundaries during native loading.

## Surface gesture transport

`SurfaceGesture.swift` unprojects raw cursor positions into the starting surface's
tangent chart, including the full perspective coupling between screen axes.
Wrap Brush version 4 transports differences in these chart coordinates over the
mesh. Earlier saved strokes are retraced from their original cursor points when
rendered; the raw gesture is preserved. Camera-depth-only pixel scaling is no
longer used to steer strokes. This fixes vertical-to-diagonal drift on oblique
planes and provides the distance needed to reach floor/wall junctions.

Text uses the same chart mapping and per-triangle depth clipping. Surface region
limiting is a separate opt-in setting for wrapped text; the original SAM region
no longer clips a cross-surface label by default. Automatic fitting is opt-in,
and geometric chart validity is independent of back-face visibility. Open wall
feet can rejoin a compatible nearby measured floor, with normal and pixel-scale
proximity checks.

`Checks/SurfaceTravelChecks.swift` covers oblique-plane vertical cursor accuracy,
planar text positioning, floor-to-wall brush transport, wall-to-floor text,
wrap around a wall's end, and reprojection of the saved user strokes. The current
mesh can still have incorrect or missing structure; correct gesture transport
cannot establish a physical wall where the reconstruction is unsupported.

## Brush stability (transport version 5)

Near a tangent plane's vanishing line, subtracting two ray/plane intersections
could amplify a tiny cursor movement or reverse the stroke when crossing the
horizon. Gesture differences now use the algebraic projection difference with a
bounded denominator. Reliable-angle behavior remains exact. Version-4 strokes
are retraced from their preserved raw points when rendered.

Live and settled strokes now share the same 24-sector footprint geometry, so
releasing the mouse changes raster resolution rather than the geometric shape.
Footprint vertices crossing the camera's near plane are discarded as degenerate
wedges instead of projected through zero depth into enormous triangles.
`Checks/BrushStabilityChecks.swift` covers horizon crossing, direction, stable
projection, unit/orthogonal transported axes, shared preview/final geometry and
finite footprints in rendering regression fixtures.
