import AppKit

struct MaterialInput:Equatable{
    let photo:UUID;let source:String;let frame:SceneFrame;let analysis:String
    let maps:[Layer];let epochs:[Int];let width:Int;let height:Int
}
final class MaterialResult:NSObject{
    let input:MaterialInput;let image:CGImage
    init(_ input:MaterialInput,_ image:CGImage){self.input=input;self.image=image}
}
final class MaterialBases:NSObject{
    let albedo:CGImage;let shading:CGImage
    init(_ albedo:CGImage,_ shading:CGImage){self.albedo=albedo;self.shading=shading}
}
@MainActor final class MaterialCache{
    let images=NSCache<NSString,MaterialResult>()
    let bases=NSCache<NSString,MaterialBases>()
    var jobs:[UUID:Task<Void,Never>]=[:]
    var requested:[UUID:MaterialInput]=[:]
    init(){images.totalCostLimit=64*1024*1024;bases.totalCostLimit=12*1024*1024}
}

/// Replaces reflectance relative to an immutable baseline, then modulates its
/// source illumination with the editable shading map. Light-panel gains follow.
/// The neutral map state is an identity transform, so analysis never recolors a photo.
enum MaterialMath{
    static func compose(original:CGImage,baselineAlbedo:CGImage,editedAlbedo:CGImage,baselineShading:CGImage,editedShading:CGImage)->CGImage?{
        let w=original.width,h=original.height
        func bitmap(_ image:CGImage)->CGContext?{
            guard let cg=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return nil}
            cg.interpolationQuality = .high;cg.draw(image,in:CGRect(x:0,y:0,width:w,height:h));return cg
        }
        guard let output=bitmap(original),let ba=bitmap(baselineAlbedo),let ea=bitmap(editedAlbedo),let bs=bitmap(baselineShading),let es=bitmap(editedShading),
              let dst=output.data?.assumingMemoryBound(to:UInt8.self),let a0=ba.data?.assumingMemoryBound(to:UInt8.self),let a=ea.data?.assumingMemoryBound(to:UInt8.self),let s0=bs.data?.assumingMemoryBound(to:UInt8.self),let s=es.data?.assumingMemoryBound(to:UInt8.self)else{return nil}
        let linear=RelightMath.linear,encoded=RelightMath.encoded
        for y in 0..<h{
            if y%16==0 && Task.isCancelled{return nil}
            for x in 0..<w{
                let i=(y*w+x)*4,alpha=Float(dst[i+3])/255
                guard alpha>0 else{continue}
                if (0..<3).allSatisfy({a[i+$0]==a0[i+$0] && s[i+$0]==s0[i+$0]}){continue}
                let baseLight=0.2126*linear[Int(s0[i])]+0.7152*linear[Int(s0[i+1])]+0.0722*linear[Int(s0[i+2])]
                let editedLight=0.2126*linear[Int(s[i])]+0.7152*linear[Int(s[i+1])]+0.0722*linear[Int(s[i+2])]
                let lightRatio:Float = editedLight == baseLight ? 1:max(0,min(8,editedLight/max(0.002,baseLight)))
                for c in 0..<3{
                    let source=min(255,Int((Float(dst[i+c])/alpha).rounded()))
                    let sourceValue=linear[source],baseValue=linear[Int(a0[i+c])],newValue=linear[Int(a[i+c])]
                    // An additive regularizer keeps very dark materials editable.
                    // Equal baseline/edit pixels reproduce source values exactly.
                    let materialRatio=(newValue+0.003)/(baseValue+0.003)
                    let value=max(0,min(1,((sourceValue+0.003)*materialRatio-0.003)*lightRatio))
                    let index=max(0,min(4096,Int((value*4096).rounded())))
                    dst[i+c]=UInt8(clamping:Int((Float(encoded[index])*alpha).rounded()))
                }
            }
        }
        return output.makeImage()
    }
}

