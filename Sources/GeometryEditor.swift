import AppKit
import SceneKit

@MainActor extension Editor{
    var hasSurfaceMesh:Bool{guard let asset=painting.scene?.geometryAsset else{return false};return FileManager.default.fileExists(atPath:root.appendingPathComponent("Analysis").appendingPathComponent(asset).path)}
    func buildSurfaceMesh(){
        guard !buildingGeometry,let id=activePhotoID,let layer=painting.layers.first(where:{$0.id==id}),let asset=layer.imageAsset,painting.scene?.sourceID==id else{status="Analyze and select a photo before building its 3D surface.";return}
        let wallMasks=painting.scene!.wallConstraintMasks ?? []
        let completionEnabled=painting.scene!.completionEnabled != false
        var evidenceMasks=Set<String>()
        func collect(_ ref:SceneReference?){
            guard let ref,ref.sourceID==id,ref.analysisAsset==painting.scene!.analysisAsset else{return}
            if let mask=ref.maskAsset{evidenceMasks.insert(mask)}
            if let mask=ref.occlusionAsset{evidenceMasks.insert(mask)}
        }
        collect(painting.scene)
        for layer in painting.layers{collect(layer.surface?.reference);for stroke in layer.strokes{collect(stroke.surface?.reference)}}
        let masks=Array(evidenceMasks).sorted()
        let prior=painting.scene!.analysisAsset
        let detail=geometryDetail,taskRoot=root,name=UUID().uuidString+".spgeo",source=taskRoot.appendingPathComponent("Assets").appendingPathComponent(asset),output=taskRoot.appendingPathComponent("Analysis").appendingPathComponent(name)
        aiStarted=Date();geometryProgress=0.05;geometryStage="Loading geometry model";buildingGeometry=true;status="Building a 3D surface locally with MoGe-2 Base…"
        Task{
            do{
                let seconds=try await Task.detached(priority:.utility){
                    let process=Process();process.executableURL=ScenePaintPaths.resources(for:taskRoot).appendingPathComponent("Runtime/Geometry/bin/python")
                    process.arguments=[ScenePaintPaths.resources(for:taskRoot).appendingPathComponent("Geometry/analyze.py").path,source.path,output.path,"--tokens",String(detail),"--depth-prior",taskRoot.appendingPathComponent("Analysis").appendingPathComponent(prior).path]
                    if !completionEnabled{process.arguments! += ["--no-completion"]}
                    for mask in masks{process.arguments! += ["--surface-mask",taskRoot.appendingPathComponent("Analysis").appendingPathComponent(mask).path]}
                    for mask in wallMasks{process.arguments! += ["--wall-mask",taskRoot.appendingPathComponent("Analysis").appendingPathComponent(mask).path]}
                    var env=ProcessInfo.processInfo.environment;env["TMPDIR"]=taskRoot.appendingPathComponent("Temporary").path+"/";env["PYTHONDONTWRITEBYTECODE"]="1";env["HF_HOME"]=taskRoot.appendingPathComponent("Cache/HuggingFace").path
                    process.environment=env
                    let log=taskRoot.appendingPathComponent("Build/geometry-runtime.log")
                    if !FileManager.default.fileExists(atPath:log.path){FileManager.default.createFile(atPath:log.path,contents:nil)}
                    let handle=try FileHandle(forWritingTo:log);try handle.seekToEnd();defer{try? handle.close()}
                    let pipe=Pipe();process.standardOutput=pipe;process.standardError=handle
                    let started=Date();try process.run()
                    var buffer=Data()
                    while true{
                        let data=pipe.fileHandleForReading.availableData
                        if data.isEmpty{break};try? handle.write(contentsOf:data);buffer.append(data)
                        while let newline=buffer.firstIndex(of:10){
                            let line=Data(buffer[..<newline]);buffer.removeSubrange(...newline)
                            if let object=try? JSONSerialization.jsonObject(with:line) as? [String:Any],let stage=object["stage"] as? String{
                                await MainActor.run{
                                    switch stage{
                                    case "loaded":self.geometryProgress=0.2;self.geometryStage="Estimating depth and normals"
                                    case "inferred":self.geometryProgress=0.65;self.geometryStage="Neural prediction ready"
                                    case "refining":self.geometryProgress=0.72;self.geometryStage="Refining surface boundaries"
                                    case "completion":self.geometryProgress=0.85;self.geometryStage="Fitting object surfaces"
                                    case "saving":self.geometryProgress=0.95;self.geometryStage="Saving mesh and normals"
                                    default:break
                                    }
                                }
                            }
                        }
                    }
                    process.waitUntilExit()
                    guard process.terminationStatus==0 else{throw SceneError.message("3D surface analysis failed. See Build/geometry-runtime.log.")}
                    _ = try SurfaceMesh.read(output)
                    return Date().timeIntervalSince(started)
                }.value
                checkpoint()
                if painting.scene?.sourceID==id{painting.scene?.geometryAsset=name;storeActiveScene()}
                else if let i=painting.scenes?.firstIndex(where:{$0.sourceID==id}){painting.scenes?[i].geometryAsset=name}
                // Keep original assets for undo; reproject raw gestures onto the revised surface.
                let normalURL=output.deletingPathExtension().appendingPathExtension("normal.png")
                if FileManager.default.fileExists(atPath:normalURL.path){
                    let normalName=UUID().uuidString+".png"
                    try FileManager.default.copyItem(at:normalURL,to:taskRoot.appendingPathComponent("Assets").appendingPathComponent(normalName))
                    for i in painting.layers.indices where painting.layers[i].generatedFor==id && painting.layers[i].plane == .normals{
                        painting.layers[i].imageAsset=normalName;painting.layers[i].name="AI surface normals"
                    }
                }
                for i in painting.layers.indices{
                    if painting.layers[i].surface?.reference.sourceID==id{painting.layers[i].surface?.reference.geometryAsset=name}
                    for j in painting.layers[i].strokes.indices where painting.layers[i].strokes[j].surface?.reference.sourceID==id{
                        painting.layers[i].strokes[j].surface?.reference.geometryAsset=name
                        painting.layers[i].strokes[j].surface?.reference.occlusionAsset=nil
                        if painting.layers[i].strokes[j].meshStroke != nil{
                            painting.layers[i].strokes[j].meshStroke=nil
                            let ink=painting.layers[i].strokes[j]
                            painting.layers[i].strokes[j].meshStroke=MeshPainter.stroke(ink,editor:self)
                        }
                    }
                }
                status=String(format:"Surface ready in %.1f s · Depth, normals and bounded shape completion; existing strokes refreshed",seconds)
            }catch{fail(error)}
            geometryProgress=1;buildingGeometry=false
            if autoGeometry,activePhotoID != id,painting.scene != nil,!hasSurfaceMesh{buildSurfaceMesh()}
        }
    }
    func squareSelectedWall(){
        guard !buildingGeometry,var ref=painting.scene,let mask=ref.maskAsset else{status="Use Surface or Outline to select one wall face first.";return}
        checkpoint()
        var masks=ref.wallConstraintMasks ?? []
        if !masks.contains(mask){masks.append(mask)}
        ref.wallConstraintMasks=masks;painting.scene=ref;storeActiveScene()
        buildSurfaceMesh()
    }
    func inspectSurfaceMesh(){
        guard let reference=painting.scene,let asset=reference.geometryAsset,let mesh=MeshPainter.mesh(asset,editor:self)else{status="Build the 3D surface first.";return}
        for window in geometryWindows{window.close()};geometryWindows.removeAll()
        let positions=mesh.vertices.map{SCNVector3(Float($0.x),Float(-$0.y),Float(-$0.z))}
        let vertices=SCNGeometrySource(vertices:positions)
        let uv=mesh.vertices.map{p -> CGPoint in let v=mesh.camera.project(p);return CGPoint(x:v.x,y:v.y)}
        let texture=SCNGeometrySource(textureCoordinates:uv)
        let split=min(mesh.observedFaceCount,mesh.faces.count)
        let indices=mesh.faces.prefix(split).flatMap{[UInt32($0.x),UInt32($0.y),UInt32($0.z)]}
        let inferred=mesh.faces.dropFirst(split).flatMap{[UInt32($0.x),UInt32($0.y),UInt32($0.z)]}
        let geometry=SCNGeometry(sources:[vertices,texture],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles),SCNGeometryElement(indices:inferred,primitiveType:.triangles)])
        let material=SCNMaterial();material.isDoubleSided=false;material.lightingModel = .constant
        if let photo=painting.layers.first(where:{$0.id==reference.sourceID}),let image=image(for:photo){material.diffuse.contents=image}else{material.diffuse.contents=NSColor.gray}
        let estimate=SCNMaterial();estimate.diffuse.contents=NSColor.systemOrange;estimate.lightingModel = .constant;estimate.isDoubleSided=true
        geometry.materials=[material,estimate]
        let scene=SCNScene();scene.rootNode.addChildNode(SCNNode(geometry:geometry))
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.fieldOfView=CGFloat(2*atan(0.5/mesh.camera.fy)*180 / .pi);camera.camera?.zNear=0.01;camera.camera?.zFar=10000;scene.rootNode.addChildNode(camera)
        let view=SCNView(frame:NSRect(x:0,y:0,width:900,height:700));view.scene=scene;view.pointOfView=camera;view.allowsCameraControl=true;view.defaultCameraController.automaticTarget=true;view.autoenablesDefaultLighting=true;view.backgroundColor=NSColor(calibratedWhite:0.12,alpha:1)
        let window=NSWindow(contentRect:view.bounds,styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title="3D surface · Orange = inferred geometry · Drag to rotate";window.contentView=view;window.isReleasedWhenClosed=false;window.center();window.makeKeyAndOrderFront(nil);geometryWindows.append(window)
    }
}
