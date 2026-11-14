import AppKit
import SwiftUI
import simd

struct RelightSettings:Codable,Equatable{
    var enabled=true
    var azimuth = -45.0
    var elevation=45.0
    var strength=0.8
    var ambient=0.5
    var relief=1.0
    var exposure=0.0
}
final class RelightResult:NSObject{
    let settings:RelightSettings;let analysis:String;let image:CGImage;let original:CGImage
    let bounds:CGRect;let frame:SceneFrame;let geometry:String?
    init(_ settings:RelightSettings,_ ref:SceneReference,_ original:CGImage,_ image:CGImage,_ bounds:CGRect){self.settings=settings;self.analysis=ref.analysisAsset;self.geometry=ref.geometryAsset;self.original=original;self.image=image;self.bounds=bounds;self.frame=ref.frame}
}
final class LightField:NSObject{
    let settings:RelightSettings;let values:[Float]
    init(_ settings:RelightSettings,_ values:[Float]){self.settings=settings;self.values=values}
}
@MainActor final class RelightCache{
    let images=NSCache<NSString,RelightResult>()
    let fields=NSCache<NSString,LightField>()
    init(){images.totalCostLimit=48*1024*1024;fields.totalCostLimit=16*1024*1024}
    func gains(_ scene:SceneData,reference:SceneReference,settings:RelightSettings,mesh:SurfaceMesh?=nil)->[Float]{
        let key="\(reference.analysisAsset)|\(reference.geometryAsset ?? "depth")" as NSString
        if let field=fields.object(forKey:key),field.settings==settings{return field.values}
        let values=RelightMath.gains(scene,settings:settings,mesh:mesh)
        fields.setObject(LightField(settings,values),forKey:key,cost:values.count*MemoryLayout<Float>.stride)
        return values
    }
}
enum RelightMath{
    static func gain(dx:Double,dy:Double,settings:RelightSettings)->Double{
        let az=settings.azimuth * .pi/180,el=settings.elevation * .pi/180
        let length=sqrt(dx*dx+dy*dy+1),nx = -dx/length,ny=dy/length,nz=1/length
        let dot=max(0,nx*cos(el)*cos(az)+ny*cos(el)*sin(az)+nz*sin(el))
        // A regularized ratio retains detail from the source photo; it does not remove its cast shadows.
        let baseline=settings.ambient+nz,target=settings.ambient+dot
        return max(0.25,min(3,1+settings.strength*(target/max(0.15,baseline)-1)))*pow(2,settings.exposure)
    }
    static func gain(normal:V3,settings:RelightSettings)->Double{
        var n=V3(normal.x*settings.relief,normal.y*settings.relief,normal.z)
        guard simd_length(n)>1e-8 else{return pow(2,settings.exposure)}
        n=simd_normalize(n)
        let az=settings.azimuth * .pi/180,el=settings.elevation * .pi/180
        let light=V3(cos(el)*cos(az),cos(el)*sin(az),sin(el))
        let baseline=settings.ambient+max(0,n.z),target=settings.ambient+max(0,simd_dot(n,light))
        return max(0.25,min(3,1+settings.strength*(target/max(0.15,baseline)-1)))*pow(2,settings.exposure)
    }
    static func blurredDepth(_ scene:SceneData)->[Float]{
        let w=scene.width,h=scene.height,radius=3
        var horizontal=scene.depth,out=scene.depth
        for y in 0..<h{for x in 0..<w{
            var sum:Float=0;var n:Float=0
            for xx in max(0,x-radius)...min(w-1,x+radius){sum += scene.depth[y*w+xx];n += 1};horizontal[y*w+x]=sum/n
        }}
        for y in 0..<h{for x in 0..<w{
            var sum:Float=0;var n:Float=0
            for yy in max(0,y-radius)...min(h-1,y+radius){sum += horizontal[yy*w+x];n += 1};out[y*w+x]=sum/n
        }}
        return out
    }
    static func gains(_ scene:SceneData,settings:RelightSettings,mesh:SurfaceMesh?=nil)->[Float]{
        let w=scene.width,h=scene.height,depth=blurredDepth(scene)
        var values=[Float](repeating:1,count:w*h)
        for y in 0..<h{for x in 0..<w{
            let dx=Double(depth[y*w+min(w-1,x+1)]-depth[y*w+max(0,x-1)])*Double(w)*0.35*settings.relief
            let dy=Double(depth[min(h-1,y+1)*w+x]-depth[max(0,y-1)*w+x])*Double(h)*0.35*settings.relief
            if let mesh,!mesh.sourceNormalField.isEmpty{
                let nx=min(mesh.sourceNormalWidth-1,x*mesh.sourceNormalWidth/w),ny=min(mesh.sourceNormalHeight-1,y*mesh.sourceNormalHeight/h)
                let n=mesh.sourceNormalField[ny*mesh.sourceNormalWidth+nx]
                if simd_length(n)>0.5{values[y*w+x]=Float(gain(normal:V3(n.x,-n.y,-n.z),settings:settings));continue}
            }
            values[y*w+x]=Float(gain(dx:dx,dy:dy,settings:settings))
        }}
        return values
    }
    static let linear:[Float]=(0...255).map{value in
        let v=Double(value)/255
        return Float(v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4))
    }
    static let encoded:[UInt8]=(0...4096).map{value in
        let v=Double(value)/4096
        let s=v<=0.0031308 ? v*12.92:1.055*pow(v,1/2.4)-0.055
        return UInt8(clamping:Int((s*255).rounded()))
    }

}
@MainActor enum Relighter{
    static func reference(for layer:Layer,editor:Editor)->SceneReference?{
        if let ref=editor.painting.scene,ref.sourceID==layer.id{return ref}
        return editor.painting.scenes?.last(where:{$0.sourceID==layer.id})
    }
    static func owner(of layer:Layer,editor:Editor)->UUID?{
        guard layer.plane == .artwork,layer.frozenSources == nil else{return nil}
        if layer.imageAsset != nil{return layer.id}
        if let id=layer.surface?.reference.sourceID ?? layer.photoSourceID ?? layer.strokes.compactMap({$0.surface?.reference.sourceID}).first{return id}
        // Migrate older unbound edit layers by their nearest photo below in the stack.
        guard let index=editor.painting.layers.firstIndex(where:{$0.id==layer.id})else{return nil}
        return editor.painting.layers[..<index].last(where:{$0.plane == .artwork && $0.imageAsset != nil})?.id
    }
    static func light(for layer:Layer,editor:Editor)->(SceneReference,RelightSettings)?{
        guard let id=owner(of:layer,editor:editor),let photo=(layer.imageAsset != nil ? layer:editor.painting.layers.first(where:{$0.id==id})),
              let settings=photo.relighting,settings.enabled,settings.strength != 0 || settings.exposure != 0,
              let ref=reference(for:photo,editor:editor)else{return nil}
        return(ref,settings)
    }
    static func image(_ original:CGImage,layer:Layer,editor:Editor)->CGImage{
        editImage(MaterialPipeline.image(editor.previewPhoto(original,layer:layer),photo:layer,editor:editor),layer:layer,bounds:CGRect(x:0,y:0,width:layer.width,height:layer.height),editor:editor)
    }
    static func editImage(_ original:CGImage,layer:Layer,bounds:CGRect,editor:Editor)->CGImage{
        guard let (ref,settings)=light(for:layer,editor:editor),let scene=editor.sceneData(ref)else{return original}
        let world=bounds.offsetBy(dx:layer.x,dy:layer.y),frame=ref.frame
        let key="\(layer.id)|\(original.width)x\(original.height)" as NSString
        if let result=editor.relightCache.images.object(forKey:key),result.settings==settings,result.analysis==ref.analysisAsset,result.geometry==ref.geometryAsset,result.original === original,result.bounds==world,result.frame==frame{return result.image}
        let gains=editor.relightCache.gains(scene,reference:ref,settings:settings,mesh:ref.geometryAsset.flatMap{MeshPainter.mesh($0,editor:editor)})
        let w=original.width,h=original.height
        guard let cg=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let pixels=cg.data?.assumingMemoryBound(to:UInt8.self)else{return original}
        cg.draw(original,in:CGRect(x:0,y:0,width:w,height:h))
        let originX=Double(world.minX),originY=Double(world.minY)
        let stepX=Double(world.width)/Double(w),stepY=Double(world.height)/Double(h)
        let xcoords:[Double]=(0..<w).map{x in
            let position=originX+(Double(x)+0.5)*stepX
            return (position-frame.x)/frame.width
        }
        for y in 0..<h{
            let sy=(originY+(Double(y)+0.5)*stepY-frame.y)/frame.height
            guard sy>=0,sy<1 else{continue}
            let fy=max(0,min(Double(scene.height-1),sy*Double(scene.height)-0.5))
            let y0=Int(fy),y1=min(scene.height-1,y0+1),ty=Float(fy-Double(y0))
            for x in 0..<w{
                let sx=xcoords[x];guard sx>=0,sx<1 else{continue}
                let fx=max(0,min(Double(scene.width-1),sx*Double(scene.width)-0.5)),x0=Int(fx),x1=min(scene.width-1,x0+1),tx=Float(fx-Double(x0))
                let top=gains[y0*scene.width+x0]*(1-tx)+gains[y0*scene.width+x1]*tx
                let bottom=gains[y1*scene.width+x0]*(1-tx)+gains[y1*scene.width+x1]*tx
                let gain=top*(1-ty)+bottom*ty,i=y*cg.bytesPerRow+x*4,alpha=Float(pixels[i+3])/255
                guard alpha>0 else{continue}
                for c in 0..<3{
                    let channel=min(255,Int((Float(pixels[i+c])/alpha).rounded()))
                    let linear=RelightMath.linear[channel]*gain
                    let index=max(0,min(4096,Int((linear*4096).rounded())))
                    pixels[i+c]=UInt8(clamping:Int((Float(RelightMath.encoded[index])*alpha).rounded()))
                }
            }
        }
        guard let image=cg.makeImage()else{return original}
        editor.relightCache.images.setObject(RelightResult(settings,ref,original,image,world),forKey:key,cost:image.bytesPerRow*image.height+original.bytesPerRow*original.height)
        return image
    }

}
@MainActor extension Editor{
    var relightPhotoIndex:Int?{painting.layers.firstIndex{$0.id==activePhotoID && $0.imageAsset != nil && $0.plane == .artwork}}
    var currentRelight:RelightSettings{relightPhotoIndex.flatMap{painting.layers[$0].relighting} ?? RelightSettings(enabled:false)}
    var canRelight:Bool{guard !isPhotoFrozen(activePhotoID),let i=relightPhotoIndex,let ref=Relighter.reference(for:painting.layers[i],editor:self)else{return false};return sceneData(ref) != nil}
    func changeRelight(_ update:(inout RelightSettings)->Void){
        guard let i=relightPhotoIndex,canRelight else{status="Select and analyze a photo before relighting.";return}
        var next=currentRelight;update(&next)
        next.azimuth=max(-180,min(180,next.azimuth));next.elevation=max(5,min(90,next.elevation));next.strength=max(0,min(1,next.strength));next.relief=max(0,min(3,next.relief));next.ambient=max(0.1,min(2,next.ambient));next.exposure=max(-2,min(1,next.exposure))
        inspectorEdit("relight"){painting.layers[i].relighting=next}
    }
}
struct RelightInspector:View{
    @ObservedObject var editor:Editor
    func setting<T>(_ key:WritableKeyPath<RelightSettings,T>)->Binding<T>{Binding(get:{editor.currentRelight[keyPath:key]},set:{value in editor.changeRelight{$0[keyPath:key]=value}})}
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Text("RELIGHT PHOTO").font(.caption).foregroundStyle(.secondary)
            Text(editor.relightPhotoIndex.map{editor.painting.layers[$0].name} ?? "Select a photo").font(.headline)
            if editor.isPhotoFrozen(editor.activePhotoID){Text("Unfreeze the snapshot to change its material or lighting.").font(.caption)}
            if !editor.canRelight && !editor.isPhotoFrozen(editor.activePhotoID){Text("Analyze the selected photo to estimate its surface shape.").font(.caption);Button("Analyze Photo",action:editor.analyzePhoto).disabled(editor.analyzing)}
            Toggle("Use albedo + shading maps",isOn:Binding(get:{editor.usesMaterialMaps},set:editor.setMaterialWorkflow)).disabled(!editor.canRelight)
            HStack{Button("Edit Albedo"){editor.editMaterialMap(.albedo)};Button("Edit Shading"){editor.editMaterialMap(.shading)}}.disabled(!editor.canRelight)
            Text("Material strokes in Artwork retain the original photo shading and texture. Albedo and Shading maps remain available for direct editing.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Group{
                Toggle("Enable relighting",isOn:setting(\.enabled))
                Text("Light direction · \(Int(editor.currentRelight.azimuth))°")
                Slider(value:setting(\.azimuth),in:-180...180)
                Text("Light height · \(Int(editor.currentRelight.elevation))°")
                Slider(value:setting(\.elevation),in:5...90)
                Text("Strength · \(Int(editor.currentRelight.strength*100))%")
                Slider(value:setting(\.strength),in:0...1)
                Text("Ambient fill");Slider(value:setting(\.ambient),in:0.1...2)
                Text("Surface relief");Slider(value:setting(\.relief),in:0...3)
                Text("Exposure · \(editor.currentRelight.exposure,specifier:"%.1f") EV")
                Slider(value:setting(\.exposure),in:-2...1)
                Button("Reset light"){editor.changeRelight{$0=RelightSettings()}}
            }.disabled(!editor.canRelight)
            Text("Approximate lighting from AI surface normals when available, with depth fallback. Original texture is retained; existing cast shadows and reflections remain. Text and brushwork on this photo follow the same light. Saved with the photo layer and included in export.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
