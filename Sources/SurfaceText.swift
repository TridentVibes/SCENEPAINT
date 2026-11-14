import AppKit
import CoreText
import simd

struct SurfaceTextSettings:Codable,Equatable{
    var enabled=true
    var curvature=0.45
    var yaw=0.0
    var pitch=0.0
    var followDepth=0.6
    var lighting=0.8
    var depthRelief:Double? = nil
    var depthDirection:Double? = nil
    var engine:Int? = nil
    var fitToSurface:Bool? = nil
    var respectRegion:Bool? = nil
}
struct SurfaceTextGrid{var points:[CGPoint];var valid:[Bool];var scale:Double;var depths:[Double]=[]}
struct TextRasterKey:Equatable{
    var text:String;var settings:TextSettings;var surface:SurfaceTextSettings
    var x:Double;var y:Double;var reference:SceneReference;var quality:Int
}
final class ProjectedTextBox:NSObject{
    let key:TextRasterKey;let image:CGImage;let bounds:CGRect
    init(_ key:TextRasterKey,_ image:CGImage,_ bounds:CGRect){self.key=key;self.image=image;self.bounds=bounds}
}
final class FailedTextBox:NSObject{
    let key:TextRasterKey
    init(_ key:TextRasterKey){self.key=key}
}
@MainActor final class ProjectedTextCache{
    let cache=NSCache<NSString,ProjectedTextBox>()
    let failures=NSCache<NSString,FailedTextBox>()
    init(){cache.totalCostLimit=32*1024*1024;failures.countLimit=128}
    func clear(){cache.removeAllObjects();failures.removeAllObjects()}
}
@MainActor enum SurfaceText {
    static func sample(_ scene:SceneData,ref:SceneReference,world:CGPoint)->(Float,Double)?{
        guard let index=scene.index(Dot(x:world.x,y:world.y),frame:ref.frame)else{return nil}
        let l=(0.2126*Double(scene.rgb[index*3])+0.7152*Double(scene.rgb[index*3+1])+0.0722*Double(scene.rgb[index*3+2]))/255
        return(scene.depth[index],l)
    }
    static func projection(_ p:CGPoint,size:CGSize,style:SurfaceTextSettings,layer:Layer,ref:SceneReference,scene:SceneData)->CGPoint{
        let cx=size.width/2,cy=size.height/2,u=p.x-cx,v=p.y-cy
        let center=CGPoint(x:layer.x+cx,y:layer.y+cy)
        let base=sample(scene,ref:ref,world:center)?.0 ?? 0.5
        let radius=max(8,Double(size.width)*0.25)
        let dl=sample(scene,ref:ref,world:CGPoint(x:center.x-radius,y:center.y))?.0 ?? base
        let dr=sample(scene,ref:ref,world:CGPoint(x:center.x+radius,y:center.y))?.0 ?? base
        let dt=sample(scene,ref:ref,world:CGPoint(x:center.x,y:center.y-radius))?.0 ?? base
        let db=sample(scene,ref:ref,world:CGPoint(x:center.x,y:center.y+radius))?.0 ?? base
        let ay=style.yaw * .pi/180 + max(-0.45,min(0.45,Double(dr-dl)*1.4))*style.followDepth
        let ax=style.pitch * .pi/180 + max(-0.35,min(0.35,Double(db-dt)*1.2))*style.followDepth
        let arc=style.curvature * .pi*0.9
        var x=Double(u),z=0.0
        if abs(arc)>0.001{let r=Double(size.width)/arc;x=r*sin(Double(u)/r);z=abs(r)*(1-cos(Double(u)/r))}
        let xx=x*cos(ay)+z*sin(ay),zz = -x*sin(ay)+z*cos(ay)
        let yy=Double(v)*cos(ax)-zz*sin(ax),z2=Double(v)*sin(ax)+zz*cos(ax)
        let focal=max(150,Double(size.width)*2.5),scale=focal/max(focal*0.5,focal+z2)
        var out=CGPoint(x:cx+xx*scale,y:cy+yy*scale)
        if style.depthRelief == nil,style.followDepth>0,let d=sample(scene,ref:ref,world:CGPoint(x:layer.x+out.x,y:layer.y+out.y))?.0{
            let plane=Double(base)+(Double(dr-dl)*Double(u)+Double(db-dt)*Double(v))/(radius*2)
            out.y += max(-Double(size.height)*0.18,min(Double(size.height)*0.18,(Double(d)-plane)*Double(size.height)*style.followDepth))
        }
        if let relief=style.depthRelief,relief>0{
            let row=layer.y+out.y
            let left=SurfaceBrush.depth(Dot(x:layer.x,y:row),scene:scene,frame:ref.frame)
            let right=SurfaceBrush.depth(Dot(x:layer.x+size.width,y:row),scene:scene,frame:ref.frame)
            let local=SurfaceBrush.depth(Dot(x:layer.x+out.x,y:row),scene:scene,frame:ref.frame)
            if let left,let right,let local{
                let t=max(0,min(1,Double(out.x/size.width))),baseline=left+(right-left)*t
                let limit=min(ref.frame.width,ref.frame.height)*0.08
                let offset=max(-limit,min(limit,(local-baseline)*ref.frame.height*0.30*relief))
                let angle=(style.depthDirection ?? -90) * .pi/180
                out.x += cos(angle)*offset;out.y += sin(angle)*offset
            }
        }
        return out
    }
    static func goodCell(_ points:[CGPoint],valid:[Bool],i:Int,columns:Int)->Bool{
        let ids=[i,i+1,i+columns+2,i+columns+1]
        guard ids.allSatisfy({valid[$0]})else{return false}
        func area(_ a:CGPoint,_ b:CGPoint,_ c:CGPoint)->Double{Double((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x))}
        return area(points[ids[0]],points[ids[1]],points[ids[2]])>0.00001 && area(points[ids[0]],points[ids[2]],points[ids[3]])>0.00001
    }
    static func textStart(mesh:SurfaceMesh,uv:V2,frame:SceneFrame,size:CGSize)->MeshLocation?{
        guard let original=mesh.hitNear(uv)else{return nil}
        guard mesh.gridWidth>1,mesh.gridHeight>1 else{return original}
        var best=original,bestScore = -Double.infinity
        for dy in -6...6{for dx in -6...6{
            guard dx*dx+dy*dy<=36,let candidate=mesh.hit(uv+V2(Double(dx)/Double(mesh.gridWidth),Double(dy)/Double(mesh.gridHeight))),
                  abs(candidate.position.z-original.position.z)<original.position.z*0.08 else{continue}
            let facing = -simd_dot(mesh.normals[candidate.face],simd_normalize(candidate.position))
            let sx=candidate.position.z/(frame.width*mesh.camera.fx),sy=candidate.position.z/(frame.height*mesh.camera.fy)
            let wx=sx*min(20,Double(size.width)*0.3),wy=sy*min(12,Double(size.height)*0.5)
            let right=mesh.walkDetailed(candidate,direction:candidate.u,distance:wx),down=mesh.walkDetailed(candidate,direction:candidate.v,distance:wy)
            let support=min(1,right.travelled/max(wx,1e-9))*min(1,down.travelled/max(wy,1e-9))
            let px=candidate.position.x/candidate.position.z,py=candidate.position.y/candidate.position.z
            let gx=sx/max(0.25,candidate.u.x-px*candidate.u.z),gy=sy/max(0.25,candidate.v.y-py*candidate.v.z)
            var row=candidate,rowValid=true,validCount=0
            for y in 0...2{
                if y>0{let r=mesh.walkDetailed(row,direction:row.v,distance:Double(size.height)*gy*0.75/2);row=r.location;rowValid = rowValid && r.complete}
                var col=row,colValid=rowValid
                for x in 0...4{
                    if x>0{let r=mesh.walkDetailed(col,direction:col.u,distance:Double(size.width)*gx*0.75/4);col=r.location;colValid = colValid && r.complete}
                    if colValid && mesh.visible(col.position){validCount += 1}
                }
            }
            let coverage=Double(validCount)/15
            let score=coverage*coverage*8+support*0.3+facing*0.8-sqrt(Double(dx*dx+dy*dy))*0.08
            if score>bestScore{bestScore=score;best=candidate}
        }}
        return best
    }
    static func meshTextVertices(mesh:SurfaceMesh,frame:SceneFrame,layer:Layer,size:CGSize,columns:Int,rows:Int,scale:Double,fit:Bool=false)->SurfaceTextGrid?{
        let originUV=V2((layer.x-frame.x)/frame.width,(layer.y-frame.y)/frame.height)
        guard let start=(fit ? textStart(mesh:mesh,uv:originUV,frame:frame,size:size):mesh.hitNear(originUV))else{return nil}
        let chart=SurfaceGestureChart(mesh:mesh,start:start)
        func grid(_ fraction:Double)->SurfaceTextGrid{
            var row=start,points:[CGPoint]=[],valid:[Bool]=[],depths:[Double]=[],rowValid=true
            for y in 0...rows{
                if y>0{
                    let a=originUV+V2(0,Double(size.height)*Double(y-1)/Double(rows)/frame.height)
                    let b=originUV+V2(0,Double(size.height)*Double(y)/Double(rows)/frame.height)
                    let delta=(chart.delta(a,b) ?? V2.zero)*scale*fraction
                    let direction=row.u*delta.x+row.v*delta.y
                    let result=mesh.walkDetailed(row,direction:direction,distance:simd_length(direction))
                    row=result.location;rowValid = rowValid && result.complete
                }
                var column=row,columnValid=rowValid
                for x in 0...columns{
                    if x>0{
                        let a=originUV+V2(Double(size.width)*Double(x-1)/Double(columns)/frame.width,Double(size.height)*Double(y)/Double(rows)/frame.height)
                        let b=originUV+V2(Double(size.width)*Double(x)/Double(columns)/frame.width,Double(size.height)*Double(y)/Double(rows)/frame.height)
                        let delta=(chart.delta(a,b) ?? V2.zero)*scale*fraction
                        let direction=column.u*delta.x+column.v*delta.y
                        let result=mesh.walkDetailed(column,direction:direction,distance:simd_length(direction))
                        column=result.location;columnValid = columnValid && result.complete
                    }
                    let uv=mesh.camera.project(column.position)
                    points.append(CGPoint(x:frame.x+uv.x*frame.width-layer.x,y:frame.y+uv.y*frame.height-layer.y))
                    valid.append(columnValid);depths.append(column.position.z)
                }
            }
            return SurfaceTextGrid(points:points,valid:valid,scale:fraction,depths:depths)
        }
        var candidate=grid(1)
        guard fit else{return candidate}
        var best=candidate,bestScore = -1.0
        for _ in 0..<4{
            var good=0
            for y in 0..<rows{for x in 0..<columns{if goodCell(candidate.points,valid:candidate.valid,i:y*(columns+1)+x,columns:columns){good += 1}}}
            let coverage=Double(good)/Double(rows*columns),score=coverage*sqrt(candidate.scale)
            if score>bestScore{bestScore=score;best=candidate}
            if coverage>=0.90{return candidate}
            candidate=grid(candidate.scale*0.8)
        }
        return best
    }
    nonisolated static func affine(_ a:CGPoint,_ b:CGPoint,_ c:CGPoint,_ p:CGPoint,_ q:CGPoint,_ r:CGPoint)->CGAffineTransform?{
        let det=(b.x-a.x)*(c.y-a.y)-(c.x-a.x)*(b.y-a.y)
        guard abs(det)>0.000001 else{return nil}
        let m11=((q.x-p.x)*(c.y-a.y)-(r.x-p.x)*(b.y-a.y))/det
        let m12=((q.y-p.y)*(c.y-a.y)-(r.y-p.y)*(b.y-a.y))/det
        let m21=((r.x-p.x)*(b.x-a.x)-(q.x-p.x)*(c.x-a.x))/det
        let m22=((r.y-p.y)*(b.x-a.x)-(q.y-p.y)*(c.x-a.x))/det
        return CGAffineTransform(a:m11,b:m12,c:m21,d:m22,tx:p.x-m11*a.x-m21*a.y,ty:p.y-m12*a.x-m22*a.y)
    }
    static func render(layer:Layer,editor:Editor,quality:Int)->ProjectedTextBox?{
        guard let text=layer.text,let ref=editor.textGeometryReference(layer),let scene=editor.sceneData(ref)else{return nil}
        let settings=layer.textSettings ?? TextSettings(size:layer.fontSize,bold:true)
        let style=layer.textSurface ?? SurfaceTextSettings()
        let key=TextRasterKey(text:text,settings:settings,surface:style,x:layer.x,y:layer.y,reference:ref,quality:quality)
        if let cached=editor.projectedTextCache.cache.object(forKey:layer.id.uuidString as NSString),cached.key==key{editor.setTextWrapWarning(layer.id,nil);return cached}
        let warning="No continuous surface was found for this placement. Move the text anchor onto the intended face, or rebuild the surface."
        if editor.projectedTextCache.failures.object(forKey:layer.id.uuidString as NSString)?.key==key{editor.setTextWrapWarning(layer.id,warning);return nil}
        let size=TextEngine.measure(text,settings:settings),q=Double(max(1,min(4,quality)))
        guard size.width>0,size.height>0,size.width*size.height*q*q<16_000_000,
              let atlas=CGContext(data:nil,width:max(1,Int(ceil(size.width*q))),height:max(1,Int(ceil(size.height*q))),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return nil}
        atlas.translateBy(x:0,y:Double(atlas.height));atlas.scaleBy(x:q,y:-q)
        TextEngine.draw(text,settings:settings,in:atlas)
        guard let image=atlas.makeImage()else{return nil}
        let columns=24,rows=8
        let meshVertices:SurfaceTextGrid?
        if style.enabled,style.engine == 2{
            guard let asset=ref.geometryAsset,let mesh=MeshPainter.mesh(asset,editor:editor),let projected=meshTextVertices(mesh:mesh,frame:ref.frame,layer:layer,size:size,columns:columns,rows:rows,scale:style.depthRelief ?? 1,fit:style.fitToSurface == true)else{return nil}
            if style.fitToSurface == true{
                var cells=0
                for y in 0..<rows{for x in 0..<columns{if goodCell(projected.points,valid:projected.valid,i:y*(columns+1)+x,columns:columns){cells += 1}}}
                if Double(cells)<Double(rows*columns)*0.90{
                    editor.projectedTextCache.failures.setObject(FailedTextBox(key),forKey:layer.id.uuidString as NSString)
                    editor.setTextWrapWarning(layer.id,warning)
                    return nil
                }
            }
            editor.setTextWrapWarning(layer.id,nil)
            meshVertices=projected
        }else{meshVertices=nil}
        var vertices:[CGPoint]=[]
        for y in 0...rows{for x in 0...columns{
            let p=CGPoint(x:size.width*Double(x)/Double(columns),y:size.height*Double(y)/Double(rows))
            if let meshVertices{vertices.append(meshVertices.points[y*(columns+1)+x])}
            else{vertices.append(style.enabled ? projection(p,size:size,style:style,layer:layer,ref:ref,scene:scene):p)}
        }}
        let minX=floor((vertices.map(\.x).min() ?? 0)-2),minY=floor((vertices.map(\.y).min() ?? 0)-2)
        let maxX=ceil((vertices.map(\.x).max() ?? size.width)+2),maxY=ceil((vertices.map(\.y).max() ?? size.height)+2)
        let bounds=CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
        guard bounds.width*bounds.height*q*q<16_000_000,
              let out=CGContext(data:nil,width:max(1,Int(ceil(bounds.width*q))),height:max(1,Int(ceil(bounds.height*q))),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return nil}
        out.translateBy(x:0,y:Double(out.height));out.scaleBy(x:q,y:-q);out.translateBy(x:-minX,y:-minY)
        out.interpolationQuality = .high
        out.setShouldAntialias(false)
        let visibilityMesh=style.engine == 2 ? ref.geometryAsset.flatMap{MeshPainter.mesh($0,editor:editor)}:nil
        if let visibilityMesh{visibilityMesh.prepareDepthEdges(scene,key:ref.analysisAsset)}
        func triangle(_ source:[CGPoint],_ dest:[CGPoint],_ indices:[Int]){
            guard let transform=affine(source[0],source[1],source[2],dest[0],dest[1],dest[2])else{return}
            out.saveGState()
            if let meshVertices,let mesh=visibilityMesh{
                let world=dest.map{CGPoint(x:$0.x+layer.x,y:$0.y+layer.y)}
                let patch=SurfacePatch(center:world[0],rim:[world[1],world[2]],depths:indices.map{meshVertices.depths[$0]})
                var transform=CGAffineTransform(translationX:-layer.x,y:-layer.y)
                if let visibility=MeshPainter.visibilityPath(patch,mesh:mesh,frame:ref.frame,quality:q).copy(using:&transform){out.addPath(visibility);out.clip()}
            }
            out.move(to:dest[0]);out.addLine(to:dest[1]);out.addLine(to:dest[2]);out.closePath();out.clip()
            out.concatenate(transform);out.translateBy(x:0,y:size.height);out.scaleBy(x:1,y:-1)
            out.draw(image,in:CGRect(origin:.zero,size:size));out.restoreGState()
        }
        for y in 0..<rows{for x in 0..<columns{
            let a=CGPoint(x:size.width*Double(x)/Double(columns),y:size.height*Double(y)/Double(rows))
            let b=CGPoint(x:size.width*Double(x+1)/Double(columns),y:a.y)
            let c=CGPoint(x:b.x,y:size.height*Double(y+1)/Double(rows)),d=CGPoint(x:a.x,y:c.y)
            let i=y*(columns+1)+x
            if let meshVertices,![i,i+1,i+columns+2,i+columns+1].allSatisfy({meshVertices.valid[$0]}){continue}
            triangle([a,b,c],[vertices[i],vertices[i+1],vertices[i+columns+2]],[i,i+1,i+columns+2])
            triangle([a,c,d],[vertices[i],vertices[i+columns+2],vertices[i+columns+1]],[i,i+columns+2,i+columns+1])
        }}
        if style.lighting>0,let bytes=out.data?.assumingMemoryBound(to:UInt8.self){
            var luminance:[Double]=[]
            for y in stride(from:0,to:out.height,by:4){for x in stride(from:0,to:out.width,by:4) where bytes[y*out.bytesPerRow+x*4+3]>32{
                if let l=sample(scene,ref:ref,world:CGPoint(x:layer.x+minX+(Double(x)+0.5)/q,y:layer.y+minY+(Double(y)+0.5)/q))?.1{luminance.append(l)}
            }}
            luminance.sort();let white=max(0.08,luminance.isEmpty ? 1:luminance[min(luminance.count-1,luminance.count*9/10)])
            for y in 0..<out.height{for x in 0..<out.width where bytes[y*out.bytesPerRow+x*4+3]>0{
                let world=CGPoint(x:layer.x+minX+(Double(x)+0.5)/q,y:layer.y+minY+(Double(y)+0.5)/q)
                let l=sample(scene,ref:ref,world:world)?.1 ?? white
                let gain=1-style.lighting+style.lighting*max(0.18,min(1,l/white))
                for c in 0..<3{let i=y*out.bytesPerRow+x*4+c;bytes[i]=UInt8(clamping:Int(Double(bytes[i])*gain))}
            }}
        }
        guard let raster=out.makeImage()else{return nil}
        editor.setTextWrapWarning(layer.id,nil)
        let box=ProjectedTextBox(key,raster,bounds);editor.projectedTextCache.cache.setObject(box,forKey:layer.id.uuidString as NSString,cost:raster.bytesPerRow*raster.height)
        return box
    }
}
