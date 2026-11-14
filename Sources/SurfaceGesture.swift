import Foundation
import simd

/// Unproject the cursor onto the starting tangent plane before transporting its
/// motion across the mesh. This includes perspective and horizontal/vertical
/// coupling: camera-space pixel size alone sends vertical gestures diagonally.
struct SurfaceGestureChart{
 let camera:MeshCamera;let origin:V3;let u:V3;let v:V3;let normal:V3
 init(mesh:SurfaceMesh,start:MeshLocation){camera=mesh.camera;origin=start.position;u=start.u;v=start.v;normal=simd_normalize(simd_cross(start.u,start.v))}
 func coordinates(_ uv:V2)->V2?{
  let ray=camera.unproject(uv,depth:1),den=simd_dot(normal,ray)
  guard abs(den)>1e-7 else{return nil}
  let distance=simd_dot(normal,origin)/den
  guard distance>0,distance<origin.z*20 else{return nil}
  let delta=ray*distance-origin
  return V2(simd_dot(delta,u),simd_dot(delta,v))
 }
 func delta(_ a:V2,_ b:V2)->V2?{
  let ra=camera.unproject(a,depth:1),rb=camera.unproject(b,depth:1)
  let da=simd_dot(normal,ra),db=simd_dot(normal,rb),offset=simd_dot(normal,origin)
  let anchorRay=camera.unproject(camera.project(origin),depth:1)
  // Exact plane-unprojection difference away from a horizon. Bound the
  // denominator near grazing incidence, including crossings of the horizon,
  // instead of dropping points and later resuming with a huge or reversed step.
  let minimum=max(0.015,abs(simd_dot(normal,anchorRay))*0.25)
  let denominator=max(minimum*minimum,da*db)
  let world=(rb*da-ra*db)*(offset/denominator)
  let result=V2(simd_dot(world,u),simd_dot(world,v))
  return result.x.isFinite && result.y.isFinite ? result:nil
 }
}
