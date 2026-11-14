import AppKit
import CoreML

struct DrawingUpgradeChecks{
    @MainActor static func main()async throws{
        let root=URL(fileURLWithPath:"Temporary/DrawingUpgrade")
        ScenePaintPaths.prepare(root)
        func assert(_ condition:Bool,_ text:String){precondition(condition,text);print("PASS: "+text);fflush(stdout)}
        func bitmap(_ ink:Ink)->[UInt8]{
            let cg=CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:128*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            BrushEngine.draw(ink,in:cg);return Array(UnsafeBufferPointer(start:cg.data!.assumingMemoryBound(to:UInt8.self),count:128*128*4))
        }
        let drag=[Dot(x:20,y:20),Dot(x:60,y:35),Dot(x:100,y:100)]
        for shape in [DrawingAssist.rectangle,.ellipse,.triangle]{
            var ink=Ink(brush:BrushPreset.hard.settings,points:DrawingGeometry.points(drag,assist:shape),width:5,red:1,green:0,blue:0);ink.closed=true
            let outline=bitmap(ink);ink.filled=true;let solid=bitmap(ink)
            assert(outline[(60*128+60)*4+3]==0 && solid[(60*128+60)*4+3]>200,"\(shape.rawValue) supports hollow and solid centers")
        }
        var line=Ink(brush:BrushPreset.hard.settings,points:[Dot(x:8,y:64),Dot(x:120,y:64)],width:7,red:1,green:1,blue:1);line.smooth=true;line.brush?.flow=0.4;line.brush?.spacing=0.8
        let pixels=bitmap(line)
        assert((12...116).allSatisfy{pixels[(64*128+$0)*4+3]>90},"Low-flow hard brush stays continuous even with sparse input and wide spacing")
        assert(pixels.enumerated().contains{$0.offset%4==3 && $0.element>0 && $0.element<90},"Stroke edges contain antialiased coverage")
        let arc=(0...50).map{i in let t=Double(i)/50;return Dot(x:10+100*t,y:10+160*t*(1-t))}
        let fitted=DrawingGeometry.points(arc,assist:.curve)
        assert(fitted.first==arc.first && fitted.last==arc.last && fitted.map{$0.y}.max()!>45,"Curve assist keeps endpoints and fits the drawn arc")
        let snapped=DrawingGeometry.points([Dot(x:0,y:0),Dot(x:60,y:48)],assist:.line,constrained:true)
        assert(abs(snapped[1].x-snapped[1].y)<0.001,"Shift snaps straight lines to 45 degrees")
        var rgb=[UInt8](repeating:255,count:100*100*4)
        for y in 0..<100{for x in 49...51{for c in 0..<3{rgb[(y*100+x)*4+c]=0}}}
        let source=SceneWorker.raster(rgb,width:100,height:100)!
        let fill=SmartFillRaster.mask(image:source,seed:Dot(x:0.2,y:0.2),tolerance:0.1)!
        assert(fill.mask[20*100+20]==255 && fill.mask[20*100+80]==0,"Connected fill stops at closed line-art boundaries")
        let coloredScene=SceneData(width:32,height:32,depth:[Float](repeating:0.5,count:1024),person:[UInt8](repeating:0,count:1024),rgb:(0..<1024).flatMap{_ in [UInt8(150),UInt8(70),UInt8(30)]},elapsed:0,segmentationAvailable:true)
        let albedo=coloredScene.rgbaMap(.albedo)
        assert(albedo[0]>albedo[1] && albedo[1]>albedo[2] && albedo[3]==255,"Albedo is an opaque color estimate rather than an empty or grayscale map")
        let editor=Editor();editor.rootOverride=root;editor.autoAnalyze=false;editor.autoGeometry=false
        editor.painting.width=1200;editor.painting.height=800
        let strokes=(0..<100).map{j in Ink(brush:BrushPreset.hard.settings,opacity:0.8,points:(0..<100).map{i in Dot(x:Double(i)*10,y:Double(j)*6+sin(Double(i))*3)},width:5,red:0.8,green:0.2,blue:0.4)}
        let layer=Layer(name:"Latency artwork",strokes:strokes);editor.painting.layers=[layer];editor.selected=layer.id
        let cache=CanvasMotionPreview();editor.interactiveRender=true
        let coldStart=Date();let first=cache.raster(editor)!;let cold=Date().timeIntervalSince(coldStart),warmStart=Date()
        for i in 0..<100{editor.zoom=1+Double(i)/20;editor.panX=Double(i)*3;editor.panY=Double(i)*2;assertIdentity(cache.raster(editor)!,first)}
        let warm=Date().timeIntervalSince(warmStart)
        assert(cache.builds==1,"100 zoom/pan updates reuse the same composite without rebuilding paint")
        let misses=editor.renderCache.misses
        editor.painting.layers[0].x=40;_ = cache.raster(editor)
        assert(editor.renderCache.misses==misses,"Moving a plain paint layer reuses its raster")
        editor.interactiveRender=false
        let encoded=try JSONEncoder().encode(line),decoded=try JSONDecoder().decode(Ink.self,from:encoded)
        assert(decoded==line,"New stroke settings round-trip through project serialization")
        var legacy=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        for key in ["smooth","closed","filled","photoShading"]{legacy.removeValue(forKey:key)}
        assert((try JSONDecoder().decode(Ink.self,from:JSONSerialization.data(withJSONObject:legacy))).smooth==nil,"Older stroke documents still decode")
        let view=PaintView(editor);view.frame=CGRect(x:0,y:0,width:1200,height:800);editor.fitCanvas();editor.drawingAssist = .line;editor.tool = .brush;editor.analyzing=true
        func event(_ type:NSEvent.EventType,_ x:Double,_ y:Double)->NSEvent{NSEvent.mouseEvent(with:type,location:CGPoint(x:x,y:y),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
        view.mouseDown(with:event(.leftMouseDown,100,100));view.mouseDragged(with:event(.leftMouseDragged,200,140));view.mouseUp(with:event(.leftMouseUp,300,200))
        assert(editor.painting.layers.last!.strokes.last!.points.count==2,"Straight-line input commits two endpoints while AI runs without blocking ordinary paint")
        editor.analyzing=false
        // Exercise the actual asynchronous mesh path while a main-actor heartbeat runs.
        let sw=32,sh=32,camera=MeshCamera(fx:1,fy:1)
        var data=Data("SPGEO001".utf8)
        func append<T>(_ value:T){var value=value;withUnsafeBytes(of:&value){data.append(contentsOf:$0)}}
        append(UInt32(sw));append(UInt32(sh));append(Float(1));append(Float(1))
        for y in 0..<sh{for x in 0..<sw{let uv=V2((Double(x)+0.5)/Double(sw),(Double(y)+0.5)/Double(sh)),p=camera.unproject(uv,depth:2);append(Float(p.x));append(Float(p.y));append(Float(p.z))}}
        try data.write(to:root.appendingPathComponent("Analysis/test.spgeo"))
        let photo=Layer(name:"Test photo",width:1200,height:800)
        editor.painting.layers.append(photo)
        let analysis=try editor.writeScene(coloredScene)
        let ref=SceneReference(sourceID:photo.id,analysisAsset:analysis,maskAsset:nil,frame:SceneFrame(x:0,y:0,width:1200,height:800),seed:nil,geometryAsset:"test.spgeo")
        editor.painting.scene=ref;editor.painting.activePhotoID=photo.id
        var wrapped=Ink(surface:SurfaceBinding(reference:ref,shading:0,conform:0),brush:BrushPreset.hard.settings,topography:BrushTopography(engine:2),points:(0...120).map{i in Dot(x:150+Double(i)*6,y:300+sin(Double(i)/10)*30)},width:30,red:0,green:0.5,blue:1)
        wrapped.photoShading=true
        editor.interactiveRender=true;let requestStart=Date();let pending=MeshPainter.render(wrapped,editor:editor,quality:1);let requestTime=Date().timeIntervalSince(requestStart);editor.interactiveRender=false
        assert(pending==nil && requestTime<0.1,"Cold mesh rendering queues work and returns to input in under 100 ms")
        var beats=0;let deadline=Date().addingTimeInterval(30)
        while !editor.meshRenderJobs.isEmpty && Date()<deadline{try await Task.sleep(for:.milliseconds(10));beats += 1}
        let result=editor.meshCache.paint.object(forKey:"\(wrapped.id!)|1" as NSString)
        assert(result != nil && beats>0,"Mesh raster completes on a worker while the main actor remains responsive")
        let grid=MeshGridBuilder.build(try SurfaceMesh.read(root.appendingPathComponent("Analysis/test.spgeo")),density:12)
        assert(grid.axes.contains{!$0.isEmpty},"Surface overlay generates world-space contour paths")
        print(String(format:"TIMING: cold composite %.3f s; 100 warm navigation updates %.4f s; mesh request %.4f s; %d main-actor heartbeats",cold,warm,requestTime,beats))
        // Compare existing append/eraser rendering against the repository regression check.
    }
    static func assertIdentity(_ a:CGImage,_ b:CGImage){precondition(a === b)}
}
