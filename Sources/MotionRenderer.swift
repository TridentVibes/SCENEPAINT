import AppKit
import Accelerate
import simd

struct MotionLight{
    var values:[Float];var width:Int;var height:Int;var frame:SceneFrame
}
struct MotionStrokePacket{
    var ink:Ink;var stacks:[MotionStack];var material:CGImage?;var mesh:SurfaceMesh?;var target:StrokeSurfaceTarget?
    var image:CGImage?;var spillMask:CGImage?
}
struct MotionObjectPacket{
    var id=UUID();var strokes:[MotionStrokePacket];var stacks:[MotionStack];var eraser=false
}
struct MotionLayerPacket{
    var layer:Layer;var base:CGImage?;var strokes:[MotionStrokePacket];var light:MotionLight?
    var mask:CGImage?;var maskFrame:SceneFrame?;var outline:CGPath?
    var textStacks:[MotionStack]=[]
    var objects:[MotionObjectPacket]=[]
}
struct MotionSpillMask{var image:CGImage;var frame:SceneFrame}
struct MotionScene:@unchecked Sendable{
    var width:Double;var height:Double;var pixelsWide:Int;var pixelsHigh:Int;var settings:MotionSettings
    var layers:[MotionLayerPacket]
    var spillMasks:[UUID:MotionSpillMask]=[:]
}
final class MotionImageBox:NSObject{let image:CGImage;let source:CGImage?;init(_ image:CGImage,source:CGImage?=nil){self.image=image;self.source=source}}

