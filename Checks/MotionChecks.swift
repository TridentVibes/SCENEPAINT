import AppKit
import SwiftUI
import AVFoundation
import ImageIO

struct MotionChecks{
    @MainActor static func main()async throws{
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Temporary/MotionChecks-"+UUID().uuidString)
        ScenePaintPaths.prepare(root);defer{try? FileManager.default.removeItem(at:root)}
        func check(_ condition:Bool,_ text:String){if !condition{print("FAIL: "+text);fflush(stdout);exit(1)};print("PASS: "+text);fflush(stdout)}
        func bytes(_ image:CGImage)->[UInt8]{
            let cg=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return Array(UnsafeBufferPointer(start:cg.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
        }
        let editor=Editor();editor.rootOverride=root;editor.autoAnalyze=false;editor.autoGeometry=false
        editor.painting.width=128;editor.painting.height=128
        let photoCG=CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        photoCG.setFillColor(CGColor(red:0.15,green:0.3,blue:0.5,alpha:1));photoCG.fill(CGRect(x:0,y:0,width:128,height:128))
        let photoImage=photoCG.makeImage()!;try SceneWorker.png(photoImage,to:root.appendingPathComponent("Assets/photo.png"))
        let photo=Layer(name:"Static photograph",width:128,height:128,imageAsset:"photo.png")
        var strokes=[Ink]()
        for index in 0..<200{
            let x=30+Double(index%20)*3,y=30+Double(index/20)*5
            strokes.append(Ink(points:[Dot(x:x,y:y),Dot(x:x+2,y:y+8)],width:2,red:1,green:0.2,blue:0.1))
        }
        var paint=Layer(name:"Artwork",width:128,height:128,strokes:strokes)
        editor.painting.layers=[photo,paint];editor.selected=paint.id
        let oldData=try JSONEncoder().encode(editor.painting),oldObject=try JSONSerialization.jsonObject(with:oldData) as! [String:Any]
        check(oldObject["motion"]==nil,"Static projects do not require animation metadata")
        editor.painting=try JSONDecoder().decode(Painting.self,from:oldData)
        check(!editor.hasMotion,"Legacy project opens without activating Motion")
        let baseline=editor.captureMotionRaster(editor.displayedLayers,width:128,height:128)!
        let staticScene=try await editor.prepareMotionScene(size:128),staticFrame=try await MotionEngine(staticScene).render(time:0.4)
        check(bytes(baseline)==bytes(staticFrame),"Static composition is pixel-identical through Motion renderer")
        var boil=MotionEffect.make(.boil);boil.intensity=2;boil.frequency=6;boil.variations=3
        paint.animation=MotionStack(effects:[boil]);editor.painting.layers[1]=paint
        var settings=MotionSettings();settings.duration=1;settings.fps=12;settings.previewSize=128;settings.outputSize=128
        editor.painting.motion=settings
        let before=editor.painting.layers[1].strokes
        let scene=try await editor.prepareMotionScene(size:128),engine=MotionEngine(scene)
        check(scene.layers.count==2 && scene.layers[1].objects.count==1,"200 strokes prepare as one artwork animation object")
        let a=try await engine.render(time:0),b=try await engine.render(time:0.2),same=try await engine.render(time:0),loop=try await engine.render(time:1)
        check(bytes(a)==bytes(same),"Same time and seed reproduce exactly the same frame")
        check(bytes(a)==bytes(loop),"Loop boundary evaluates to identical pixels")
        check(bytes(a) != bytes(b),"Line boil produces distinct artwork variations")
        let originalPhoto=bytes(photoImage),frameA=bytes(a),frameB=bytes(b)
        check(Array(frameA[0..<100])==Array(originalPhoto[0..<100]) && Array(frameB[0..<100])==Array(originalPhoto[0..<100]),"Photograph pixels outside artwork remain static")
        check(editor.painting.layers[1].strokes==before,"Animation never modifies original stroke geometry")
        let start=Date()
        for index in 0..<36{_ = try await engine.render(time:Double(index)/12)}
        print(String(format:"TIMING: 200-stroke object, 36 warm 128px frames %.4f s",Date().timeIntervalSince(start)))
        var large=scene;large.pixelsWide=768;large.pixelsHigh=768
        let largeEngine=MotionEngine(large)
        for t in [0.0,0.2,0.4]{_ = try await largeEngine.render(time:t)}
        let largeStart=Date()
        for index in 0..<24{_ = try await largeEngine.render(time:Double(index)/12)}
        print(String(format:"TIMING: 200-stroke object, 24 warm 768px frames %.4f s",Date().timeIntervalSince(largeStart)))
        let builds=await engine.variationBuilds
        check(builds==3,"Three cached object variations serve repeated loops without per-stroke rebuilds")
        editor.motionScope = .layer
        editor.updateMotionEffect(boil.id){$0.intensity=4}
        editor.stopMotion(clear:true)
        check(editor.painting.layers[1].animation?.effects[0].intensity==4,"Existing layer effect remains editable")
        editor.undo();check(editor.painting.layers[1].animation?.effects[0].intensity==2,"Undo restores effect settings")
        editor.redo();check(editor.painting.layers[1].animation?.effects[0].intensity==4,"Redo restores effect settings")
        let preEditScene=try await editor.prepareMotionScene(size:128),preEdit=try await MotionEngine(preEditScene).render(time:0)
        let retainedEffect=editor.painting.layers[1].animation
        editor.checkpoint();editor.painting.layers[1].strokes[0].points[0].x += 24
        let editedScene=try await editor.prepareMotionScene(size:128),editedFrame=try await MotionEngine(editedScene).render(time:0)
        check(editor.painting.layers[1].animation==retainedEffect && bytes(preEdit) != bytes(editedFrame),"Editing stroke geometry invalidates prepared artwork while retaining its effects")
        editor.undo()
        editor.motionSelection=Set(before.prefix(3).compactMap(\.id));editor.makeMotionGroup()
        check(editor.painting.motionGroups?.count==1 && editor.painting.layers[1].strokes.prefix(3).allSatisfy{$0.motionGroup==editor.motionGroupSelection},"Multiple strokes form one synchronized group")
        let package=root.appendingPathComponent("Motion.scenepaint");try ProjectPackage.save(editor.painting,root:root,to:package)
        let reopened=try ProjectPackage.load(package,root:root)
        check(reopened.motion==editor.painting.motion && reopened.motionGroups==editor.painting.motionGroups && reopened.layers==editor.painting.layers,"Effects, groups, original geometry and loop settings survive .scpt save/reopen")
        var blink=MotionEffect.make(.blink);blink.fadeIn=0;blink.fadeOut=0;blink.frequency=1
        var emission=MotionEffect.make(.emission);emission.intensity=2;emission.spill=2;emission.glowRadius=5;emission.spillRadius=12;emission.constrainSpill=false
        editor.painting.layers[1].animation=MotionStack(effects:[blink,emission]);editor.painting.motionGroups=[]
        let luminous=try await editor.prepareMotionScene(size:128),luminousEngine=MotionEngine(luminous)
        let on=try await luminousEngine.render(time:0.25),off=try await luminousEngine.render(time:0.75)
        if bytes(off) != bytes(photoImage){
            let actual=bytes(off),expected=bytes(photoImage),different=zip(actual,expected).filter{$0 != $1}
            print("DEBUG off-state differences: \(different.count), max: \(different.map{abs(Int($0.0)-Int($0.1))}.max() ?? 0), center: \(Array(actual[32896..<32904])), photo: \(Array(expected[32896..<32904]))")
            try SceneWorker.png(off,to:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Build/motion-off-debug.png"))
        }
        check(bytes(off)==bytes(photoImage),"Blink-off removes artwork, emission and linked spill together")
        check(bytes(on) != bytes(off),"Blink and linked light spill produce a visible on state")
        let noSpillEffect=MotionEffect(kind:.emission,intensity:2,glowRadius:5,spill:0,spillRadius:12,constrainSpill:false)
        editor.painting.layers[1].animation=MotionStack(effects:[blink,noSpillEffect])
        let withoutSpill=try await MotionEngine(try await editor.prepareMotionScene(size:128)).render(time:0.25)
        check(bytes(on) != bytes(withoutSpill),"Linked light spill contributes independent composited illumination")
        var glitch=MotionEffect.make(.glitch);glitch.intensity=10;glitch.eventDuration=0.4;glitch.randomness=0;glitch.rgbOffset=true
        editor.painting.layers[1].animation=MotionStack(effects:[glitch])
        let glitchScene=try await editor.prepareMotionScene(size:128),glitchEngine=MotionEngine(glitchScene)
        let ga=try await glitchEngine.render(time:0.1),gb=try await glitchEngine.render(time:0.1)
        check(bytes(ga)==bytes(gb),"Glitch and RGB offsets are deterministic")
        check(Array(bytes(ga)[0..<100])==Array(originalPhoto[0..<100]),"Glitch cannot displace the background photograph")
        // Native ImageIO GIF roundtrip, preserving the same evaluated frame sequence.
        let gif=root.appendingPathComponent("Motion.gif")
        try await MotionExporter().write(scene:scene,to:gif,format:.gif){_ in}
        let gifSource=CGImageSourceCreateWithURL(gif as CFURL,nil)!
        check(CGImageSourceGetCount(gifSource)==12,"GIF export contains every deterministic output frame")
        let props=CGImageSourceCopyProperties(gifSource,nil) as! [String:Any]
        check((props[kCGImagePropertyGIFDictionary as String] as? [String:Any])?[kCGImagePropertyGIFLoopCount as String] as? Int == 0,"GIF export repeats indefinitely when Loop is enabled")
        var gifDuration=0.0
        for index in 0..<CGImageSourceGetCount(gifSource){
            let properties=CGImageSourceCopyPropertiesAtIndex(gifSource,index,nil) as! [String:Any]
            let values=properties[kCGImagePropertyGIFDictionary as String] as! [String:Any]
            gifDuration += (values[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? (values[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0
        }
        check(abs(gifDuration-1)<0.011,"GIF timing preserves the intended loop duration despite centisecond rounding")
        let gifFirst=CGImageSourceCreateImageAtIndex(gifSource,0,nil)!
        let encoded=bytes(gifFirst),reference=bytes(a)
        let error=zip(encoded,reference).reduce(0){$0+abs(Int($1.0)-Int($1.1))}
        check(Double(error)/Double(reference.count)<8,"Encoded GIF agrees with preview within palette quantization")
        let mp4=root.appendingPathComponent("Motion.mp4")
        do{
        try await MotionExporter().write(scene:scene,to:mp4,format:.mp4){_ in}
        let asset=AVURLAsset(url:mp4),duration=try await asset.load(.duration),tracks=try await asset.loadTracks(withMediaType:.video)
        check(abs(duration.seconds-1)<0.02 && tracks.count==1,"MP4 export has the expected video track and duration")
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);check(reader.startReading(),"MP4 can be decoded by the native video reader")
        var frames=0;while output.copyNextSampleBuffer() != nil{frames += 1}
        check(frames==12,"MP4 exports every frame without gaps")
        }catch{
            let issue=error as NSError
            if issue.domain==AVFoundationErrorDomain && issue.code == -11834{
                print("UNTESTED: MP4 encode/decode · native H.264 encoder unavailable in this execution environment")
                fflush(stdout)
            }else{throw error}
        }
        let preserved=Data("existing export".utf8),cancelURL=root.appendingPathComponent("Cancelled.gif");try preserved.write(to:cancelURL)
        let cancelled=Task{try await MotionExporter().write(scene:scene,to:cancelURL,format:.gif){_ in}}
        cancelled.cancel();do{try await cancelled.value;fatalError("Cancellation should throw")}catch{}
        check(try Data(contentsOf:cancelURL)==preserved,"Cancelled export preserves an existing destination")
        // Bake freezes an evaluated still and retains editable originals.
        editor.painting.layers[1].animation=MotionStack(effects:[boil]);editor.motionPosition=0.2
        editor.bakeMotionFrame()
        for _ in 0..<500{if !editor.freezingLayers{break};try await Task.sleep(for:.milliseconds(10))}
        check(editor.selectedFrozenLayer != nil && !editor.hasMotion,"Bake Current Frame creates a still snapshot")
        editor.unfreezeSelectedLayer()
        check(editor.hasMotion && editor.painting.layers[1].animation?.effects[0]==boil,"Unfreeze restores original animated artwork after baking")
        editor.stopMotion(clear:true)
        editor.motionPlaying=true;editor.motionPreviewEnabled=false;editor.refreshMotionIfNeeded()
        check(!editor.motionPlaying && editor.motionEngine==nil,"Turning preview off stops animation work and releases its worker cache")
        editor.motionPreviewEnabled=true
        try await MotionSurfaceChecks.run(root:root)
        try await FreezeLayerChecks.main()
        print("Motion integration checks complete")
    }
}
