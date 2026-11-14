import AppKit
import SwiftUI
import simd

enum MotionSurfaceChecks{
    @MainActor static func run(root:URL)async throws{
        func check(_ condition:Bool,_ text:String){if !condition{print("FAIL: "+text);fflush(stdout);exit(1)};print("PASS: "+text);fflush(stdout)}
        func bytes(_ image:CGImage)->[UInt8]{
            let cg=CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:512,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.draw(image,in:CGRect(x:0,y:0,width:128,height:128));return Array(UnsafeBufferPointer(start:cg.data!.assumingMemoryBound(to:UInt8.self),count:65536))
        }
        let camera=MeshCamera(fx:1,fy:1)
        let vertices=[V3(-2,-2,3),V3(2,-2,3),V3(2,2,3),V3(-2,2,3),V3(-0.15,-0.4,2),V3(0.15,-0.4,2),V3(0.15,0.4,2),V3(-0.15,0.4,2)]
        let mesh=SurfaceMesh(vertices:vertices,faces:[SIMD3(0,2,1),SIMD3(0,3,2),SIMD3(4,6,5),SIMD3(4,7,6)],camera:camera)
        let frame=SceneFrame(x:0,y:0,width:128,height:128)
        let ref=SceneReference(sourceID:UUID(),analysisAsset:"fixture.json",maskAsset:nil,frame:frame,geometryAsset:"fixture.spgeo")
        let material=CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        material.setFillColor(CGColor(red:1,green:0.2,blue:0.1,alpha:1));material.fill(CGRect(x:12,y:40,width:104,height:48))
        var ink=Ink(surface:SurfaceBinding(reference:ref,shading:0.85,conform:0),topography:BrushTopography(engine:2),points:[Dot(x:24,y:64),Dot(x:104,y:64)],width:6,red:1,green:0.2,blue:0.1)
        ink.meshStroke=MeshPainter.trace(ink,mesh:mesh,frame:frame,asset:"fixture.spgeo")
        check(ink.meshStroke != nil,"Surface fixture traces actual mesh-attached stroke geometry")
        var boil=MotionEffect.make(.boil);boil.intensity=1;boil.frequency=6
        let stack=MotionStack(effects:[boil]),layer=Layer(name:"Surface art",width:128,height:128,strokes:[ink])
        let stroke=MotionStrokePacket(ink:ink,stacks:[stack],material:material.makeImage(),mesh:mesh,target:nil)
        var packet=MotionLayerPacket(layer:layer,base:nil,strokes:[stroke],light:nil)
        packet.objects=[MotionObjectPacket(strokes:[stroke],stacks:[stack])]
        var settings=MotionSettings();settings.duration=1
        let scene=MotionScene(width:128,height:128,pixelsWide:128,pixelsHigh:128,settings:settings,layers:[packet]),engine=MotionEngine(scene)
        let a=try await engine.render(time:0),b=try await engine.render(time:0.2),pixels=bytes(a)
        check(bytes(a) != bytes(b),"Line boil produces variations through existing mesh projection")
        func alpha(_ x:Int)->Int{(58...70).reduce(0){$0+Int(pixels[($1*128+x)*4+3])}}
        check(alpha(40)>0 && alpha(64)==0,"Animated surface artwork remains hidden behind a foreground object")
        check(ink.meshStroke==stroke.ink.meshStroke,"Surface animation retains the original mesh anchors")
        var outside=0
        for y in 0..<128{for x in 0..<128 where x<12 || x>=116 || y<40 || y>=88{outside += Int(pixels[(y*128+x)*4+3])}}
        check(outside==0,"Surface animation stays inside its immutable material mask")
        let editor=Editor();editor.rootOverride=root;editor.autoAnalyze=false;editor.autoGeometry=false
        editor.painting.width=128;editor.painting.height=128
        let line=Ink(opacity:0.35,points:[Dot(x:20,y:30),Dot(x:100,y:30)],width:10,red:1,green:0.3,blue:0.1)
        let eraser=Ink(eraser:true,points:[Dot(x:64,y:10),Dot(x:64,y:90)],width:20,red:0,green:0,blue:0)
        let art=Layer(name:"Eraser composite",opacity:0.7,width:128,height:128,strokes:[line,eraser])
        editor.painting.layers=[art]
        let baseline=editor.captureMotionRaster([art],width:128,height:128)!
        var neutral=MotionEffect.make(.blink);neutral.minimum=1;neutral.maximum=1
        editor.painting.layers[0].animation=MotionStack(effects:[neutral])
        let neutralFrame=try await MotionEngine(try await editor.prepareMotionScene(size:128)).render(time:0.25)
        check(bytes(baseline)==bytes(neutralFrame),"Motion preserves layer opacity, stroke order and erasing")
        // Frozen static runs must stay on the correct sides of animated artwork.
        let first=Layer(name:"Static A",strokes:[line]),second=Layer(name:"Static B",strokes:[line])
        var animated=art;animated.animation=MotionStack(effects:[boil])
        editor.painting.layers=[first,second,animated]
        editor.freezeVisibleLayers()
        for _ in 0..<500{if !editor.freezingLayers{break};try await Task.sleep(for:.milliseconds(10))}
        check(editor.displayedLayers.count==2 && editor.displayedLayers.last?.id==animated.id && editor.hasMotion,"Freeze batches static layers while keeping animated artwork live and ordered")
        editor.unfreezeSelectedLayer();check(editor.painting.layers.count==3,"Unfreeze restores static layers beside animated artwork")
        editor.stopMotion(clear:true)
        // A real SwiftUI layout render catches missing controls and clipped widths.
        _=NSApplication.shared
        editor.painting.layers=[animated];editor.selected=animated.id;editor.motionScope = .layer
        let view=NSHostingView(rootView:ScrollView{MotionInspector(editor:editor).padding(12)}.frame(width:310,height:1100).environment(\.colorScheme,.dark).foregroundStyle(Color.white).background(Color(white:0.13)))
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:310,height:1100),styleMask:[.titled],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:.darkAqua);window.contentView=view
        view.frame=CGRect(x:0,y:0,width:310,height:1100);view.layoutSubtreeIfNeeded()
        if let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds){
            view.cacheDisplay(in:view.bounds,to:rep)
            if let png=rep.representation(using:.png,properties:[:]){try png.write(to:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Build/motion-inspector-check.png"))}
        }
        window.contentView=nil
        check(view.fittingSize.width<=320,"Motion inspector fits the existing sidebar width")
        editor.stopMotion(clear:true)
    }
}
