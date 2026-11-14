import AppKit
import SwiftUI
import Combine

struct MotionStartupChecks{
    @MainActor static func main()async throws{
        _=NSApplication.shared
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Temporary/MotionStartup-"+UUID().uuidString)
        ScenePaintPaths.prepare(root);defer{try? FileManager.default.removeItem(at:root)}
        let editor=Editor();editor.rootOverride=root;editor.autoAnalyze=false;editor.autoGeometry=false
        var updates=0
        let subscription=editor.objectWillChange.sink{updates += 1}
        func check(_ condition:Bool,_ message:String){if !condition{print("FAIL: "+message);fflush(stdout);exit(1)};print("PASS: "+message);fflush(stdout)}
        for _ in 0..<1000{editor.refreshMotionIfNeeded()}
        check(updates==0,"1,000 empty-project Motion refreshes publish no editor changes")
        for _ in 0..<1000{editor.stopMotion();editor.stopMotion(clear:true)}
        check(updates==0,"Repeated idle stop and clear operations do not trigger view updates")
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:640,height:480),styleMask:[.titled],backing:.buffered,defer:false)
        let view=NSHostingView(rootView:EditorCanvas(editor:editor).frame(width:640,height:480))
        window.contentView=view;view.frame=CGRect(x:0,y:0,width:640,height:480);view.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(250))
        check(updates==0 && editor.motionPreparation==nil && !editor.motionPlaying,"Mounting the real empty canvas stays idle without a refresh loop")
        editor.status="Startup responsiveness check"
        let expected=updates
        try await Task.sleep(for:.milliseconds(250))
        check(expected==1 && updates==expected,"One editor update settles without publishing another update")
        editor.motionPlaying=true
        editor.motionPreparing=true
        let activeUpdates=updates
        editor.stopMotion()
        check(!editor.motionPlaying && !editor.motionPreparing && updates==activeUpdates+2,"Stopping active Motion still publishes its real state transitions")
        let settled=updates;editor.stopMotion()
        check(updates==settled,"Stopping an already stopped player stays silent")
        window.contentView=nil
        try await Task.sleep(for:.milliseconds(50))
        check(editor.motionPreparation==nil && editor.motionFrameTask==nil,"Detaching the canvas leaves no pending Motion jobs")
        withExtendedLifetime(subscription){}
        print("Startup responsiveness checks complete")
    }
}
