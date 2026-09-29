import Foundation

/// Plain-text log at ~/.fxmic/fxmic.log plus a state.json snapshot, so the app can be inspected from a terminal.
enum Log {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/EP2350Voice")
    static let url = dir.appendingPathComponent("fxmic.log")
    private static let queue = DispatchQueue(label: "fxmic.log")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        NSLog("[fxmic] %@", message)
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                h.closeFile()
            }
        }
    }

    static func state(_ fields: [String: Any]) {
        var record = fields
        record["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        queue.async {
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("state.json"))
            }
        }
    }
}
