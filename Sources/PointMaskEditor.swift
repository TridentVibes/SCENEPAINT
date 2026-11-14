import AppKit
import SwiftUI

@MainActor extension Editor {
    func beginSurfaceSelection(at point: Dot, append: Bool = false, label: Int32 = 1, lock: Bool = false, promptsOverride: [SegmentPoint]? = nil, automaticTarget: Bool = false) -> Task<SceneReference?, Never>? {
        guard !analyzing else { status = "The photo is still being analyzed. Painting will be ready when it finishes."; return nil }
        guard var reference = painting.scene, sceneAligned(reference), let scene = sceneData(reference),
              reference.frame.contains(point), let feature = reference.samAsset, let featureURL = analysisURL(feature) else {
            if let id = activePhotoID { requestPhotoAnalysis(id) }
            status = "Preparing this photo's precise masks first…"; return nil
        }
        reference.automaticTarget = automaticTarget
        if !automaticTarget && lockSurface && !append && !lock, reference.maskAsset != nil {
            liveSurface = reference
            return Task { reference }
        }
        let f = reference.frame
        let prompt = SegmentPoint(x: (point.x-f.x)/f.width, y: (point.y-f.y)/f.height, label: label)
        let prompts = promptsOverride ?? (append ? (reference.prompts ?? []) + [prompt] : [prompt])
        guard prompts.count <= 64, prompts.contains(where: { $0.label == 1 }) else { status = "Pick a positive surface point first."; return nil }
        let revision = sceneRevision, request = UUID(), location = root, choice = automaticTarget ? 0:maskChoice
        if !analyzing && !buildingGeometry{aiStarted=Date()}
        liveGestureID = request; liveSurface = nil; selectionCount += 1; selectingSurface = true
        status = "SAM is finding the region's boundaries…"
        return Task {
            defer {
                selectionCount -= 1; selectingSurface = selectionCount > 0
                drainQueuedAnalysis()
            }
            do {
                let selection: SAMSelection
                if choice == 1 && prompts.count == 1 {
                    let base = try await SAMService.shared.select(root: location, featuresURL: featureURL, points: prompts, width: scene.width, height: scene.height, choice: 0)
                    let hints = MaterialGuidance.exclusions(scene: scene, mask: base.mask, seed: prompts[0])
                    let detailed = hints.isEmpty ? nil : try? await SAMService.shared.select(root: location, featuresURL: featureURL, points: prompts+hints, width: scene.width, height: scene.height, choice: 0)
                    let baseArea = base.mask.filter { $0 > 128 }.count
                    if let detailed, detailed.score >= max(0.55,base.score-0.12), detailed.mask.filter({ $0 > 128 }).count < baseArea*9/10 {
                        selection = detailed
                    } else {
                        let small = try await SAMService.shared.select(root: location, featuresURL: featureURL, points: prompts, width: scene.width, height: scene.height, choice: 1)
                        selection = small.score >= max(0.55,base.score-0.15) ? small : base
                    }
                } else {
                    selection = try await SAMService.shared.select(root: location, featuresURL: featureURL, points: prompts, width: scene.width, height: scene.height, choice: choice)
                }
                guard sceneRevision == revision, activePhotoID == reference.sourceID, sceneAligned(reference) else { return nil }
                reference.maskAsset = try writeMask(selection.mask); reference.seed = point; reference.prompts = prompts; reference.maskScore = selection.score; reference.outline = nil
                if lock || append { checkpoint() }
                reference.geometryAsset=painting.scene?.geometryAsset ?? reference.geometryAsset
                if automaticTarget{
                    await prepareBrushResources(reference)
                    var preview=makeInk([],erasing:false)
                    preview.surface=SurfaceBinding(reference:reference,shading:shadeStrength,conform:0)
                    await prepareSurfaceMaterial(preview)
                    guard sceneRevision == revision,activePhotoID == reference.sourceID else{return nil}
                }
                painting.scene = reference
                if lock || append { lockSurface = true; showMask = true }
                if liveGestureID == request { liveSurface = reference }
                status = String(format: "SAM region selected in %.2f s · Shift-click adds, Option-click excludes · Mask + / − refine edges", selection.elapsed)
                return reference
            } catch { fail(error); return nil }
        }
    }
    func pickSAMSurface(at point: Dot, append: Bool = false, label: Int32 = 1) {
        guard plane == .artwork else { status = "Select surfaces in the Artwork tab."; return }
        _ = beginSurfaceSelection(at: point, append: append, label: label, lock: true)
    }
    func updateSAMSelection() {
        guard let reference = painting.scene, let prompt = reference.prompts?.last else { return }
        let f = reference.frame
        let last = Dot(x: f.x+prompt.x*f.width, y: f.y+prompt.y*f.height)
        _ = beginSurfaceSelection(at: last, append: true, label: prompt.label, lock: true, promptsOverride: reference.prompts)
    }
    func finishSurfaceStroke(_ captured: Ink, task: Task<SceneReference?, Never>,targetLayerID:UUID?=nil) {
        let id = captured.id!, revision = sceneRevision, photo = activePhotoID
        var pending=captured;pending.topography=nil;pending.surface=nil;pending.meshStroke=nil;pendingInk.append(pending)
        Task {
            let reference = await task.value
            defer { pendingInk.removeAll { $0.id == id } }
            guard let reference, revision == sceneRevision, photo == activePhotoID else { return }
            var resolved=captured
            if reference.automaticTarget == true { resolved.meshStroke=nil }
            commitCapturedInk(resolved, reference: reference, targetPlane: .artwork,targetLayerID:targetLayerID)
        }
    }
    func placeText(at point: Dot) {
        textInput="text here"
        if !surfaceMode || plane != .artwork { addText(at: point); return }
        guard let task = beginSurfaceSelection(at: point) else { return }
        let text = textInput, revision = sceneRevision, settings = textSettings, opacity = textOpacity, surfaceStyle = textSurfaceSettings
        Task {
            guard let reference = await task.value, sceneRevision == revision else { return }
            checkpoint()
            let layer = Layer(name: "Text", opacity: opacity, x: point.x, y: point.y, text: text, fontSize: settings.size, textSettings: settings, textSurface: surfaceStyle, photoSourceID:reference.sourceID, surface: SurfaceBinding(reference: reference, shading: 0, conform: 0))
            painting.layers.append(layer); selected = layer.id;textInput=text
            status = "Text is attached to this surface · Moving it keeps foreground occlusion fixed to the photo"
        }
    }
    func applyMaskToSelectedLayer() {
        guard let i = activeIndex, plane == .artwork, let reference = painting.scene, reference.maskAsset != nil,
              painting.layers[i].id != reference.sourceID else { status = "Select a text, overlay, or paint layer, then choose its target surface."; return }
        checkpoint()
        if !painting.layers[i].strokes.isEmpty {
            var local = reference; local.frame.x -= painting.layers[i].x; local.frame.y -= painting.layers[i].y
            for j in painting.layers[i].strokes.indices where painting.layers[i].strokes[j].eraser != true {
                painting.layers[i].strokes[j].surface = SurfaceBinding(reference: local, shading: shadeStrength, conform: 0)
                painting.layers[i].strokes[j].id = UUID()
            }
            painting.layers[i].surface = nil
        } else { painting.layers[i].surface = SurfaceBinding(reference: reference, shading: 0, conform: 0) }
        status = "Selected layer now uses the precise surface mask · Undo restores its previous mask"
    }
    func layerMask(_ reference: SceneReference) -> CGImage? {
        let key = "layer-mask|\(reference.maskAsset ?? "")|\(reference.analysisAsset)" as NSString
        if let image = sceneCache.strokes.object(forKey: key) { return image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard let scene = sceneData(reference), let mask = maskData(reference) else { return nil }
        var pixels = [UInt8](repeating: 0, count: scene.count*4)
        for i in 0..<scene.count { for c in 0..<4 { pixels[i*4+c] = reference.outline == nil ? mask[i] : 255 } }
        guard let image = SceneWorker.raster(pixels, width: scene.width, height: scene.height) else { return nil }
        sceneCache.strokes.setObject(NSImage(cgImage: image, size: NSSize(width: scene.width, height: scene.height)), forKey: key, cost: image.bytesPerRow*image.height)
        return image
    }
}
