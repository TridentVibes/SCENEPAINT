import Foundation

enum ScenePaintPaths{
    static let projectTypeIdentifier="local.scenepaint.project"
    static var isRelease:Bool{Bundle.main.object(forInfoDictionaryKey:"ScenePaintRelease") as? Bool == true}
    static var windowTitle:String{isRelease ? "ScenePaint v0.2":"ScenePaint 0.2 · Development"}
    static var bundledDemo:URL?{
        let url=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ScenePaint/Demo/Pumpkin Motion.scenepaint")
        return FileManager.default.fileExists(atPath:url.appendingPathComponent("document.json").path) ? url:nil
    }
    static var developmentRoot:URL{
        if isRelease{
            return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ScenePaint",isDirectory:true)
        }
        let parent=Bundle.main.bundleURL.deletingLastPathComponent()
        return parent.lastPathComponent=="Build" ? parent.deletingLastPathComponent():parent.appendingPathComponent("ScenePaint Data")
    }
    static func resources(for dataRoot:URL)->URL{
        let bundled=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ScenePaint")
        return FileManager.default.fileExists(atPath:bundled.appendingPathComponent("Models").path) ? bundled:dataRoot
    }
    static func prepare(_ root:URL){for name in ["Assets","Analysis","Projects","Build","Cache","Temporary"]{try? FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)}}
}
