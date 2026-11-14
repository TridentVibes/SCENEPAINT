# Third-party notices

ScenePaint's MIT license covers its original code, not all components used by it.

The geometry code includes methods adapted from Microsoft MoGe; preserve Geometry/MoGe-LICENSE.txt and Geometry/NOTICE.md. Model repositories, license identifiers and pinned revisions are documented in Models/README.md and Tools/models.lock.json. Apache-2.0 text is included in Packaging/Apache-2.0.txt.

Python is distributed under its Python Software Foundation license and bundled component licenses. NumPy, SciPy, ONNX Runtime, Pillow, pillow-heif and other dependencies keep their own license/attribution files. Packaging includes those files and additional runtime notices; don't remove them when redistributing a binary app.

The pinned standalone interpreter comes from [Astral python-build-standalone](https://github.com/astral-sh/python-build-standalone). Its URL and SHA256 are in Packaging/PythonStandalone/PROVENANCE.json. Interpreter/component notices are under Packaging and Packaging/RuntimeLicenses. These notices do not relicense any component under the app's MIT license.

Apple system frameworks and SDKs are not redistributed in the source archive; use an appropriately licensed Apple toolchain on macOS.
