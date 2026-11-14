import Foundation
import CoreML

@main struct CompileModels{
    static func main()throws{
        guard CommandLine.arguments.count==3 else{throw NSError(domain:"ScenePaintSetup",code:1,userInfo:[NSLocalizedDescriptionKey:"Usage: CompileModels model.mlpackage output-directory"])}
        let input=URL(fileURLWithPath:CommandLine.arguments[1]),directory=URL(fileURLWithPath:CommandLine.arguments[2])
        let destination=directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent+".mlmodelc")
        if FileManager.default.fileExists(atPath:destination.path){print("Already compiled: "+destination.lastPathComponent);return}
        let compiled=try MLModel.compileModel(at:input)
        defer{try? FileManager.default.removeItem(at:compiled)}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:compiled,to:destination)
        print("Compiled: "+destination.lastPathComponent)
    }
}
