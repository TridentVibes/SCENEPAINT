import AppKit
import simd

struct SurfaceDab:Codable,Equatable{
    var anchor:MeshAnchor;var u:[Double];var v:[Double];var radius:Double
    var position:[Double]? = nil
}
struct SurfaceStroke:Codable,Equatable{
    var geometryAsset:String;var dabs:[SurfaceDab]
    var version:Int? = nil
}
struct SurfacePatch{var center:CGPoint;var rim:[CGPoint];var visible:[Bool]? = nil
    var depths:[Double] = [];var continuation=false;var texture:[CGPoint]? = nil;var surfaceFace:Int? = nil
}
final class MeshPaintResult:NSObject{
    let ink:Ink;let quality:Int;let image:CGImage;let bounds:CGRect;var patchCount=0
    init(_ ink:Ink,_ quality:Int,_ image:CGImage,_ bounds:CGRect){self.ink=ink;self.quality=quality;self.image=image;self.bounds=bounds}
}
final class MeshShapeResult:NSObject{
    let ink:Ink;let patches:[SurfacePatch];let bounds:CGRect
    init(_ ink:Ink,_ patches:[SurfacePatch],_ bounds:CGRect){self.ink=ink;self.patches=patches;self.bounds=bounds}
}
final class SurfaceMeshBox:NSObject{let mesh:SurfaceMesh;init(_ mesh:SurfaceMesh){self.mesh=mesh}}
@MainActor final class SurfaceMeshCache{
    let meshes=NSCache<NSString,SurfaceMeshBox>();let paint=NSCache<NSString,MeshPaintResult>();let shapes=NSCache<NSString,MeshShapeResult>()
    init(){meshes.totalCostLimit=48*1024*1024;paint.totalCostLimit=32*1024*1024;shapes.totalCostLimit=24*1024*1024}
}
struct StrokeSurfaceTarget{
    let mask:[UInt8];let width:Int;let height:Int
    func contains(_ uv:V2)->Bool{
        guard uv.x>=0,uv.x<1,uv.y>=0,uv.y<1,mask.count==width*height else{return false}
        return mask[min(height-1,Int(uv.y*Double(height)))*width+min(width-1,Int(uv.x*Double(width)))]>127
    }
}
@MainActor enum MeshPainter{
    static func target(_ ink:Ink,editor:Editor)->StrokeSurfaceTarget?{
        guard let ref=ink.surface?.reference,ref.automaticTarget == true,let scene=editor.sceneData(ref),let mask=editor.maskData(ref)else{return nil}
        return StrokeSurfaceTarget(mask:mask,width:scene.width,height:scene.height)
    }
    static func mesh(_ asset:String,editor:Editor)->SurfaceMesh?{
        if let box=editor.meshCache.meshes.object(forKey:asset as NSString){return box.mesh}
        guard asset==URL(fileURLWithPath:asset).lastPathComponent,let mesh=try? SurfaceMesh.read(editor.root.appendingPathComponent("Analysis").appendingPathComponent(asset))else{return nil}
        editor.meshCache.meshes.setObject(SurfaceMeshBox(mesh),forKey:asset as NSString,cost:mesh.vertices.count*32+mesh.faces.count*56+mesh.occlusionDepth.count*4+mesh.sourceNormalField.count*24+mesh.completionBins.reduce(0,{$0+$1.count})*8)
        return mesh
    }
    nonisolated static func trace(_ ink:Ink,mesh:SurfaceMesh,frame:SceneFrame,asset:String,prefix:SurfaceStroke?=nil,processedPoints:Int=0,target:StrokeSurfaceTarget?=nil)->SurfaceStroke?{
        guard let first=ink.points.first,let start=mesh.hitNear(V2((first.x-frame.x)/frame.width,(first.y-frame.y)/frame.height))else{return nil}
        let version=target == nil ? 5:7
        let chart=SurfaceGestureChart(mesh:mesh,start:start)
        var state=start,dabs:[SurfaceDab]=[],continuing=false
        var lastAnchor=mesh.anchor(start)
        let sx=start.position.z/(frame.width*mesh.camera.fx),sy=start.position.z/(frame.height*mesh.camera.fy)
        let radius=max(1e-7,ink.width*sqrt(sx*sy)*0.5),speed=max(0.25,min(2,ink.topography?.relief ?? 1))
        func append(){
            if !continuing{lastAnchor=mesh.anchor(state)}
            dabs.append(SurfaceDab(anchor:lastAnchor,u:[state.u.x,state.u.y,state.u.z],v:[state.v.x,state.v.y,state.v.z],radius:radius,position:continuing ? [state.position.x,state.position.y,state.position.z]:nil))
        }
        var begin=1
        if let prefix,prefix.geometryAsset==asset,prefix.version==version,processedPoints>0,let last=prefix.dabs.last,let point=mesh.point(last.anchor),last.u.count==3,last.v.count==3{
            if processedPoints>=ink.points.count{return prefix}
            dabs=prefix.dabs;lastAnchor=last.anchor;continuing=last.position != nil
            state=mesh.location(face:last.anchor.face,position:last.position.map{V3($0[0],$0[1],$0[2])} ?? point)
            state.u=V3(last.u[0],last.u[1],last.u[2]);state.v=V3(last.v[0],last.v[1],last.v[2]);begin=processedPoints
        }else{append()}
        let spacing=max(0.5,ink.width*max(0.05,ink.brush?.spacing ?? 0.15))
        for i in begin..<ink.points.count{
            let a=ink.points[i-1],b=ink.points[i],dx=b.x-a.x,dy=b.y-a.y,length=hypot(dx,dy)
            guard length>0 else{continue}
            let steps=max(1,min(4096,Int(ceil(length/spacing))))
            for step in 0..<steps{
                let ta=Double(step)/Double(steps),tb=Double(step+1)/Double(steps)
                let ua=V2((a.x+dx*ta-frame.x)/frame.width,(a.y+dy*ta-frame.y)/frame.height)
                let ub=V2((a.x+dx*tb-frame.x)/frame.width,(a.y+dy*tb-frame.y)/frame.height)
                if let target{
                    // Cursor rays define the visible center. A target mask selects
                    // the object; it must never turn an occluder into a mesh stop.
                    if target.contains(ub),let hit=mesh.hit(ub,includeCompletion:false) ?? mesh.hit(ub){
                        state=hit;continuing=false
                    }else{
                        let ray=mesh.camera.unproject(ub,depth:1),normal=simd_cross(state.u,state.v)
                        let denominator=simd_dot(normal,ray)
                        let z=abs(denominator)>1e-8 ? simd_dot(normal,state.position)/denominator:state.position.z
                        // Near a tangent horizon, use a bounded depth on the same
                        // cursor ray rather than creating a spike or reversed step.
                        state.position=ray*(z.isFinite && z>start.position.z*0.1 && z<start.position.z*10 ? z:state.position.z)
                        continuing=true
                    }
                    append()
                    if dabs.count>=8192{break}
                    continue
                }
                guard let delta=chart.delta(ua,ub)else{continue}
                let travel=(state.u*delta.x+state.v*delta.y)*speed,distance=simd_length(travel)
                guard distance.isFinite,distance>1e-10 else{continue}
                if continuing{
                    state.position += travel
                }else{
                    let moved=mesh.walkDetailed(state,direction:travel,distance:distance,allows:target.map{target in {target.contains(mesh.camera.project($0.position))}})
                    state=moved.location
                    if !moved.complete{
                        // Continue on the last surface tangent while its geometry is hidden.
                        let tangent=(state.u*delta.x+state.v*delta.y)*speed
                        if simd_length(tangent)>1e-10{state.position += simd_normalize(tangent)*max(0,distance-moved.travelled)}
                        continuing=true
                    }
                }
                if continuing,let hit=mesh.hit(mesh.camera.project(state.position)),
                   target?.contains(mesh.camera.project(hit.position)) != false,
                   abs(hit.position.z-state.position.z)<state.position.z*0.04,
                   abs(simd_dot(mesh.normals[hit.face],simd_normalize(simd_cross(state.u,state.v))))>0.65{
                    // Reattach only to a compatible surface; never jump onto the occluder.
                    let normal=mesh.normals[hit.face]
                    var u=state.u-normal*simd_dot(state.u,normal)
                    if simd_length(u)>1e-8{
                        u=simd_normalize(u);var v=simd_normalize(simd_cross(normal,u))
                        if simd_dot(v,state.v)<0{v = -v}
                        state=MeshLocation(face:hit.face,position:hit.position,u:u,v:v);continuing=false
                    }
                }
                if state.position.z>0,state.position.x.isFinite,state.position.y.isFinite,state.position.z.isFinite{append()}
                if dabs.count>=8192{break}
            }
            if dabs.count>=8192{break}
        }
        return SurfaceStroke(geometryAsset:asset,dabs:dabs,version:version)
    }
    nonisolated static func patches(_ stroke:SurfaceStroke,mesh:SurfaceMesh,frame:SceneFrame,segments:Int=24)->[SurfacePatch]{
        var patches:[SurfacePatch]=[]
        func project(_ p:V3)->CGPoint{let uv=mesh.camera.project(p);return CGPoint(x:frame.x+uv.x*frame.width,y:frame.y+uv.y*frame.height)}
        for dab in stroke.dabs{
            guard dab.u.count==3,dab.v.count==3,let anchor=mesh.point(dab.anchor)else{continue}
            let p=dab.position.flatMap{$0.count==3 ? V3($0[0],$0[1],$0[2]):nil} ?? anchor
            guard p.z>0 else{continue}
            var state=mesh.location(face:dab.anchor.face,position:p);state.u=V3(dab.u[0],dab.u[1],dab.u[2]);state.v=V3(dab.v[0],dab.v[1],dab.v[2])
            var rim:[CGPoint]=[],depths=[p.z],crossesCrease=false
            for i in 0..<segments{
                let angle=Double(i)*2 * .pi/Double(segments),dir=state.u*cos(angle)+state.v*sin(angle),distance=dab.radius*(48.0/46.0)
                let edge:V3
                if dab.position != nil{edge=p+dir*distance}
                else{
                    let walked=mesh.walkDetailed(state,direction:dir,distance:distance)
                    if simd_dot(mesh.normals[state.face],mesh.normals[walked.location.face])<0.96{crossesCrease=true}
                    // A brush footprint can straddle a silhouette; clip it by depth later.
                    edge=walked.location.position + (walked.complete ? V3.zero:simd_normalize(walked.location.u*cos(angle)+walked.location.v*sin(angle))*max(0,distance-walked.travelled))
                }
                if edge.z>max(1e-6,p.z*0.01),edge.x.isFinite,edge.y.isFinite,edge.z.isFinite{
                    rim.append(project(edge));depths.append(edge.z)
                }else{
                    // An off-camera rim must not project through z=0 into a
                    // screen-spanning triangle. Degenerate this fan wedge.
                    rim.append(project(p));depths.append(p.z)
                }
            }
            if crossesCrease,dab.position == nil{
                let conforming=mesh.creaseFootprint(state,radius:dab.radius*(48.0/46.0),frame:frame)
                if !conforming.isEmpty{patches += conforming;continue}
            }
            patches.append(SurfacePatch(center:project(p),rim:rim,depths:depths,continuation:dab.position != nil,surfaceFace:dab.position == nil ? state.face:nil))
        }
        return patches
    }
    static func stroke(_ ink:Ink,editor:Editor)->SurfaceStroke?{
        if let saved=ink.meshStroke{
            if saved.version == (ink.surface?.reference.automaticTarget == true ? 7:5){return saved}
            guard let ref=ink.surface?.reference,let mesh=mesh(saved.geometryAsset,editor:editor)else{return saved}
            return trace(ink,mesh:mesh,frame:ref.frame,asset:saved.geometryAsset,target:target(ink,editor:editor))
        }
        guard ink.topography?.engine == 2,let ref=ink.surface?.reference,let asset=ref.geometryAsset,let mesh=mesh(asset,editor:editor)else{return nil}
        return trace(ink,mesh:mesh,frame:ref.frame,asset:asset,target:target(ink,editor:editor))
    }
    // Geometry and raster prefixes are reusable only for an unchanged brush,
    // target, camera and an exactly matching sequence of existing dabs.
    nonisolated static func extends(_ previous:Ink,_ current:Ink)->Bool{
        guard let a=previous.meshStroke,let b=current.meshStroke,a.geometryAsset==b.geometryAsset,a.version==b.version,
              a.dabs.count<=b.dabs.count,b.dabs.prefix(a.dabs.count).elementsEqual(a.dabs)else{return false}
        var old=previous,new=current;old.points=[];new.points=[];old.meshStroke=nil;new.meshStroke=nil
        return old==new
    }
    static func shape(_ ink:Ink,editor:Editor,preview:Bool=false)->MeshShapeResult?{
        var source=ink;source.opacity=1;source.red=0;source.green=0;source.blue=0
        let key="\(source.id?.uuidString ?? "live")|24" as NSString
        let previous=editor.meshCache.shapes.object(forKey:key)
        if let result=previous,result.ink==source{return result}
        guard let ref=source.surface?.reference,let traced=stroke(source,editor:editor),let mesh=mesh(traced.geometryAsset,editor:editor)else{return nil}
        var prefix:[SurfacePatch]=[],tail=traced
        if let previous,extends(previous.ink,source),let count=previous.ink.meshStroke?.dabs.count{
            prefix=previous.patches;tail.dabs=Array(traced.dabs.dropFirst(count))
        }
        let patches=prefix+patches(tail,mesh:mesh,frame:ref.frame,segments:24)
        var bounds=CGRect.null
        for patch in patches{for p in patch.rim{bounds=bounds.union(CGRect(x:p.x,y:p.y,width:0,height:0))}}
        bounds=bounds.insetBy(dx:-2,dy:-2).intersection(CGRect(x:ref.frame.x,y:ref.frame.y,width:ref.frame.width,height:ref.frame.height)).integral
        guard !bounds.isNull,!bounds.isEmpty else{return nil}
        let result=MeshShapeResult(source,patches,bounds)
        editor.meshCache.shapes.setObject(result,forKey:key,cost:patches.count*512)
        return result
    }
    nonisolated static func visibilityPath(_ patch:SurfacePatch,mesh:SurfaceMesh,frame:SceneFrame,quality:Double)->CGPath{
        let path=CGMutablePath(),q=max(1,quality)
        guard patch.depths.count==patch.rim.count+1 else{return path}
        for i in patch.rim.indices{
            let j=(i+1)%patch.rim.count,a=patch.center,b=patch.rim[i],c=patch.rim[j]
            let det=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
            guard det>0.000001 else{continue}
            let x0=Int(floor(max(frame.x,min(a.x,b.x,c.x))*q)),x1=Int(ceil(min(frame.x+frame.width,max(a.x,b.x,c.x))*q))
            let y0=Int(floor(max(frame.y,min(a.y,b.y,c.y))*q)),y1=Int(ceil(min(frame.y+frame.height,max(a.y,b.y,c.y))*q))
            guard x1>x0,y1>y0,(x1-x0)*(y1-y0)<4_000_000 else{continue}
            for y in y0..<y1{
                var run:Int?=nil
                for x in x0...x1{
                    var allowed=false
                    if x<x1{
                        let px=(Double(x)+0.5)/q-a.x,py=(Double(y)+0.5)/q-a.y
                        let v=(px*(c.y-a.y)-py*(c.x-a.x))/det,w=((b.x-a.x)*py-(b.y-a.y)*px)/det,u=1-v-w
                        if min(u,v,w) >= -0.001{
                            let z=1/(u/patch.depths[0]+v/patch.depths[i+1]+w/patch.depths[j+1])
                            let uv=V2(((Double(x)+0.5)/q-frame.x)/frame.width,((Double(y)+0.5)/q-frame.y)/frame.height)
                            let front=mesh.frontDepth(uv)
                            if let front{allowed=z<=front+max(1e-5,front*0.015) && abs(z-front)<front*0.04}
                            if !allowed,let face=patch.surfaceFace,front == nil || abs(z-front!)<front!*0.04,
                               let hit=mesh.hit(uv,includeCompletion:face>=mesh.observedFaceCount),abs(hit.position.z-z)<z*0.003{
                                // The nearest measured mesh surface is the paint's own
                                // face. Small raster/mesh disagreements at a crease
                                // must not make that surface occlude itself. A nearer
                                // foreground mesh or a substantial guide-depth jump
                                // still rejects the paint.
                                allowed=true
                            }
                        }
                    }
                    if allowed{if run==nil{run=x}}
                    else if let begin=run{path.addRect(CGRect(x:Double(begin)/q,y:Double(y)/q,width:Double(x-begin)/q,height:1/q));run=nil}
                }
            }
        }
        return path
    }
    static func render(_ ink:Ink,editor:Editor,quality:Int=2)->MeshPaintResult?{
        var ink=ink;ink.opacity=1
        let key="\(ink.id?.uuidString ?? "live")|\(quality)" as NSString
        let previous=editor.meshCache.paint.object(forKey:key)
        if let result=previous,result.ink==ink{return result}
        guard let ref=ink.surface?.reference,let asset=ink.meshStroke?.geometryAsset ?? ref.geometryAsset else{return nil}
        if editor.interactiveRender{
            if !editor.meshRenderJobs.contains(key){
                editor.meshRenderJobs.insert(key)
                let target=target(ink,editor:editor),revision=editor.sceneRevision
                Task{
                    await editor.prepareBrushResources(ref)
                    // prepareBrushResources publishes a separate immutable mesh.
                    guard let prepared=editor.meshCache.meshes.object(forKey:asset as NSString)?.mesh else{editor.meshRenderJobs.remove(key);return}
                    let output=await Task.detached(priority:.userInitiated){()->(MeshShapeResult,MeshPaintResult)? in
                        guard let traced=ink.meshStroke ?? trace(ink,mesh:prepared,frame:ref.frame,asset:asset,target:target)else{return nil}
                        let parts=patches(traced,mesh:prepared,frame:ref.frame)
                        var bounds=CGRect.null
                        for part in parts{for point in part.rim{bounds=bounds.union(CGRect(origin:point,size:.zero))}}
                        bounds=bounds.insetBy(dx:-2,dy:-2).intersection(CGRect(x:ref.frame.x,y:ref.frame.y,width:ref.frame.width,height:ref.frame.height)).integral
                        guard !bounds.isNull,!bounds.isEmpty else{return nil}
                        var source=ink;source.opacity=1;source.red=0;source.green=0;source.blue=0
                        let shape=MeshShapeResult(source,parts,bounds)
                        guard let image=raster(ink,shape:shape,mesh:prepared,frame:ref.frame,quality:quality,previous:nil)else{return nil}
                        return (shape,image)
                    }.value
                    editor.meshRenderJobs.remove(key)
                    guard editor.sceneRevision==revision,let (shape,image)=output else{return}
                    editor.meshCache.shapes.setObject(shape,forKey:"\(shape.ink.id?.uuidString ?? "live")|24" as NSString,cost:shape.patches.count*512)
                    editor.meshCache.paint.setObject(image,forKey:key,cost:image.image.bytesPerRow*image.image.height)
                    editor.invalidateRenderedStroke(ink)
                }
            }
            return nil
        }
        guard let mesh=mesh(asset,editor:editor)else{return nil}
        if let scene=editor.sceneData(ref){mesh.prepareDepthEdges(scene,key:ref.analysisAsset)}
        guard let shape=shape(ink,editor:editor,preview:quality==1),let result=raster(ink,shape:shape,mesh:mesh,frame:ref.frame,quality:quality,previous:previous)else{return nil}
        editor.meshCache.paint.setObject(result,forKey:key,cost:result.image.bytesPerRow*result.image.height);return result
    }
    nonisolated static func raster(_ ink:Ink,shape:MeshShapeResult,mesh:SurfaceMesh,frame:SceneFrame,quality:Int,previous:MeshPaintResult?)->MeshPaintResult?{
        let patches=shape.patches,bounds=shape.bounds
        let q=min(Double(max(1,quality)),sqrt(4_000_000/(bounds.width*bounds.height)))
        guard let cg=CGContext(data:nil,width:max(1,Int(ceil(bounds.width*q))),height:max(1,Int(ceil(bounds.height*q))),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
              let tip=CGContext(data:nil,width:96,height:96,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return nil}
        tip.translateBy(x:0,y:96);tip.scaleBy(x:1,y:-1)
        var stamp=ink;stamp.points=[Dot(x:48,y:48)];stamp.width=92;stamp.surface=nil;stamp.opacity=1
        BrushEngine.draw(stamp,in:tip);guard let atlas=tip.makeImage()else{return nil}
        cg.translateBy(x:0,y:Double(cg.height));cg.scaleBy(x:q,y:-q);cg.translateBy(x:-bounds.minX,y:-bounds.minY);cg.setShouldAntialias(true);cg.interpolationQuality = .high
        var startPatch=0
        if let previous,extends(previous.ink,ink),previous.patchCount<=patches.count,
           abs(Double(previous.image.width)/previous.bounds.width-q)<1e-8,
           abs(Double(previous.image.height)/previous.bounds.height-q)<1e-8{
            cg.saveGState();cg.translateBy(x:previous.bounds.minX,y:previous.bounds.maxY);cg.scaleBy(x:1,y:-1)
            cg.draw(previous.image,in:CGRect(origin:.zero,size:previous.bounds.size));cg.restoreGState()
            startPatch=previous.patchCount
        }
        for patch in patches.dropFirst(startPatch){
          let visible=visibilityPath(patch,mesh:mesh,frame:frame,quality:q)
          guard !visible.isEmpty else{continue}
          if (ink.brush?.preset ?? .hard) == .hard && (ink.brush?.roundness ?? 1)>0.99{
            cg.setFillColor(CGColor(red:ink.red,green:ink.green,blue:ink.blue,alpha:ink.brush?.flow ?? 1));cg.addPath(visible);cg.fillPath();continue
          }
          cg.saveGState();cg.addPath(visible);cg.clip()
          for i in patch.rim.indices{
            let j=(i+1)%patch.rim.count,a=Double(i)*2 * .pi/Double(patch.rim.count),b=Double(j)*2 * .pi/Double(patch.rim.count)
            let src=patch.texture ?? [CGPoint(x:48,y:48),CGPoint(x:48+48*cos(a),y:48+48*sin(a)),CGPoint(x:48+48*cos(b),y:48+48*sin(b))]
            let dst=[patch.center,patch.rim[i],patch.rim[j]]
            let area=(dst[1].x-dst[0].x)*(dst[2].y-dst[0].y)-(dst[1].y-dst[0].y)*(dst[2].x-dst[0].x)
            guard area>0.000001 else{continue}
            guard let t=SurfaceText.affine(src[0],src[1],src[2],dst[0],dst[1],dst[2])else{continue}
            cg.saveGState();cg.move(to:dst[0]);cg.addLine(to:dst[1]);cg.addLine(to:dst[2]);cg.closePath();cg.clip();cg.concatenate(t)
            cg.translateBy(x:0,y:96);cg.scaleBy(x:1,y:-1);cg.draw(atlas,in:CGRect(x:0,y:0,width:96,height:96));cg.restoreGState()
          }
          cg.restoreGState()
        }
        guard let image=cg.makeImage()else{return nil}
        let result=MeshPaintResult(ink,quality,image,bounds);result.patchCount=patches.count;return result
    }
}
