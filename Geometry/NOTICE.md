# Local geometry runtime

MoGe-2 Base normal ONNX model by Ruicheng Wang and Microsoft Research.
Model: https://huggingface.co/Ruicheng/moge-2-vitb-normal-onnx
Model SHA256: bbf14e07a30f11e69d36ab861590123f5598ababcbc8946a063eb4a966f35a21
Source: https://github.com/microsoft/MoGe
Deployment: https://github.com/microsoft/MoGe/blob/main/docs/onnx.md

The focal/shift recovery in analyze.py follows solve_optimal_focal_shift and
normalized_view_plane_uv_numpy in Microsoft's moge/utils/geometry_numpy.py.
Copyright Microsoft Corporation. See MoGe-LICENSE.txt for MIT / Apache notices.
Base model card lists MIT licensing; preserve MoGe-LICENSE.txt when redistributing.

Runtime packages come from PyPI: onnxruntime, numpy, scipy, pillow, pillow-heif.
Inference uses ONNX Runtime's CPU provider, eight intra-op threads, no telemetry.
No image is sent to a server. Python exits after creating the point map.

Mesh format SPGEO001:
8-byte ASCII magic, little-endian UInt32 width/height, Float32 normalized focal
fx/fy, then width*height camera-space XYZ Float32 triplets. A zero Z is invalid.
Image UV: pixel centers, top-left origin. Camera Z is positive forward.
The app triangulates valid samples, drops sharp depth discontinuities, and caches
one or more surfaces under a 48 MB total mesh-cache cost limit.
