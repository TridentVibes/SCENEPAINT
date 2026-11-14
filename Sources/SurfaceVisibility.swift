import AppKit
import simd

/// Extend an automatically selected surface across occlusion while retaining the cursor path.
enum SurfaceVisibility{
 static func mask(_ ink:Ink,mesh:SurfaceMesh,selected:[UInt8],width:Int,height:Int)->[UInt8]{
  guard let ref=ink.surface?.reference,ref.outline==nil,let seed=ref.seed ?? ink.points.first,
        let start=mesh.hitNear(V2((seed.x-ref.frame.x)/ref.frame.width,(seed.y-ref.frame.y)/ref.frame.height))else{return selected}
  var normal=mesh.normals[start.face]
  if mesh.gridWidth>1,mesh.gridHeight>1{
   let uv=mesh.camera.project(start.position);var sum=normal*3
   for dy in -2...2{for dx in -2...2{
    if let hit=mesh.hit(uv+V2(Double(dx)/Double(mesh.gridWidth),Double(dy)/Double(mesh.gridHeight))),
       abs(hit.position.z-start.position.z)<start.position.z*0.06,simd_dot(mesh.normals[hit.face],normal)>0.8{sum += mesh.normals[hit.face]}
   }}
   normal=simd_normalize(sum)
  }
  let offset=simd_dot(normal,start.position)
  // Ray-depth percentages are unstable on foreshortened floors. Compare perpendicular
  // plane distance, with uncertainty for monocular scale drift at grazing angles.
  let uncertainty=max(start.position.z*0.025,abs(offset)*0.24*(1-abs(normal.z)))
  var result=[UInt8](repeating:0,count:width*height)
  for y in 0..<height{for x in 0..<width{
   let uv=V2((Double(x)+0.5)/Double(width),(Double(y)+0.5)/Double(height)),ray=mesh.camera.unproject(uv,depth:1)
   let denominator=simd_dot(normal,ray)
   guard abs(denominator)>1e-8,let actual=mesh.frontDepth(uv)else{continue}
   let expected=offset/denominator
   guard expected>0 else{continue}
   let relative=(actual-expected)/expected,index=y*width+x
   // A nearer object hides paint. The same plane may reappear in another SAM component.
   let distance=abs(simd_dot(normal,ray*actual)-offset)
   if distance<uncertainty{result[index]=255}
   else if selected[index]>0,relative > -0.08,relative<0.30{result[index]=selected[index]}
  }}
  return result
 }
}
