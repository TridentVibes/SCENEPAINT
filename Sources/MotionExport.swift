import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum MotionExportFormat:String{case gif,mp4}

// Streams frames to disk. A sibling staging file protects an existing export
// until every frame has encoded successfully; cancellation removes the stage.
actor MotionExporter{
    func write(scene:MotionScene,to destination:URL,format:MotionExportFormat,progress:@Sendable (Double)async->Void)async throws{
        let stage=destination.deletingLastPathComponent().appendingPathComponent(".ScenePaint-motion-"+UUID().uuidString+"."+format.rawValue)
        defer{try? FileManager.default.removeItem(at:stage)}
        let engine=MotionEngine(scene),count=scene.settings.frameCount,fps=max(6,min(30,scene.settings.fps))
        switch format{
        case .gif:
            guard let encoder=CGImageDestinationCreateWithURL(stage as CFURL,UTType.gif.identifier as CFString,count,nil)else{throw SceneError.message("Cannot create GIF at this location.")}
            if scene.settings.loop{CGImageDestinationSetProperties(encoder,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)}
            for frame in 0..<count{
                try Task.checkCancellation()
                let image=try await engine.render(time:Double(frame)/Double(fps))
                autoreleasepool{
                    // GIF stores centiseconds. Distribute rounding across the
                    // cycle so 24/30 FPS do not shorten the exported loop.
                    let start=(Double(frame)*100/Double(fps)).rounded()
                    let end=(Double(frame+1)*100/Double(fps)).rounded()
                    let delay=max(0.01,(end-start)/100)
                    CGImageDestinationAddImage(encoder,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay,kCGImagePropertyGIFUnclampedDelayTime:delay],kCGImageDestinationLossyCompressionQuality:scene.settings.quality] as CFDictionary)
                }
                await progress(Double(frame+1)/Double(count)*0.95)
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(encoder)else{throw SceneError.message("GIF encoding failed. Check free disk space.")}
        case .mp4:
            let writer=try AVAssetWriter(outputURL:stage,fileType:.mp4)
            let bitrate=Int(Double(scene.pixelsWide*scene.pixelsHigh*fps)*(0.04+scene.settings.quality*0.16))
            let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:scene.pixelsWide,AVVideoHeightKey:scene.pixelsHigh,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:bitrate,AVVideoMaxKeyFrameIntervalKey:fps]])
            input.expectsMediaDataInRealTime=false
            let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:scene.pixelsWide,kCVPixelBufferHeightKey as String:scene.pixelsHigh,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
            guard writer.canAdd(input)else{throw SceneError.message("The system H.264 encoder cannot accept these settings.")};writer.add(input)
            guard writer.startWriting()else{throw writer.error ?? SceneError.message("Cannot start MP4 encoder.")}
            writer.startSession(atSourceTime:.zero)
            do{
                for frame in 0..<count{
                    try Task.checkCancellation()
                    let image=try await engine.render(time:Double(frame)/Double(fps))
                    let deadline=Date().addingTimeInterval(30)
                    while !input.isReadyForMoreMediaData{
                        try Task.checkCancellation()
                        guard writer.status == .writing,Date()<deadline else{throw writer.error ?? SceneError.message("MP4 encoder stopped responding.")}
                        try await Task.sleep(for:.milliseconds(5))
                    }
                    try autoreleasepool{
                        var optional:CVPixelBuffer?
                        guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&optional)==kCVReturnSuccess,let buffer=optional else{throw SceneError.message("Cannot allocate a video frame.")}
                        CVPixelBufferLockBaseAddress(buffer,[]);defer{CVPixelBufferUnlockBaseAddress(buffer,[])}
                        guard let cg=CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:scene.pixelsWide,height:scene.pixelsHigh,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue)else{throw SceneError.message("Cannot draw video frame.")}
                        cg.setFillColor(CGColor(gray:0,alpha:1));cg.fill(CGRect(x:0,y:0,width:scene.pixelsWide,height:scene.pixelsHigh))
                        cg.draw(image,in:CGRect(x:0,y:0,width:scene.pixelsWide,height:scene.pixelsHigh))
                        guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:Int32(fps)))else{throw writer.error ?? SceneError.message("MP4 frame encoding failed.")}
                    }
                    await progress(Double(frame+1)/Double(count)*0.95)
                }
                input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:Int64(count),timescale:Int32(fps)))
                await writer.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else{throw writer.error ?? SceneError.message("MP4 could not be finalized.")}
            }catch{writer.cancelWriting();throw error}
        }
        try Task.checkCancellation()
        let result=stage.path.withCString{from in destination.path.withCString{to in Darwin.rename(from,to)}}
        guard result==0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        await progress(1)
    }
}

