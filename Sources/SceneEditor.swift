import AppKit
import SwiftUI

final class AnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
final class SceneBox: NSObject { let data: SceneData; init(_ data: SceneData) { self.data = data } }
final class MaskBox: NSObject { let bytes: [UInt8]; init(_ bytes: [UInt8]) { self.bytes = bytes } }
@MainActor final class SceneCache {
    let scenes = NSCache<NSString, SceneBox>()
    let masks = NSCache<NSString, MaskBox>()
    let strokes = NSCache<NSString, NSImage>()
    var occlusionRequests=Set<UUID>()
    init() { scenes.countLimit = 4; masks.totalCostLimit = 8 * 1024 * 1024; strokes.totalCostLimit = 48 * 1024 * 1024 }
    func clear() { scenes.removeAllObjects(); masks.removeAllObjects(); strokes.removeAllObjects() }
}

@MainActor extension Editor {
    func analysisURL(_ name: String) -> URL? {
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.hasPrefix(".") else { return nil }
        return root.appendingPathComponent("Analysis").appendingPathComponent(name)
    }
    func sceneData(_ reference: SceneReference) -> SceneData? {
        if let box = sceneCache.scenes.object(forKey: reference.analysisAsset as NSString) { return box.data }
        guard let url = analysisURL(reference.analysisAsset), let data = try? Data(contentsOf: url),
              let scene = try? JSONDecoder().decode(SceneData.self, from: data), scene.valid() else { return nil }
        sceneCache.scenes.setObject(SceneBox(scene), forKey: reference.analysisAsset as NSString)
        return scene
    }
    func maskData(_ reference: SceneReference) -> [UInt8]? {
        guard let asset = reference.maskAsset else { return nil }
        if let box = sceneCache.masks.object(forKey: asset as NSString) { return box.bytes }
        guard let url = analysisURL(asset), let data = try? Data(contentsOf: url), let scene = sceneData(reference), data.count == scene.count else { return nil }
        let bytes = [UInt8](data)
        sceneCache.masks.setObject(MaskBox(bytes), forKey: asset as NSString, cost: bytes.count)
        return bytes
    }
    func writeScene(_ scene: SceneData) throws -> String {
        let name = UUID().uuidString + ".scene.json"
        try ExternalFiles.write(JSONEncoder().encode(scene), to: analysisURL(name)!)
        sceneCache.scenes.setObject(SceneBox(scene), forKey: name as NSString)
        return name
    }
    func writeMask(_ mask: [UInt8]) throws -> String {
        let name = UUID().uuidString + ".mask"
        try ExternalFiles.write(Data(mask), to: analysisURL(name)!)
        sceneCache.masks.setObject(MaskBox(mask), forKey: name as NSString, cost: mask.count)
        return name
    }
    func cancelAnalysis() {
        queuedPhotoAnalysis = nil; analysisCancellation?.cancel()
        if analyzing { status = "Cancel requested · Finishing the current model operation…" }
    }
    func analyzePhoto() {
        guard !isPhotoFrozen(activePhotoID) else{status="Unfreeze the snapshot before updating photo analysis.";return}
        let selectedPhoto = activeIndex.flatMap { painting.layers[$0].plane == .artwork && painting.layers[$0].imageAsset != nil ? painting.layers[$0].id : nil }
        guard let id = selectedPhoto ?? activePhotoID ?? painting.layers.last(where: { $0.plane == .artwork && $0.imageAsset != nil && $0.visible })?.id else { status = "Import or select a photo first."; return }
        requestPhotoAnalysis(id)
    }
    func analyzePhoto(sourceID: UUID) {
        guard !analyzing, selectionCount == 0 else { queuedPhotoAnalysis = sourceID; return }
        guard let layer = painting.layers.first(where: { $0.id == sourceID && $0.plane == .artwork }), let asset = layer.imageAsset,
              asset == URL(fileURLWithPath: asset).lastPathComponent else { status = "Select a photo layer to analyze."; return }
        let modelURL = ScenePaintPaths.resources(for:root).appendingPathComponent("Models/DepthAnythingV2SmallF16.mlmodelc")
        guard FileManager.default.fileExists(atPath: modelURL.path),
              FileManager.default.fileExists(atPath: SAMService.encoderURL(root: root).path) else { status = "Local models are missing from the external drive."; return }
        storeActiveScene(); painting.activePhotoID = layer.id
        let imageURL = root.appendingPathComponent("Assets").appendingPathComponent(asset)
        let frame = SceneFrame(x: layer.x, y: layer.y, width: layer.width, height: layer.height)
        let job = UUID(), token = AnalysisCancellation(), revision = sceneRevision, location = root
        let featureName = UUID().uuidString + ".samfeatures"
        let featureURL = analysisURL(featureName)!
        analysisJob = job; analysisCancellation = token; aiStarted=Date();analysisProgress=0.05;analysisStage="Loading depth model";analyzing = true; liveSurface = nil
        status = "Analyzing this photo: depth and precise-mask image features…"
        Task {
            let start = Date()
            RuntimeLog.write(root: location, "Photo analysis: start depth")
            let result: Result<SceneData, Error>
            do {
                var scene = try await Task.detached(priority: .utility) {
                    try SceneWorker.analyze(imageURL: imageURL, modelURL: modelURL, cancelled: { token.cancelled })
                }.value
                analysisProgress=0.4;analysisStage="Depth ready · Encoding precise selections"
                RuntimeLog.write(root: location, "Depth ready; preparing SAM")
                if analysisJob == job && !token.cancelled { status = "Depth ready · Preparing this photo's precise mask cache…" }
                try await SAMService.shared.prepare(imageURL: imageURL, root: location, destination: featureURL, cancelled: token)
                analysisProgress=0.85;analysisStage="Creating depth, normal, albedo and shading maps"
                scene.segmentationAvailable = true; scene.engine = "SAM2.1BasePlus"; scene.elapsed = Date().timeIntervalSince(start)
                result = .success(scene)
            } catch { result = .failure(error) }
            guard analysisJob == job else { return }
            analysisProgress=1;analyzing = false; analysisJob = nil; analysisCancellation = nil
            defer { drainQueuedAnalysis() }
            guard !token.cancelled else { if queuedPhotoAnalysis == nil { status = "Analysis cancelled." }; return }
            guard sceneRevision == revision, activePhotoID == layer.id,
                  let current = painting.layers.first(where: { $0.id == layer.id }), current.imageAsset == asset,
                  SceneFrame(x: current.x, y: current.y, width: current.width, height: current.height) == frame else {
                status = "Photo changed; the previous photo's result was not applied."; return
            }
            switch result {
            case .success(let scene):
                do {
                    let name = try writeScene(scene)
                    let reference = SceneReference(sourceID: layer.id, analysisAsset: name, maskAsset: nil, frame: frame, seed: nil, samAsset: featureName)
                    let maps = try makeMapLayers(scene, reference: reference)
                    checkpoint(); painting.scene = reference
                    painting.layers.removeAll { $0.generatedFor == layer.id }
                    painting.layers.insert(contentsOf: maps, at: 0)
                    RuntimeLog.write(root: location, "Photo analysis applied to matching source")
                    storeActiveScene(); surfaceMode = true; lockSurface = false; showMask = false; tool = .brush
                    if autoGeometry && !hasSurfaceMesh{buildSurfaceMesh()}
                    status = String(format: "This photo is ready in %.1f s · Depth and map tabs updated · SAM selects each surface", scene.elapsed)
                } catch { fail(error) }
            case .failure(let error):
                if error is CancellationError { status = "Analysis cancelled." } else { fail(error) }
            }
        }
    }
    func makeMapLayers(_ scene: SceneData, reference: SceneReference, planes: [Plane] = [.depth, .normals, .albedo, .shading]) throws -> [Layer] {
        var layers: [Layer] = []
        for plane in planes {
            let name = UUID().uuidString + ".png"
            guard let image = SceneWorker.raster(scene.rgbaMap(plane), width: scene.width, height: scene.height) else { throw SceneError.message("Cannot render scene map.") }
            try SceneWorker.png(image, to: root.appendingPathComponent("Assets").appendingPathComponent(name))
            let title = plane == .depth ? "AI depth · near is bright" : plane == .normals ? "Depth-derived normals · approximate" : plane == .albedo ? "Estimated albedo · lighting reduced" : "Photo luminance · shading guide"
            let f = reference.frame
            layers.append(Layer(name: title, plane: plane, x: f.x, y: f.y, width: f.width, height: f.height, imageAsset: name, generatedFor: reference.sourceID))
        }
        return layers
    }
    func sceneAligned(_ reference: SceneReference) -> Bool {
        guard let layer = painting.layers.first(where: { $0.id == reference.sourceID }), layer.visible else { return false }
        return SceneFrame(x: layer.x, y: layer.y, width: layer.width, height: layer.height) == reference.frame
    }
    func refineMask(points: [Dot], adding: Bool) {
        guard !points.isEmpty, var reference = painting.scene, let scene = sceneData(reference), var mask = maskData(reference) else { status = "Choose a surface first."; return }
        let oldMask = reference.maskAsset
        let rx = max(0.6, brushSize * Double(scene.width) / reference.frame.width / 2)
        let ry = max(0.6, brushSize * Double(scene.height) / reference.frame.height / 2)
        func stamp(_ p: Dot) {
            let cx = (p.x - reference.frame.x) / reference.frame.width * Double(scene.width)
            let cy = (p.y - reference.frame.y) / reference.frame.height * Double(scene.height)
            let x0 = max(0, Int(floor(cx - rx))), x1 = min(scene.width - 1, Int(ceil(cx + rx)))
            let y0 = max(0, Int(floor(cy - ry))), y1 = min(scene.height - 1, Int(ceil(cy + ry)))
            guard x0 <= x1, y0 <= y1 else { return }
            for y in y0...y1 { for x in x0...x1 where pow((Double(x) - cx) / rx, 2) + pow((Double(y) - cy) / ry, 2) <= 1 { mask[y * scene.width + x] = adding ? 255 : 0 } }
        }
        if let first = points.first { stamp(first) }
        for i in 1..<max(1, points.count) {
            let a = points[i - 1], b = points[i], steps = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / max(1, brushSize / 4))))
            for step in 1...min(10000, steps) { let t = Double(step) / Double(steps); stamp(Dot(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
        }
        do {
            let name = try writeMask(mask)
            checkpoint(); reference.maskAsset = name; reference.outline = nil; painting.scene = reference
            // Existing paint that uses this selection follows its manual corrections as well.
            for i in painting.layers.indices { for j in painting.layers[i].strokes.indices {
                if painting.layers[i].strokes[j].surface?.reference.maskAsset == oldMask {
                    painting.layers[i].strokes[j].surface?.reference.maskAsset = name
                    painting.layers[i].strokes[j].surface?.reference.outline = nil
                    painting.layers[i].strokes[j].id = UUID()
                }
            } }
            for i in painting.layers.indices where painting.layers[i].surface?.reference.maskAsset == oldMask {
                painting.layers[i].surface?.reference.maskAsset = name
                painting.layers[i].surface?.reference.outline = nil
            }
            lockSurface = true; showMask = true; status = "Surface mask corrected · Existing paint on this surface updated"
        } catch { fail(error) }
    }
    func applyEditedDepth() {
        guard plane == .depth, var reference = painting.scene, var scene = sceneData(reference), let png = pngData(), let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { status = "Analyze a photo first, then edit its Depth map."; return }
        let f = reference.frame
        let crop = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
        guard crop.minX >= 0, crop.minY >= 0, crop.maxX <= painting.width, crop.maxY <= painting.height, let region = image.cropping(to: crop) else { status = "Photo must be fully inside the canvas to apply depth edits."; return }
        var pixels = [UInt8](repeating: 0, count: scene.count * 4)
        pixels.withUnsafeMutableBytes { bytes in
            if let cg = CGContext(data: bytes.baseAddress, width: scene.width, height: scene.height, bitsPerComponent: 8, bytesPerRow: scene.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                cg.draw(region, in: CGRect(x: 0, y: 0, width: scene.width, height: scene.height))
            }
        }
        for i in 0..<scene.count { scene.depth[i] = Float(0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1]) + 0.0722 * Double(pixels[i * 4 + 2])) / 255 }
        do {
            reference.analysisAsset = try writeScene(scene)
            let maps = try makeMapLayers(scene, reference: reference, planes: [.normals])
            checkpoint(); painting.scene = reference
            painting.layers.removeAll { $0.generatedFor == reference.sourceID && $0.plane == .normals }
            painting.layers.insert(contentsOf: maps, at: 0)
            for i in painting.layers.indices { for j in painting.layers[i].strokes.indices {
                if painting.layers[i].strokes[j].surface?.reference.sourceID == reference.sourceID {
                    painting.layers[i].strokes[j].surface?.reference.analysisAsset = reference.analysisAsset
                    painting.layers[i].strokes[j].id = UUID()
                }
            } }
            status = "Edited depth applied · Approximate normals and existing surface paint refreshed"
        } catch { fail(error) }
    }
    func surfaceMaterialKey(_ stroke:Ink)->NSString?{
        guard let binding=stroke.surface else{return nil}
        let pathDependent=stroke.photoShading != true && stroke.topography == nil && binding.reference.outline == nil && binding.reference.geometryAsset != nil
        var pathKey=Hasher()
        if pathDependent{pathKey.combine(stroke.width);for p in stroke.points{pathKey.combine(p.x);pathKey.combine(p.y)}}
        let geometry=pathDependent ? (binding.reference.geometryAsset ?? ""):""
        let seedX=pathDependent ? (binding.reference.seed?.x ?? -1):0,seedY=pathDependent ? (binding.reference.seed?.y ?? -1):0
        return "material-v14|\(stroke.invertSelection == true)|\(binding.reference.occlusionAsset ?? "")|\(pathDependent ? pathKey.finalize():0)|\(geometry)|\(seedX)|\(seedY)|\(stroke.topography?.engine ?? 0)|\(stroke.topography?.respectRegion == true)|\(binding.reference.analysisAsset)|\(binding.reference.maskAsset ?? "")|\(binding.shading)|\(stroke.red)|\(stroke.green)|\(stroke.blue)" as NSString
    }
    func surfaceMaterial(_ stroke: Ink) -> CGImage? {
        guard let binding=stroke.surface,let key=surfaceMaterialKey(stroke)else{return nil}
        if let prepared=preparedLiveMaterial,prepared.key==key{return prepared.image}
        if let image = sceneCache.strokes.object(forKey: key) { return image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard let scene = sceneData(binding.reference)else{return nil}
        var mask:[UInt8]
        if stroke.photoShading == true && binding.reference.maskAsset == nil || (stroke.topography?.engine == 2 && stroke.topography?.respectRegion != true && binding.reference.automaticTarget != true){mask=[UInt8](repeating:255,count:scene.count)}
        else{
            guard let selected=maskData(binding.reference)else{return nil}
            if stroke.photoShading != true,stroke.topography == nil,binding.reference.outline == nil,let asset=binding.reference.geometryAsset,let mesh=MeshPainter.mesh(asset,editor:self){
                mesh.prepareDepthEdges(scene,key:binding.reference.analysisAsset)
                var foreground:[UInt8]?=nil
                var coarse=SurfaceVisibility.mask(stroke,mesh:mesh,selected:selected,width:scene.width,height:scene.height)
                if let asset=binding.reference.occlusionAsset{
                    var occluderRef=binding.reference;occluderRef.maskAsset=asset
                    if let occluder=maskData(occluderRef){foreground=occluder;for i in coarse.indices{coarse[i]=UInt8(Int(coarse[i])*(255-Int(occluder[i]))/255)}}
                }else{requestStrokeOcclusion(stroke,coarse:coarse,scene:scene)}
                let f=binding.reference.frame
                let focus=stroke.points.map{CGPoint(x:($0.x-f.x)/f.width*Double(scene.width),y:($0.y-f.y)/f.height*Double(scene.height))}
                var refined=EdgeMatte.refine(coarse,rgb:scene.rgb,width:scene.width,height:scene.height,focus:focus,brushRadius:stroke.width*max(Double(scene.width)/f.width,Double(scene.height)/f.height)*0.5)
                // Color matching must never restore paint inside a confident foreground object.
                if let foreground{for i in refined.indices{refined[i]=min(refined[i],255-foreground[i])}}
                mask=refined
            }else{mask=selected}
        }
        if stroke.invertSelection == true,binding.reference.maskAsset != nil{mask=mask.map{255-$0}}
        if interactiveRender{
            if !materialJobs.contains(key){
                materialJobs.insert(key)
                Task{await prepareSurfaceMaterial(stroke);materialJobs.remove(key);invalidateRenderedStroke(stroke)}
            }
            let previewKey=("preview|"+(key as String)) as NSString
            if let cached=sceneCache.strokes.object(forKey:previewKey){return cached.cgImage(forProposedRect:nil,context:nil,hints:nil)}
            guard let preview=SurfacePaint.material(stroke,binding:binding,scene:scene,mask:mask)else{return nil}
            sceneCache.strokes.setObject(NSImage(cgImage:preview,size:NSSize(width:preview.width,height:preview.height)),forKey:previewKey,cost:preview.bytesPerRow*preview.height)
            return preview
        }
        let sourcePhoto=painting.layers.first{$0.id==binding.reference.sourceID}.flatMap{image(for:$0)}?.cgImage(forProposedRect:nil,context:nil,hints:nil)
        let highResolution=sourcePhoto.flatMap{SurfacePaint.photoMaterial(stroke,binding:binding,scene:scene,mask:mask,photo:$0)}
        guard let image=highResolution ?? SurfacePaint.material(stroke,binding:binding,scene:scene,mask:mask)else{return nil}
        sceneCache.strokes.setObject(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
    func previewInk(_ points: [Dot]) -> Ink {
        var ink = makeInk(points, erasing: tool == .eraser)
        ink.id = nil
        if ink.eraser != true && surfaceMode && plane == .artwork, let reference = liveSurface, reference.maskAsset != nil { ink.surface = SurfaceBinding(reference: reference, shading: shadeStrength, conform: 0) }
        return ink
    }
    func maskOverlay() -> CGImage? {
        guard let reference = painting.scene, let scene = sceneData(reference), let mask = maskData(reference) else { return nil }
        let key="mask-overlay|\(reference.analysisAsset)|\(reference.maskAsset ?? "")" as NSString
        if let image=sceneCache.strokes.object(forKey:key){return image.cgImage(forProposedRect:nil,context:nil,hints:nil)}
        var rgba = [UInt8](repeating: 0, count: scene.count * 4)
        for i in 0..<scene.count { let a = mask[i] / 3; rgba[i * 4] = 0; rgba[i * 4 + 1] = a; rgba[i * 4 + 2] = a; rgba[i * 4 + 3] = a }
        guard let image=SceneWorker.raster(rgba,width:scene.width,height:scene.height)else{return nil}
        sceneCache.strokes.setObject(NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)),forKey:key,cost:image.bytesPerRow*image.height)
        return image
    }
}
