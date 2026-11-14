import AppKit
import simd

private struct StampVertex{var position:V3;var uv:V2}
private struct UnfoldedFace{var face:Int;var origin:V3;var u:V3;var v:V3}

extension SurfaceMesh{
 /// Render the stamp on the actual mesh faces at a crease. A single fan across
 /// two faces is a chord inside a convex corner and incorrectly self-occludes.
 func creaseFootprint(_ start:MeshLocation,radius:Double,frame:SceneFrame)->[SurfacePatch]{
  guard radius>0 else{return []}
  var queue=[UnfoldedFace(face:start.face,origin:start.position,u:start.u,v:start.v)],head=0,visited:Set<Int>=[start.face],output:[SurfacePatch]=[]
  func clipped(_ input:[StampVertex],axis:Int,sign:Double)->[StampVertex]{
   guard var a=input.last else{return []};var result:[StampVertex]=[]
   for b in input{
    let da=sign*a.uv[axis]-radius,db=sign*b.uv[axis]-radius
    if (da<=0) != (db<=0){
     let t=da/(da-db);result.append(StampVertex(position:a.position+(b.position-a.position)*t,uv:a.uv+(b.uv-a.uv)*t))
    }
    if db<=0{result.append(b)};a=b
   }
   return result
  }
  while head<queue.count,head<256{
   let state=queue[head];head += 1;let face=faces[state.face]
   var polygon=[face.x,face.y,face.z].map{index->StampVertex in
    let p=vertices[Int(index)],d=p-state.origin
    return StampVertex(position:p,uv:V2(simd_dot(d,state.u),simd_dot(d,state.v)))
   }
   for axis in 0..<2{for sign in [-1.0,1.0]{polygon=clipped(polygon,axis:axis,sign:sign)}}
   guard polygon.count>=3 else{continue}
   for i in 1..<polygon.count-1{
    var triangle=[polygon[0],polygon[i],polygon[i+1]]
    guard triangle.allSatisfy({$0.position.z>1e-6})else{continue}
    func project(_ vertex:StampVertex)->CGPoint{
     let uv=camera.project(vertex.position);return CGPoint(x:frame.x+uv.x*frame.width,y:frame.y+uv.y*frame.height)
    }
    var points=triangle.map{project($0)}
    // Preserve front-face winding; atlas coordinates travel with each vertex.
    let area=(points[1].x-points[0].x)*(points[2].y-points[0].y)-(points[1].y-points[0].y)*(points[2].x-points[0].x)
    if simd_dot(normals[state.face],triangle[0].position)>=0{continue}
    if area<0{triangle.swapAt(1,2);points.swapAt(1,2)}
    let texture=triangle.map{CGPoint(x:48+48*$0.uv.x/radius,y:48+48*$0.uv.y/radius)}
    output.append(SurfacePatch(center:points[0],rim:[points[1],points[2]],depths:triangle.map{$0.position.z},texture:texture,surfaceFace:state.face))
   }
   for edge in 0..<3{
    let next=Int(neighbors[state.face][edge]);guard next>=0,!visited.contains(next)else{continue}
    let a=vertices[Int(face[(edge+1)%3])],b=vertices[Int(face[(edge+2)%3])],axis=simd_normalize(b-a)
    let n=normals[state.face],other=normals[next],angle=atan2(simd_dot(axis,simd_cross(n,other)),simd_dot(n,other))
    let origin=a+Self.rotate(state.origin-a,axis:axis,angle:angle)
    visited.insert(next)
    queue.append(UnfoldedFace(face:next,origin:origin,u:Self.rotate(state.u,axis:axis,angle:angle),v:Self.rotate(state.v,axis:axis,angle:angle)))
   }
  }
  return output
 }
}
