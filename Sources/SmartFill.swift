import AppKit

enum SmartFillRaster{
    static func mask(image:CGImage,seed:Dot,tolerance:Double)->(mask:[UInt8],width:Int,height:Int)?{
        let ratio=min(1,1024/Double(max(image.width,image.height))),w=max(1,Int(Double(image.width)*ratio)),h=max(1,Int(Double(image.height)*ratio))
        guard seed.x>=0,seed.x<1,seed.y>=0,seed.y<1,let cg=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let data=cg.data?.assumingMemoryBound(to:UInt8.self)else{return nil}
        cg.interpolationQuality = .high;cg.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        // CGContext memory and CGImage source use top-left row order when read back.
        let start=min(h-1,Int(seed.y*Double(h)))*w+min(w-1,Int(seed.x*Double(w)))
        let target=(0..<4).map{Double(data[start*4+$0])/255},threshold=max(0.005,tolerance)*max(0.005,tolerance)*3
        var visited=[UInt8](repeating:0,count:w*h),mask=visited,queue=[Int]();queue.reserveCapacity(w*h/4);queue.append(start);visited[start]=1
        var head=0
        while head<queue.count{
            let i=queue[head];head += 1
            let alpha=Double(data[i*4+3])/255
            var delta=pow(alpha-target[3],2)
            if alpha>0.02 || target[3]>0.02{for c in 0..<3{delta += pow(Double(data[i*4+c])/255-target[c],2)}}
            guard delta<=threshold else{continue};mask[i]=255
            let x=i%w,y=i/w
            for n in [x>0 ? i-1:-1,x+1<w ? i+1:-1,y>0 ? i-w:-1,y+1<h ? i+w:-1] where n>=0 && visited[n]==0{visited[n]=1;queue.append(n)}
        }
        return(mask,w,h)
    }
    static func photoImage(mask:[UInt8],width:Int,height:Int,color:[Double],photo:CGImage,shading:Double)->CGImage?{
        let count=width*height
        let scene=SceneData(width:width,height:height,depth:[Float](repeating:0.5,count:count),person:[UInt8](repeating:0,count:count),rgb:[UInt8](repeating:255,count:count*3),elapsed:0,segmentationAvailable:false)
        let ref=SceneReference(sourceID:UUID(),analysisAsset:"",maskAsset:nil,frame:SceneFrame(x:0,y:0,width:Double(photo.width),height:Double(photo.height)),seed:nil)
        let ink=Ink(points:[],width:1,red:color[0],green:color[1],blue:color[2])
        return SurfacePaint.photoMaterial(ink,binding:SurfaceBinding(reference:ref,shading:shading,conform:0),scene:scene,mask:mask,photo:photo)
    }
    static func image(mask:[UInt8],width:Int,height:Int,color:[Double],opacity:Double)->CGImage?{
        var rgba=[UInt8](repeating:0,count:width*height*4)
        for i in mask.indices{let a=Double(mask[i])*opacity;for c in 0..<3{rgba[i*4+c]=UInt8(clamping:Int(color[c]*a))};rgba[i*4+3]=UInt8(clamping:Int(a))}
        return SceneWorker.raster(rgba,width:width,height:height)
    }
}
@MainActor extension Editor{
    func ensureAlbedoMap(){
        guard let ref=painting.scene,!painting.layers.contains(where:{$0.plane == .albedo && ($0.mapSourceID ?? $0.generatedFor)==ref.sourceID}),let scene=sceneData(ref)else{return}
        let revision=sceneRevision,location=root
        Task{
            do{
                let name=UUID().uuidString+".png"
                try await Task.detached(priority:.utility){
                    guard let image=SceneWorker.raster(AlbedoEstimate.rgba(scene),width:scene.width,height:scene.height)else{throw SceneError.message("Cannot estimate albedo.")}
                    try SceneWorker.png(image,to:location.appendingPathComponent("Assets").appendingPathComponent(name))
                }.value
                guard sceneRevision==revision,!painting.layers.contains(where:{$0.plane == .albedo && ($0.mapSourceID ?? $0.generatedFor)==ref.sourceID})else{return}
                let f=ref.frame
                painting.layers.append(Layer(name:"Estimated albedo · lighting reduced",plane:.albedo,x:f.x,y:f.y,width:f.width,height:f.height,imageAsset:name,generatedFor:ref.sourceID))
                dirty=true;status="Albedo estimate ready · Broad lighting reduced; fine texture retained"
            }catch{fail(error)}
        }
    }
    func smartFill(at point:Dot){
        guard !filling else{return};if preserveShading,plane == .artwork,isPhotoFrozen(activePhotoID){status="Unfreeze to edit material color, or turn off Keep photo shading for an overlay fill.";return};aiStarted=Date();let location=root,revision=sceneRevision,targetPlane=plane,source=activePhotoID,targetLayer=selected,materialMode=false,outside=paintArea == .outside
        let color=NSColor(self.color).usingColorSpace(.deviceRGB) ?? .orange
        let rgb=[Double(color.redComponent),Double(color.greenComponent),Double(color.blueComponent)],opacity=brushOpacity,shading=shadeStrength,tolerance=bucketTolerance
        if bucketUseAI,plane == .artwork,let ref=painting.scene,ref.frame.contains(point),let selection=beginSurfaceSelection(at:point){
            filling=true;status="Finding a region for Smart Fill…"
            Task{
                defer{filling=false}
                guard let reference=await selection.value,sceneRevision==revision,plane==targetPlane else{return}
                let f=reference.frame
                var ink=Ink(opacity:opacity,points:[Dot(x:f.x,y:f.y),Dot(x:f.x+f.width,y:f.y),Dot(x:f.x+f.width,y:f.y+f.height),Dot(x:f.x,y:f.y+f.height)],width:1,red:rgb[0],green:rgb[1],blue:rgb[2])
                ink.invertSelection=outside;ink.materialPaint=materialMode;ink.closed=true;ink.filled=true;ink.photoShading=true;ink.surface=SurfaceBinding(reference:reference,shading:shading,conform:0)
                await prepareSurfaceMaterial(ink)
                guard sceneRevision==revision,plane==targetPlane else{return}
                commitCapturedInk(ink,reference:reference,targetPlane:targetPlane,targetLayerID:targetLayer);status="Smart Fill applied to the AI region · Undo restores the previous paint"
            };return
        }
        // Use the current composite, including line art and transparent regions.
        guard let image=canvasSnapshot,canvasSnapshotPlane==plane else{status="Let the canvas finish drawing, then click Smart Fill again.";return}
        let width=painting.width,height=painting.height
        let photoFill=targetPlane == .artwork && painting.scene?.frame.contains(point) == true
        filling=true;status="Filling the connected color region…"
        Task{
            defer{filling=false}
            do{
                let name=UUID().uuidString+".png"
                try await Task.detached(priority:.userInitiated){
                    guard let result=SmartFillRaster.mask(image:image,seed:Dot(x:point.x/width,y:point.y/height),tolerance:tolerance)else{throw SceneError.message("No fillable region at that point.")}
                    let fill=photoFill ? SmartFillRaster.photoImage(mask:result.mask,width:result.width,height:result.height,color:rgb,photo:image,shading:shading):SmartFillRaster.image(mask:result.mask,width:result.width,height:result.height,color:rgb,opacity:1)
                    guard let fill else{throw SceneError.message("Cannot render the bucket fill.")}
                    try SceneWorker.png(fill,to:location.appendingPathComponent("Assets").appendingPathComponent(name))
                }.value
                guard sceneRevision==revision,plane==targetPlane else{return}
                var ink=Ink(opacity:opacity,points:[Dot(x:0,y:0),Dot(x:width,y:height)],width:1,red:rgb[0],green:rgb[1],blue:rgb[2])
                ink.imageAsset=name;ink.imageFrame=SceneFrame(x:0,y:0,width:width,height:height)
                commitCapturedInk(ink,reference:nil,targetPlane:targetPlane,targetLayerID:targetLayer)
                status="Connected region filled · Adjust tolerance for smaller or larger regions"
            }catch{fail(error)}
        }
    }
}