@MainActor enum MaterialPipeline{
    static func maps(for photo:Layer,editor:Editor)->[Layer]{
        guard photo.plane == .artwork,photo.imageAsset != nil,photo.materialWorkflow != false else{return []}
        return editor.painting.layers.filter{layer in
            guard layer.plane == .albedo || layer.plane == .shading else{return false}
            let owner=layer.mapSourceID ?? layer.generatedFor
            return owner==photo.id || (owner==nil && editor.activePhotoID==photo.id)
        }
    }
    static func hasEdits(_ maps:[Layer],photo:Layer)->Bool{
        maps.contains{layer in
            guard layer.visible,layer.opacity>0 else{return false}
            return !layer.strokes.isEmpty || layer.text != nil || (layer.imageAsset != nil && layer.generatedFor != photo.id)
        }
    }
    static func bases(scene:SceneData,reference:SceneReference,editor:Editor)->MaterialBases?{
        let key=reference.analysisAsset as NSString
        if let base=editor.materialCache.bases.object(forKey:key){return base}
        guard let albedo=SceneWorker.raster(scene.rgbaMap(.albedo),width:scene.width,height:scene.height),let shading=SceneWorker.raster(scene.rgbaMap(.shading),width:scene.width,height:scene.height)else{return nil}
        let base=MaterialBases(albedo,shading);editor.materialCache.bases.setObject(base,forKey:key,cost:scene.count*8);return base
    }
    static func flattened(_ plane:Plane,maps:[Layer],base:CGImage,frame:SceneFrame,editor:Editor)->CGImage?{
        guard let cg=CGContext(data:nil,width:base.width,height:base.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return nil}
        cg.draw(base,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
        cg.translateBy(x:0,y:Double(cg.height));cg.scaleBy(x:Double(cg.width)/frame.width,y:-Double(cg.height)/frame.height);cg.translateBy(x:-frame.x,y:-frame.y)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
        Renderer.draw(editor,cacheLayers:true,quality:1,layers:maps.filter{$0.plane==plane})
        NSGraphicsContext.restoreGraphicsState();return cg.makeImage()
    }
    static func image(_ original:CGImage,photo:Layer,editor:Editor)->CGImage{
        guard photo.plane == .artwork,photo.materialWorkflow != false,let ref=Relighter.reference(for:photo,editor:editor)else{return original}
        let maps=maps(for:photo,editor:editor)
        guard hasEdits(maps,photo:photo)else{editor.materialCache.jobs[photo.id]?.cancel();editor.materialCache.requested[photo.id]=nil;editor.materialCache.jobs[photo.id]=nil;return original}
        let key=MaterialInput(photo:photo.id,source:photo.imageAsset ?? "",frame:ref.frame,analysis:ref.analysisAsset,maps:maps,epochs:maps.map{editor.layerRenderEpochs[$0.id] ?? 0},width:original.width,height:original.height)
        let cacheKey=photo.id.uuidString as NSString
        let previous=editor.materialCache.images.object(forKey:cacheKey)
        if let previous,previous.input==key{return previous.image}
        if editor.interactiveRender && editor.materialCache.requested[photo.id]==key{return previous?.image ?? original}
        if !editor.interactiveRender{editor.materialCache.jobs[photo.id]?.cancel();editor.materialCache.jobs[photo.id]=nil;editor.materialCache.requested[photo.id]=nil}
        guard let scene=editor.sceneData(ref),let base=bases(scene:scene,reference:ref,editor:editor),let albedo=flattened(.albedo,maps:maps,base:base.albedo,frame:ref.frame,editor:editor),let shading=flattened(.shading,maps:maps,base:base.shading,frame:ref.frame,editor:editor)else{return original}
        if editor.interactiveRender{
            let revision=editor.sceneRevision
            editor.materialCache.jobs[photo.id]?.cancel();editor.materialCache.requested[photo.id]=key
            editor.materialCache.jobs[photo.id]=Task{
                if editor.materialUpdates==0 && !editor.analyzing && !editor.buildingGeometry && !editor.selectingSurface && !editor.filling{editor.aiStarted=Date()}
                editor.materialUpdates += 1
                defer{editor.materialUpdates -= 1}
                defer{if editor.materialCache.requested[photo.id]==key{editor.materialCache.requested[photo.id]=nil;editor.materialCache.jobs[photo.id]=nil}}
                do{try await Task.sleep(for:.milliseconds(75))}catch{return}
                let worker=Task.detached(priority:.userInitiated){MaterialMath.compose(original:original,baselineAlbedo:base.albedo,editedAlbedo:albedo,baselineShading:base.shading,editedShading:shading)}
                let result=await withTaskCancellationHandler{await worker.value}onCancel:{worker.cancel()}
                guard !Task.isCancelled,editor.materialCache.requested[photo.id]==key,editor.sceneRevision==revision,let result else{return}
                editor.materialCache.images.setObject(MaterialResult(key,result),forKey:cacheKey,cost:result.bytesPerRow*result.height)
                editor.materialCache.requested[photo.id]=nil;editor.materialCache.jobs[photo.id]=nil
                editor.layerRenderEpochs[photo.id,default:0] += 1;editor.renderEpoch += 1
            }
            return previous?.image ?? original
        }
        guard let result=MaterialMath.compose(original:original,baselineAlbedo:base.albedo,editedAlbedo:albedo,baselineShading:base.shading,editedShading:shading)else{return original}
        editor.materialCache.images.setObject(MaterialResult(key,result),forKey:cacheKey,cost:result.bytesPerRow*result.height)
        return result
    }
}

@MainActor extension Editor{
    var materialDependencies:[Layer]{
        guard plane == .artwork else{return []}
        if let cached=materialDependencyCache,cached.revision==contentRevision{return cached.layers}
        let layers=painting.layers.filter{$0.plane == .albedo || $0.plane == .shading};materialDependencyCache=(contentRevision,layers);return layers
    }
    var usesMaterialMaps:Bool{relightPhotoIndex.map{painting.layers[$0].materialWorkflow != false} ?? false}
    func setMaterialWorkflow(_ enabled:Bool){guard let i=relightPhotoIndex else{return};inspectorEdit("materials"){painting.layers[i].materialWorkflow=enabled}}
    func editMaterialMap(_ target:Plane){
        guard canRelight else{status="Analyze a photo before editing its material maps.";return}
        if !usesMaterialMaps{setMaterialWorkflow(true)}
        switchViewport(target);tool = .brush
        if target == .albedo{ensureAlbedoMap()}
        inspectorTab="Brush"
    }
    func commitMaterialInk(_ captured:Ink,reference:SceneReference){
        guard painting.layers.contains(where:{$0.id==reference.sourceID})else{return}
        checkpoint()
        if let photo=painting.layers.firstIndex(where:{$0.id==reference.sourceID}){painting.layers[photo].materialWorkflow=true}
        var index=painting.layers.lastIndex{$0.plane == .albedo && $0.mapSourceID==reference.sourceID && $0.materialPaint == true && $0.visible && $0.opacity==1}
        if index==nil{
            let layer=Layer(name:"Material color",plane:.albedo,width:painting.width,height:painting.height,mapSourceID:reference.sourceID,materialPaint:true)
            painting.layers.append(layer);index=painting.layers.count-1
        }
        guard let index else{return};var ink=captured
        ink.points=captured.points.map{Dot(x:$0.x-painting.layers[index].x,y:$0.y-painting.layers[index].y)}
        var ref=reference;ref.frame.x -= painting.layers[index].x;ref.frame.y -= painting.layers[index].y
        ink.surface=SurfaceBinding(reference:ref,shading:0,conform:0);ink.photoShading=true;ink.materialPaint=nil
        painting.layers[index].strokes.append(ink);selectedStroke=nil
        status="Material color updated · Shading and Light controls apply to the result"
    }
}
