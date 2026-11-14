import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum Plane: String, Codable, CaseIterable, Identifiable {
    case artwork = "Artwork", depth = "Depth", normals = "Normals", albedo = "Albedo", shading = "Shading"
    var id: String { rawValue }
}
enum Tool: String, CaseIterable { case bucket = "Bucket Fill", move = "Move", brush = "Brush", wrapBrush = "Wrap Brush", eraser = "Eraser", hand = "Zoom", text = "Text", surface = "Surface", outline = "Outline", maskAdd = "Mask +", maskRemove = "Mask −" }
struct Dot: Codable, Equatable { var x: Double; var y: Double }
struct Ink: Codable, Equatable {
    var id: UUID? = UUID()
    var surface: SurfaceBinding? = nil
    var brush: BrushSettings? = nil
    var topography:BrushTopography? = nil
    var meshStroke:SurfaceStroke? = nil
    var opacity: Double? = nil
    var eraser: Bool? = nil
    var smooth: Bool? = nil
    var closed: Bool? = nil
    var filled: Bool? = nil
    var photoShading: Bool? = nil
    var materialPaint: Bool? = nil
    var invertSelection:Bool? = nil
    var imageAsset:String? = nil
    var imageFrame:SceneFrame? = nil
    var animation:MotionStack? = nil
    var motionGroup:UUID? = nil
    var points: [Dot]; var width: Double; var red: Double; var green: Double; var blue: Double
}
struct Layer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var plane: Plane = .artwork
    var visible = true
    var opacity = 1.0
    var x = 0.0; var y = 0.0
    var width = 1200.0; var height = 800.0
    var imageAsset: String? = nil
    var text: String? = nil
    var fontSize = 64.0
    var textSettings: TextSettings? = nil
    var textSurface: SurfaceTextSettings? = nil
    var relighting:RelightSettings? = nil
    var photoSourceID:UUID? = nil
    var materialWorkflow:Bool? = nil
    var strokes: [Ink] = []
    var generatedFor: UUID? = nil
    var mapSourceID: UUID? = nil
    var surface: SurfaceBinding? = nil
    var materialPaint:Bool? = nil
    var frozenSources:[UUID]? = nil
    var frozenBy:UUID? = nil
    var animation:MotionStack? = nil
    var motionMuted:Bool? = nil
}
struct Painting: Codable {
    var version = 1
    var width = 1200.0; var height = 800.0
    var layers: [Layer] = []
    var scene: SceneReference? = nil
    var scenes: [SceneReference]? = nil
    var activePhotoID: UUID? = nil
    var toolPreferences: ToolPreferences? = nil
    var motion:MotionSettings? = nil
    var motionGroups:[MotionGroup]? = nil
}

