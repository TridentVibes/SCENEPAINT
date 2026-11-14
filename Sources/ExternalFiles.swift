import Foundation
import Darwin

// Foundation's .atomic can ask macOS for a replacement directory outside the
// project folder. Use a sibling temporary file and same-volume atomic rename.
enum ExternalFiles {
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".scenepaint-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        let result = temporary.path.withCString { from in url.path.withCString { to in Darwin.rename(from, to) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
