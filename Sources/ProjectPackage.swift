import Foundation

enum ProjectPackage{
    struct Manifest:Codable{var format=1;var assets:[String];var analysis:[String]}
    static func dependencies(_ painting:Painting,root:URL)throws->Manifest{
        let value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(painting))
        var assets=Set<String>(),analysis=Set<String>()
        func visit(_ value:Any,key:String=""){
            if let object=value as? [String:Any]{for (key,value) in object{visit(value,key:key)}}
            else if let values=value as? [Any]{for value in values{visit(value,key:key)}}
            else if let name=value as? String{
                if key=="imageAsset"{assets.insert(name)}
                else if key.hasSuffix("Asset") || key=="wallConstraintMasks"{analysis.insert(name)}
            }
        }
        visit(value)
        let files=(try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("Analysis").path)) ?? []
        for name in analysis where name.hasSuffix(".spgeo"){
            let prefix=String(name.dropLast(6))+"."
            analysis.formUnion(files.filter{$0.hasPrefix(prefix)})
        }
        return Manifest(assets:assets.sorted(),analysis:analysis.sorted())
    }
    static func safe(_ name:String)->Bool{!name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") && name==URL(fileURLWithPath:name).lastPathComponent && !name.contains("/") && !name.contains("\\")}
    static func copy(_ names:[String],from:URL,to:URL)throws{
        let fm=FileManager.default;try fm.createDirectory(at:to,withIntermediateDirectories:true)
        for name in names{
            guard safe(name)else{throw SceneError.message("Invalid project asset name.")}
            let source=from.appendingPathComponent(name),destination=to.appendingPathComponent(name)
            let values=try source.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile==true,values.isSymbolicLink != true else{throw SceneError.message("Project contains a missing or unsupported asset: \(name)")}
            if fm.fileExists(atPath:destination.path){
                guard fm.contentsEqual(atPath:source.path,andPath:destination.path)else{throw SceneError.message("An asset with the same name has different contents: \(name)")}
            }else{try fm.copyItem(at:source,to:destination)}
        }
    }
    static func save(_ painting:Painting,root:URL,to:URL)throws{
        let fm=FileManager.default,parent=to.deletingLastPathComponent()
        let stage=parent.appendingPathComponent(".ScenePaint-save-"+UUID().uuidString),backup=parent.appendingPathComponent(".ScenePaint-backup-"+UUID().uuidString)
        defer{try? fm.removeItem(at:stage)}
        try fm.createDirectory(at:stage,withIntermediateDirectories:true)
        let manifest=try dependencies(painting,root:root)
        try copy(manifest.assets,from:root.appendingPathComponent("Assets"),to:stage.appendingPathComponent("Assets"))
        try copy(manifest.analysis,from:root.appendingPathComponent("Analysis"),to:stage.appendingPathComponent("Analysis"))
        try ExternalFiles.write(JSONEncoder().encode(painting),to:stage.appendingPathComponent("document.json"))
        try ExternalFiles.write(JSONEncoder().encode(manifest),to:stage.appendingPathComponent("manifest.json"))
        let existed=fm.fileExists(atPath:to.path)
        if existed{try fm.moveItem(at:to,to:backup)}
        do{try fm.moveItem(at:stage,to:to)}catch{if existed{try? fm.moveItem(at:backup,to:to)};throw error}
        if existed{try? fm.removeItem(at:backup)}
    }
    static func load(_ url:URL,root:URL)throws->Painting{
        var directory:ObjCBool=false
        if !FileManager.default.fileExists(atPath:url.path,isDirectory:&directory){throw SceneError.message("Project file is missing.")}
        if !directory.boolValue{return try JSONDecoder().decode(Painting.self,from:Data(contentsOf:url))}
        let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:url.appendingPathComponent("manifest.json")))
        guard manifest.format==1 else{throw SceneError.message("Unsupported project package version.")}
        let painting=try JSONDecoder().decode(Painting.self,from:Data(contentsOf:url.appendingPathComponent("document.json")))
        guard painting.version==1,painting.width>0,painting.height>0,painting.width<=8192,painting.height<=8192 else{throw SceneError.message("Unsupported project canvas.")}
        // Validate and copy only declared dependencies, never arbitrary package contents.
        try copy(manifest.assets,from:url.appendingPathComponent("Assets"),to:root.appendingPathComponent("Assets"))
        try copy(manifest.analysis,from:url.appendingPathComponent("Analysis"),to:root.appendingPathComponent("Analysis"))
        let needed=try dependencies(painting,root:root)
        guard Set(needed.assets).isSubset(of:Set(manifest.assets)),Set(needed.analysis).isSubset(of:Set(manifest.analysis))else{throw SceneError.message("This project package is missing required assets.")}
        return painting
    }
}
