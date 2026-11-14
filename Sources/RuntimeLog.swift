import Foundation

enum RuntimeLog {
    static func write(root: URL, _ message: String) {
        let url = root.appendingPathComponent("Build/analysis-runtime.log")
        var data = (try? Data(contentsOf: url)) ?? Data()
        if data.count > 64*1024 { data = Data(data.suffix(32*1024)) }
        data.append(Data("\(Date().timeIntervalSince1970) \(message)\n".utf8))
        try? ExternalFiles.write(data, to: url)
    }
}
