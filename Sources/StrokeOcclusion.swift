import AppKit
@MainActor extension Editor{
 func requestStrokeOcclusion(_ stroke:Ink,coarse:[UInt8],scene:SceneData){
  guard let id=stroke.id,!sceneCache.occlusionRequests.contains(id),let ref=stroke.surface?.reference,
        let feature=ref.samAsset,let url=analysisURL(feature),let seed=ref.seed ?? stroke.points.first else{return}
  sceneCache.occlusionRequests.insert(id)
  let f=ref.frame
  func index(_ p:Dot)->Int?{scene.index(p,frame:f)}
  // Sample the middle of each hidden run, away from ambiguous silhouette pixels.
  var runs:[[Dot]]=[],run:[Dot]=[]
  var samples:[Dot]=[]
  for (i,p) in stroke.points.enumerated(){
   if i==0{samples.append(p);continue}
   let a=stroke.points[i-1],spacing=max(1,min(f.width/Double(scene.width),f.height/Double(scene.height))*4)
   let steps=max(1,min(4096,Int(ceil(hypot(p.x-a.x,p.y-a.y)/spacing))))
   for n in 1...steps{let t=Double(n)/Double(steps);samples.append(Dot(x:a.x+(p.x-a.x)*t,y:a.y+(p.y-a.y)*t))}
  }
  for p in samples{
   if let i=index(p),coarse[i]<64{run.append(p)}
   else if !run.isEmpty{runs.append(run);run=[]}
  }
  if !run.isEmpty{runs.append(run)}
  let candidates=runs.filter{$0.count>=2}.sorted{$0.count>$1.count}.prefix(3).map{$0[$0.count/2]}
  let location=root
  Task{[weak self] in
   guard let self else{return}
   defer{self.sceneCache.occlusionRequests.remove(id)}
   var combined=[UInt8](repeating:0,count:scene.count)
   for p in candidates{
    let points=[SegmentPoint(x:(p.x-f.x)/f.width,y:(p.y-f.y)/f.height,label:1),SegmentPoint(x:(seed.x-f.x)/f.width,y:(seed.y-f.y)/f.height,label:0)]
    guard let selection=try? await SAMService.shared.select(root:location,featuresURL:url,points:points,width:scene.width,height:scene.height,choice:0),selection.score>=0.70 else{continue}
    // A foreground mask must exclude the target surface itself.
    if let i=index(seed),selection.mask[i]>128{continue}
    for i in combined.indices{combined[i]=max(combined[i],selection.mask[i])}
   }
   guard let i=self.painting.layers.indices.first(where:{self.painting.layers[$0].strokes.contains(where:{$0.id==id})}),
         let j=self.painting.layers[i].strokes.firstIndex(where:{$0.id==id}),
         self.painting.layers[i].strokes[j].surface?.reference==ref else{return}
   do{
    let asset=try self.writeMask(combined)
    self.painting.layers[i].strokes[j].surface?.reference.occlusionAsset=asset
   }catch{self.fail(error)}
  }
 }
}
