# ScenePaint v0.2 — source release

A native macOS editor for painting onto photographs and animating your own artwork with line boil, blink, glitch, and composited emission/light spill. Original application code and build scripts are MIT-licensed. Model weights and dependencies retain their own licenses.

## Build the editor

Requires an Apple Silicon Mac, macOS 14+, and Xcode or Apple's Command Line Tools.

```sh
zsh build.command
open Build/ScenePaint.app
```

The editor builds without Python or model weights. Drawing, layers, text, Motion, project saving, and export are available immediately. Photo analysis and geometry need the optional local model/runtime setup below. A source build begins with a blank project; the public binary release's creator artwork and icon are not part of this code archive.

The build uses the selected Xcode toolchain. If you have multiple installations, set `DEVELOPER_DIR` to a matching toolchain/SDK pair. The code was validated with Apple's Swift 6.3 compiler in its default language mode. The build is optimized for arm64 and ad-hoc signed, not Apple-notarized.

## Optional local analysis setup

Install Python 3.12 and the official Hugging Face `hf` CLI. Then run:

```sh
zsh Tools/setup-runtime.command
zsh Tools/setup-models.command
```

Set `SCENEPAINT_PYTHON` if Python 3.12 is not on your PATH. The runtime script creates a project-local virtual environment and installs `Geometry/requirements.lock`. The model script uses `Tools/models.lock.json` to download the same pinned model revisions used for v0.2, verifies the MoGe ONNX checksum, and compiles the Core ML packages using Apple's Core ML framework (no separate `coremlcompiler` command is required).

Initial setup needs internet access and substantial disk space. Normal inference then runs locally; no paid API, cloud inference service, or API key is required. The binary download already includes its models and relocated runtime and does not require these setup steps.

Model download sources and licenses: [Models/README.md](Models/README.md). [Official hf installation instructions](https://huggingface.co/docs/huggingface_hub/guides/cli).

## Run checks

```sh
zsh Tools/check.command all
# Or choose startup, motion, queue, material, package or drawing.
```

Swift checks use synthetic fixtures and require no model downloads or private photos. They write generated data under Temporary, Build, and Cache, all excluded from version control. Some graphics/video checks need normal macOS UI/encoder services. An unavailable H.264 encoder is reported as untested, not passed.

Optional geometry checks, after setting up the Python dependencies:

```sh
Runtime/Geometry/bin/python Checks/completion-checks.py
Runtime/Geometry/bin/python Checks/fusion-checks.py
```

## Find the code

- `Sources/App.swift`, `Canvas.swift`, `Document.swift`: SwiftUI interface, native canvas, document state, tools, and undo/redo.
- `Sources/Motion*.swift`: deterministic effect metadata, cached object rendering, inspector, playback, baking and GIF/MP4 export.
- `Sources/FreezeLayers.swift`: retained originals, frozen snapshots, nested restoration and Unfreeze All.
- `Sources/Surface*.swift`, `MeshPainting.swift`, `DepthEdges.swift`: projection, masks, mesh transport and depth visibility.
- `Sources/SurfacePaint.swift`, `MaterialWorkflow.swift`, `Relighting.swift`: photo shading/texture transfer and editable material/light compositing.
- `Sources/ProjectPackage.swift`: portable `.scenepaint` packages and referenced asset copying.
- `Sources/SAMService.swift`, `SceneAnalysis.swift`, `Geometry/`: local selection, depth and geometry inference.

[Motion architecture and limits](Documentation/Motion.md). [Geometry completion](Geometry/COMPLETION.md).

## Package a self-contained app

For redistribution, first set up models and the development runtime, then fetch the pinned standalone Python runtime:

```sh
python3.12 Tools/get-standalone.py
SCENEPAINT_RELEASE=1 zsh build.command
python3 Packaging/package.py
```

The packager relocates runtime libraries, includes dependency notices, checks minimum OS versions, and signs the assembled app. It requires Python 3.12, Apple's build tools, and the files produced by setup. The standalone download is checksum-verified. The resulting folder is under Releases. Notarization and public hosting are separate steps.

Optional: supply your own `Branding/ScenePaint.icns` and `Packaging/PublicDemo/Pumpkin Motion.scenepaint`. With a demo, the app starts paused on Motion; without one it starts blank. Any artwork, fonts or branding you add must be yours to redistribute. Do not add credentials, caches or personal projects to your repository.

## Contributing and licensing

Keep working brush, bucket, surface masking and static-image rendering intact when changing Motion. Add a regression check for behavior changes. Use an immutable timestamp-based evaluation for effects and preserve original stroke data.

See [LICENSE](LICENSE), [NOTICE.md](NOTICE.md), and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The MIT code license does not change the separate licenses of models or dependencies. Creator demo artwork and branding are omitted rather than relicensed.
