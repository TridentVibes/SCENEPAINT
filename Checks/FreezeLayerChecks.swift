import AppKit

struct FreezeLayerChecks{
    @MainActor static func main()async throws{
        let editor=Editor(),root=URL(fileURLWithPath:"Temporary/FreezeLayers")
        editor.rootOverride=root;ScenePaintPaths.prepare(root);editor.autoAnalyze=false;editor.autoGeometry=false
        editor.painting.width=256;editor.painting.height=256
        let originals=(0..<80).map{j in Layer(name:"Art \(j)",strokes:[Ink(brush:BrushPreset.hard.settings,opacity:0.6,points:[Dot(x:10,y:Double(j)*3),Dot(x:240,y:Double(j)*3+8)],width:4,red:Double(j%3)/2,green:0.3,blue:0.8)])}
        editor.painting.layers=originals;editor.selected=originals.last!.id
        let preview=CanvasMotionPreview();editor.interactiveRender=true;let before=preview.raster(editor)!;editor.interactiveRender=false
        func check(_ condition:Bool,_ text:String){precondition(condition,text);print("PASS: "+text);fflush(stdout)}
        func rgba(_ image:CGImage)->[UInt8]{let cg=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;cg.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return Array(UnsafeBufferPointer(start:cg.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))}
        func awaitFreeze()async throws{
            let deadline=Date().addingTimeInterval(10)
            while editor.freezingLayers && Date()<deadline{try await Task.sleep(for:.milliseconds(10))}
            precondition(!editor.freezingLayers,"Freeze must finish")
        }
        let start=Date()
        for i in 0..<10_000{editor.panX=Double(i);editor.zoom=1+Double(i%20)/20;precondition(preview.raster(editor) === before)}
        let navigation=Date().timeIntervalSince(start)
        check(preview.builds==1 && navigation<0.2,"10,000 navigation updates avoid comparing or rendering 80 layer contents")
        let freezeStart=Date();editor.freezeVisibleLayers();try await awaitFreeze()
        check(editor.displayedLayers.count==1 && editor.painting.layers.count==81,"Freeze displays one cached layer and retains all 80 originals")
        let frozen=editor.selectedFrozenLayer!
        check(Set(frozen.frozenSources!)==Set(originals.map{$0.id}) && editor.painting.layers.prefix(80).allSatisfy{$0.frozenBy==frozen.id},"Frozen snapshot records its complete source layer set")
        check(Relighter.owner(of:frozen,editor:editor)==nil,"Frozen output does not receive a second lighting pass")
        editor.interactiveRender=true;let after=preview.raster(editor)!;editor.interactiveRender=false
        check(zip(rgba(before),rgba(after)).allSatisfy{abs(Int($0)-Int($1))<=2},"Freezing preserves visible pixels")
        let portable=root.appendingPathComponent("Frozen.scenepaint")
        try ProjectPackage.save(editor.painting,root:root,to:portable)
        let reopened=Editor(),destination=root.appendingPathComponent("Reopened");ScenePaintPaths.prepare(destination);reopened.rootOverride=destination
        reopened.painting=try ProjectPackage.load(portable,root:destination);reopened.selected=frozen.id
        check(reopened.displayedLayers.count==1 && reopened.selectedFrozenLayer?.frozenSources?.count==80,"Portable save/reopen retains the frozen snapshot and original layers")
        reopened.unfreezeSelectedLayer()
        check(reopened.painting.layers==originals && reopened.displayedLayers.count==80,"Unfreeze after reopening restores every original layer unchanged")
        editor.unfreezeSelectedLayer()
        check(editor.painting.layers==originals,"Unfreeze restores the exact editable layer stack")
        editor.undo();editor.selected=frozen.id
        check(editor.displayedLayers.count==1,"Undo restores the frozen state")
        // New overlay paint is kept separate from the frozen image.
        let overlay=Ink(points:[Dot(x:20,y:20),Dot(x:100,y:20)],width:10,red:1,green:0,blue:0)
        editor.commitCapturedInk(overlay,reference:nil,targetPlane:.artwork)
        check(editor.displayedLayers.count==2 && editor.painting.layers.last?.strokes.count==1,"New paint goes above the frozen snapshot without modifying it")
        editor.interactiveRender=true;_ = preview.raster(editor);editor.interactiveRender=false
        editor.freezeVisibleLayers();try await awaitFreeze()
        let second=editor.selectedFrozenLayer!
        check(second.frozenSources?.count==2 && editor.displayedLayers.count==1,"A frozen snapshot can be frozen with new layers")
        editor.unfreezeSelectedLayer()
        check(editor.displayedLayers.count==2 && editor.painting.layers.contains{$0.id==frozen.id},"Unfreezing a nested snapshot restores its prior group and overlay")
        editor.selected=frozen.id;editor.deleteLayer()
        check(editor.displayedLayers.count==81 && editor.painting.layers.prefix(80).elementsEqual(originals),"Deleting a frozen snapshot safely unfreezes its originals")
        let revision=editor.contentRevision
        editor.painting.layers[0].strokes[0].red=0.37
        check(editor.contentRevision>revision,"Nested paint changes invalidate the lightweight viewport key")
        print(String(format:"TIMING: 10,000 warm navigation updates %.4f s; freeze and checks elapsed %.3f s",navigation,Date().timeIntervalSince(freezeStart)))
    }
}
