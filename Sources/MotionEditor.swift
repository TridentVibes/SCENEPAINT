import AppKit
import SwiftUI
import ImageIO

@MainActor extension Editor{
    var motionSettings:MotionSettings{painting.motion ?? MotionSettings()}
    func motionStacks(for ink:Ink,in layer:Layer)->[MotionStack]{
        if layer.motionMuted == true{return []}
        var result=[MotionStack]()
        if let stack=layer.animation{result.append(stack)}
        if let id=ink.motionGroup,let group=painting.motionGroups?.first(where:{$0.id==id}){result.append(group.animation)}
        if let stack=ink.animation{result.append(stack)}
        return result
    }
    func layerHasMotion(_ layer:Layer)->Bool{
        guard layer.plane == .artwork,layer.motionMuted != true else{return false}
        if layer.text != nil,layer.animation?.active == true{return true}
        return layer.strokes.contains{$0.eraser != true && motionStacks(for:$0,in:layer).contains{$0.active}}
    }
    var hasMotion:Bool{painting.layers.contains{$0.visible && $0.frozenBy == nil && layerHasMotion($0)}}
    var motionEligible:Bool{
        if motionScope == .group{return motionGroupSelection != nil}
        if motionScope == .strokes{return !motionSelectedLocations.isEmpty}
        guard let i=activeIndex else{return false};let layer=painting.layers[i]
        return layer.plane == .artwork && layer.frozenSources == nil && (layer.text != nil || layer.strokes.contains{$0.eraser != true})
    }
    var motionSelectedLocations:[(Int,Int)]{
        var result=[(Int,Int)]()
        for i in painting.layers.indices where painting.layers[i].plane == .artwork && painting.layers[i].frozenBy == nil{
            for j in painting.layers[i].strokes.indices{
                if let id=painting.layers[i].strokes[j].id,motionSelection.contains(id),painting.layers[i].strokes[j].eraser != true{result.append((i,j))}
            }
        }
        if result.isEmpty,let i=activeIndex,let j=strokeIndex,painting.layers[i].strokes[j].eraser != true{result.append((i,j))}
        return result
    }
    var selectedMotionStack:MotionStack{
        switch motionScope{
        case .layer:return activeIndex.flatMap{painting.layers[$0].animation} ?? MotionStack()
        case .strokes:return motionSelectedLocations.first.flatMap{painting.layers[$0.0].strokes[$0.1].animation} ?? MotionStack()
        case .group:return painting.motionGroups?.first{$0.id==motionGroupSelection}?.animation ?? MotionStack()
        }
    }
    func editMotion(_ key:String,_ update:(inout MotionStack)->Void){
        guard motionEligible else{return}
        inspectorEdit("motion-\(motionScope.rawValue)-\(key)"){
            var stack=selectedMotionStack;update(&stack)
            switch motionScope{
            case .layer:if let i=activeIndex{painting.layers[i].animation=stack}
            case .strokes:for (i,j) in motionSelectedLocations{painting.layers[i].strokes[j].animation=stack}
            case .group:if let i=painting.motionGroups?.firstIndex(where:{$0.id==motionGroupSelection}){painting.motionGroups?[i].animation=stack}
            }
        }
        motionPreparation?.cancel();motionPreparation=nil;motionPreparationID=UUID();motionPreparing=false
        motionPrepared=nil;motionFrame=nil;motionPlaying=true;motionLastTick=Date();refreshMotionIfNeeded()
    }
    func addMotionEffect(_ kind:MotionKind){editMotion("add-\(UUID())"){$0.effects.append(.make(kind))}}
    func updateMotionEffect(_ id:UUID,_ update:(inout MotionEffect)->Void){editMotion(id.uuidString){stack in if let i=stack.effects.firstIndex(where:{$0.id==id}){update(&stack.effects[i])}}}
    func moveMotionEffect(_ id:UUID,by offset:Int){editMotion("reorder"){stack in if let i=stack.effects.firstIndex(where:{$0.id==id}),stack.effects.indices.contains(i+offset){stack.effects.swapAt(i,i+offset)}}}
    func duplicateMotionEffect(_ id:UUID){editMotion("duplicate"){stack in if var copy=stack.effects.first(where:{$0.id==id}){copy.id=UUID();stack.effects.append(copy)}}}
    func removeMotionEffect(_ id:UUID){editMotion("remove"){$0.effects.removeAll{$0.id==id}}}
    func setMotionSettings(_ update:(inout MotionSettings)->Void){
        inspectorEdit("motion-settings"){var value=motionSettings;update(&value);painting.motion=value}
        motionPosition=min(motionPosition,motionSettings.duration);motionPrepared=nil;refreshMotionIfNeeded()
    }
    func toggleMotionStroke(_ index:Int){
        guard let i=activeIndex,painting.layers[i].strokes.indices.contains(index)else{return}
        if painting.layers[i].strokes[index].id == nil{checkpoint();painting.layers[i].strokes[index].id=UUID()}
        guard let id=painting.layers[i].strokes[index].id else{return}
        if motionSelection.contains(id){motionSelection.remove(id)}else{motionSelection.insert(id)}
        selectedStroke=index;if motionScope != .group{motionScope = .strokes}
    }
    func makeMotionGroup(){
        let members=motionSelectedLocations;guard !members.isEmpty else{return};checkpoint()
        let group=MotionGroup(name:"Motion Group \((painting.motionGroups?.count ?? 0)+1)")
        if painting.motionGroups == nil{painting.motionGroups=[]};painting.motionGroups?.append(group)
        for (i,j) in members{painting.layers[i].strokes[j].motionGroup=group.id}
        motionGroupSelection=group.id;motionScope = .group;motionPrepared=nil
    }
    func toggleLayerMotion(_ id:UUID){
        guard let i=painting.layers.firstIndex(where:{$0.id==id})else{return}
        checkpoint();painting.layers[i].motionMuted = painting.layers[i].motionMuted != true
        motionPrepared=nil;refreshMotionIfNeeded()
    }
    func removeMotionGroup(){
        guard let id=motionGroupSelection else{return};checkpoint()
        for i in painting.layers.indices{for j in painting.layers[i].strokes.indices where painting.layers[i].strokes[j].motionGroup==id{painting.layers[i].strokes[j].motionGroup=nil}}
        painting.motionGroups?.removeAll{$0.id==id};motionGroupSelection=nil;motionScope = .strokes;motionPrepared=nil;refreshMotionIfNeeded()
    }
    func assignMotionGroup(){
        guard let id=motionGroupSelection else{return};let members=motionSelectedLocations;guard !members.isEmpty else{return}
        checkpoint();for (i,j) in members{painting.layers[i].strokes[j].motionGroup=id};motionPrepared=nil;refreshMotionIfNeeded()
    }
    func stopMotion(clear:Bool=false){
        // @Published emits even for an equal assignment. The canvas asks for an
        // idle refresh on startup: writing false here used to feed SwiftUI's
        // next update straight back into this method forever.
        let active=motionPlaying || motionPreparing || motionPreparation != nil || motionFrameTask != nil
        if !active && !clear{return}
        if motionPlaying{motionPlaying=false}
        motionPreparation?.cancel();motionPreparation=nil;motionFrameTask?.cancel();motionFrameTask=nil
        motionPreparationID=UUID();motionFrameID=UUID()
        if motionPreparing{motionPreparing=false}
        if clear{
            let hadFrame=motionFrame != nil
            motionPrepared=nil;motionEngine=nil;motionFrame=nil;motionPosition=0
            if !motionSelection.isEmpty{motionSelection=[]}
            if motionGroupSelection != nil{motionGroupSelection=nil}
            if hadFrame{motionFrameDisplay?()}
        }
    }
    func playMotion(){
        guard hasMotion else{status="Select artwork, open Motion, and add an effect.";return}
        if motionPosition>=motionSettings.duration{motionPosition=0}
        motionPreviewEnabled=true;motionPlaying.toggle();motionLastTick=Date();refreshMotionIfNeeded()
    }
    func restartMotion(){motionPosition=0;motionPlaying=hasMotion;motionLastTick=Date();refreshMotionIfNeeded();requestMotionFrame()}
    func seekMotion(_ time:Double){motionPlaying=false;motionPosition=max(0,min(motionSettings.duration,time));refreshMotionIfNeeded();requestMotionFrame()}
    func refreshMotionIfNeeded(){
        guard plane == .artwork,motionPreviewEnabled,hasMotion else{
            if motionFrame != nil{motionFrame=nil;motionFrameDisplay?()};if !hasMotion || plane != .artwork || !motionPreviewEnabled{stopMotion();motionPrepared=nil;motionEngine=nil};return
        }
        guard !analyzing,!buildingGeometry,!filling,pendingInk.isEmpty,!freezingLayers else{return}
        if motionPrepared != nil,motionPreparedRevision==contentRevision,motionPreparedScene==sceneRevision,motionPreparedEpoch==renderEpoch{return}
        guard motionPreparation == nil else{return}
        let id=UUID(),revision=contentRevision,project=sceneRevision
        motionPreparationID=id;motionPreparing=true;motionPreviewNote="Preparing reusable artwork variations…"
        motionPreparation=Task{[weak self] in
            guard let self else{return}
            do{
                // Debounce sliders and typing; obsolete preparation is discarded.
                try await Task.sleep(for:.milliseconds(180))
                let scene=try await self.prepareMotionScene(size:self.motionSettings.previewSize)
                try Task.checkCancellation()
                guard self.motionPreparationID==id,self.contentRevision==revision,self.sceneRevision==project else{
                    if self.motionPreparationID==id{self.motionPreparation=nil;self.motionPreparing=false;self.refreshMotionIfNeeded()};return
                }
                self.motionPrepared=scene;self.motionEngine=MotionEngine(scene);self.motionPreparedRevision=revision;self.motionPreparedScene=project;self.motionPreparedEpoch=self.renderEpoch
                self.motionPreparation=nil;self.motionPreparing=false;self.motionPreviewNote="Cached preview · \(scene.pixelsWide) × \(scene.pixelsHigh)"
                self.requestMotionFrame()
            }catch{
                guard self.motionPreparationID==id else{return};self.motionPreparation=nil;self.motionPreparing=false
                if !(error is CancellationError){self.motionPlaying=false;self.fail(error)}
            }
        }
    }
    func tickMotion(){
        let now=Date(),elapsed=min(0.25,now.timeIntervalSince(motionLastTick));motionLastTick=now
        guard motionPreviewEnabled,plane == .artwork,motionPlaying,!motionPreparing,!motionExporting,!analyzing,!buildingGeometry,!filling,!freezingLayers,pendingInk.isEmpty else{return}
        guard motionPreparedRevision==contentRevision else{refreshMotionIfNeeded();return}
        var next=motionPosition+elapsed
        if next>=motionSettings.duration{
            if motionSettings.loop{next=next.truncatingRemainder(dividingBy:motionSettings.duration)}else{next=motionSettings.duration;motionPlaying=false}
        }
        motionPosition=next
        if now.timeIntervalSince(motionLastRender)>=max(1/Double(motionSettings.fps),motionPreviewInterval){requestMotionFrame()}
    }
    func requestMotionFrame(){
        guard motionPreviewEnabled,plane == .artwork,motionFrameTask==nil,let engine=motionEngine,motionPreparedRevision==contentRevision,motionPreparedScene==sceneRevision else{return}
        motionLastRender=Date()
        let time=motionPosition,id=motionFrameID,start=Date(),revision=contentRevision
        motionFrameTask=Task{[weak self] in
            defer{
                if let self,self.motionFrameID==id{
                    self.motionFrameTask=nil
                    if !self.motionPlaying,self.motionPosition != time,self.motionPreparedRevision==self.contentRevision{self.requestMotionFrame()}
                }
            }
            do{
                let image=try await engine.render(time:time)
                guard let self,self.motionFrameID==id,self.contentRevision==revision else{return}
                self.motionFrame=image;self.motionFrameDisplay?()
                let elapsed=Date().timeIntervalSince(start)
                self.motionPreviewInterval=max(1/30,elapsed*2)

            }catch{if let self,!(error is CancellationError){self.motionPlaying=false;self.fail(error)}}
        }
    }
    func captureMotionRaster(_ layers:[Layer],width:Int,height:Int)->CGImage?{
        guard !layers.isEmpty,let cg=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return nil}
        cg.translateBy(x:0,y:Double(height));cg.scaleBy(x:Double(width)/painting.width,y:-Double(height)/painting.height)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
        let interactive=interactiveRender;interactiveRender=false
        Renderer.draw(self,cacheLayers:true,quality:1,layers:layers)
        interactiveRender=interactive;NSGraphicsContext.restoreGraphicsState();return cg.makeImage()
    }
    func prepareMotionScene(size:Int)async throws->MotionScene{
        let revision=contentRevision,project=sceneRevision,settings=motionSettings
        let ratio=min(1,Double(max(128,min(2048,size)))/max(painting.width,painting.height))
        // Even dimensions work for H.264 as well as GIF.
        let w=max(2,Int(painting.width*ratio)/2*2),h=max(2,Int(painting.height*ratio)/2*2)
        var scene=MotionScene(width:painting.width,height:painting.height,pixelsWide:w,pixelsHigh:h,settings:settings,layers:[])
        var staticRun=[Layer](),meshes=[String:SurfaceMesh]()
        func flush(){if !staticRun.isEmpty{let base=captureMotionRaster(staticRun,width:w,height:h);scene.layers.append(MotionLayerPacket(layer:Layer(name:"Static cache"),base:base,strokes:[],light:nil));staticRun=[]}}
        for layer in displayedLayers where layer.visible{
            try Task.checkCancellation()
            guard revision==contentRevision,project==sceneRevision else{throw CancellationError()}
            if !layerHasMotion(layer){staticRun.append(layer);continue}
            flush()
            var baseLayer=layer;baseLayer.strokes=[];baseLayer.opacity=1
            let base=(layer.imageAsset != nil || layer.text != nil) ? captureMotionRaster([baseLayer],width:w,height:h):nil
            var light:MotionLight?
            if let (ref,settings)=Relighter.light(for:layer,editor:self),let data=sceneData(ref){
                let values=relightCache.gains(data,reference:ref,settings:settings,mesh:ref.geometryAsset.flatMap{MeshPainter.mesh($0,editor:self)})
                light=MotionLight(values:values,width:data.width,height:data.height,frame:ref.frame)
            }
            var packet=MotionLayerPacket(layer:layer,base:base,strokes:[],light:light)
            if layer.text != nil,let stack=layer.animation{packet.textStacks=[stack]}
            if let ref=layer.surface?.reference{
                packet.mask=layerMask(ref);packet.maskFrame=ref.frame;packet.outline=ref.outline.map{MotionGeometry.outline($0,frame:ref.frame)}
            }
            for effect in packet.textStacks.flatMap(\.effects) where effect.kind == .emission{
                if let asset=effect.spillMaskAsset,let frame=effect.spillMaskFrame ?? packet.maskFrame,let url=analysisURL(asset),let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil){
                    scene.spillMasks[effect.id]=MotionSpillMask(image:image,frame:frame)
                }else if let mask=packet.mask,let frame=packet.maskFrame{scene.spillMasks[effect.id]=MotionSpillMask(image:mask,frame:frame)}
            }
            for (index,stored) in layer.strokes.enumerated(){
                try Task.checkCancellation()
                var ink=stored
                if ink.id == nil{ink.id=UUID()}
                let stacks=ink.eraser == true ? []:motionStacks(for:ink,in:layer)
                var material:CGImage?,mesh:SurfaceMesh?,target:StrokeSurfaceTarget?
                if let ref=ink.surface?.reference{
                    if ink.topography?.engine == 2,let asset=ink.meshStroke?.geometryAsset ?? ref.geometryAsset{
                        if let cached=meshes[asset]{mesh=cached}else{
                            let url=root.appendingPathComponent("Analysis").appendingPathComponent(asset),data=sceneData(ref)
                            mesh=try await Task.detached(priority:.utility){let m=try SurfaceMesh.read(url);if let data{m.prepareDepthEdges(data,key:ref.analysisAsset)};return m}.value
                            meshes[asset]=mesh
                        }
                        target=MeshPainter.target(ink,editor:self)
                    }
                }
                if ink.surface != nil{material=try await prepareMotionMaterial(ink,mesh:mesh)}
                var image:CGImage?
                if let asset=ink.imageAsset{image=self.image(for:Layer(id:ink.id!,name:"Motion bucket \(index)",imageAsset:asset))?.cgImage(forProposedRect:nil,context:nil,hints:nil)}
                var spillMask:CGImage?
                for effect in stacks.flatMap(\.effects) where effect.kind == .emission{
                    if scene.spillMasks[effect.id]==nil,let asset=effect.spillMaskAsset,let frame=effect.spillMaskFrame ?? ink.surface?.reference.frame,let url=analysisURL(asset),let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil){scene.spillMasks[effect.id]=MotionSpillMask(image:image,frame:frame)}
                }
                if let asset=stacks.flatMap(\.effects).first(where:{$0.kind == .emission && $0.spillMaskAsset != nil})?.spillMaskAsset,
                   let url=analysisURL(asset),let source=CGImageSourceCreateWithURL(url as CFURL,nil){spillMask=CGImageSourceCreateImageAtIndex(source,0,nil)}
                packet.strokes.append(MotionStrokePacket(ink:ink,stacks:stacks,material:material,mesh:mesh,target:target,image:image,spillMask:spillMask))
                await Task.yield()
            }
            // Batch contiguous artwork with the same effect stack into one cached
            // animation object. Stroke count does not become playback job count.
            for stroke in packet.strokes{
                let eraser=stroke.ink.eraser == true
                if let last=packet.objects.indices.last,packet.objects[last].stacks==stroke.stacks,packet.objects[last].eraser==eraser{
                    packet.objects[last].strokes.append(stroke)
                }else{packet.objects.append(MotionObjectPacket(strokes:[stroke],stacks:stroke.stacks,eraser:eraser))}
            }
            scene.layers.append(packet);await Task.yield()
        }
        flush();try Task.checkCancellation()
        guard revision==contentRevision,project==sceneRevision else{throw CancellationError()};return scene
    }
    func prepareMotionMaterial(_ ink:Ink,mesh prepared:SurfaceMesh?)async throws->CGImage?{
        guard let binding=ink.surface,let key=surfaceMaterialKey(ink),let data=sceneData(binding.reference)else{return nil}
        if let cached=sceneCache.strokes.object(forKey:key)?.cgImage(forProposedRect:nil,context:nil,hints:nil){return cached}
        let selected=maskData(binding.reference),location=root
        var foreground:[UInt8]?
        if let asset=binding.reference.occlusionAsset{var ref=binding.reference;ref.maskAsset=asset;foreground=maskData(ref)}
        let photo=painting.layers.first{$0.id==binding.reference.sourceID}.flatMap{self.image(for:$0)}?.cgImage(forProposedRect:nil,context:nil,hints:nil)
        let image=try await Task.detached(priority:.utility){()->CGImage? in
            try Task.checkCancellation()
            var mask:[UInt8]
            if ink.photoShading == true && binding.reference.maskAsset == nil || (ink.topography?.engine == 2 && ink.topography?.respectRegion != true && binding.reference.automaticTarget != true){mask=[UInt8](repeating:255,count:data.count)}
            else{
                guard let selected else{return nil}
                if ink.photoShading != true,ink.topography == nil,binding.reference.outline == nil,let asset=binding.reference.geometryAsset{
                    let mesh:SurfaceMesh
                    if let prepared{mesh=prepared}else{mesh=try SurfaceMesh.read(location.appendingPathComponent("Analysis").appendingPathComponent(asset));mesh.prepareDepthEdges(data,key:binding.reference.analysisAsset)}
                    var coarse=SurfaceVisibility.mask(ink,mesh:mesh,selected:selected,width:data.width,height:data.height)
                    if let foreground{for i in coarse.indices{let visible=255-Int(foreground[i]);let product=Int(coarse[i])*visible;coarse[i]=UInt8(product/255)}}
                    let f=binding.reference.frame,focus=ink.points.map{CGPoint(x:($0.x-f.x)/f.width*Double(data.width),y:($0.y-f.y)/f.height*Double(data.height))}
                    mask=EdgeMatte.refine(coarse,rgb:data.rgb,width:data.width,height:data.height,focus:focus,brushRadius:ink.width*max(Double(data.width)/f.width,Double(data.height)/f.height)*0.5)
                    if let foreground{for i in mask.indices{mask[i]=min(mask[i],255-foreground[i])}}
                }else{mask=selected}
            }
            if ink.invertSelection == true,binding.reference.maskAsset != nil{mask=mask.map{255-$0}}
            return photo.flatMap{SurfacePaint.photoMaterial(ink,binding:binding,scene:data,mask:mask,photo:$0)} ?? SurfacePaint.material(ink,binding:binding,scene:data,mask:mask)
        }.value
        if let image{sceneCache.strokes.setObject(NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)),forKey:key,cost:image.bytesPerRow*image.height)}
        return image
    }
    func useSurfaceForSpill(_ effectID:UUID){
        guard let ref=painting.scene,var image=layerMask(ref)else{status="Select a surface first.";return}
        if let outline=ref.outline,let cg=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue){
            cg.translateBy(x:0,y:Double(image.height));cg.scaleBy(x:Double(image.width)/ref.frame.width,y:-Double(image.height)/ref.frame.height)
            cg.translateBy(x:-ref.frame.x,y:-ref.frame.y);cg.addPath(MotionGeometry.outline(outline,frame:ref.frame));cg.setFillColor(CGColor(gray:1,alpha:1));cg.fillPath(using:.evenOdd)
            if let outlined=cg.makeImage(){image=outlined}
        }
        do{let asset=UUID().uuidString+".png";try SceneWorker.png(image,to:root.appendingPathComponent("Analysis").appendingPathComponent(asset));updateMotionEffect(effectID){$0.spillMaskAsset=asset;$0.spillMaskFrame=ref.frame;$0.constrainSpill=true}}
        catch{fail(error)}
    }
}
