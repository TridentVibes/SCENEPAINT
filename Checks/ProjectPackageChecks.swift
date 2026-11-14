import AppKit
struct ProjectPackageChecks{
 static func main()throws{
  let fm=FileManager.default,base=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Temporary/ProjectPackageChecks-"+UUID().uuidString)
  defer{try? fm.removeItem(at:base)}
  let source=base.appendingPathComponent("source"),target=base.appendingPathComponent("other-drive")
  for root in [source,target]{for folder in ["Assets","Analysis"]{try fm.createDirectory(at:root.appendingPathComponent(folder),withIntermediateDirectories:true)}}
  var p=Painting();let photo=Layer(name:"Test",imageAsset:"photo.png");p.layers=[photo]
  p.scene=SceneReference(sourceID:photo.id,analysisAsset:"scene.json",maskAsset:"wall.mask",frame:SceneFrame(x:0,y:0,width:1200,height:800),geometryAsset:"mesh.spgeo")
  try Data([1,2,3]).write(to:source.appendingPathComponent("Assets/photo.png"))
  for file in ["scene.json","wall.mask","mesh.spgeo","mesh.spnormal","mesh.spregion","mesh.completion.json"]{try Data(file.utf8).write(to:source.appendingPathComponent("Analysis/"+file))}
  let url=base.appendingPathComponent("Portable.scenepaint")
  try ProjectPackage.save(p,root:source,to:url)
  let loaded=try ProjectPackage.load(url,root:target)
  precondition(loaded.layers.first?.name=="Test")
  precondition(fm.fileExists(atPath:target.appendingPathComponent("Analysis/mesh.spnormal").path))
  p.layers[0].name="Updated";try ProjectPackage.save(p,root:source,to:url)
  let second=try ProjectPackage.load(url,root:target);precondition(second.layers.first?.name=="Updated")
  let prior=base.appendingPathComponent("Previous.scenepaint")
  try fm.copyItem(at:url,to:prior)
  let priorLoaded=try ProjectPackage.load(prior,root:target)
  precondition(priorLoaded.layers.first?.name=="Updated")
  try fm.removeItem(at:source.appendingPathComponent("Assets/photo.png"))
  do{try ProjectPackage.save(p,root:source,to:url);fatalError("Missing photo must reject save")}catch{}
  let preserved=try ProjectPackage.load(url,root:target);precondition(preserved.layers.first?.name=="Updated","A failed save must preserve the previous project")
  precondition(!ProjectPackage.safe("../private.png") && !ProjectPackage.safe("..") && ProjectPackage.safe("photo.png"))
  let legacy=base.appendingPathComponent("Legacy.scenepaint");try JSONEncoder().encode(p).write(to:legacy)
  let old=try ProjectPackage.load(legacy,root:target);precondition(old.layers.count==1)
  print("PASS: .scpt and .scenepaint compatibility, portable project roundtrip, geometry sidecars, replacement, failed-save preservation, safe names, legacy loading")
 }
}
