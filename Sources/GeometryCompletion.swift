import Foundation
import simd

struct CompletionSupport:Decodable{var up:[Double]}
struct CompletionGroup:Decodable{
 var kind:String;var confidence:Double;var vertices:[[Double]];var faces:[[Int]];var dimensions:CompletionSupport?
}
struct CompletionFile:Decodable{var version:Int;var groups:[CompletionGroup]}
struct CompletedRegion{var firstFace:Int;var endFace:Int;var kind:String;var confidence:Double;var bounds:SIMD4<Double>;var supportUp:V3?=nil}

extension SurfaceMesh{
 /// Inferred triangles stay separate from the observed raster. Hidden backs can
 /// coexist at the same UV; this is no longer a single-valued depth sheet.
 static func withCompletion(_ mesh:SurfaceMesh,url:URL)->SurfaceMesh{
  guard let data=try? Data(contentsOf:url.deletingPathExtension().appendingPathExtension("completion.json")),
        let file=try? JSONDecoder().decode(CompletionFile.self,from:data),file.version==1 else{return mesh}
  var vertices=mesh.vertices,faces=mesh.faces,regions:[CompletedRegion]=[]
  for group in file.groups.prefix(100){
   guard group.confidence>=0.3,group.vertices.count<=10000,group.faces.count<=20000,
         group.vertices.allSatisfy({$0.count==3 && $0.allSatisfy(\.isFinite) && $0[2]>0}),
         group.faces.allSatisfy({$0.count==3 && $0.allSatisfy{group.vertices.indices.contains($0)}})else{continue}
   let base=vertices.count,first=faces.count
   let added=group.vertices.map{V3($0[0],$0[1],$0[2])};vertices += added
   faces += group.faces.map{SIMD3<Int32>(Int32(base+$0[0]),Int32(base+$0[1]),Int32(base+$0[2]))}
   let uv=added.map{mesh.camera.project($0)}
   guard let minX=uv.map(\.x).min(),let maxX=uv.map(\.x).max(),let minY=uv.map(\.y).min(),let maxY=uv.map(\.y).max()else{continue}
   regions.append(CompletedRegion(firstFace:first,endFace:faces.count,kind:group.kind,confidence:group.confidence,bounds:SIMD4(minX,minY,maxX,maxY),supportUp:group.dimensions.flatMap{$0.up.count==3 ? V3($0.up[0],$0.up[1],$0.up[2]):nil}))
  }
  let result=SurfaceMesh(vertices:vertices,faces:faces,camera:mesh.camera,width:mesh.gridWidth,height:mesh.gridHeight,gridFaces:mesh.gridFaces)
  result.observedFaceCount=mesh.faces.count;result.completedRegions=regions
  result.completionBins=Array(repeating:[],count:64*64)
  for region in regions{for face in region.firstFace..<region.endFace{
   let f=result.faces[face],uv=[f.x,f.y,f.z].map{result.camera.project(result.vertices[Int($0)])}
   let x0=max(0,min(63,Int(floor(uv.map(\.x).min()!*64)))),x1=max(0,min(63,Int(floor(uv.map(\.x).max()!*64))))
   let y0=max(0,min(63,Int(floor(uv.map(\.y).min()!*64)))),y1=max(0,min(63,Int(floor(uv.map(\.y).max()!*64))))
   for y in y0...y1{for x in x0...x1{result.completionBins[y*64+x].append(face)}}
  }}
  return result
 }
 func isStructuralFace(_ face:Int)->Bool{completedRegions.contains{$0.kind == "wall" && face >= $0.firstFace && face < $0.endFace}}
 func completionFaces(_ uv:V2)->[Int]{
  guard !completionBins.isEmpty,uv.x>=0,uv.y>=0,uv.x<=1,uv.y<=1 else{return []}
  return completionBins[min(63,Int(uv.y*64))*64+min(63,Int(uv.x*64))]
 }
 func completedHit(_ uv:V2)->MeshLocation?{
  let ray=camera.unproject(uv,depth:1);var closest=Double.infinity;var result:MeshLocation?
  for i in completionFaces(uv){
   let f=faces[i],a=vertices[Int(f.x)],n=normals[i],den=simd_dot(n,ray)
   guard den < -1e-9 else{continue}
   let t=simd_dot(n,a)/den;guard t>0,t<closest else{continue}
   let p=ray*t
   if barycentric(p,face:i).min() >= -1e-6{closest=t;result=location(face:i,position:p)}
  }
  return result
 }
 /// A measured floor can meet a generated wall along an analytic intersection
 /// even though their triangulations do not share vertex indices.
 func completedCrossing(_ state:MeshLocation,direction:V3,distance:Double)->(MeshLocation,Double)?{
  guard !completedRegions.contains(where:{$0.kind == "wall" && state.face >= $0.firstFace && state.face < $0.endFace}) else{return nil}
  var closest=distance+1e-8;var result:MeshLocation?
  for region in completedRegions where region.kind == "wall"{
   for i in region.firstFace..<region.endFace{
    let n=normals[i],den=simd_dot(n,direction)
    guard den < -1e-8,simd_dot(n,normals[state.face])<0.85 else{continue}
    let a=vertices[Int(faces[i].x)],t=simd_dot(n,a-state.position)/den
    guard t>1e-7,t<=closest else{continue}
    let p=state.position+direction*t
    let f=faces[i];var b=barycentric(p,face:i);let within=b.min() >= -0.00001
    b=simd_max(b,V3(repeating:0));b /= b.x+b.y+b.z
    let snapped=vertices[Int(f.x)]*b.x+vertices[Int(f.y)]*b.y+vertices[Int(f.z)]*b.z
    if !within{
        guard let up=region.supportUp,abs(simd_dot(up,normals[state.face]))>0.9,abs(simd_dot(up,n))<0.1 else{continue}
        let offset=snapped-p,vertical=simd_dot(offset,up)
        let pixel=state.position.z/max(1,Double(gridWidth)*camera.fx)
        guard vertical>=0,simd_length(offset-up*vertical)<pixel*0.3,simd_length(offset)<pixel*3 else{continue}
    }
    var next=location(face:i,position:snapped)
    let axis=simd_cross(normals[state.face],n)
    guard simd_length(axis)>1e-8 else{continue}
    let angle=acos(max(-1,min(1,simd_dot(normals[state.face],n))))
    next.u=Self.rotate(state.u,axis:simd_normalize(axis),angle:angle)
    next.v=Self.rotate(state.v,axis:simd_normalize(axis),angle:angle)
    result=next;closest=t
   }
  }
  return result.map{($0,closest)}
 }
}


