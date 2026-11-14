import AppKit
import simd

struct MeshGridPaths{let axes:[CGPath]}
enum MeshGridBuilder{
    static func build(_ mesh:SurfaceMesh,density:Int)->MeshGridPaths{
        let axes=(0..<3).map{_ in CGMutablePath()}
        let valid=mesh.vertices.filter{$0.z>0 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite}
        guard valid.count>3 else{return MeshGridPaths(axes:axes)}
        var lower=V3.zero,step=V3.zero
        for axis in 0..<3{let values=valid.map{$0[axis]}.sorted();lower[axis]=values[values.count/100];let upper=values[values.count*99/100];step[axis]=max(1e-6,(upper-lower[axis])/Double(density))}
        var segments=0
        for face in mesh.faces.prefix(mesh.observedFaceCount){
            let points=[mesh.vertices[Int(face.x)],mesh.vertices[Int(face.y)],mesh.vertices[Int(face.z)]]
            guard points.allSatisfy({$0.z>0})else{continue}
            for axis in 0..<3{
                let lo=points.map{$0[axis]}.min()!,hi=points.map{$0[axis]}.max()!
                let first=max(0,Int(ceil((lo-lower[axis])/step[axis]))),last=min(density,Int(floor((hi-lower[axis])/step[axis])))
                guard first<=last else{continue}
                for level in first...last{
                    let value=lower[axis]+Double(level)*step[axis];var intersections=[CGPoint]()
                    for edge in 0..<3{let a=points[edge],b=points[(edge+1)%3],delta=b[axis]-a[axis];guard abs(delta)>1e-10 else{continue};let t=(value-a[axis])/delta
                        if t>=0 && t<1{let uv=mesh.camera.project(a+(b-a)*t);intersections.append(CGPoint(x:uv.x,y:uv.y))}
                    }
                    if intersections.count==2{axes[axis].move(to:intersections[0]);axes[axis].addLine(to:intersections[1]);segments += 1}
                }
            }
            if segments>200_000{break}
        }
        return MeshGridPaths(axes:axes)
    }
}
@MainActor final class MeshGridOverlay{
    var key:String?;var paths:MeshGridPaths?;var task:Task<Void,Never>?
    func draw(in cg:CGContext,frame:SceneFrame,scale:Double){
        guard let paths else{return};cg.saveGState();defer{cg.restoreGState()}
        cg.clip(to:CGRect(x:frame.x,y:frame.y,width:frame.width,height:frame.height));cg.translateBy(x:frame.x,y:frame.y);cg.scaleBy(x:frame.width,y:frame.height)
        cg.setLineWidth(0.8/max(0.001,scale*sqrt(frame.width*frame.height)));cg.setShouldAntialias(true)
        for (i,path) in paths.axes.enumerated(){cg.setStrokeColor((i==2 ? NSColor.systemYellow:NSColor.systemCyan).withAlphaComponent(0.65).cgColor);cg.addPath(path);cg.strokePath()}
    }
}
@MainActor extension PaintView{
    func prepareGrid(){
        guard editor.showMeshGrid,let reference=editor.painting.scene,let asset=reference.geometryAsset else{grid.task?.cancel();grid.task=nil;grid.key=nil;grid.paths=nil;return}
        let density=Int(editor.gridDensity),key=asset+"|\(density)"
        guard grid.key != key else{return};grid.key=key;grid.paths=nil;grid.task?.cancel()
        let url=editor.root.appendingPathComponent("Analysis").appendingPathComponent(asset)
        grid.task=Task{[weak self] in
            let paths=await Task.detached(priority:.utility){()->MeshGridPaths? in guard let mesh=try? SurfaceMesh.read(url)else{return nil};return MeshGridBuilder.build(mesh,density:density)}.value
            guard let self,!Task.isCancelled,self.grid.key==key else{return};self.grid.paths=paths;self.needsDisplay=true
        }
    }
}
