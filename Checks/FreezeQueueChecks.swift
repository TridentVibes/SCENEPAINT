import AppKit

struct FreezeQueueChecks{
 @MainActor static func main()async throws{
  let root=URL(fileURLWithPath:"Temporary/FreezeQueue"),editor=Editor()
  ScenePaintPaths.prepare(root);editor.rootOverride=root;editor.painting.width=128;editor.painting.height=128
  var originals=[Layer]()
  for i in 0..<12{
   let y=Double(i)*9
   let points=[Dot(x:5,y:y+5),Dot(x:120,y:y+9)]
   let ink=Ink(points:points,width:5,red:0.8,green:0.3,blue:0.2)
   originals.append(Layer(name:"Paint \(i)",strokes:[ink]))
  }
  editor.painting.layers=originals
  let preview=CanvasMotionPreview();_ = preview.raster(editor)
  func check(_ value:Bool,_ text:String){precondition(value,text);print("PASS: "+text);fflush(stdout)}
  func wait()async throws{let deadline=Date().addingTimeInterval(5);while editor.freezingLayers && Date()<deadline{try await Task.sleep(for:.milliseconds(5))};precondition(!editor.freezingLayers,"Freeze must finish")}
  // Reproduce the exact busy-cache state that previously refused to freeze.
  editor.meshRenderJobs.insert("cache remains busy");editor.materialJobs.insert("cache remains busy");editor.materialUpdates=1
  let cacheUpdates=Task{for _ in 0..<100{try? await Task.sleep(for:.milliseconds(1));if Task.isCancelled{return};editor.renderEpoch += 1}}
  editor.freezeVisibleLayers();try await wait();cacheUpdates.cancel()
  check(editor.displayedLayers.count==1 && editor.selectedFrozenLayer != nil,"Freeze succeeds while mesh/material cache jobs remain active")
  check(editor.selectedFrozenLayer?.frozenSources?.count==12 && editor.painting.layers.count==13,"All original layers remain in the frozen project")
  editor.unfreezeSelectedLayer()
  check(editor.painting.layers==originals,"Unfreeze restores every original layer unchanged")
  editor.meshRenderJobs.removeAll();editor.materialJobs.removeAll();editor.materialUpdates=0
  _ = preview.raster(editor)
  editor.selectionCount=1;editor.pendingInk=[Ink(points:[Dot(x:1,y:1)],width:2,red:1,green:0,blue:0)]
  _ = preview.raster(editor)
  editor.freezeVisibleLayers()
  try await Task.sleep(for:.milliseconds(40))
  check(editor.freezingLayers && editor.selectedFrozenLayer==nil,"Freeze queues rather than failing when a stroke/selection is pending")
  editor.selectionCount=0;editor.pendingInk=[]
  try await Task.sleep(for:.milliseconds(40))
  check(editor.freezingLayers && editor.selectedFrozenLayer==nil,"Freeze does not bake a stale pending-stroke preview")
  _ = preview.raster(editor)
  try await wait()
  check(editor.selectedFrozenLayer != nil,"Queued freeze completes automatically after pending work finishes")
  editor.unfreezeSelectedLayer();_ = preview.raster(editor)
  editor.analyzing=true;editor.freezeVisibleLayers();editor.sceneRevision=UUID();editor.analyzing=false
  try await wait()
  check(editor.selectedFrozenLayer==nil && editor.painting.layers==originals,"Switching projects cancels queued freeze without hiding originals")
  // Exercise the original save/reopen, nested-freeze and pixel-preservation tests.
  try await FreezeLayerChecks.main()
 }
}
