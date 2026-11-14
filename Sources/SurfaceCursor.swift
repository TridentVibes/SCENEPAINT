import AppKit
import simd

enum SurfaceCursorGeometry{
 static func plane(mesh:SurfaceMesh,point:Dot,frame:SceneFrame,diameter:Double)->[CGPoint]?{
  let uv=V2((point.x-frame.x)/frame.width,(point.y-frame.y)/frame.height)
  // Observed faces retain subtle creases that a broad completion plane can flatten.
  guard let hit=mesh.hit(uv,includeCompletion:false) ?? mesh.hitNear(uv),diameter>0 else{return nil}
  let sx=hit.position.z/(frame.width*mesh.camera.fx),sy=hit.position.z/(frame.height*mesh.camera.fy),radius=diameter*sqrt(sx*sy)*0.5
  let center=mesh.camera.project(hit.position)
  var points:[CGPoint]=[]
  for i in 0..<48{
   let angle=Double(i)*2*Double.pi/48,x=cos(angle),y=sin(angle)
   let p=hit.position+hit.u*(x*radius)+hit.v*(y*radius)
   guard p.z>hit.position.z*0.01 else{return nil}
   let projected=mesh.camera.project(p)
   points.append(CGPoint(x:point.x+(projected.x-center.x)*frame.width,y:point.y+(projected.y-center.y)*frame.height))
  }
  return points
 }
}

@MainActor final class BrushCursorView:NSView{
 var plane:[CGPoint]=[]
 override var isFlipped:Bool{true}
 override func hitTest(_ point:NSPoint)->NSView?{nil}
 func showPlane(_ points:[CGPoint]){plane=points;layer?.borderWidth=0;layer?.cornerRadius=0;needsDisplay=true}
 func showCircle(){if !plane.isEmpty{plane=[];needsDisplay=true};layer?.borderWidth=1}
 override func draw(_ dirtyRect:NSRect){
  guard plane.count==48 else{return}
  let path=NSBezierPath();path.move(to:plane[0]);for p in plane.dropFirst(){path.line(to:p)};path.close()
  NSColor.systemCyan.withAlphaComponent(0.12).setFill();path.fill()
  NSColor.white.withAlphaComponent(0.95).setStroke();path.lineWidth=1;path.stroke()
  let grid=NSBezierPath()
  grid.move(to:plane[0]);grid.line(to:plane[24])
  grid.move(to:plane[12]);grid.line(to:plane[36])
  NSColor.systemCyan.withAlphaComponent(0.8).setStroke();grid.lineWidth=0.75;grid.stroke()
 }
}
