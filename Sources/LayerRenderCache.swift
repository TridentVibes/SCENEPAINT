import AppKit

final class CachedLayer:NSObject{
    let materialInputs:[Layer];let epoch:Int;let source:Layer;let documentSize:CGSize;let revision:UUID;let quality:Int;let image:CGImage;let bounds:CGRect
    init(_ source:Layer,_ documentSize:CGSize,_ revision:UUID,_ quality:Int,_ image:CGImage,_ bounds:CGRect,epoch:Int=0,materialInputs:[Layer]=[]){self.materialInputs=materialInputs;self.epoch=epoch;self.source=source;self.documentSize=documentSize;self.revision=revision;self.quality=quality;self.image=image;self.bounds=bounds}
}
@MainActor final class LayerRenderCache{
    let items=NSCache<NSString,CachedLayer>()
    var hits=0;var misses=0;var incrementalBuilds=0
    init(){items.totalCostLimit=192*1024*1024}
    func raster(_ layer:Layer,editor:Editor,quality:Int)->CachedLayer?{
        // Unpainted source photos already have a bounded decoded-image cache.
        guard layer.text != nil || !layer.strokes.isEmpty else{return nil}
        var source=layer;source.opacity=1;source.visible=true;source.name="";source.relighting=nil
        source.animation=nil;source.motionMuted=nil
        for i in source.strokes.indices{source.strokes[i].animation=nil;source.strokes[i].motionGroup=nil}
        if source.textSurface?.enabled != true && source.surface == nil && !source.strokes.contains(where:{$0.surface != nil || $0.imageAsset != nil}){source.x=0;source.y=0}
        let materialInputs=MaterialPipeline.maps(for:layer,editor:editor)
        let documentSize=CGSize(width:editor.painting.width,height:editor.painting.height)
        let key="\(source.id)|\(quality)" as NSString
        var previous=items.object(forKey:key)
        // Entering live preview must not rerender every older masked stroke just
        // to obtain a lower-quality copy of an already finished layer.
        if quality==1,previous==nil{
            for level in [2,3,4]{
                if let cached=items.object(forKey:"\(source.id)|\(level)" as NSString),cached.documentSize==documentSize,cached.revision==editor.sceneRevision{
                    previous=cached;break
                }
            }
        }
        if quality==1,let previous,previous.source==source,previous.materialInputs==materialInputs,previous.documentSize==documentSize,previous.revision==editor.sceneRevision,previous.epoch==(editor.layerRenderEpochs[layer.id] ?? 0){hits += 1;return previous}
        if let old=previous,old.source==source,old.materialInputs==materialInputs,old.documentSize==documentSize,old.revision==editor.sceneRevision,old.epoch==(editor.layerRenderEpochs[layer.id] ?? 0),old.quality==quality{hits += 1;return old}
        var bounds=CGRect.null
        if source.imageAsset != nil{bounds=CGRect(x:0,y:0,width:source.width,height:source.height)}
        if let text=source.text{
            let size=TextEngine.measure(text,settings:source.textSettings ?? TextSettings(size:source.fontSize,bold:true))
            let rect: CGRect
            if source.textSurface?.enabled == true,let warped=SurfaceText.render(layer:source,editor:editor,quality:quality){rect=warped.bounds}
            else{rect=CGRect(origin:.zero,size:size).insetBy(dx:-source.fontSize,dy:-source.fontSize)}
            bounds=bounds.union(rect)
        }
        for raw in source.strokes where raw.eraser != true{
            let ink:Ink
            if editor.interactiveRender,raw.topography?.engine == 2,let shape=editor.meshCache.shapes.object(forKey:"\(raw.id?.uuidString ?? "live")|24" as NSString){var bounded=raw;bounded.points=[Dot(x:shape.bounds.minX,y:shape.bounds.minY),Dot(x:shape.bounds.maxX,y:shape.bounds.maxY)];ink=bounded}
            else if editor.interactiveRender,raw.topography?.engine == 2{ink=raw}
            else{ink=editor.topographicInk(raw)}
            guard let first=ink.points.first else{continue}
            var rect=CGRect(x:first.x,y:first.y,width:0,height:0)
            for p in ink.points.dropFirst(){rect=rect.union(CGRect(x:p.x,y:p.y,width:0,height:0))}
            bounds=bounds.union(rect.insetBy(dx:-ink.width,dy:-ink.width))
        }
        let document=CGRect(x:-source.x,y:-source.y,width:editor.painting.width,height:editor.painting.height)
        bounds=bounds.intersection(document).integral
        guard !bounds.isNull,!bounds.isEmpty else{return nil}
        let q=min(Double(max(1,quality)),sqrt(4_000_000/(bounds.width*bounds.height)))
        let width=max(1,Int(ceil(bounds.width*q))),height=max(1,Int(ceil(bounds.height*q)))
        guard let cg=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return nil}
        cg.translateBy(x:0,y:Double(height));cg.scaleBy(x:Double(width)/bounds.width,y:-Double(height)/bounds.height);cg.translateBy(x:-bounds.minX,y:-bounds.minY)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
        var content=source
        if let previous,previous.materialInputs==materialInputs,previous.documentSize==documentSize,previous.revision==editor.sceneRevision,previous.epoch==(editor.layerRenderEpochs[layer.id] ?? 0),
           previous.source.strokes.count<source.strokes.count,
           source.strokes.prefix(previous.source.strokes.count).elementsEqual(previous.source.strokes),
           (quality==1 || (abs(Double(previous.image.width)/previous.bounds.width-Double(width)/bounds.width)<1e-8 &&
           abs(Double(previous.image.height)/previous.bounds.height-Double(height)/bounds.height)<1e-8)){
            var oldStyle=previous.source,newStyle=source;oldStyle.strokes=[];newStyle.strokes=[]
            if oldStyle==newStyle{
                cg.saveGState();cg.translateBy(x:previous.bounds.minX,y:previous.bounds.maxY);cg.scaleBy(x:1,y:-1)
                cg.draw(previous.image,in:CGRect(origin:.zero,size:previous.bounds.size));cg.restoreGState()
                content.strokes=Array(source.strokes.dropFirst(previous.source.strokes.count))
                content.imageAsset=nil;content.text=nil
                incrementalBuilds += 1
            }
        }
        Renderer.content(content,editor:editor,in:cg,quality:quality)
        NSGraphicsContext.restoreGraphicsState()
        guard let image=cg.makeImage()else{return nil}
        let result=CachedLayer(source,documentSize,editor.sceneRevision,quality,image,bounds,epoch:(editor.layerRenderEpochs[layer.id] ?? 0),materialInputs:materialInputs)
        items.setObject(result,forKey:key,cost:image.bytesPerRow*image.height);misses += 1;return result
    }
}
