# ScenePaint 0.2 third-party components

Depth Anything V2 Small, Core ML conversion by Apple: Apache-2.0.
https://huggingface.co/apple/coreml-depth-anything-v2-small
https://github.com/DepthAnything/Depth-Anything-V2

SAM 2.1 BasePlus and Tiny (legacy project caches), Core ML conversion by Apple: Apache-2.0.
https://huggingface.co/apple/coreml-sam2.1-baseplus
https://huggingface.co/apple/coreml-sam2.1-tiny
https://github.com/facebookresearch/sam2/blob/main/LICENSE

MoGe-2 Base / ViT-B normal model by Ruicheng Wang and Microsoft Research.
Base weights are listed as MIT; the ONNX file is the author's conversion.
https://huggingface.co/Ruicheng/moge-2-vitb-normal
https://huggingface.co/Ruicheng/moge-2-vitb-normal-onnx
https://github.com/microsoft/MoGe
See MoGe-LICENSE.txt, which also preserves Apache notices for incorporated code.

Python 3.12: Python Software Foundation license (plus bundled component notices).
NumPy, SciPy, ONNX Runtime, Pillow, pillow-heif and their dependencies retain
license files and distribution metadata inside the bundled runtime's site-packages.
Native library license copies are included in this folder where applicable.
The runtime is relocated for this distribution; it does not need Homebrew or a
separately installed Python. Models were converted to Core ML or ONNX by their
respective distributors. Any optional demo/branding is supplied by the distributor; the source archive contains no creator project or photograph.
