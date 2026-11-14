# Model files are downloaded separately

The source archive contains no model weights. `Tools/setup-models.command` downloads pinned public revisions from `Tools/models.lock.json` and compiles the Core ML packages through the native framework. Review the upstream license before redistribution.

- **Depth Anything V2 Small F16** — Apache-2.0. [Apple Core ML conversion](https://huggingface.co/apple/coreml-depth-anything-v2-small), [original project](https://github.com/DepthAnything/Depth-Anything-V2).
- **SAM 2.1 BasePlus F16** — Apache-2.0. [Apple conversion](https://huggingface.co/apple/coreml-sam2.1-baseplus), [Meta SAM 2 license](https://github.com/facebookresearch/sam2/blob/main/LICENSE). Used for new photo features and selections.
- **SAM 2.1 Tiny prompt/mask decoders** — Apache-2.0. [Apple conversion](https://huggingface.co/apple/coreml-sam2.1-tiny). Retained to decode old project feature archives; new analysis uses BasePlus.
- **MoGe-2 Base normal ONNX** — the [base model](https://huggingface.co/Ruicheng/moge-2-vitb-normal) is listed as MIT. [Author's ONNX conversion](https://huggingface.co/Ruicheng/moge-2-vitb-normal-onnx), [upstream code/notices](https://github.com/microsoft/MoGe). Preserve `Geometry/MoGe-LICENSE.txt` and `Geometry/NOTICE.md`.

The application uses native Core ML and ONNX Runtime's CPU provider. The binary release includes the weights and runtime; this source distribution provides reproducible download/setup instructions. Do not commit downloaded weights or Hugging Face caches/tokens to the repository.
