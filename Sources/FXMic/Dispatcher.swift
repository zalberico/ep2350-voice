import AppKit
import Foundation

struct Target: Codable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let armedAt: Date
}

/// Where utterances go: Claude Code sessions that registered themselves under ~/.fxmic/targets.
final class Dispatcher {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/EP2350Voice")
    var targetsDir: URL { root.appendingPathComponent("targets") }
    var inboxDir: URL { root.appendingPathComponent("inbox") }
    private(set) var targets: [Target] = []
    var onTargetsChanged: (() -> Void)?
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    init() {
        for dir in [targetsDir, inboxDir, root.appendingPathComponent("outbox")] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        reload()
        watchTargetsDir()
    }

    var currentTarget: Target? {
        if let id = Settings.shared.selectedTargetID, let t = targets.first(where: { $0.id == id }) { return t }
        return targets.max { $0.armedAt < $1.armedAt }
    }

    func select(_ id: String?) {
        Settings.shared.selectedTargetID = id
        onTargetsChanged?()
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: targetsDir, includingPropertiesForKeys: nil)) ?? []
        targets = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            if let t = try? decoder.decode(Target.self, from: data) { return t }
            // Tolerate a missing or non-ISO armedAt by falling back to the file date.
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = raw["id"] as? String {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                return Target(id: id, title: raw["title"] as? String ?? id, cwd: raw["cwd"] as? String ?? "", armedAt: date)
            }
            return nil
        }
        onTargetsChanged?()
    }

    enum Outcome { case sent(Target), copied }

    /// Appends the utterance to the current target's inbox, or copies it to the clipboard when no session is armed.
    func dispatch(text: String, locale: String, confidence: Double, seconds: Double) -> Outcome {
        guard let target = currentTarget else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .copied
        }
        append(["type": "utterance", "text": text, "locale": locale, "confidence": (confidence * 100).rounded() / 100, "seconds": (seconds * 10).rounded() / 10], to: target)
        return .sent(target)
    }

    func sendControl(_ type: String) -> Target? {
        guard let target = currentTarget else { return nil }
        append(["type": type], to: target)
        return target
    }

    private func append(_ fields: [String: Any], to target: Target) {
        var record = fields
        record["ts"] = ISO8601DateFormatter().string(from: Date())
        record["source"] = "ep-2350"
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let url = inboxDir.appendingPathComponent("\(target.id).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write("\n".data(using: .utf8)!)
            handle.closeFile()
        }
    }

    private func watchTargetsDir() {
        dirFD = open(targetsDir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { [weak self] in if let fd = self?.dirFD, fd >= 0 { close(fd) } }
        source.resume()
        dirSource = source
    }
}