@MainActor extension Editor{
    func exportMotion(_ format:MotionExportFormat){
        guard !motionExporting,!freezingLayers,pendingInk.isEmpty,selectionCount==0,!filling,!analyzing,!buildingGeometry else{status="Finish pending artwork and AI work before exporting Motion.";return}
        let panel=NSSavePanel();panel.title="Export ScenePaint Motion";panel.allowedContentTypes=[format == .gif ? .gif:.mpeg4Movie]
        panel.nameFieldStringValue="ScenePaint Motion."+format.rawValue;panel.directoryURL=root.appendingPathComponent("Projects")
        guard panel.runModal() == .OK,let url=panel.url else{return}
        motionPlaying=false;motionExporting=true;motionProgress=0;status="Preparing Motion export…"
        motionExportTask=Task{
            defer{motionExporting=false;motionExportTask=nil}
            do{
                let scene=try await prepareMotionScene(size:motionSettings.outputSize)
                try await MotionExporter().write(scene:scene,to:url,format:format){[self] value in
                    await MainActor.run{self.motionProgress=value;self.status="Exporting \(format.rawValue.uppercased()) · \(Int(value*100))%"}
                }
                status="Exported \(url.lastPathComponent) · \(scene.settings.frameCount) frames"
            }catch{
                if error is CancellationError{status="Motion export cancelled · Existing file preserved"}
                else if (error as NSError).domain==AVFoundationErrorDomain && (error as NSError).code == -11834{status="MP4 export could not start the macOS H.264 encoder. Try GIF export; the existing file was preserved."}
                else{fail(error)}
            }
        }
    }
    func bakeMotionFrame(){
        guard hasMotion,!motionExporting,!freezingLayers,pendingInk.isEmpty,selectionCount==0,!analyzing,!buildingGeometry,!filling else{status="Finish pending work before baking.";return}
        motionPlaying=false;let time=motionPosition,revision=contentRevision,project=sceneRevision,location=root
        freezingLayers=true;status="Baking the current Motion frame · Originals retained"
        Task{
            defer{freezingLayers=false}
            let asset=UUID().uuidString+".png",url=location.appendingPathComponent("Assets").appendingPathComponent(asset)
            do{
                let scene=try await prepareMotionScene(size:2048),image=try await MotionEngine(scene).render(time:time)
                try await Task.detached(priority:.utility){try SceneWorker.png(image,to:url)}.value
                guard revision==contentRevision,project==sceneRevision,location==root else{try? FileManager.default.removeItem(at:url);status="Artwork changed; bake cancelled.";return}
                let sources=displayedLayers.filter{$0.visible}.map(\.id),ids=Set(sources)
                let baked=Layer(name:String(format:"Baked · %.2f s",time),width:painting.width,height:painting.height,imageAsset:asset,frozenSources:sources)
                checkpoint();for i in painting.layers.indices where ids.contains(painting.layers[i].id){painting.layers[i].frozenBy=baked.id}
                painting.layers.append(baked);selected=baked.id;selectedStroke=nil;stopMotion(clear:true)
                status="Baked current frame · Unfreeze restores the editable animation"
            }catch{try? FileManager.default.removeItem(at:url);fail(error)}
        }
    }
    func freezeMotionStaticLayers(){
        guard !freezingLayers,pendingInk.isEmpty,selectionCount==0,!analyzing,!buildingGeometry,!filling else{status="Finish pending work before freezing static layers.";return}
        motionPlaying=false;freezingLayers=true
        let revision=contentRevision,project=sceneRevision,location=root,layers=displayedLayers
        var runs=[[Layer]](),run=[Layer]()
        for layer in layers{
            if layerHasMotion(layer) || !layer.visible{if run.count>1{runs.append(run)};run=[]}
            else{run.append(layer)}
        }
        if run.count>1{runs.append(run)}
        guard !runs.isEmpty else{freezingLayers=false;status="Static layers are already separate · Use Bake Current Frame to flatten animation";return}
        status="Freezing static layers · Animated artwork stays live"
        Task{
            defer{freezingLayers=false}
            var snapshots=[Layer](),written=[URL]()
            do{
                let ratio=min(1,2048/max(painting.width,painting.height)),w=max(1,Int(painting.width*ratio)),h=max(1,Int(painting.height*ratio))
                for run in runs{
                    guard let image=captureMotionRaster(run,width:w,height:h)else{throw SceneError.message("Cannot freeze static layers.")}
                    let asset=UUID().uuidString+".png",url=location.appendingPathComponent("Assets").appendingPathComponent(asset)
                    written.append(url);try await Task.detached(priority:.utility){try SceneWorker.png(image,to:url)}.value
                    snapshots.append(Layer(name:"Frozen static · \(run.count) layers",width:painting.width,height:painting.height,imageAsset:asset,frozenSources:run.map(\.id)))
                }
                guard revision==contentRevision,project==sceneRevision,location==root else{throw SceneError.message("Artwork changed; freeze cancelled.")}
                var updated=painting
                for snapshot in snapshots{
                    let ids=Set(snapshot.frozenSources ?? []),last=updated.layers.lastIndex{ids.contains($0.id)}!
                    for i in updated.layers.indices where ids.contains(updated.layers[i].id){updated.layers[i].frozenBy=snapshot.id}
                    updated.layers.insert(snapshot,at:last+1)
                }
                checkpoint();painting=updated;selected=snapshots.last?.id;motionPrepared=nil;status="Static layers frozen · Animation remains editable"
            }catch{for url in written{try? FileManager.default.removeItem(at:url)};fail(error)}
        }
    }
}
