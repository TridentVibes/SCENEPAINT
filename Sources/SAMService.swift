import AppKit
import CoreML

struct SegmentPoint: Codable, Equatable { var x: Double; var y: Double; var label: Int32 }
struct SAMTensor: Codable {
    var shape: [Int]
    var type: Int
    var bytes: Data
    init(_ array: MLMultiArray) throws {
        shape = array.shape.map(\.intValue); type = array.dataType.rawValue
        let size = array.dataType == .float16 ? 2 : array.dataType == .double ? 8 : 4
        var stride = 1
        for i in shape.indices.reversed() {
            guard array.strides[i].intValue == stride else { throw SceneError.message("Unexpected image-feature layout.") }
            stride *= shape[i]
        }
        bytes = Data(bytes: array.dataPointer, count: array.count * size)
    }
    func array() throws -> MLMultiArray {
        guard !shape.isEmpty, shape.count <= 5, shape.allSatisfy({ $0 > 0 && $0 <= 4096 }), shape.reduce(1, *) <= 8_000_000,
              let kind = MLMultiArrayDataType(rawValue: type) else { throw SceneError.message("Invalid cached image features.") }
        let size = kind == .float16 ? 2 : kind == .double ? 8 : 4
        guard bytes.count == shape.reduce(1, *) * size else { throw SceneError.message("Incomplete cached image features.") }
        let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: kind)
        bytes.withUnsafeBytes { raw in if let pointer = raw.baseAddress { array.dataPointer.copyMemory(from: pointer, byteCount: bytes.count) } }
        return array
    }
}
struct SAMArchive: Codable { var version = 1; var model: String? = nil; var tensors: [String: SAMTensor] }
struct SAMSelection { var mask: [UInt8]; var score: Float; var elapsed: Double }

