import AppKit

struct BrushTopography:Codable,Equatable{
    var enabled=true
    var relief=1.0
    var direction = -90.0
    var engine:Int? = nil
    var respectRegion:Bool? = nil
    var autoTarget:Bool? = nil
    var excludeRegion:Bool? = nil
    var keepDrawnShape:Bool? = nil
    var lockLayerSurface:Bool? = nil
}
enum SurfaceBrush{
    static func depth(_ point:Dot,scene:SceneData,frame:SceneFrame)->Double?{
        guard frame.contains(point)else{return nil}
        let fx=max(0,min(Double(scene.width-1),(point.x-frame.x)/frame.width*Double(scene.width)-0.5))
        let fy=max(0,min(Double(scene.height-1),(point.y-frame.y)/frame.height*Double(scene.height)-0.5))
        let x=Int(fx),y=Int(fy),tx=fx-Double(x),ty=fy-Double(y)
        let a=Double(scene.depth[y*scene.width+x]),b=Double(scene.depth[y*scene.width+min(scene.width-1,x+1)])
        let c=Double(scene.depth[min(scene.height-1,y+1)*scene.width+x]),d=Double(scene.depth[min(scene.height-1,y+1)*scene.width+min(scene.width-1,x+1)])
        return(a*(1-tx)+b*tx)*(1-ty)+(c*(1-tx)+d*tx)*ty
    }
    static func projected(_ ink:Ink,scene:SceneData)->Ink{
        guard ink.eraser != true,let style=ink.topography,style.enabled,style.relief>0,
              let ref=ink.surface?.reference,let start=ink.points.first,let end=ink.points.last,
              let firstDepth=depth(start,scene:scene,frame:ref.frame),let lastDepth=depth(end,scene:scene,frame:ref.frame)else{return ink}
        let dx=end.x-start.x,dy=end.y-start.y,length2=dx*dx+dy*dy
        guard length2>0.25 else{return ink}
        // Relative depth residual above the local endpoint plane. A plane stays straight;
        // a protrusion bends the gesture in the chosen projection direction.
        let angle=style.direction * .pi/180,scale=ref.frame.height*0.30*style.relief
        let limit=min(ref.frame.width,ref.frame.height)*0.08
        var points:[Dot]=[]
        for i in 0..<ink.points.count-1{
            let a=ink.points[i],b=ink.points[i+1],length=hypot(b.x-a.x,b.y-a.y)
            let steps=max(1,min(2048,Int(ceil(length/max(0.5,ink.width*0.12)))))
            for n in 0..<steps{
                let t=Double(n)/Double(steps),p=Dot(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)
                let along=max(0,min(1,((p.x-start.x)*dx+(p.y-start.y)*dy)/length2))
                let baseline=firstDepth+(lastDepth-firstDepth)*along
                let value=depth(p,scene:scene,frame:ref.frame) ?? baseline
                let offset=max(-limit,min(limit,(value-baseline)*scale))
                points.append(Dot(x:p.x+cos(angle)*offset,y:p.y+sin(angle)*offset))
            }
        }
        points.append(end)
        var result=ink;result.points=points;return result
    }
}
@MainActor extension Editor{
    func topographicInk(_ ink:Ink)->Ink{
        if ink.topography?.engine == 2,let result=MeshPainter.shape(ink,editor:self){
            var boundsInk=ink;boundsInk.points=[Dot(x:result.bounds.minX,y:result.bounds.minY),Dot(x:result.bounds.maxX,y:result.bounds.maxY)];return boundsInk
        }
        guard ink.topography?.engine != 2,ink.topography?.enabled == true,let ref=ink.surface?.reference,let scene=sceneData(ref)else{return ink}
        return SurfaceBrush.projected(ink,scene:scene)
    }
    func applyBrushTopography(){
        guard let i=activeIndex,let j=strokeIndex,painting.layers[i].strokes[j].surface != nil,painting.layers[i].strokes[j].eraser != true else{status="Select a surface brush stroke to wrap.";return}
        inspectorEdit("brush-topography"){painting.layers[i].strokes[j].topography=brushTopography;painting.layers[i].strokes[j].meshStroke=nil;painting.layers[i].strokes[j].id=UUID()}
        if let i=activeIndex,let j=strokeIndex{
            if brushTopography.respectRegion != true{painting.layers[i].strokes[j].surface?.reference.maskAsset=nil;painting.layers[i].strokes[j].surface?.reference.outline=nil}
            painting.layers[i].strokes[j].meshStroke=MeshPainter.stroke(painting.layers[i].strokes[j],editor:self)}
        status="Selected stroke now travels over the 3D surface · Original gesture preserved"
    }
}


enum PaintArea:String,CaseIterable,Identifiable{
    case everywhere="ESS · Every single surface",inside="ISS · Inside selected surface",outside="OSS · Outside selected surface"
    var id:String{rawValue}
}
@MainActor extension Editor{
    var paintArea:PaintArea{
        get{(brushTopography.respectRegion == true || lockSurface) ? (brushTopography.excludeRegion == true ? .outside:.inside):.everywhere}
        set{brushTopography.respectRegion=newValue != .everywhere;brushTopography.excludeRegion=newValue == .outside;brushTopography.autoTarget=false;lockSurface=newValue != .everywhere && painting.scene?.maskAsset != nil;if newValue != .everywhere{surfaceMode=painting.scene != nil}}
    }
    func capturePlainBrush()->Ink?{
        if plane == .artwork,preserveShading,isPhotoFrozen(activePhotoID){status="Unfreeze to edit material color, or turn off Keep photo shading to paint an overlay.";return nil}
        var ink=makeInk([],erasing:false)
        if paintArea != .everywhere && painting.scene?.maskAsset == nil{
            status="Choose a surface with Surface or Outline, then paint inside or outside it.";return nil
        }
        if var ref=painting.scene,(plane == .artwork && preserveShading) || paintArea != .everywhere{
            if paintArea == .everywhere{ref.maskAsset=nil;ref.outline=nil}
            ref.automaticTarget=false
            ink.surface=SurfaceBinding(reference:ref,shading:plane == .artwork && preserveShading ? shadeStrength:0,conform:0);ink.photoShading=true
        }
        return ink
    }
}
