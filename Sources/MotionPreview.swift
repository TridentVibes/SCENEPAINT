import AppKit

@MainActor extension Editor{
    func requestInteractivePreview(){
        previewTask?.cancel()
        if !interactivePreview{interactivePreview=true}
        previewTask=Task{[weak self] in
            do{try await Task.sleep(for:.milliseconds(200))}catch{return}
            guard !Task.isCancelled else{return};self?.interactivePreview=false
        }
    }
    func finishInteractivePreview(){previewTask?.cancel();interactivePreview=false}
    func previewPhoto(_ original:CGImage,layer:Layer)->CGImage{
        guard interactivePreview,max(original.width,original.height)>768 else{return original}
        let key="\(layer.id)|\(layer.imageAsset ?? "")" as NSString
        if let image=motionPhotos.object(forKey:key){return image.cgImage(forProposedRect:nil,context:nil,hints:nil) ?? original}
        let ratio=768/Double(max(original.width,original.height)),w=max(1,Int(Double(original.width)*ratio)),h=max(1,Int(Double(original.height)*ratio))
        guard let cg=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return original}
        cg.interpolationQuality = .medium;cg.draw(original,in:CGRect(x:0,y:0,width:w,height:h))
        guard let image=cg.makeImage()else{return original}
        motionPhotos.setObject(NSImage(cgImage:image,size:CGSize(width:w,height:h)),forKey:key,cost:image.bytesPerRow*image.height)
        return image
    }
}
struct MotionPreviewKey:Equatable{
    let content:UInt64;let plane:Plane;let width:Double;let height:Double;let revision:UUID;let epoch:Int;let pending:UInt64
}
@MainActor final class CanvasMotionPreview{
    var key:MotionPreviewKey?;var image:CGImage?;var builds=0
    func raster(_ editor:Editor)->CGImage?{
        let next=MotionPreviewKey(content:editor.contentRevision,plane:editor.plane,width:editor.painting.width,height:editor.painting.height,revision:editor.sceneRevision,epoch:editor.renderEpoch,pending:editor.pendingRevision)
        if key==next,let image{return image}
        let ratio=min(1,2048/max(next.width,next.height)),w=max(1,Int(next.width*ratio)),h=max(1,Int(next.height*ratio))
        guard let cg=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return nil}
        cg.translateBy(x:0,y:Double(h));cg.scaleBy(x:Double(w)/next.width,y:-Double(h)/next.height)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
        Renderer.draw(editor,includePending:true,cacheLayers:true,quality:2)
        NSGraphicsContext.restoreGraphicsState()
        image=cg.makeImage();editor.canvasSnapshot=image;editor.canvasSnapshotPlane=editor.plane;editor.canvasSnapshotRevision=editor.contentRevision;editor.canvasSnapshotEpoch=editor.renderEpoch;key=next;builds += 1;return image
    }
}
