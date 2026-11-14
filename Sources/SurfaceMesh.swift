import AppKit
import simd

typealias V3=SIMD3<Double>
typealias V2=SIMD2<Double>
struct MeshAnchor:Codable,Equatable{
    var face:Int;var bary:[Double]
}
struct MeshWalk{var location:MeshLocation;var travelled:Double;var complete:Bool}
struct MeshLocation{var face:Int;var position:V3;var u:V3;var v:V3}
struct MeshCamera{
    var fx:Double;var fy:Double
    func project(_ p:V3)->V2{V2(p.x/p.z*fx+0.5,p.y/p.z*fy+0.5)}
    func unproject(_ uv:V2,depth:Double)->V3{V3((uv.x-0.5)/fx*depth,(uv.y-0.5)/fy*depth,depth)}
}
final class SurfaceMesh{
    var observedFaceCount=Int.max;var completedRegions:[CompletedRegion]=[];var completionBins:[[Int]]=[]
    var sourceNormalField:[V3]=[];var sourceNormalWidth=0;var sourceNormalHeight=0
    var guidedDepth:[Float]=[];var guidedWidth=0;var guidedHeight=0;var depthGuideKey:String?
    var occlusionDepth:[Float]=[];var occlusionWidth=0;var occlusionHeight=0
    let vertices:[V3];let faces:[SIMD3<Int32>];let camera:MeshCamera
    var neighbors:[SIMD3<Int32>];let normals:[V3]
    let gridWidth:Int;let gridHeight:Int;let gridFaces:[Int32]
    init(vertices:[V3],faces:[SIMD3<Int32>],camera:MeshCamera,width:Int=0,height:Int=0,gridFaces:[Int32]=[]){
        self.vertices=vertices;self.faces=faces;self.camera=camera;self.gridWidth=width;self.gridHeight=height;self.gridFaces=gridFaces
        normals=faces.map{f in
            let n=simd_cross(vertices[Int(f.y)]-vertices[Int(f.x)],vertices[Int(f.z)]-vertices[Int(f.x)])
            return simd_length(n)>1e-12 ? simd_normalize(n):V3(0,0,-1)
        }
        neighbors=Array(repeating:SIMD3<Int32>(repeating:-1),count:faces.count)
        var edges:[UInt64:(Int,Int)]=[:];edges.reserveCapacity(faces.count*2)
        for (i,f) in faces.enumerated(){for k in 0..<3{
            let a=UInt32(f[(k+1)%3]),b=UInt32(f[(k+2)%3]),key=UInt64(min(a,b))<<32|UInt64(max(a,b))
            if let (j,l)=edges.removeValue(forKey:key){neighbors[i][k]=Int32(j);neighbors[j][l]=Int32(i)}else{edges[key]=(i,k)}
        }}
    }
    func barycentric(_ p:V3,face:Int)->V3{
        let f=faces[face],a=vertices[Int(f.x)],v0=vertices[Int(f.y)]-a,v1=vertices[Int(f.z)]-a,v2=p-a
        let d00=simd_dot(v0,v0),d01=simd_dot(v0,v1),d11=simd_dot(v1,v1),d20=simd_dot(v2,v0),d21=simd_dot(v2,v1)
        let denominator=d00*d11-d01*d01
        guard abs(denominator)>1e-18 else{return V3(-1,-1,-1)}
        let v=(d11*d20-d01*d21)/denominator,w=(d00*d21-d01*d20)/denominator
        return V3(1-v-w,v,w)
    }
    func point(_ anchor:MeshAnchor)->V3?{
        guard faces.indices.contains(anchor.face),anchor.bary.count==3 else{return nil}
        let f=faces[anchor.face];return vertices[Int(f.x)]*anchor.bary[0]+vertices[Int(f.y)]*anchor.bary[1]+vertices[Int(f.z)]*anchor.bary[2]
    }
    func anchor(_ location:MeshLocation)->MeshAnchor{let b=barycentric(location.position,face:location.face);return MeshAnchor(face:location.face,bary:[b.x,b.y,b.z])}
    func location(face:Int,position:V3)->MeshLocation{
        let n=normals[face]
        // Screen-horizontal tangent, rather than camera-X projected onto a sloping face.
        let jy=V3(0,1,-position.y/position.z)
        var u=simd_cross(n,jy)
        if simd_length(u)<1e-10{u=V3(1,0,0)-n*n.x}
        u=simd_normalize(u)
        if u.x-position.x/position.z*u.z<0{u = -u}
        var v=simd_normalize(simd_cross(n,u))
        if v.y-position.y/position.z*v.z<0{v = -v}
        return MeshLocation(face:face,position:position,u:u,v:v)
    }
    func hit(_ uv:V2,includeCompletion:Bool=true)->MeshLocation?{
        guard uv.x>=0,uv.x<=1,uv.y>=0,uv.y<=1 else{return nil}
        let ray=camera.unproject(uv,depth:1)
        let candidates:[Int]
        if gridWidth>1,gridHeight>1{
            let x=max(0,min(gridWidth-2,Int(uv.x*Double(gridWidth)-0.5))),y=max(0,min(gridHeight-2,Int(uv.y*Double(gridHeight)-0.5)))
            let i=(y*(gridWidth-1)+x)*2
            candidates=[Int(gridFaces[i]),Int(gridFaces[i+1])].filter{$0>=0}
        }else{candidates=Array(faces.indices)}
        var result:MeshLocation?,distance=Double.infinity
        for i in candidates{
            let f=faces[i],a=vertices[Int(f.x)],n=normals[i],denominator=simd_dot(n,ray)
            guard denominator < -1e-10 else{continue}
            let t=simd_dot(n,a)/denominator;guard t>0,t<distance else{continue}
            let p=ray*t,b=barycentric(p,face:i)
            if b.min() >= -1e-7{distance=t;result=location(face:i,position:p)}
        }
        if includeCompletion,let inferred=completedHit(uv){
            // Retain genuinely nearer occluders. A close fit can replace the
            // noisy sheet, and a missing raster triangle can use a hypothesis.
            if result == nil || abs(inferred.position.z-distance)<distance*0.04 || (isStructuralFace(inferred.face) && inferred.position.z<distance*0.985){return inferred}
        }
        return result
    }
    func hitNear(_ uv:V2)->MeshLocation?{
        if let hit=hit(uv){return hit}
        guard gridWidth>1,gridHeight>1 else{return nil}
        // Small gaps at a depth silhouette must not turn a label into a degenerate chart.
        for radius in 1...2{
            for (dx,dy) in [(radius,0),(-radius,0),(0,radius),(0,-radius),(radius,radius),(-radius,radius),(radius,-radius),(-radius,-radius)]{
                if let hit=hit(uv+V2(Double(dx)/Double(gridWidth),Double(dy)/Double(gridHeight))){return hit}
            }
        }
        return nil
    }
    static func rotate(_ p:V3,axis:V3,angle:Double)->V3{p*cos(angle)+simd_cross(axis,p)*sin(angle)+axis*simd_dot(axis,p)*(1-cos(angle))}
    /// Edge-exact walking with explicit boundary termination and no off-face nudges.
    func walkDetailed(_ initial:MeshLocation,direction:V3,distance:Double,allows:((MeshLocation)->Bool)?=nil)->MeshWalk{
        var state=initial,remaining=max(0,distance),direction=direction,travelled=0.0
        var zeroCrossings=Set<Int>()
        for _ in 0..<256{
            let n=normals[state.face];direction -= n*simd_dot(n,direction)
            guard simd_length(direction)>1e-10 else{return MeshWalk(location:state,travelled:travelled,complete:remaining<1e-8)}
            if remaining<1e-9{return MeshWalk(location:state,travelled:travelled,complete:true)}
            direction=simd_normalize(direction)
            var b=barycentric(state.position,face:state.face)
            guard b.min() > -1e-5 else{return MeshWalk(location:state,travelled:travelled,complete:false)}
            b=simd_max(b,V3(repeating:0));b /= b.x+b.y+b.z
            let f=faces[state.face]
            state.position=vertices[Int(f.x)]*b.x+vertices[Int(f.y)]*b.y+vertices[Int(f.z)]*b.z
            if let (next,t)=completedCrossing(state,direction:direction,distance:remaining),allows?(next) != false{
                let du=simd_dot(direction,state.u),dv=simd_dot(direction,state.v)
                state=next;remaining -= t;travelled += t
                direction=state.u*du+state.v*dv
                continue
            }
            let delta=barycentric(state.position+direction,face:state.face)-b
            var step=remaining,edge = -1
            for k in 0..<3 where delta[k] < -1e-10{
                let t=max(0,-b[k]/delta[k]);if t<step{step=t;edge=k}
            }
            state.position += direction*step;remaining -= step;travelled += step
            guard edge>=0,remaining>1e-9 else{return MeshWalk(location:state,travelled:travelled,complete:true)}
            if step<1e-9{
                let crossing=state.face*3+edge
                guard zeroCrossings.insert(crossing).inserted else{return MeshWalk(location:state,travelled:travelled,complete:false)}
            }else{zeroCrossings.removeAll(keepingCapacity:true)}
            let next=Int(neighbors[state.face][edge])
            if next<0{
                if let joined=structuralFloorJoin(state),allows?(joined) != false{
                    let du=simd_dot(direction,state.u),dv=simd_dot(direction,state.v)
                    state=joined;direction=state.u*du+state.v*dv;continue
                }
                return MeshWalk(location:state,travelled:travelled,complete:false)
            }
            if let allows{
                let nf=faces[next],center=(vertices[Int(nf.x)]+vertices[Int(nf.y)]+vertices[Int(nf.z)])/3
                if !allows(location(face:next,position:center)){return MeshWalk(location:state,travelled:travelled,complete:false)}
            }
            let axis=simd_normalize(vertices[Int(f[(edge+2)%3])]-vertices[Int(f[(edge+1)%3])])
            let other=normals[next],angle=atan2(simd_dot(axis,simd_cross(n,other)),simd_dot(n,other))
            direction=Self.rotate(direction,axis:axis,angle:angle)
            var u=Self.rotate(state.u,axis:axis,angle:angle);u -= other*simd_dot(other,u);u=simd_normalize(u)
            let rotatedV=Self.rotate(state.v,axis:axis,angle:angle)
            var v=simd_normalize(simd_cross(other,u));if simd_dot(v,rotatedV)<0{v = -v}
            state.u=u;state.v=v;state.face=next
        }
        return MeshWalk(location:state,travelled:travelled,complete:false)
    }
    func walk(_ initial:MeshLocation,direction:V3,distance:Double)->MeshLocation{walkDetailed(initial,direction:direction,distance:distance).location}
    func visible(_ p:V3)->Bool{
        guard p.z>0,let front=hit(camera.project(p))else{return false}
        return abs(front.position.z-p.z)<max(1e-5,p.z*0.003)
    }
    /// The depth raster remains available at silhouettes even where triangles are disconnected.
    func frontDepth(_ uv:V2)->Double?{
        guard uv.x>=0,uv.x<=1,uv.y>=0,uv.y<=1 else{return nil}
        let w=guidedWidth>1 ? guidedWidth:(occlusionWidth>1 ? occlusionWidth:gridWidth),h=guidedHeight>1 ? guidedHeight:(occlusionHeight>1 ? occlusionHeight:gridHeight)
        if w>1,h>1{
            func depth(_ x:Int,_ y:Int)->Double{!guidedDepth.isEmpty ? Double(guidedDepth[y*w+x]):(occlusionDepth.isEmpty ? vertices[y*w+x].z:Double(occlusionDepth[y*w+x]))}
            let x=max(0,min(w-1,Int(uv.x*Double(w)))),y=max(0,min(h-1,Int(uv.y*Double(h))))
            let z=depth(x,y)
            if z>0{return z}
            var nearby:[Double]=[]
            for yy in max(0,y-1)...min(h-1,y+1){for xx in max(0,x-1)...min(w-1,x+1){let d=depth(xx,yy);if d>0{nearby.append(d)}}}
            if nearby.count>=3,let lo=nearby.min(),let hi=nearby.max(),hi-lo<lo*0.03{return nearby.reduce(0,+)/Double(nearby.count)}
            return nil
        }
        return hit(uv)?.position.z
    }
    static func read(_ url:URL,maxSide:Int=384)throws->SurfaceMesh{
        let data=try Data(contentsOf:url)
        guard data.count>=24,String(data:data.prefix(8),encoding:.utf8)=="SPGEO001"else{throw SceneError.message("Unsupported 3D surface file")}
        func word(_ offset:Int)->UInt32{data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self).littleEndian}}
        let originalW=Int(word(8)),originalH=Int(word(12)),camera=MeshCamera(fx:Double(Float(bitPattern:word(16))),fy:Double(Float(bitPattern:word(20))))
        guard originalW>=2,originalH>=2,originalW<=2048,originalH<=2048,data.count==24+originalW*originalH*12,camera.fx>0,camera.fy>0 else{throw SceneError.message("Invalid 3D surface dimensions")}
        let scale=min(1,Double(maxSide)/Double(max(originalW,originalH))),w=max(2,Int(Double(originalW)*scale)),h=max(2,Int(Double(originalH)*scale))
        var sourceNormals:[V3]=[]
        if let data=try? Data(contentsOf:url.deletingPathExtension().appendingPathExtension("spnormal")),data.count==16+originalW*originalH*12,String(data:data.prefix(8),encoding:.utf8)=="SPNOR001"{
            sourceNormals=data.withUnsafeBytes{bytes in (0..<originalW*originalH).map{i in
                func f(_ c:Int)->Double{Double(Float(bitPattern:bytes.loadUnaligned(fromByteOffset:16+i*12+c*4,as:UInt32.self).littleEndian))}
                return V3(f(0),f(1),f(2))
            }}
        }
        var sourceRegions:[UInt32]=[]
        if let regions=try? Data(contentsOf:url.deletingPathExtension().appendingPathExtension("spregion")),regions.count==16+originalW*originalH*4,String(data:regions.prefix(8),encoding:.utf8)=="SPREG001"{
            sourceRegions=regions.withUnsafeBytes{bytes in (0..<originalW*originalH).map{bytes.loadUnaligned(fromByteOffset:16+$0*4,as:UInt32.self).littleEndian}}
        }
        var sampledRegions:[UInt32]=[]
        var sampledNormals:[V3]=[]
        var vertices:[V3]=[];vertices.reserveCapacity(w*h)
        for y in 0..<h{for x in 0..<w{
            let fx=max(0,min(Double(originalW-1),(Double(x)+0.5)/Double(w)*Double(originalW)-0.5))
            let fy=max(0,min(Double(originalH-1),(Double(y)+0.5)/Double(h)*Double(originalH)-0.5))
            let x0=Int(fx),y0=Int(fy),x1=min(originalW-1,x0+1),y1=min(originalH-1,y0+1)
            func zAt(_ xx:Int,_ yy:Int)->Double{Double(Float(bitPattern:word(24+(yy*originalW+xx)*12+8)))}
            let samples=[zAt(x0,y0),zAt(x1,y0),zAt(x0,y1),zAt(x1,y1)]
            let lo=samples.min()!,hi=samples.max()!,tx=fx-Double(x0),ty=fy-Double(y0)
            let z:Double
            let localNormals=sourceNormals.isEmpty ? []:[sourceNormals[y0*originalW+x0],sourceNormals[y0*originalW+x1],sourceNormals[y1*originalW+x0],sourceNormals[y1*originalW+x1]]
            let sameRegion=sourceRegions.isEmpty || [y0*originalW+x0,y0*originalW+x1,y1*originalW+x0,y1*originalW+x1].allSatisfy{sourceRegions[$0]==sourceRegions[y0*originalW+x0]}
            let sameFace=sameRegion && (localNormals.isEmpty || localNormals.allSatisfy{simd_dot($0,localNormals[0])>0.94})
            if lo>0,hi-lo<lo*0.03,sameFace{
                z=(samples[0]*(1-tx)+samples[1]*tx)*(1-ty)+(samples[2]*(1-tx)+samples[3]*tx)*ty
            }else{z=zAt(Int(fx.rounded()),Int(fy.rounded()))}
            if !sourceNormals.isEmpty{sampledNormals.append(sourceNormals[Int(fy.rounded())*originalW+Int(fx.rounded())])}
            if !sourceRegions.isEmpty{sampledRegions.append(sourceRegions[Int(fy.rounded())*originalW+Int(fx.rounded())])}
            // Reproject at the sampled pixel center; camera and texture UV remain consistent.
            vertices.append(camera.unproject(V2((Double(x)+0.5)/Double(w),(Double(y)+0.5)/Double(h)),depth:z))
        }}
        // Stabilize noisy within-surface normals while retaining depth discontinuities.
        for _ in 0..<2{
            let source=vertices
            for y in 0..<h{for x in 0..<w{
                let center=source[y*w+x].z;guard center>0 else{continue}
                var sum=0.0,weight=0.0
                for yy in max(0,y-1)...min(h-1,y+1){for xx in max(0,x-1)...min(w-1,x+1){
                    let value=source[yy*w+xx].z
                    if !sampledRegions.isEmpty,sampledRegions[y*w+x] != sampledRegions[yy*w+xx]{continue}
                    if !sampledNormals.isEmpty,simd_dot(sampledNormals[y*w+x],sampledNormals[yy*w+xx])<0.94{continue}
                    guard value>0,abs(value-center)<center*0.02 else{continue}
                    let spatial=Double((xx==x ? 2:1)*(yy==y ? 2:1))
                    let range=max(0,1-abs(value-center)/(center*0.02)),wgt=spatial*range
                    sum += value*wgt;weight += wgt
                }}
                if weight>0{vertices[y*w+x]=camera.unproject(V2((Double(x)+0.5)/Double(w),(Double(y)+0.5)/Double(h)),depth:sum/weight)}
            }}
        }
        let result=withCompletion(grid(vertices:vertices,width:w,height:h,camera:camera),url:url)
        result.sourceNormalField=sourceNormals;result.sourceNormalWidth=originalW;result.sourceNormalHeight=originalH
        // Keep full model resolution for silhouette clipping, independent of the walking mesh.
        result.occlusionWidth=originalW;result.occlusionHeight=originalH
        result.occlusionDepth=(0..<originalW*originalH).map{Float(bitPattern:word(24+$0*12+8))}
        if !result.completedRegions.isEmpty{
            for y in 0..<originalH{for x in 0..<originalW{
                let uv=V2((Double(x)+0.5)/Double(originalW),(Double(y)+0.5)/Double(originalH))
                if let hit=result.completedHit(uv){
                    let i=y*originalW+x,z=Double(result.occlusionDepth[i]),estimated=hit.position.z
                    if z<=0 || abs(estimated-z)<z*0.04 || (result.isStructuralFace(hit.face) && estimated<z*0.985){result.occlusionDepth[i]=Float(estimated)}
                }
            }}
        }
        return result
    }
    static func grid(vertices:[V3],width:Int,height:Int,camera:MeshCamera)->SurfaceMesh{
        var faces:[SIMD3<Int32>]=[],lookup=[Int32](repeating:-1,count:(width-1)*(height-1)*2)
        func add(_ indices:SIMD3<Int32>,slot:Int){
            let p=[vertices[Int(indices.x)],vertices[Int(indices.y)],vertices[Int(indices.z)]]
            guard p.allSatisfy({$0.z>0 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite})else{return}
            let near=p.map(\.z).min()!,far=p.map(\.z).max()!
            guard far-near<near*0.06 else{return} // Never bridge foreground/background depth jumps.
            lookup[slot]=Int32(faces.count);faces.append(indices)
        }
        for y in 0..<height-1{for x in 0..<width-1{
            let a=Int32(y*width+x),b=a+1,d=a+Int32(width),c=d+1,i=(y*(width-1)+x)*2
            add(SIMD3(a,c,b),slot:i);add(SIMD3(a,d,c),slot:i+1)
        }}
        return SurfaceMesh(vertices:vertices,faces:faces,camera:camera,width:width,height:height,gridFaces:lookup)
    }
}
