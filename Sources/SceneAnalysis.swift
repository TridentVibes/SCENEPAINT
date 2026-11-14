import AppKit
import CoreML
import ImageIO

struct SceneFrame: Codable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    func contains(_ p: Dot) -> Bool { p.x >= x && p.y >= y && p.x < x + width && p.y < y + height }
}
struct SceneReference: Codable, Equatable {
    var sourceID: UUID
    var analysisAsset: String
    var maskAsset: String?
    var frame: SceneFrame
    var seed: Dot?
    var samAsset: String? = nil
    var geometryAsset:String? = nil
    var automaticTarget:Bool? = nil
    var occlusionAsset:String? = nil
    var wallConstraintMasks:[String]? = nil
    var completionEnabled:Bool? = nil
    var prompts: [SegmentPoint]? = nil
    var maskScore: Float? = nil
    var outline: [Dot]? = nil
}
struct SurfaceBinding: Codable, Equatable {
    var reference: SceneReference
    var shading: Double
    var conform: Double
}
struct SceneData: Codable {
    var width: Int; var height: Int
    var depth: [Float]          // Relative inverse depth; near is bright, not meters.
    var person: [UInt8]         // Person class from the small local segmentation model.
    var classes: [UInt8]? = nil
    var rgb: [UInt8]            // RGB from the source photo, at analysis resolution.
    var elapsed: Double
    var segmentationAvailable: Bool
    var engine: String? = nil
    var count: Int { width * height }
    func valid() -> Bool {
        width > 0 && height > 0 && width <= 1024 && height <= 1024 && depth.count == count && person.count == count && rgb.count == count * 3 && (classes == nil || classes?.count == count) && depth.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }
    func index(_ point: Dot, frame: SceneFrame) -> Int? {
        guard frame.contains(point) else { return nil }
        let x = min(width - 1, Int((point.x - frame.x) / frame.width * Double(width)))
        let y = min(height - 1, Int((point.y - frame.y) / frame.height * Double(height)))
        return y * width + x
    }
    func rgbaMap(_ plane: Plane) -> [UInt8] {
        if plane == .albedo{return AlbedoEstimate.rgba(self)}
        var out = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            let x = i % width, y = i / width
            if plane == .normals {
                let dx = Double(depth[y * width + min(width - 1, x + 1)] - depth[y * width + max(0, x - 1)]) * 10
                let dy = Double(depth[min(height - 1, y + 1) * width + x] - depth[max(0, y - 1) * width + x]) * 10
                let length = sqrt(dx * dx + dy * dy + 1)
                out[i * 4] = UInt8(clamping: Int(((-dx / length) * 0.5 + 0.5) * 255))
                out[i * 4 + 1] = UInt8(clamping: Int(((dy / length) * 0.5 + 0.5) * 255))
                out[i * 4 + 2] = UInt8(clamping: Int((1 / length * 0.5 + 0.5) * 255))
            } else {
                let value = plane == .depth ? Double(depth[i]) : (0.2126 * Double(rgb[i * 3]) + 0.7152 * Double(rgb[i * 3 + 1]) + 0.0722 * Double(rgb[i * 3 + 2])) / 255
                let byte = UInt8(clamping: Int(value * 255))
                out[i * 4] = byte; out[i * 4 + 1] = byte; out[i * 4 + 2] = byte
            }
        }
        return out
    }
}