// Only this actor owns frame caches and effect processing. Nothing here mutates
// the editing document or asks the photo-analysis models to run.
actor MotionEngine{
    let scene:MotionScene
    private let cache=NSCache<NSString,MotionImageBox>()
    private(set) var variationBuilds=0
    init(_ scene:MotionScene){self.scene=scene;cache.totalCostLimit=96*1024*1024;cache.countLimit=160}
    func render(time:Double,artworkOnly:Bool=false)throws->CGImage{
        try Task.checkCancellation()
        return try autoreleasepool{
            guard let cg=context()else{throw SceneError.message("Not enough memory for the Motion frame.")}
            for packet in scene.layers{
                try Task.checkCancellation()
                if artworkOnly,packet.layer.imageAsset != nil,packet.strokes.isEmpty{continue}
                if packet.strokes.isEmpty,packet.textStacks.isEmpty{
                    if let base=packet.base{draw(base,in:cg)};continue
                }
                guard let layer=context()else{throw SceneError.message("Cannot allocate Motion layer.")}
                if let base=packet.base,!(artworkOnly && packet.layer.imageAsset != nil){
                    let image=packet.textStacks.isEmpty ? base:appearance(base,stacks:packet.textStacks,ink:nil,time:time,spillMask:packet.mask)
                    draw(image,in:layer)
                }
                for object in packet.objects{
                    let raster=try objectGeometry(object,layer:packet.layer,time:time,light:packet.light)
                    let source=object.strokes.first
                    let animated=appearance(raster,stacks:object.stacks,ink:source?.ink,time:time,spillMask:source?.spillMask ?? (source?.ink.surface != nil ? source?.material:nil),layerOffset:CGPoint(x:packet.layer.x,y:packet.layer.y))
                    layer.saveGState()
                    if object.eraser{layer.setBlendMode(.destinationOut)}
                    draw(animated,in:layer);layer.restoreGState()
                }
                if let frame=packet.maskFrame{
                    layer.saveGState();documentTransform(layer)
                    if let outline=packet.outline{layer.addPath(outline);layer.clip(using:.evenOdd)}
                    if let mask=packet.mask{
                        layer.setBlendMode(.destinationIn);drawDocument(mask,frame:frame,in:layer)
                    }
                    layer.restoreGState()
                    // Outlines are also applied to the final layer below.
                }
                guard let image=layer.makeImage()else{continue}
                cg.saveGState();cg.setAlpha(packet.layer.opacity)
                if let frame=packet.maskFrame{
                    documentTransform(cg);cg.clip(to:CGRect(x:frame.x,y:frame.y,width:frame.width,height:frame.height))
                    if let outline=packet.outline{cg.addPath(outline);cg.clip(using:.evenOdd)}
                    undoDocumentTransform(cg)
                }
                draw(image,in:cg);cg.restoreGState()
            }
            guard let image=cg.makeImage()else{throw SceneError.message("Cannot finish Motion frame.")};return image
        }
    }
    private func context()->CGContext?{CGContext(data:nil,width:scene.pixelsWide,height:scene.pixelsHigh,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)}
    private func draw(_ image:CGImage,in cg:CGContext){cg.draw(image,in:CGRect(x:0,y:0,width:scene.pixelsWide,height:scene.pixelsHigh))}
    private func documentTransform(_ cg:CGContext){cg.translateBy(x:0,y:Double(scene.pixelsHigh));cg.scaleBy(x:Double(scene.pixelsWide)/scene.width,y:-Double(scene.pixelsHigh)/scene.height)}
    private func undoDocumentTransform(_ cg:CGContext){cg.scaleBy(x:scene.width/Double(scene.pixelsWide),y:-scene.height/Double(scene.pixelsHigh));cg.translateBy(x:0,y:-Double(scene.pixelsHigh))}
    private func drawDocument(_ image:CGImage,frame:SceneFrame,in cg:CGContext){
        cg.saveGState();cg.translateBy(x:frame.x,y:frame.y+frame.height);cg.scaleBy(x:1,y:-1)
        cg.draw(image,in:CGRect(x:0,y:0,width:frame.width,height:frame.height));cg.restoreGState()
    }
    private func objectGeometry(_ object:MotionObjectPacket,layer:Layer,time:Double,light:MotionLight?)throws->CGImage{
        var states=[String]()
        for stack in object.stacks where stack.enabled{for effect in stack.effects where effect.enabled && effect.kind == .boil{
            states.append("\(effect.id):\(MotionTiming.variation(effect,time:time+stack.phase,duration:scene.settings.duration))")
        }}
        let key="object|\(object.id)|\(states.joined(separator:"/"))" as NSString
        if let cached=cache.object(forKey:key){return cached.image}
        guard let cg=context()else{throw SceneError.message("Cannot prepare Motion object.")}
        for stroke in object.strokes{
            try Task.checkCancellation()
            cg.saveGState();cg.setAlpha(max(0,min(1,stroke.ink.opacity ?? 1)));cg.beginTransparencyLayer(auxiliaryInfo:nil)
            try drawStroke(stroke,layer:layer,time:time,in:cg)
            cg.endTransparencyLayer();cg.restoreGState()
        }
        guard var image=cg.makeImage()else{throw SceneError.message("Cannot finish Motion object.")}
        if let light,!object.eraser{image=relight(image,light:light)}
        cache.setObject(MotionImageBox(image),forKey:key,cost:image.bytesPerRow*image.height);variationBuilds += 1
        return image
    }
    private func drawStroke(_ packet:MotionStrokePacket,layer:Layer,time:Double,in cg:CGContext)throws{
        var ink=packet.ink
        for stack in packet.stacks where stack.enabled{
            for effect in stack.effects where effect.enabled && effect.kind == .boil{
                let variation=MotionTiming.variation(effect,time:time+stack.phase,duration:scene.settings.duration)
                ink=deform(ink,effect:effect,variation:variation,mesh:packet.mesh,target:packet.target)
            }
        }
        documentTransform(cg);cg.translateBy(x:layer.x,y:layer.y)
        if let image=packet.image,let frame=ink.imageFrame{
            // Raster fills retain their existing footprint; boil uses a tiny masked
            // displacement. Vector/mesh strokes use actual geometry variations.
            var moved=frame
            for stack in packet.stacks where stack.enabled{for effect in stack.effects where effect.enabled && effect.kind == .boil{
                let v=MotionTiming.variation(effect,time:time+stack.phase,duration:scene.settings.duration),d=MotionTiming.geometryOffset(effect,index:0,variation:v)
                moved.x += d.x;moved.y += d.y
            }}
            cg.saveGState();cg.beginTransparencyLayer(auxiliaryInfo:nil);drawDocument(image,frame:moved,in:cg);if moved != frame{cg.setBlendMode(.destinationIn);drawDocument(image,frame:frame,in:cg)};cg.endTransparencyLayer();cg.restoreGState()
        }else if let binding=ink.surface,let material=packet.material{
            let f=binding.reference.frame
            cg.saveGState();cg.clip(to:CGRect(x:f.x,y:f.y,width:f.width,height:f.height))
            if let outline=binding.reference.outline{
                if ink.invertSelection == true{cg.addRect(CGRect(x:f.x,y:f.y,width:f.width,height:f.height))}
                cg.addPath(MotionGeometry.outline(outline,frame:f));cg.clip(using:.evenOdd)
            }
            cg.beginTransparencyLayer(auxiliaryInfo:nil)
            if ink.topography?.engine == 2,let mesh=packet.mesh,let surface=ink.meshStroke ?? MeshPainter.trace(ink,mesh:mesh,frame:f,asset:binding.reference.geometryAsset ?? "",target:packet.target){
                let patches=MeshPainter.patches(surface,mesh:mesh,frame:f)
                var bounds=CGRect.null
                for patch in patches{for p in patch.rim{bounds=bounds.union(CGRect(origin:p,size:.zero))}}
                bounds=bounds.insetBy(dx:-2,dy:-2).intersection(CGRect(x:f.x,y:f.y,width:f.width,height:f.height)).integral
                if !bounds.isNull,!bounds.isEmpty{
                    var white=ink;white.red=1;white.green=1;white.blue=1
                    let shape=MeshShapeResult(white,patches,bounds)
                    if let rendered=MeshPainter.raster(white,shape:shape,mesh:mesh,frame:f,quality:1,previous:nil){
                        drawDocument(rendered.image,frame:SceneFrame(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height),in:cg)
                    }
                }
            }else{BrushEngine.draw(ink,in:cg)}
            cg.setBlendMode(.sourceIn);drawDocument(material,frame:f,in:cg)
            cg.endTransparencyLayer();cg.restoreGState()
        }else{BrushEngine.draw(ink,in:cg)}
    }
    private func deform(_ original:Ink,effect:MotionEffect,variation:Int,mesh:SurfaceMesh?,target:StrokeSurfaceTarget?)->Ink{
        var ink=original
        if original.topography?.engine == 2,let mesh,let ref=original.surface?.reference,
           var surface=original.meshStroke ?? MeshPainter.trace(original,mesh:mesh,frame:ref.frame,asset:ref.geometryAsset ?? "",target:target){
            for i in surface.dabs.indices{
                var dab=surface.dabs[i]
                guard dab.u.count==3,dab.v.count==3,let anchor=mesh.point(dab.anchor)else{continue}
                let p=dab.position.flatMap{$0.count==3 ? V3($0[0],$0[1],$0[2]):nil} ?? anchor
                let d=MotionTiming.geometryOffset(effect,point:Dot(x:ref.frame.x+mesh.camera.project(p).x*ref.frame.width,y:ref.frame.y+mesh.camera.project(p).y*ref.frame.height),variation:variation)
                let u=V3(dab.u[0],dab.u[1],dab.u[2]),v=V3(dab.v[0],dab.v[1],dab.v[2])
                let pixel=p.z/sqrt(max(1,ref.frame.width*mesh.camera.fx*ref.frame.height*mesh.camera.fy))
                let movement=(u*d.x+v*d.y)*pixel
                if dab.position != nil{let q=p+movement;dab.position=[q.x,q.y,q.z]}
                else if simd_length(movement)>1e-12{
                    let state=mesh.location(face:dab.anchor.face,position:p),moved=mesh.walkDetailed(state,direction:movement,distance:simd_length(movement)).location
                    dab.anchor=mesh.anchor(moved)
                }
                surface.dabs[i]=dab
            }
            ink.meshStroke=surface
        }else{
            ink.points=original.points.map{p in
                let d=MotionTiming.geometryOffset(effect,point:p,variation:variation)
                return Dot(x:p.x+d.x,y:p.y+d.y)
            }
        }
        return ink
    }
    private func relight(_ image:CGImage,light:MotionLight)->CGImage{
        guard let cg=context(),let pixels=cg.data?.assumingMemoryBound(to:UInt8.self)else{return image};draw(image,in:cg)
        let f=light.frame
        for y in 0..<cg.height{for x in 0..<cg.width{
            let px=(Double(x)+0.5)*scene.width/Double(cg.width),py=(Double(y)+0.5)*scene.height/Double(cg.height)
            let u=(px-f.x)/f.width,v=(py-f.y)/f.height
            guard u>=0,u<1,v>=0,v<1 else{continue}
            let fx=max(0,min(Double(light.width-1),u*Double(light.width)-0.5)),fy=max(0,min(Double(light.height-1),v*Double(light.height)-0.5))
            let x0=Int(fx),y0=Int(fy),x1=min(light.width-1,x0+1),y1=min(light.height-1,y0+1),tx=Float(fx-Double(x0)),ty=Float(fy-Double(y0))
            let top=light.values[y0*light.width+x0]*(1-tx)+light.values[y0*light.width+x1]*tx
            let bottom=light.values[y1*light.width+x0]*(1-tx)+light.values[y1*light.width+x1]*tx
            let gain=top*(1-ty)+bottom*ty,i=y*cg.bytesPerRow+x*4,a=Float(pixels[i+3])/255
            guard a>0 else{continue}
            for c in 0..<3{
                let source=min(255,Int((Float(pixels[i+c])/a).rounded())),value=RelightMath.linear[source]*gain
                let index=max(0,min(4096,Int((value*4096).rounded())))
                pixels[i+c]=UInt8(clamping:Int((Float(RelightMath.encoded[index])*a).rounded()))
            }
        }}
        return cg.makeImage() ?? image
    }
    private func opacity(_ image:CGImage,_ alpha:Double)->CGImage{
        guard alpha<0.999999,let cg=context()else{return image}
        cg.setAlpha(max(0,min(1,alpha)));draw(image,in:cg);return cg.makeImage() ?? image
    }
    private func tinted(_ original:CGImage,effect:MotionEffect)->CGImage{
        let key="tint|\(Unmanaged.passUnretained(original).toOpaque())|\(effect.id)" as NSString
        if let box=cache.object(forKey:key){return box.image}
        guard let cg=context(),let p=cg.data?.assumingMemoryBound(to:UInt8.self)else{return original}
        draw(original,in:cg)
        if !effect.inheritColor{
            let c=effect.color.count==3 ? effect.color:[1,1,1]
            for y in 0..<cg.height{for x in 0..<cg.width{
                let i=y*cg.bytesPerRow+x*4,a=Double(p[i+3])
                for channel in 0..<3{p[i+channel]=UInt8(clamping:Int(c[channel]*a))}
            }}
        }
        let image=cg.makeImage() ?? original
        cache.setObject(MotionImageBox(image,source:original),forKey:key,cost:(image.bytesPerRow*image.height+original.bytesPerRow*original.height));return image
    }
    private func blurred(_ original:CGImage,radius:Double,key suffix:String)->CGImage{
        let key="blur|\(Unmanaged.passUnretained(original).toOpaque())|\(suffix)" as NSString
        if let box=cache.object(forKey:key){return box.image}
        guard let a=context(),let b=context(),let c=context(),let ap=a.data,let bp=b.data,let cp=c.data else{return original}
        draw(original,in:a)
        var source=vImage_Buffer(data:ap,height:vImagePixelCount(a.height),width:vImagePixelCount(a.width),rowBytes:a.bytesPerRow)
        var middle=vImage_Buffer(data:bp,height:vImagePixelCount(b.height),width:vImagePixelCount(b.width),rowBytes:b.bytesPerRow)
        var output=vImage_Buffer(data:cp,height:vImagePixelCount(c.height),width:vImagePixelCount(c.width),rowBytes:c.bytesPerRow)
        let r=UInt32(max(1,min(200,Int(radius))))*2+1
        guard vImageBoxConvolve_ARGB8888(&source,&middle,nil,0,0,r,r,nil,vImage_Flags(kvImageEdgeExtend))==kvImageNoError,
              vImageBoxConvolve_ARGB8888(&middle,&output,nil,0,0,r,r,nil,vImage_Flags(kvImageEdgeExtend))==kvImageNoError else{return original}
        let image=c.makeImage() ?? original
        cache.setObject(MotionImageBox(image,source:original),forKey:key,cost:(image.bytesPerRow*image.height+original.bytesPerRow*original.height));return image
    }
    private func appearance(_ original:CGImage,stacks:[MotionStack],ink:Ink?,time:Double,spillMask:CGImage?,layerOffset:CGPoint = .zero)->CGImage{
        guard stacks.contains(where:{$0.active})else{return original}
        var image=original
        let duration=scene.settings.duration,scale=Double(scene.pixelsWide)/scene.width
        let blink=MotionTiming.blinkGain(stacks,time:time,duration:duration)
        for stack in stacks where stack.enabled{
            for effect in stack.effects where effect.enabled{
                let t=time+stack.phase
                switch effect.kind{
                case .boil:
                    if ink == nil,effect.intensity>0,let cg=context(){
                        let variation=MotionTiming.variation(effect,time:t,duration:duration)
                        if effect.boilMode == .jitter{
                            let d=MotionTiming.geometryOffset(effect,index:0,variation:variation)
                            cg.translateBy(x:d.x*scale,y:d.y*scale);draw(image,in:cg)
                            cg.translateBy(x:-d.x*scale,y:-d.y*scale)
                        }else{
                            for y in stride(from:0,to:scene.pixelsHigh,by:4){
                                let d=MotionTiming.geometryOffset(effect,point:Dot(x:0,y:Double(y)/scale),variation:variation)
                                cg.saveGState();cg.clip(to:CGRect(x:0,y:y,width:scene.pixelsWide,height:min(4,scene.pixelsHigh-y)))
                                cg.translateBy(x:d.x*scale,y:d.y*scale);draw(image,in:cg);cg.restoreGState()
                            }
                        }
                        cg.setBlendMode(.destinationIn);draw(original,in:cg);image=cg.makeImage() ?? image
                    }
                case .blink:image=opacity(image,MotionTiming.level(effect,time:t,duration:duration))
                case .glitch:
                    let cycles=MotionTiming.cycles(effect,duration),p=MotionTiming.phase(t,duration)*Double(cycles),event=Int(p),local=p-floor(p)
                    guard local<min(0.95,effect.eventDuration*Double(cycles)/duration),MotionTiming.random(effect.seed,event)>effect.randomness*0.5,let cg=context()else{continue}
                    let strips=max(1,min(32,effect.segments)),height=Double(scene.pixelsHigh)/Double(strips)
                    for i in 0..<strips{
                        let dx=(MotionTiming.random(effect.seed,event*97+i)*2-1)*effect.intensity*scale
                        cg.saveGState();cg.clip(to:CGRect(x:0,y:Double(i)*height,width:Double(scene.pixelsWide),height:height))
                        cg.translateBy(x:dx,y:0);draw(image,in:cg);cg.restoreGState()
                    }
                    if effect.rgbOffset,let channels=context(),let pixels=channels.data?.assumingMemoryBound(to:UInt8.self){
                        draw(image,in:channels)
                        for y in 0..<channels.height{for x in 0..<channels.width{
                            let i=y*channels.bytesPerRow+x*4;pixels[i+1]=0;pixels[i+2]=0;pixels[i+3]=pixels[i]
                        }}
                        if let red=channels.makeImage(){cg.saveGState();cg.setBlendMode(.plusLighter);cg.translateBy(x:effect.intensity*scale,y:0);draw(red,in:cg);cg.restoreGState()}
                    }
                    cg.setBlendMode(.destinationIn);draw(original,in:cg);image=cg.makeImage() ?? image
                case .emission:
                    let gain=effect.intensity*MotionTiming.pulse(effect,time:t,duration:duration)*(effect.syncBlink ? blink:1)
                    guard gain>0.00001,let cg=context()else{continue}
                    let light=tinted(original,effect:effect)
                    let glow=blurred(light,radius:effect.glowRadius*scale/max(0.2,effect.falloff),key:"glow|\(effect.id)")
                    draw(image,in:cg)
                    cg.saveGState();cg.setBlendMode(.plusLighter)
                    // Bounded additional passes let intensity exceed one without
                    // regenerating the cached luminous raster every frame.
                    var remaining=min(4,gain)
                    while remaining>0.001{cg.setAlpha(min(1,remaining));draw(light,in:cg);draw(glow,in:cg);remaining -= 1}
                    cg.restoreGState()
                    if effect.spill>0{
                        let spill=blurred(light,radius:effect.spillRadius*scale/max(0.2,effect.falloff),key:"spill|\(effect.id)")
                        cg.saveGState();cg.setAlpha(min(1,gain*effect.spill*effect.spillOpacity));cg.beginTransparencyLayer(auxiliaryInfo:nil)
                        draw(spill,in:cg)
                        let custom=scene.spillMasks[effect.id]
                        if effect.constrainSpill,let mask=custom?.image ?? spillMask,var frame=custom?.frame ?? ink?.surface?.reference.frame,let fullMask=context(){
                            if custom == nil{frame.x += layerOffset.x;frame.y += layerOffset.y}
                            documentTransform(fullMask);drawDocument(mask,frame:frame,in:fullMask)
                            if let raster=fullMask.makeImage(){cg.setBlendMode(.destinationIn);draw(raster,in:cg)}
                        }
                        cg.endTransparencyLayer();cg.restoreGState()
                    }
                    image=cg.makeImage() ?? image
                }
            }
        }
        return image
    }

}

enum MotionGeometry{
    static func outline(_ points:[Dot],frame:SceneFrame)->CGPath{
        let p=CGMutablePath()
        guard let first=points.first else{return p}
        // Scene outlines use normalized coordinates, as the existing renderer does.
        p.move(to:CGPoint(x:frame.x+first.x*frame.width,y:frame.y+first.y*frame.height))
        for dot in points.dropFirst(){p.addLine(to:CGPoint(x:frame.x+dot.x*frame.width,y:frame.y+dot.y*frame.height))}
        p.closeSubpath();return p
    }
}