@MainActor final class Editor: ObservableObject {
    var contentRevision:UInt64=0
    var pendingRevision:UInt64=0
    var displayedCache:(revision:UInt64,plane:Plane,photo:UUID?,layers:[Layer])?
    var materialDependencyCache:(revision:UInt64,layers:[Layer])?
    var frozenIDCache:(revision:UInt64,ids:Set<UUID>)?
    @Published var painting = Painting() {
        didSet { contentRevision &+= 1; if painting.scene == nil { surfaceMode = false; lockSurface = false; showMask = false } }
    }
    @Published var motionPlaying=false
    var motionPosition=0.0
    @Published var motionPreparing=false
    @Published var motionExporting=false
    @Published var motionProgress=0.0
    @Published var motionScope:MotionScope = .layer
    @Published var motionSelection=Set<UUID>()
    @Published var motionGroupSelection:UUID?
    @Published var motionPreviewEnabled=true
    var motionFrame:CGImage?
    @Published var motionPreviewNote=""
    var motionPreparation:Task<Void,Never>?
    var motionFrameTask:Task<Void,Never>?
    var motionExportTask:Task<Void,Never>?
    var motionEngine:MotionEngine?
    var motionPrepared:MotionScene?
    var motionPreparedEpoch=0
    var motionPreparedRevision:UInt64=0
    var motionPreparedScene=UUID()
    var motionPreparationID=UUID()
    var motionFrameID=UUID()
    var motionFrameDisplay:(()->Void)?
    var motionLastRender=Date.distantPast
    var motionLastTick=Date()
    var motionPreviewInterval=1.0/24
    var motionSelectionMask:SurfaceBinding?
    @Published var selected: UUID?
    @Published var plane: Plane = .artwork
    @Published var tool: Tool = .brush
    @Published var brushSize = 16.0
    @Published var workspacePreferences=WorkspacePreferences()
    @Published var savingProject=false
    @Published var brushSettings = BrushPreset.hard.settings
    @Published var brushOpacity = 1.0
    @Published var drawingAssist:DrawingAssist = .freehand
    @Published var fillShapes=false
    @Published var smoothLines=true
    @Published var preserveShading=false
    @Published var showMeshGrid=false
    @Published var gridDensity=12.0
    @Published var bucketUseAI=true
    @Published var bucketTolerance=0.16
    @Published var filling=false
    @Published var analysisProgress=0.0
    @Published var geometryProgress=0.0
    @Published var analysisStage="Preparing photo"
    @Published var geometryStage="Loading geometry model"
    @Published var renderEpoch=0
    @Published var materialUpdates=0
    @Published var freezingLayers=false
    var interactiveRender=false
    var materialJobs=Set<NSString>()
    var layerRenderEpochs:[UUID:Int]=[:]
    var meshRenderJobs=Set<NSString>()
    var canvasSnapshot:CGImage?
    var canvasSnapshotPlane:Plane = .artwork
    var canvasSnapshotRevision:UInt64=0
    var canvasSnapshotEpoch=0
    var aiStarted=Date()

    @Published var brushTopography=BrushTopography(engine:2)
    @Published var interactivePreview=false
    var previewTask:Task<Void,Never>?
    let motionPhotos:NSCache<NSString,NSImage> = {let cache=NSCache<NSString,NSImage>();cache.totalCostLimit=12*1024*1024;return cache}()
    @Published var textSettings = TextSettings()
    @Published var textSurfaceSettings=SurfaceTextSettings(enabled:false,curvature:0,followDepth:0,depthRelief:1,depthDirection:-90,engine:2)
    @Published var textOpacity = 1.0
    @Published var textWrapWarnings:[UUID:String]=[:]
    @Published var zoom = 1.0
    @Published var panX = 0.0
    @Published var panY = 0.0
    @Published var inspectorTab = "Brush"
    @Published var selectedStroke: Int?
    var lastInspectorKey: String?
    var lastInspectorTime = Date.distantPast
    @Published var color = Color.orange
    @Published var textInput = "text here"
    @Published var status = "Import a photo, select its layer, then Analyze Photo"
    @Published var dirty = false
    @Published var analyzing = false
    @Published var selectingSurface = false
    @Published var pendingInk: [Ink] = []{didSet{pendingRevision &+= 1;contentRevision &+= 1}}
    @Published var liveSurface: SceneReference?
    @Published var maskChoice = 1
    @Published var autoAnalyze = true
    var queuedPhotoAnalysis: UUID?
    var liveGestureID: UUID?
    var selectionCount = 0
    @Published var surfaceMode = false
    @Published var lockSurface = false
    @Published var showMask = false
    @Published var surfaceTolerance = 0.25
    @Published var shadeStrength = 0.85
    @Published var conformStrength = 0.0
    let sceneCache = SceneCache()
    let projectedTextCache = ProjectedTextCache()
    let meshCache=SurfaceMeshCache()
    var brushResourceTasks:[String:Task<Void,Never>]=[:]
    var preparedLiveMaterial:(key:NSString,image:CGImage)?