enum SceneError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum SceneWorker {
    static func raster(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard rgba.count == width * height * 4, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    static func png(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw SceneError.message("Cannot create map file on the external drive.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SceneError.message("Could not save the map. Check the external drive.") }
    }
    static func thumbnail(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1536] as CFDictionary) else { throw SceneError.message("Could not read the source image.") }
        return image
    }
    static func analyze(imageURL: URL, modelURL: URL, cancelled: () -> Bool) throws -> SceneData {
        let start = Date()
        let image = try thumbnail(imageURL)
        let (inputWidth, inputHeight, predictedDepth): (Int, Int, [Float]) = try autoreleasepool {
            guard !cancelled() else { throw CancellationError() }
            let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            guard let input = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }), let constraint = input.value.imageConstraint else { throw SceneError.message("Unexpected depth model input.") }
            let w = constraint.pixelsWide, h = constraint.pixelsHigh
            guard w > 0, h > 0, w <= 1024, h <= 1024 else { throw SceneError.message("Unsupported analysis size.") }
            var buffer: CVPixelBuffer?
            let allocation = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw SceneError.message("Depth input allocation failed (code \(allocation)).") }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, []); throw SceneError.message("Cannot prepare depth input.")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: MLFeatureValue(pixelBuffer: buffer)]))
            guard !cancelled() else { throw CancellationError() }
            var raw = [Float](repeating: 0, count: w * h)
            if let output = prediction.featureNames.compactMap({ prediction.featureValue(for: $0)?.imageBufferValue }).first {
                CVPixelBufferLockBaseAddress(output, .readOnly); defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
                let ow = CVPixelBufferGetWidth(output), oh = CVPixelBufferGetHeight(output), row = CVPixelBufferGetBytesPerRow(output)
                guard let base = CVPixelBufferGetBaseAddress(output) else { throw SceneError.message("Empty depth image.") }
                let format = CVPixelBufferGetPixelFormatType(output)
                for y in 0..<h { for x in 0..<w {
                    let px = min(ow - 1, x * ow / w), py = min(oh - 1, y * oh / h)
                    let line = base.advanced(by: py * row)
                    switch format {
                    case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32:
                        raw[y * w + x] = line.assumingMemoryBound(to: Float.self)[px]
                    case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16:
                        raw[y * w + x] = Float(Float16(bitPattern: line.assumingMemoryBound(to: UInt16.self)[px]))
                    case kCVPixelFormatType_OneComponent8:
                        raw[y * w + x] = Float(line.assumingMemoryBound(to: UInt8.self)[px])
                    default: throw SceneError.message("Unsupported depth pixel format: \(format)")
                    }
                } }
            } else if let array = prediction.featureNames.compactMap({ prediction.featureValue(for: $0)?.multiArrayValue }).first, array.shape.count >= 2 {
                let shape = array.shape.map { $0.intValue }, stride = array.strides.map { $0.intValue }
                let oh = shape[shape.count - 2], ow = shape[shape.count - 1]
                guard ow > 0, oh > 0 else { throw SceneError.message("Empty depth prediction.") }
                for y in 0..<h { for x in 0..<w {
                    let offset = min(oh - 1, y * oh / h) * stride[stride.count - 2] + min(ow - 1, x * ow / w) * stride[stride.count - 1]
                    raw[y * w + x] = array[offset].floatValue
                } }
            } else { throw SceneError.message("Unexpected depth output.") }
            guard raw.allSatisfy(\.isFinite), let low = raw.min(), let high = raw.max(), high > low else { throw SceneError.message("The depth model returned an invalid or flat map.") }
            return (w, h, raw.map { ($0 - low) / (high - low) })
        }
        guard !cancelled() else { throw CancellationError() }
        let ratio = min(1, 1024.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * ratio)), height = max(1, Int(Double(image.height) * ratio))
        var depth = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let px = Double(x) / Double(max(1, width-1)) * Double(inputWidth-1)
            let py = Double(y) / Double(max(1, height-1)) * Double(inputHeight-1)
            let x0 = Int(px), y0 = Int(py), x1 = min(inputWidth-1,x0+1), y1 = min(inputHeight-1,y0+1)
            let tx = Float(px-Double(x0)), ty = Float(py-Double(y0))
            depth[y*width+x] = (predictedDepth[y0*inputWidth+x0]*(1-tx)+predictedDepth[y0*inputWidth+x1]*tx)*(1-ty) + (predictedDepth[y1*inputWidth+x0]*(1-tx)+predictedDepth[y1*inputWidth+x1]*tx)*ty
        } }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneError.message("Cannot prepare scene pixels.") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) { for c in 0..<3 { rgb[i * 3 + c] = rgba[i * 4 + c] } }
        guard !cancelled() else { throw CancellationError() }
        return SceneData(width: width, height: height, depth: depth, person: [UInt8](repeating: 0, count: width*height), rgb: rgb, elapsed: Date().timeIntervalSince(start), segmentationAvailable: false)
    }
}
