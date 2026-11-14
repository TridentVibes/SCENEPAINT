import AppKit

struct PaintScenePreviewKey:Equatable{
 let scene:MotionPreviewKey;let viewport:CanvasViewport;let target:UUID?
}
/// Cache the static layers around the active paint layer in a bounded viewport
/// raster. The active layer remains separate, preserving erase, opacity and order.
@MainActor final class PaintScenePreview{
 var key:PaintScenePreviewKey?;var below:CGImage?;var above:CGImage?;var frame=CGRect.zero;var builds=0
 var active:[Layer]=[]
 func prepare(_ editor:Editor,viewport:CanvasViewport,ink:Ink){
  let layers=editor.displayedLayers
  let selected=layers.first{$0.id==editor.selected}
  let target=selected.flatMap{layer->UUID? in
   guard ink.eraser == true || (layer.imageAsset == nil && layer.text == nil) else{return nil}
   if let source=ink.surface?.reference.sourceID,Relighter.owner(of:layer,editor:editor) != source{return nil}
   return layer.id
  }
  let scene=MotionPreviewKey(content:editor.contentRevision,plane:editor.plane,width:editor.painting.width,height:editor.painting.height,revision:editor.sceneRevision,epoch:editor.renderEpoch,pending:editor.pendingRevision)
  let next=PaintScenePreviewKey(scene:scene,viewport:viewport,target:target)
  if key==next{return}
  let p=viewport.documentPoint(.zero)
  let visible=CGRect(x:p.x,y:p.y,width:viewport.viewWidth/viewport.scale,height:viewport.viewHeight/viewport.scale)
  frame=visible.intersection(CGRect(x:0,y:0,width:scene.width,height:scene.height)).integral
  guard !frame.isNull,!frame.isEmpty else{return}
  let ratio=min(viewport.scale,2048/max(frame.width,frame.height))
  let w=max(1,Int(ceil(frame.width*ratio))),h=max(1,Int(ceil(frame.height*ratio)))
  func raster(_ subset:[Layer])->CGImage?{
   guard !subset.isEmpty,let cg=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return nil}
   cg.translateBy(x:0,y:Double(h));cg.scaleBy(x:Double(w)/frame.width,y:-Double(h)/frame.height);cg.translateBy(x:-frame.minX,y:-frame.minY)
   NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
   Renderer.draw(editor,cacheLayers:true,quality:1,layers:subset)
   NSGraphicsContext.restoreGraphicsState();return cg.makeImage()
  }
  if let target,let i=layers.firstIndex(where:{$0.id==target}){
   below=raster(Array(layers[..<i]));above=raster(Array(layers[(i+1)...]));active=[layers[i]]
  }else{below=raster(layers);above=nil;active=[]}
  key=next;builds += 1
 }
 func draw(_ image:CGImage?,in cg:CGContext){
  guard let image else{return}
  cg.saveGState();cg.interpolationQuality = .medium;cg.translateBy(x:frame.minX,y:frame.maxY);cg.scaleBy(x:1,y:-1)
  cg.draw(image,in:CGRect(origin:.zero,size:frame.size));cg.restoreGState()
 }
}