    @Published var buildingGeometry=false
    @Published var autoGeometry=true
    @Published var geometryDetail=2500
    var geometryWindows:[NSWindow]=[]
    let renderCache = LayerRenderCache()
    let relightCache = RelightCache()
    let materialCache = MaterialCache()
    var analysisJob: UUID?
    var analysisCancellation: AnalysisCancellation?
    var rootOverride: URL?
    var sceneRevision = UUID()
    private let images = NSCache<NSString, NSImage>()
    init() { images.totalCostLimit = 64 * 1024 * 1024 }
    private var history: [Painting] = []
    private var future: [Painting] = []
    var loadedStartupDemo=false
    private var projectURL: URL?
    var activeIndex: Int? { painting.layers.firstIndex { $0.id == selected && $0.plane == plane } }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var root: URL { rootOverride ?? ScenePaintPaths.developmentRoot }
    func checkpoint() {
        history.append(painting)
        if history.count > 20 { history.removeFirst() }
        future.removeAll(); dirty = true
    }
    func undo() {
        guard let previous = history.popLast() else { return }
        stopMotion(clear:true);future.append(painting); painting = previous; dirty = true; sceneRevision = UUID(); lastInspectorKey = nil; syncSelectionControls()
    }
    func redo() {
        guard let next = future.popLast() else { return }
        stopMotion(clear:true);history.append(painting); painting = next; dirty = true; sceneRevision = UUID(); lastInspectorKey = nil; syncSelectionControls()
    }
    func fail(_ error: Error) { status = error.localizedDescription }
    func image(for layer: Layer) -> NSImage? {
        if let cached = images.object(forKey: layer.id.uuidString as NSString) { return cached }
        guard let asset = layer.imageAsset, asset == URL(fileURLWithPath: asset).lastPathComponent else { return nil }
        let url = root.appendingPathComponent("Assets").appendingPathComponent(asset)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { return nil }
        let preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        images.setObject(preview, forKey: layer.id.uuidString as NSString, cost: cg.bytesPerRow * cg.height)
        return preview
    }
    func importImages() { importPanel(asMap: false) }
    func importMap() { importPanel(asMap: true) }
    func importPanel(asMap: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls, asMap: asMap)
    }
    func importURLs(_ urls: [URL], asMap: Bool = false) {
        let targetPlane: Plane = asMap ? plane : .artwork
        var added: [Layer] = []
        for url in urls {
            do {
                let asset = UUID().uuidString + "." + url.pathExtension
                let destination = root.appendingPathComponent("Assets").appendingPathComponent(asset)
                try FileManager.default.copyItem(at: url, to: destination)
                var layer = Layer(name: url.deletingPathExtension().lastPathComponent, plane: targetPlane, imageAsset: asset, mapSourceID: asMap ? painting.activePhotoID : nil)
                guard let image = image(for: layer) else {
                    try? FileManager.default.removeItem(at: destination)
                    status = "Could not decode \(url.lastPathComponent)"; continue
                }
                let scale = min(painting.width / image.size.width, painting.height / image.size.height)
                layer.width = image.size.width * scale; layer.height = image.size.height * scale
                layer.x = (painting.width - layer.width) / 2; layer.y = (painting.height - layer.height) / 2
                added.append(layer)
            } catch { fail(error) }
        }
        guard !added.isEmpty else { return }
        checkpoint(); painting.layers.append(contentsOf: added); selected = added.last?.id
        status = "Imported \(added.count) image(s) · Original files preserved"
        if !asMap, let id = added.last?.id { activatePhoto(id, analyzeIfNeeded: autoAnalyze) }
    }
    func addPaintLayer() {
        checkpoint()
        let layer = Layer(name: "Paint \(painting.layers.count + 1)", plane: plane, photoSourceID:plane == .artwork ? activePhotoID:nil, mapSourceID: plane == .artwork ? nil : painting.activePhotoID)
        painting.layers.append(layer); selected = layer.id
    }
    func commitInk(_ points: [Dot]) {
        let ink = makeInk(points, erasing: tool == .eraser)
        commitCapturedInk(ink, reference: surfaceMode && plane == .artwork ? painting.scene : nil, targetPlane: plane)
    }
    func commitCapturedInk(_ captured: Ink, reference: SceneReference?, targetPlane: Plane, targetLayerID:UUID? = nil) {
        guard !captured.points.isEmpty else { return }
        var index:Int?
        if let targetLayerID{index=painting.layers.firstIndex{$0.id==targetLayerID && $0.plane==targetPlane && $0.frozenBy == nil}}else{index=activeIndex}
        if captured.eraser == true && index == nil { status = "Select a layer to erase first."; return }
        checkpoint()
        if captured.eraser != true && (targetPlane != plane || index == nil || painting.layers[index!].imageAsset != nil || painting.layers[index!].text != nil || (targetLayerID == nil && targetPlane == .artwork && reference != nil && Relighter.owner(of:painting.layers[index!],editor:self) != reference?.sourceID)) {
            let layer = Layer(name: "Paint \(painting.layers.count + 1)", plane: targetPlane, photoSourceID:targetPlane == .artwork ? (reference?.sourceID ?? activePhotoID):nil, mapSourceID: targetPlane == .artwork ? nil : painting.activePhotoID)
            painting.layers.append(layer); selected = layer.id; index = painting.layers.count-1
        }
        guard let i = index else { return }
        var ink = captured;ink.materialPaint=nil
        ink.points = captured.points.map { Dot(x: $0.x-painting.layers[i].x, y: $0.y-painting.layers[i].y) }
        ink.imageFrame?.x -= painting.layers[i].x;ink.imageFrame?.y -= painting.layers[i].y
        ink.surface = nil
        if captured.eraser != true, var reference, (captured.photoShading == true || reference.maskAsset != nil || (captured.topography?.engine == 2 && reference.geometryAsset != nil)) {
            reference.frame.x -= painting.layers[i].x; reference.frame.y -= painting.layers[i].y
            ink.surface = SurfaceBinding(reference: reference, shading: shadeStrength, conform: 0)
        }
        // Surface tracing and rasterization are deferred during interactive drawing.
        painting.layers[i].strokes.append(ink); selectedStroke = painting.layers[i].strokes.count-1
    }
    func addText(at point: Dot) {
        guard !textInput.isEmpty else { return }
        checkpoint()
        let layer = Layer(name: "Text", plane: plane, opacity: textOpacity, x: point.x, y: point.y, text: textInput, fontSize: textSettings.size, textSettings: textSettings, textSurface:textSurfaceSettings, photoSourceID:plane == .artwork ? activePhotoID:nil)
        painting.layers.append(layer); selected = layer.id
    }
    func updateText() {
        guard let i = activeIndex, painting.layers[i].text != nil else { return }
        checkpoint(); painting.layers[i].text = textInput
    }
    func toggle(_ id: UUID) {
        guard let i = painting.layers.firstIndex(where: { $0.id == id }) else { return }
        guard painting.layers[i].frozenBy == nil else{status="Unfreeze the snapshot to edit its original layers.";return}
        checkpoint(); painting.layers[i].visible.toggle()
    }
    func deleteLayer() {
        if selectedFrozenLayer != nil{unfreezeSelectedLayer();return}
        guard let i = activeIndex else { return }
        let deletingSource = painting.scene?.sourceID == painting.layers[i].id
        checkpoint(); painting.layers.remove(at: i); selected = nil
        if deletingSource { painting.scene = nil }
    }
    func reorder(_ delta: Int) {
        guard let i = activeIndex else { return }
        let indices = painting.layers.indices.filter { painting.layers[$0].plane == plane && painting.layers[$0].frozenBy == nil }
        guard let current = indices.firstIndex(of: i), indices.indices.contains(current + delta) else { return }
        checkpoint(); painting.layers.swapAt(i, indices[current + delta])
    }
    func save(){saveProject(asCopy:false)}
    func saveAs(){saveProject(asCopy:true)}
    func saveProject(asCopy:Bool){
        guard !savingProject,pendingInk.isEmpty,selectionCount==0,!buildingGeometry,!filling else{status="Finishing pending work before saving…";return}
        storeActiveScene()
        let ink=NSColor(color).usingColorSpace(.deviceRGB) ?? .orange
        painting.toolPreferences=ToolPreferences(brush:brushSettings,size:brushSize,opacity:brushOpacity,ink:[ink.redComponent,ink.greenComponent,ink.blueComponent],text:textSettings,textOpacity:textOpacity,textInput:textInput,regionChoice:maskChoice,topography:brushTopography,textSurface:textSurfaceSettings,drawingAssist:drawingAssist,fillShapes:fillShapes,smoothLines:smoothLines,preserveShading:preserveShading,bucketUseAI:bucketUseAI,bucketTolerance:bucketTolerance)
        var destination=projectURL
        if asCopy || destination==nil{
            let panel=NSSavePanel();panel.title="Save ScenePaint Project";panel.nameFieldStringValue=(projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")+".scenepaint"
            panel.allowedContentTypes=[UTType(exportedAs:ScenePaintPaths.projectTypeIdentifier,conformingTo:.package)];panel.canCreateDirectories=true;panel.isExtensionHidden=false;panel.canSelectHiddenExtension=false;panel.allowsOtherFileTypes=false
            panel.directoryURL=projectURL?.deletingLastPathComponent() ?? root.appendingPathComponent("Projects")
            guard panel.runModal() == .OK,let url=panel.url else{return};destination=url
        }
        guard let destination else{return}
        savingProject=true;status="Saving project and its photos…"
        let snapshot=painting,location=root
        // Keep the native save synchronous for quit/save decisions; package I/O
        // is bounded to referenced assets and uses a staged replacement.
        defer{savingProject=false}
        do{
            var directory:ObjCBool=false
            let existing=FileManager.default.fileExists(atPath:destination.path,isDirectory:&directory)
            if existing && !directory.boolValue && !asCopy{
                try ExternalFiles.write(JSONEncoder().encode(snapshot),to:destination)
                status="Saved legacy project · Use Save As for a portable project"
            }else{try ProjectPackage.save(snapshot,root:location,to:destination);status="Saved \(destination.lastPathComponent) · Photos and analysis included"}
            projectURL=destination;dirty=false
        }catch{fail(error)}
    }
    func confirmReplacingProject()->Bool{
        guard dirty else{return true}
        let alert=NSAlert();alert.messageText="Save changes to this project?";alert.informativeText="Your unsaved edits will be lost if you continue without saving."
        alert.addButton(withTitle:"Save");alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:"Don't Save")
        switch alert.runModal(){case .alertFirstButtonReturn:save();return !dirty;case .alertThirdButtonReturn:return true;default:return false}
    }
    func showScenePaintTips(){
        let bundled=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ScenePaint Tips.txt")
        let local=root.appendingPathComponent("Packaging/README.txt")
        let url=FileManager.default.fileExists(atPath:bundled.path) ? bundled:local
        if FileManager.default.fileExists(atPath:url.path){NSWorkspace.shared.open(url)}
    }
    func loadStartupDemoIfNeeded(){
        guard ScenePaintPaths.isRelease,!loadedStartupDemo else{return}
        loadedStartupDemo=true
        guard projectURL==nil,painting.layers.isEmpty,!dirty,let url=ScenePaintPaths.bundledDemo else{return}
        openDemoProject(at:url)
    }
    func openMotionDemo(){
        guard let url=ScenePaintPaths.bundledDemo else{return}
        openDemoProject(at:url)
    }
    func openDemoProject(at url:URL){
        guard confirmReplacingProject() else{return}
        let previousAutoAnalyze=autoAnalyze;autoAnalyze=false
        openProject(at:url);autoAnalyze=previousAutoAnalyze
        guard projectURL==url else{return}
        // Never save back into the bundled example. First Save uses Save As.
        projectURL=nil;dirty=false;plane = .artwork;inspectorTab="Motion"
        selected=displayedLayers.last(where:{layerHasMotion($0)})?.id ?? displayedLayers.last?.id
        motionPosition=0;motionPlaying=false;motionScope = .layer;motionPreviewEnabled=true
        fitCanvas();status="ScenePaint v0.2 · Pumpkin Motion demo · Press Play"
    }
    func newProject(){
        guard confirmReplacingProject(),selectionCount==0,!buildingGeometry else{return}
        stopMotion(clear:true);cancelAnalysis();painting=Painting();history.removeAll();future.removeAll();selected=nil;projectURL=nil;sceneRevision=UUID();dirty=false;fitCanvas();status="New blank 1200 × 800 canvas · Import or drop images to begin"
    }
    func open() {
        guard confirmReplacingProject(),selectionCount==0,!buildingGeometry else{return}
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.directoryURL = root.appendingPathComponent("Projects");panel.canChooseDirectories=true;panel.treatsFilePackagesAsDirectories=false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at:url)
    }
    func openProject(at url:URL){
        guard confirmReplacingProject(),selectionCount==0,!buildingGeometry else{return}
        do {
            let restored=V01MaterialStroke.restoreStoredStrokes(try ProjectPackage.load(url,root:root))
            let loaded=restored.painting
            guard loaded.version == 1, loaded.width > 0, loaded.height > 0,
                  loaded.width <= 8192, loaded.height <= 8192 else {
                status = "Unsupported project version or canvas size"; return
            }
            stopMotion(clear:true);cancelAnalysis(); painting = loaded; images.removeAllObjects(); sceneCache.clear()
            surfaceMode = loaded.scene != nil; showMask = false; sceneRevision = UUID()
            if let prefs=loaded.toolPreferences {
                drawingAssist=prefs.drawingAssist ?? .freehand;fillShapes=prefs.fillShapes ?? false;smoothLines=prefs.smoothLines ?? true;preserveShading=prefs.preserveShading ?? false;bucketUseAI=prefs.bucketUseAI ?? true;bucketTolerance=max(0.02,min(0.5,prefs.bucketTolerance ?? 0.16))
                brushSettings=prefs.brush;brushSize=max(1,min(500,prefs.size));brushOpacity=max(0,min(1,prefs.opacity))
                brushTopography=prefs.topography.map{var style=$0;style.engine=2;return style} ?? BrushTopography(engine:2);textSurfaceSettings=prefs.textSurface ?? Self.defaultTextSurface;textSettings=prefs.text;textOpacity=prefs.textOpacity;textInput="text here";maskChoice=prefs.regionChoice
                if prefs.ink.count==3 { color=Color(red:prefs.ink[0],green:prefs.ink[1],blue:prefs.ink[2]) }
            }
            history.removeAll(); future.removeAll(); selected = nil
            projectURL = url
            dirty = restored.changed; plane = .artwork; status = "Opened \(url.lastPathComponent)"
            if let id = loaded.activePhotoID ?? loaded.layers.last(where: { $0.plane == .artwork && $0.imageAsset != nil && $0.visible })?.id ?? loaded.scene?.sourceID { activatePhoto(id, analyzeIfNeeded: autoAnalyze) }
        } catch { fail(error) }
    }
    func onExternalDrive(_ url: URL) -> Bool {
        if ScenePaintPaths.resources(for:root) != root{return true}
        let drive = root.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(drive) else {
            status = "Choose a location on your project drive to keep editor files together."
            return false
        }
        return true
    }
    func exportPNG() {
        guard pendingInk.isEmpty, selectionCount == 0 else { status = "Finishing the pending paint selection before export…"; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(plane.rawValue).png"
        panel.directoryURL = root.appendingPathComponent("Projects")
        guard panel.runModal() == .OK, let url = panel.url, onExternalDrive(url) else { return }
        do {
            guard let data = pngData() else { status = "Could not render PNG"; return }
            try ExternalFiles.write(data, to: url)
            status = "Exported \(plane.rawValue) at 1200 × 800 (preview resolution)"
        } catch { fail(error) }
    }
    func pngData() -> Data? {
        finishInteractivePreview()
        let w = Int(painting.width), h = Int(painting.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: CGFloat(h)); context.cgContext.scaleBy(x: 1, y: -1)
        Renderer.draw(self)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
