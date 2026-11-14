import AppKit

@MainActor extension Editor{
    var selectedFrozenLayer:Layer?{activeIndex.flatMap{painting.layers[$0].frozenSources != nil ? painting.layers[$0]:nil}}
    func isPhotoFrozen(_ id:UUID?)->Bool{
        guard let id else{return false}
        if let cache=frozenIDCache,cache.revision==contentRevision{return cache.ids.contains(id)}
        let ids=Set(painting.layers.flatMap{$0.frozenSources ?? []});frozenIDCache=(contentRevision,ids);return ids.contains(id)
    }
    var canFreezeVisible:Bool{
        guard plane == .artwork,!freezingLayers else{return false}
        let layers=displayedLayers.filter{$0.visible}
        return layers.count>1 || (layers.count==1 && (!layers[0].strokes.isEmpty || layers[0].text != nil))
    }
    func freezeVisibleLayers(){
        guard canFreezeVisible else{return}
        if hasMotion{freezeMotionStaticLayers();return}
        let location=root,project=sceneRevision
        if !analyzing && !buildingGeometry && !selectingSurface && !filling{aiStarted=Date()}
        freezingLayers=true;status="Freeze queued · Finishing pending strokes and AI work…"
        Task{
            defer{freezingLayers=false}
            do{
                // Wait for operations that change document content. Cache refreshes
                // are deliberately excluded: heavy stacks can keep those busy.
                let deadline=Date().addingTimeInterval(30)
                while analyzing || buildingGeometry || filling || selectionCount>0 || !pendingInk.isEmpty{
                    guard root==location,sceneRevision==project else{status="Project changed; freeze cancelled.";return}
                    guard Date()<deadline else{status="AI work is still running. Freeze again when it finishes.";return}
                    try await Task.sleep(for:.milliseconds(20))
                }
                guard root==location,sceneRevision==project,plane == .artwork else{status="Project view changed; freeze cancelled.";return}
                let revision=contentRevision,width=painting.width,height=painting.height
                let sources=displayedLayers.filter{$0.visible}.map{$0.id}
                guard !sources.isEmpty else{return}
                status="Freezing the visible result · Originals are retained"
                // Latch the latest displayed document image. A cache-quality update
                // may finish during PNG compression without changing the artwork.
                for _ in 0..<100{
                    if canvasSnapshotRevision==revision && canvasSnapshotPlane == .artwork && canvasSnapshot != nil{break}
                    try await Task.sleep(for:.milliseconds(20))
                }
                guard root==location,sceneRevision==project,contentRevision==revision,canvasSnapshotRevision==revision,canvasSnapshotPlane == .artwork,let image=canvasSnapshot else{status="Canvas changed while freezing. Try Freeze Visible again.";return}
                let asset=UUID().uuidString+".png"
                try await Task.detached(priority:.utility){try SceneWorker.png(image,to:location.appendingPathComponent("Assets").appendingPathComponent(asset))}.value
                guard contentRevision==revision,sceneRevision==project,root==location else{status="Canvas changed while freezing; original layers were kept.";return}
                let snapshot=Layer(name:"Frozen · \(sources.count) layers",width:width,height:height,imageAsset:asset,frozenSources:sources)
                let set=Set(sources);var updated=painting
                for i in updated.layers.indices where set.contains(updated.layers[i].id){updated.layers[i].frozenBy=snapshot.id}
                updated.layers.append(snapshot);checkpoint();painting=updated;selected=snapshot.id;selectedStroke=nil
                status="Frozen into one displayed layer · Select it and Unfreeze to restore the originals"
            }catch{fail(error)}
        }
    }
    var hasFrozenLayers:Bool{painting.layers.contains{$0.frozenSources != nil}}
    func unfreezeAllLayers(){
        guard !freezingLayers else{return}
        let snapshots=Set(painting.layers.filter{$0.frozenSources != nil}.map(\.id))
        guard !snapshots.isEmpty else{return}
        var restored=painting
        restored.layers.removeAll{snapshots.contains($0.id)}
        for i in restored.layers.indices{
            if let id=restored.layers[i].frozenBy,snapshots.contains(id){restored.layers[i].frozenBy=nil}
        }
        checkpoint();stopMotion(clear:true);painting=restored
        if !restored.layers.contains(where:{$0.id==selected}){selected=displayedLayers.last?.id}
        selectedStroke=nil
        status="All originals restored · Strokes, surfaces and Motion settings retained"
    }
    func unfreezeSelectedLayer(){
        guard let layer=selectedFrozenLayer,let sources=layer.frozenSources else{return}
        var updated=painting
        for i in updated.layers.indices where updated.layers[i].frozenBy==layer.id{updated.layers[i].frozenBy=nil}
        updated.layers.removeAll{$0.id==layer.id};checkpoint();painting=updated
        selected=sources.last;selectedStroke=nil;status="Original layers restored · Material and light edits are live again"
    }
}
