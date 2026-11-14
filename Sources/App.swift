import AppKit
import SwiftUI

@main struct ScenePaintApp: App {
    @StateObject private var editor = Editor()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() {
        let root = ScenePaintPaths.developmentRoot
        ScenePaintPaths.prepare(root)
        setenv("TMPDIR", root.appendingPathComponent("Temporary").path + "/", 1)
        setenv("XDG_CACHE_HOME", root.appendingPathComponent("Cache").path, 1)
    }
    var body: some Scene {
        WindowGroup(ScenePaintPaths.windowTitle) {
            EditorView(editor: editor).preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 650)
                .onAppear { delegate.editor = editor;editor.loadWorkspacePreferences();editor.loadStartupDemoIfNeeded() }
                .onOpenURL{editor.openProject(at:$0)}
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project",action:editor.newProject).keyboardShortcut("n")
                if ScenePaintPaths.bundledDemo != nil{Button("Open Motion Demo",action:editor.openMotionDemo)}
                Button("Open Project…", action: editor.open).keyboardShortcut("o")
                Button("Save Project", action: editor.save).keyboardShortcut("s")
                Button("Save Project As…",action:editor.saveAs).keyboardShortcut("s",modifiers:[.command,.shift])
                Button("Analyze Photo", action: editor.analyzePhoto).disabled(editor.analyzing)
                Button("Cancel Analysis", action: editor.cancelAnalysis).disabled(!editor.analyzing)
                Button("Import Images…", action: editor.importImages).keyboardShortcut("i")
                Button("Export Animated GIF…"){editor.exportMotion(.gif)}
                Button("Export Motion MP4…"){editor.exportMotion(.mp4)}
                Button("Bake Current Frame",action:editor.bakeMotionFrame).disabled(!editor.hasMotion)
                Button("Export Current View…", action: editor.exportPNG).keyboardShortcut("e")
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { editor.zoomBy(1.25) }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { editor.zoomBy(1/1.25) }.keyboardShortcut("-", modifiers: .command)
                Button("Fit Canvas", action: editor.fitCanvas).keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("ScenePaint Tips & Getting Started…",action:editor.showScenePaintTips)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: editor.undo).keyboardShortcut("z").disabled(!editor.canUndo)
                Button("Redo", action: editor.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo)
            }
        }
        Settings{WorkspaceSettingsView(editor:editor).preferredColorScheme(.dark)}
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var editor: Editor?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editor?.buildingGeometry == true{editor?.status="Finishing the 3D surface before quitting…";return .terminateCancel}
        if editor?.selectionCount ?? 0 > 0 || editor?.pendingInk.isEmpty == false {
            editor?.status = "Finishing a mask selection before quitting…"; return .terminateCancel
        }
        editor?.stopMotion(clear:true);editor?.motionExportTask?.cancel()
        editor?.cancelAnalysis()
        guard editor?.dirty == true else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Save your edits before quitting?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: editor?.save(); return editor?.dirty == true ? .terminateCancel : .terminateNow
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}
struct EditorView:View{
    @ObservedObject var editor:Editor
    func toolIcon(_ tool:Tool)->String{
        switch tool{case .bucket:return "drop.fill";case .move:return "arrow.up.left.and.arrow.down.right";case .brush:return "paintbrush.pointed";case .wrapBrush:return "scribble.variable";case .eraser:return "eraser";case .hand:return "hand.draw";case .text:return "textformat";case .surface:return "scope";case .outline:return "lasso";case .maskAdd:return "plus.circle";case .maskRemove:return "minus.circle"}
    }
    var toolbar:some View{
        HStack{
            Text("SCENEPAINT").font(.system(size:13,weight:.bold,design:.rounded)).tracking(2)
            Spacer()
            if editor.selectingSurface{ProgressView().controlSize(.small)}
            if editor.analyzing{ProgressView().controlSize(.small);Button("Cancel",action:editor.cancelAnalysis)}else{Button("Analyze Photo",action:editor.analyzePhoto)}
            Button("Import Images…",action:editor.importImages);Button("Open…",action:editor.open)
            Button(editor.dirty ? "Save •":"Save",action:editor.save);Button("Export PNG…",action:editor.exportPNG)
        }.padding(editor.workspacePreferences.compact ? 8:12)
    }
    var rail:some View{
        ScrollView{
            VStack(spacing:editor.workspacePreferences.compact ? 3:8){
                ForEach(Tool.allCases,id:\.self){tool in
                    Button{editor.activateTool(tool)}label:{
                        VStack(spacing:4){Image(systemName:toolIcon(tool));Text(tool.rawValue).font(.caption2).minimumScaleFactor(0.65).lineLimit(1)}.frame(width:52,height:45).background(editor.tool == tool ? Color.accentColor.opacity(0.3):Color.clear).clipShape(RoundedRectangle(cornerRadius:7))
                    }.buttonStyle(.plain)
                }
                Divider();ColorPicker("Ink",selection:$editor.color,supportsOpacity:false).labelsHidden()
            }.padding(8)
        }.frame(width:editor.workspacePreferences.railWidth)
    }
    var workspace:some View{
        VStack(spacing:0){
            Picker("View",selection:Binding(get:{editor.plane},set:editor.switchViewport)){ForEach(Plane.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented).padding(10)
            if editor.plane == .albedo || editor.plane == .shading{
                HStack{
                    Text(editor.plane == .albedo ? "Material color · edits update Artwork and relighting":"Shading · brighter adds light, darker adds shadow to Artwork").font(.caption).foregroundStyle(.secondary)
                    Spacer();Button("View Artwork"){editor.switchViewport(.artwork)};Button("Light controls"){editor.switchViewport(.artwork);editor.inspectorTab="Light"}
                }.padding(.horizontal,10).padding(.bottom,6)
            }
            if editor.plane != .artwork{HStack{Text(editor.painting.layers.first(where:{$0.id == editor.activePhotoID})?.name ?? "Select a photo").font(.caption);Spacer();Button("Import Map…",action:editor.importMap)}.padding(.horizontal,10)}
            Group{
                if editor.analyzing || editor.buildingGeometry || editor.selectingSurface || editor.filling || editor.materialUpdates>0 || editor.freezingLayers{
                    VStack(alignment:.leading,spacing:4){
                        ProgressView(value:editor.analyzing ? editor.analysisProgress:editor.buildingGeometry ? editor.geometryProgress:nil).progressViewStyle(.linear)
                        TimelineView(.periodic(from:.now,by:1)){context in
                            HStack{Text(editor.analyzing ? editor.analysisStage:editor.buildingGeometry ? editor.geometryStage:editor.freezingLayers ? "Freezing visible layers":editor.filling ? "Bucket Fill":editor.materialUpdates>0 ? "Updating material color and shading":"Selecting region")
                                Spacer();Text("\(max(0,Int(context.date.timeIntervalSince(editor.aiStarted)))) s").monospacedDigit()}.font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal,12).padding(.bottom,8)
                }
                else{Color.clear}
            }.frame(height:34)
            EditorCanvas(editor:editor)
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .clipped()
                .background(Color(white:0.1))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.14),lineWidth:1))
            HStack{
                Button{editor.zoomBy(1/1.25)}label:{Image(systemName:"minus.magnifyingglass")}
                Text("\(Int(editor.zoom*100))%").font(.caption.monospacedDigit()).frame(width:48)
                Button{editor.zoomBy(1.25)}label:{Image(systemName:"plus.magnifyingglass")}
                Button("Fit",action:editor.fitCanvas)
                Text("Pinch to zoom · Two fingers to pan · A/Z: tools · S/X: layers · Q/W: views").font(.caption).foregroundStyle(.secondary)
                Spacer();Text("\(Int(editor.painting.width)) × \(Int(editor.painting.height))").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    var sidebar:some View{
        VStack(spacing:0){
            Picker("Inspector",selection:$editor.inspectorTab){Text("Brush").tag("Brush");Text("Text").tag("Text");Text("Surface").tag("Surface");Text("Light").tag("Light");Text("Motion").tag("Motion")}.pickerStyle(.segmented).padding(10)
            ScrollView{
                VStack(alignment:.leading){
                    if editor.inspectorTab == "Motion"{MotionInspector(editor:editor)}else if editor.inspectorTab == "Brush"{BrushInspector(editor:editor)}else if editor.inspectorTab == "Text"{TextInspector(editor:editor)}else if editor.inspectorTab == "Light"{RelightInspector(editor:editor)}else{SurfaceInspector(editor:editor)}
                }.padding(editor.workspacePreferences.compact ? 8:12)
            }.frame(minHeight:180)
            Divider();LayerInspector(editor:editor).padding(12).frame(maxHeight:editor.workspacePreferences.layerHeight)
        }.frame(width:editor.workspacePreferences.sidebarWidth)
    }
    var body:some View{
        VStack(spacing:0){
            toolbar;Divider()
            HStack(spacing:0){rail;Divider();workspace;Divider();sidebar}
            Divider()
            HStack{Text(editor.status).lineLimit(2);Spacer();Button("Undo",action:editor.undo).disabled(!editor.canUndo);Button("Redo",action:editor.redo).disabled(!editor.canRedo)}.font(.caption).padding(8)
        }.background(Color(nsColor:.windowBackgroundColor))
    }
}
