import AppKit

@MainActor extension Editor{
    /// Publish a mesh only after depth guidance is ready. Never mutate a mesh on
    /// a worker while the canvas can read it. One job per immutable geometry asset.
    func prepareBrushResources(_ ref:SceneReference)async{
        if let asset=ref.geometryAsset,let scene=sceneData(ref){
            let resourceKey=asset+"|"+ref.analysisAsset
            if let pending=brushResourceTasks[resourceKey]{await pending.value}
            else if meshCache.meshes.object(forKey:asset as NSString)?.mesh.depthGuideKey != ref.analysisAsset{
                let url=root.appendingPathComponent("Analysis").appendingPathComponent(asset)
                let task=Task{[weak self] in
                    let mesh=try? await Task.detached(priority:.utility){
                        let mesh=try SurfaceMesh.read(url)
                        mesh.prepareDepthEdges(scene,key:ref.analysisAsset)
                        return mesh
                    }.value
                    guard let self,let mesh else{return}
                    self.meshCache.meshes.setObject(SurfaceMeshBox(mesh),forKey:asset as NSString,cost:mesh.vertices.count*32+mesh.faces.count*56+mesh.occlusionDepth.count*4+mesh.sourceNormalField.count*24+mesh.guidedDepth.count*4)
                }
                brushResourceTasks[resourceKey]=task
                await task.value;brushResourceTasks.removeValue(forKey:resourceKey)
            }
        }
        if let asset=ref.samAsset,let url=analysisURL(asset){try? await SAMService.shared.warmUp(root:root,featuresURL:url)}
    }
    /// The costly full-photo pixel passes run away from the UI thread. Keep the
    /// most recent material alive even if the bounded document cache evicts it.
    func prepareSurfaceMaterial(_ ink:Ink)async{
        guard let binding=ink.surface,let key=surfaceMaterialKey(ink)else{return}
        if preparedLiveMaterial?.key==key{return}
        if let image=sceneCache.strokes.object(forKey:key)?.cgImage(forProposedRect:nil,context:nil,hints:nil){preparedLiveMaterial=(key,image);return}
        guard let scene=sceneData(binding.reference)else{return}
        var mask:[UInt8]
        if binding.reference.maskAsset != nil && (ink.photoShading == true || binding.reference.automaticTarget == true || ink.topography?.respectRegion == true){
            guard let selected=maskData(binding.reference)else{return};mask=selected
        }else{mask=[UInt8](repeating:255,count:scene.count)}
        if ink.invertSelection == true,binding.reference.maskAsset != nil{mask=mask.map{255-$0}}
        let photo=painting.layers.first{$0.id==binding.reference.sourceID}.flatMap{self.image(for:$0)}?.cgImage(forProposedRect:nil,context:nil,hints:nil)
        let image=await Task.detached(priority:.utility){
            photo.flatMap{SurfacePaint.photoMaterial(ink,binding:binding,scene:scene,mask:mask,photo:$0)} ?? SurfacePaint.material(ink,binding:binding,scene:scene,mask:mask)
        }.value
        guard let image else{return}
        sceneCache.strokes.setObject(NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)),forKey:key,cost:image.bytesPerRow*image.height)
        preparedLiveMaterial=(key,image)
    }
}

@MainActor extension Editor{
    func invalidateRenderedStroke(_ ink:Ink){
        for layer in painting.layers where layer.strokes.contains(where:{$0.id==ink.id}){layerRenderEpochs[layer.id,default:0] += 1}
        renderEpoch += 1
    }
}
