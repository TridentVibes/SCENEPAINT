import AppKit
import SwiftUI

struct V01MaterialRestoreChecks{
 @MainActor static func main()async throws{
  let root=URL(fileURLWithPath:"Temporary/V01MaterialRestore");ScenePaintPaths.prepare(root)
  try Data().write(to:root.appendingPathComponent("Analysis/locked.samfeatures"))
  func check(_ condition:Bool,_ text:String){precondition(condition,text);print("PASS: "+text);fflush(stdout)}
  let w=64,h=64
  var rgb=[UInt8](),rgba=[UInt8]()
  for y in 0..<h{for x in 0..<w{let v=UInt8(65+y*2+(x%2==0 ? 16:0));rgb += [v,v,v];rgba += [v,v,v,255]}}
  let photoImage=SceneWorker.raster(rgba,width:w,height:h)!
  try SceneWorker.png(photoImage,to:root.appendingPathComponent("Assets/photo.png"))
  let editor=Editor();editor.rootOverride=root;editor.autoAnalyze=false;editor.autoGeometry=false;editor.painting.width=64;editor.painting.height=64
  let photo=Layer(name:"Photo",width:64,height:64,imageAsset:"photo.png")
  let first=Layer(name:"First paint",width:64,height:64,photoSourceID:photo.id),second=Layer(name:"New paint",width:64,height:64,photoSourceID:photo.id)
  let scene=SceneData(width:w,height:h,depth:[Float](repeating:0.5,count:w*h),person:[UInt8](repeating:0,count:w*h),rgb:rgb,elapsed:0,segmentationAvailable:true)
  let analysis=try editor.writeScene(scene),mask=try editor.writeMask([UInt8](repeating:255,count:w*h))
  let ref=SceneReference(sourceID:photo.id,analysisAsset:analysis,maskAsset:mask,frame:SceneFrame(x:0,y:0,width:64,height:64),seed:nil,samAsset:"locked.samfeatures")
  editor.painting.layers=[photo,first,second];editor.painting.scene=ref;editor.painting.activePhotoID=photo.id;editor.selected=second.id;editor.preserveShading=true;editor.lockSurface=true;editor.color=Color(red:0.45,green:0.12,blue:0.05)
  var ink=editor.capturePlainBrush()!;ink.points=[Dot(x:0,y:0),Dot(x:64,y:0),Dot(x:64,y:64),Dot(x:0,y:64)];ink.filled=true;ink.closed=true
  editor.commitCapturedInk(ink,reference:ink.surface?.reference,targetPlane:.artwork,targetLayerID:second.id)
  check(editor.painting.layers.count==3 && editor.painting.layers[2].strokes.count==1 && editor.painting.layers[1].strokes.isEmpty,"Material brush paints on the newly selected Artwork layer")
  check(!editor.painting.layers.contains{$0.plane == .albedo},"Material brush no longer redirects strokes into Albedo")
  let stored=editor.painting.layers[2].strokes[0]
  check(stored.surface?.shading==0.85,"Material stroke stores the original v0.1 shading strength")
  func bytes(_ image:CGImage)->[UInt8]{let cg=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;cg.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return Array(UnsafeBufferPointer(start:cg.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))}
  func detail(_ image:CGImage,_ label:String){let p=bytes(image);let x=16,y=24;let a=p[(y*image.width+x)*4],b=p[(y*image.width+x+1)*4]
   check(abs(Int(a)-Int(b))>=4,label+" retains fine object texture")
   let dark=p[(12*image.width+x)*4],bright=p[(48*image.width+x)*4];check(bright>dark+12,label+" retains shadow and highlight differences")
  }
  detail(editor.surfaceMaterial(stored)!,"v0.1 brush")
  var later=stored;later.id=UUID();editor.selected=second.id
  editor.commitCapturedInk(later,reference:ref,targetPlane:.artwork,targetLayerID:first.id)
  check(editor.painting.layers[1].strokes.count==1 && editor.painting.layers[2].strokes.count==1,"A delayed stroke stays on its starting layer after selection changes")
  editor.selected=second.id;editor.bucketUseAI=true
  editor.smartFill(at:Dot(x:24,y:24))
  let deadline=Date().addingTimeInterval(10)
  while editor.filling && Date()<deadline{try await Task.sleep(for:.milliseconds(10))}
  check(!editor.filling && editor.painting.layers[2].strokes.count==2,"AI bucket fills the selected paint layer")
  detail(editor.surfaceMaterial(editor.painting.layers[2].strokes.last!)!,"v0.1 AI bucket")
  let connected=SmartFillRaster.photoImage(mask:[UInt8](repeating:255,count:w*h),width:w,height:h,color:[0.45,0.12,0.05],photo:photoImage,shading:0.85)!
  detail(connected,"v0.1 connected bucket")
  // Recover an existing material stroke saved in the faulty Albedo route.
  var wrong=Layer(name:"Material color",plane:.albedo,width:64,height:64,strokes:[stored],mapSourceID:photo.id,materialPaint:true)
  wrong.strokes[0].surface?.shading=0
  var old=editor.painting;old.layers.append(wrong)
  let repaired=V01MaterialStroke.restoreStoredStrokes(old)
  check(repaired.changed && repaired.painting.layers.last?.plane == .artwork && repaired.painting.layers.last?.photoSourceID==photo.id,"Reopening restores existing misplaced material strokes to Artwork")
  check(repaired.painting.layers.last?.strokes[0].points==wrong.strokes[0].points && repaired.painting.layers.last?.strokes[0].surface?.shading==0.85,"Existing gestures and masks survive v0.1 material restoration")
  editor.painting=repaired.painting
  detail(editor.surfaceMaterial(editor.painting.layers.last!.strokes[0])!,"Restored saved stroke")
  // Connected bucket payloads remain editable strokes on the chosen layer.
  let asset="bucket.png";try SceneWorker.png(connected,to:root.appendingPathComponent("Assets").appendingPathComponent(asset))
  var raster=Ink(opacity:0.7,points:[Dot(x:0,y:0),Dot(x:64,y:64)],width:1,red:0.45,green:0.12,blue:0.05)
  raster.imageAsset=asset;raster.imageFrame=SceneFrame(x:0,y:0,width:64,height:64)
  let count=editor.painting.layers[2].strokes.count
  editor.commitCapturedInk(raster,reference:nil,targetPlane:.artwork,targetLayerID:second.id)
  check(editor.painting.layers[2].strokes.count==count+1,"Connected bucket payload is added to the requested layer")
  let package=root.appendingPathComponent("Material.scenepaint")
  try ProjectPackage.save(editor.painting,root:root,to:package)
  let destination=root.appendingPathComponent("Reopened");ScenePaintPaths.prepare(destination)
  let loaded=try ProjectPackage.load(package,root:destination)
  check(loaded.layers[2].strokes.last?.imageAsset==asset && FileManager.default.fileExists(atPath:destination.appendingPathComponent("Assets").appendingPathComponent(asset).path),"Bucket strokes and their image data survive portable save/reopen")
 }
}