// Serial model work. Keep one photo's features in memory and persist every photo's
// features on the external drive. The large image encoder is released after prepare.
actor SAMService {
    static let shared = SAMService()
    let computeUnits: MLComputeUnits
    private var featureKey: String?
    private var featureModel = "Tiny"
    let preparationModel: String
    private var features: [String: MLMultiArray] = [:]
    private var promptModel: MLModel?
    private var decoderModel: MLModel?
    init(computeUnits: MLComputeUnits = .cpuOnly, preparationModel: String = "BasePlus") { self.computeUnits = computeUnits; self.preparationModel = preparationModel }
    static func encoderURL(root: URL) -> URL { ScenePaintPaths.resources(for: root).appendingPathComponent("Models/SAM2BasePlus/SAM2_1BasePlusImageEncoderFLOAT16.mlmodelc") }
    private func model(_ part: String, root: URL, variant: String? = nil) throws -> MLModel {
        let config = MLModelConfiguration(); config.computeUnits = computeUnits
        let variant = variant ?? featureModel
        let folder = variant == "Tiny" ? "SAM2" : "SAM2BasePlus"
        return try MLModel(contentsOf: ScenePaintPaths.resources(for:root).appendingPathComponent("Models/" + folder + "/SAM2_1" + variant + part + "FLOAT16.mlmodelc"), configuration: config)
    }
    private func inputBuffer(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let code = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw SceneError.message("SAM image allocation failed (\(code)).") }
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw SceneError.message("Cannot prepare SAM image.") }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
    func prepare(imageURL: URL, root: URL, destination: URL, cancelled: AnalysisCancellation) throws {
        guard !cancelled.cancelled else { throw CancellationError() }
        RuntimeLog.write(root: root, "SAM prepare: start")
        let output: [String: MLMultiArray] = try autoreleasepool {
            let image = try SceneWorker.thumbnail(imageURL)
            let encoder = try model("ImageEncoder", root: root, variant: preparationModel)
            RuntimeLog.write(root: root, "SAM encoder loaded")
            guard let desc = encoder.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }), let shape = desc.value.imageConstraint else { throw SceneError.message("Unexpected SAM image input.") }
            let buffer = try inputBuffer(image, width: shape.pixelsWide, height: shape.pixelsHigh)
            let result = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [desc.key: MLFeatureValue(pixelBuffer: buffer)]))
            RuntimeLog.write(root: root, "SAM image prediction finished")
            var output: [String: MLMultiArray] = [:]
            for name in result.featureNames { if let array = result.featureValue(for: name)?.multiArrayValue { output[name] = array } }
            guard output["image_embedding"] != nil, output["feats_s0"] != nil, output["feats_s1"] != nil else { throw SceneError.message("SAM image encoder did not return usable features.") }
            return output
        }
        guard !cancelled.cancelled else { throw CancellationError() }
        let archive = SAMArchive(model: preparationModel, tensors: try output.mapValues { try SAMTensor($0) })
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try ExternalFiles.write(encoder.encode(archive), to: destination)
        setFeatureModel(preparationModel)
        features = output; featureKey = destination.path
        RuntimeLog.write(root: root, "SAM features saved")
    }
    private func setFeatureModel(_ model: String) {
        if featureModel != model { promptModel = nil; decoderModel = nil; featureModel = model }
    }
    private func loadFeatures(_ url: URL) throws {
        if featureKey == url.path && !features.isEmpty { return }
        let archive = try PropertyListDecoder().decode(SAMArchive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw SceneError.message("Unsupported image-feature cache. Analyze the photo again.") }
        let model = archive.model ?? "Tiny"
        guard ["Tiny", "BasePlus"].contains(model) else { throw SceneError.message("Unsupported selection model. Analyze the photo again.") }
        let decoded = try archive.tensors.mapValues { try $0.array() }
        setFeatureModel(model)
        features = decoded; featureKey = url.path
    }
    private func values(_ array: MLMultiArray) -> [Float] {
        // Respect strides: Core ML can return non-contiguous tensors.
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        var output = [Float](repeating: 0, count: array.count)
        for flat in 0..<array.count {
            var index = flat, offset = 0
            for dimension in shape.indices.reversed() { offset += (index % shape[dimension]) * strides[dimension]; index /= shape[dimension] }
            switch array.dataType {
            case .float16: output[flat] = Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
            case .float32: output[flat] = array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
            default: output[flat] = array[offset].floatValue
            }
        }
        return output
    }
    func warmUp(root:URL,featuresURL:URL)throws{
        try loadFeatures(featuresURL)
        if promptModel == nil { promptModel = try model("PromptEncoder",root:root) }
        if decoderModel == nil { decoderModel = try model("MaskDecoder",root:root) }
    }
    func select(root: URL, featuresURL: URL, points: [SegmentPoint], width: Int, height: Int, choice: Int = 0) throws -> SAMSelection {
        let start = Date()
        guard !points.isEmpty, points.count <= 64, width > 0, height > 0, width <= 1024, height <= 1024 else { throw SceneError.message("Select a point inside the photo.") }
        try loadFeatures(featuresURL)
        if promptModel == nil { promptModel = try model("PromptEncoder", root: root) }
        if decoderModel == nil { decoderModel = try model("MaskDecoder", root: root) }
        let coords = try MLMultiArray(shape: [1, NSNumber(value: points.count), 2], dataType: promptModel!.modelDescription.inputDescriptionsByName["points"]!.multiArrayConstraint!.dataType)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: points.count)], dataType: promptModel!.modelDescription.inputDescriptionsByName["labels"]!.multiArrayConstraint!.dataType)
        for (i, point) in points.enumerated() {
            coords[[0, NSNumber(value: i), 0]] = NSNumber(value: point.x * 1024)
            coords[[0, NSNumber(value: i), 1]] = NSNumber(value: point.y * 1024)
            labels[[0, NSNumber(value: i)]] = NSNumber(value: point.label)
        }
        let prompt = try promptModel!.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": MLFeatureValue(multiArray: coords), "labels": MLFeatureValue(multiArray: labels)]))
        guard let sparse = prompt.featureValue(for: "sparse_embeddings")?.multiArrayValue,
              let dense = prompt.featureValue(for: "dense_embeddings")?.multiArrayValue else { throw SceneError.message("SAM prompt encoder returned no selection.") }
        var inputs = features.mapValues { MLFeatureValue(multiArray: $0) }
        inputs["sparse_embedding"] = MLFeatureValue(multiArray: sparse); inputs["dense_embedding"] = MLFeatureValue(multiArray: dense)
        let result = try decoderModel!.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let masks = result.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = result.featureValue(for: "scores")?.multiArrayValue, masks.shape.count == 4 else { throw SceneError.message("SAM returned no mask candidates.") }
        let logits = values(masks), quality = values(scores)
        let mh = masks.shape[2].intValue, mw = masks.shape[3].intValue, candidates = masks.shape[1].intValue
        guard mh > 1, mw > 1, candidates > 0, quality.count >= candidates, logits.allSatisfy(\.isFinite) else { throw SceneError.message("SAM returned invalid masks.") }
        func at(_ x: Double, _ y: Double, candidate: Int) -> Float {
            let fx = max(0, min(Double(mw - 1), x)), fy = max(0, min(Double(mh - 1), y))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(mw - 1, x0 + 1), y1 = min(mh - 1, y0 + 1)
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0)), offset = candidate * mw * mh
            let top = logits[offset + y0 * mw + x0] * (1-tx) + logits[offset + y0 * mw + x1] * tx
            let bottom = logits[offset + y1 * mw + x0] * (1-tx) + logits[offset + y1 * mw + x1] * tx
            return top * (1-ty) + bottom * ty
        }
        let valid = (0..<candidates).filter { candidate in
            points.allSatisfy { point in
                let value = at(point.x * Double(mw), point.y * Double(mh), candidate: candidate)
                return point.label == 1 ? value > 0 : value < 0
            }
        }
        guard !valid.isEmpty else { throw SceneError.message("No mask satisfied those points. Try a clearer point, or fewer refinement points.") }
        let best: Int
        if choice == 1 || choice == 2 {
            let sorted = valid.sorted { a, b in
                let areaA = logits[(a * mw * mh)..<((a+1) * mw * mh)].filter { $0 > 0 }.count
                let areaB = logits[(b * mw * mh)..<((b+1) * mw * mh)].filter { $0 > 0 }.count
                return areaA < areaB
            }
            best = choice == 1 ? sorted.first! : sorted.last!
        } else { best = valid.max(by: { quality[$0] < quality[$1] })! }
        var mask = [UInt8](repeating: 0, count: width * height)
        let dx = Double(mw) / Double(width), dy = Double(mh) / Double(height)
        for y in 0..<height { for x in 0..<width {
            let px = (Double(x)+0.5) * dx - 0.5, py = (Double(y)+0.5) * dy - 0.5
            let value = at(px, py, candidate: best)
            let gx = at(px+dx/2, py, candidate: best) - at(px-dx/2, py, candidate: best)
            let gy = at(px, py+dy/2, candidate: best) - at(px, py-dy/2, candidate: best)
            let alpha = max(0, min(1, 0.5 + value / max(0.1, hypot(gx, gy))))
            mask[y * width + x] = UInt8(clamping: Int(alpha * 255))
        } }
        guard mask.contains(where: { $0 > 128 }) else { throw SceneError.message("SAM selected an empty area. Try another point.") }
        return SAMSelection(mask: SAMMaskCleanup.apply(mask, width: width, height: height, points: points), score: quality[best], elapsed: Date().timeIntervalSince(start))
    }
}
