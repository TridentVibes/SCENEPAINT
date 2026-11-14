import AppKit

@MainActor extension Editor {
    var activePhotoID: UUID? { painting.activePhotoID ?? painting.scene?.sourceID }
    var displayedLayers: [Layer] {
        if let cached=displayedCache,cached.revision==contentRevision,cached.plane==plane,cached.photo==activePhotoID{return cached.layers}
        let layers=painting.layers.filter { layer in
            guard layer.frozenBy == nil else{return false}
            guard layer.plane == plane else { return false }
            if plane == .artwork { return true }
            let owner = layer.mapSourceID ?? layer.generatedFor
            return owner == nil || owner == activePhotoID
        }
        displayedCache=(contentRevision,plane,activePhotoID,layers);return layers
    }
    func storeActiveScene() {
        guard let current = painting.scene else { return }
        var scenes = painting.scenes ?? []
        scenes.removeAll { $0.sourceID == current.sourceID }; scenes.append(current)
        painting.scenes = scenes
    }
    func selectLayer(_ id: UUID) {
        selected = id; selectedStroke = nil; lastInspectorKey = nil
        guard let layer = painting.layers.first(where: { $0.id == id }) else { return }
        if let text = layer.text {
            textSurfaceSettings=layer.textSurface ?? Self.defaultTextSurface
            textInput = text; textSettings = layer.textSettings ?? TextSettings(size: layer.fontSize, bold: true)
            textOpacity = layer.opacity; inspectorTab = "Text"
        }
        if layer.plane == .artwork && layer.imageAsset != nil && layer.frozenSources == nil { activatePhoto(id, analyzeIfNeeded: autoAnalyze) }
    }
    func activatePhoto(_ id: UUID, analyzeIfNeeded: Bool) {
        requestInteractivePreview()
        guard let layer = painting.layers.first(where: { $0.id == id && $0.plane == .artwork && $0.imageAsset != nil }) else { return }
        if activePhotoID != id {
            // Migrate old projects' unowned correction layers to the previous photo.
            if let previous = activePhotoID {
                for i in painting.layers.indices where painting.layers[i].plane != .artwork && painting.layers[i].mapSourceID == nil {
                    painting.layers[i].mapSourceID = painting.layers[i].generatedFor ?? previous
                }
            }
            storeActiveScene(); sceneRevision = UUID(); liveSurface = nil
            let cached = painting.scenes?.last(where: { $0.sourceID == id })
            painting.activePhotoID = id; painting.scene = cached; lockSurface = false; showMask = false
        } else { painting.activePhotoID = id }
        selected = layer.id; plane = .artwork
        if let scene = painting.scene, scene.sourceID == id, let sam = scene.samAsset,
           let url = analysisURL(sam), FileManager.default.fileExists(atPath: url.path), sceneData(scene) != nil {
            surfaceMode = true
            if analyzing && queuedPhotoAnalysis != id { analysisCancellation?.cancel(); queuedPhotoAnalysis = nil }
            status = "Restored this photo's cached depth and SAM masks"
            Task{await prepareBrushResources(scene)}
            if autoGeometry && !hasSurfaceMesh && !buildingGeometry{buildSurfaceMesh()}
        } else if analyzeIfNeeded { requestPhotoAnalysis(id) }
        else { status = "Photo selected · Analyze Photo updates all scene-map tabs" }
    }
    func requestPhotoAnalysis(_ id: UUID) {
        if analyzing || selectionCount > 0 {
            queuedPhotoAnalysis = id
            analysisCancellation?.cancel()
            status = "Switching analysis to the newly selected photo…"
        } else { analyzePhoto(sourceID: id) }
    }
    func drainQueuedAnalysis() {
        guard !analyzing, selectionCount == 0, let id = queuedPhotoAnalysis else { return }
        queuedPhotoAnalysis = nil
        analyzePhoto(sourceID: id)
    }
}