extension SurfaceMesh{
 /// Join a wall's open foot to the measured support without requiring matching
 /// triangulations. Candidate support must meet the same normal and pixel-scale
 /// proximity checks used for entry onto the wall.
 func structuralFloorJoin(_ state:MeshLocation)->MeshLocation?{
  guard let region=completedRegions.first(where:{$0.kind == "wall" && state.face >= $0.firstFace && state.face < $0.endFace}),let up=region.supportUp,
        abs(simd_dot(normals[state.face],up))<0.1,gridWidth>1,gridHeight>1 else{return nil}
  let uv=camera.project(state.position),cx=Int(uv.x*Double(gridWidth)-0.5),cy=Int(uv.y*Double(gridHeight)-0.5)
  let tolerance=state.position.z/max(1,Double(gridWidth)*camera.fx)*3
  var closest=tolerance,result:MeshLocation?
  let y0=max(0,cy-3),y1=min(gridHeight-2,cy+3),x0=max(0,cx-3),x1=min(gridWidth-2,cx+3)
  guard x1>=x0,y1>=y0 else{return nil}
  for y in y0...y1{for x in x0...x1{for k in 0..<2{
   let i=Int(gridFaces[(y*(gridWidth-1)+x)*2+k]);guard i>=0,simd_dot(normals[i],up)>0.9 else{continue}
   let n=normals[i],a=vertices[Int(faces[i].x)],p=state.position-n*simd_dot(state.position-a,n)
   guard barycentric(p,face:i).min() >= -0.00001 else{continue}
   let distance=simd_distance(p,state.position);guard distance<closest else{continue}
   let axis=simd_cross(normals[state.face],n);guard simd_length(axis)>1e-8 else{continue}
   let angle=acos(max(-1,min(1,simd_dot(normals[state.face],n))))
   var next=location(face:i,position:p)
   next.u=Self.rotate(state.u,axis:simd_normalize(axis),angle:angle);next.v=Self.rotate(state.v,axis:simd_normalize(axis),angle:angle)
   closest=distance;result=next
  }}}
  return result
 }
}
