import Foundation

/// Identifies the only reply that may play; squeezing invalidates all older replies.
public struct VoiceTurnGate {
    public private(set) var turnID = UUID().uuidString
    public private(set) var held = false
    public private(set) var serial = 0
    private var accepted = Set<String>()
    public init() {}

    public mutating func press(serial: Int) {
        self.serial = serial
        turnID = UUID().uuidString
        held = true
        accepted.removeAll()
    }
    public mutating func release() { held = false }
    public mutating func cancel() {
        turnID = UUID().uuidString
        accepted.removeAll()
    }
    public mutating func accept(replyID: String, turnID: String) -> Bool {
        guard !held, self.turnID == turnID, !accepted.contains(replyID) else { return false }
        accepted.insert(replyID)
        return true
    }
}
