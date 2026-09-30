import Foundation

/// Main-thread policy for resuming a previously active native monitor on its exact input.
/// No device access, permission requests, timers, or callbacks are performed here.
public struct NativeInputReconnectPolicy {
    public struct Request: Equatable {
        public let uid: String
        public let attempt: Int
        fileprivate let generation: UInt64
        fileprivate let serial: UInt64
    }

    public private(set) var targetUID: String?
    private var deadline: TimeInterval?
    private var generation: UInt64 = 0
    private var serial: UInt64 = 0
    private var attempts = 0
    private var queued: Request?
    private var inFlight: Request?
    private let maximumAttempts: Int

    public init(maximumAttempts: Int = 3) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public var isWaiting: Bool { targetUID != nil }

    /// Called only after an active native monitor loses its device. Keep its idle deadline.
    public mutating func waitForReturn(uid: String, now: TimeInterval, deadline: TimeInterval?) {
        cancel()
        guard !uid.isEmpty, now.isFinite,
              deadline == nil || (deadline!.isFinite && deadline! > now) else { return }
        targetUID = uid
        self.deadline = deadline
    }

    /// Explicit Stop, input/mode changes, and idle expiry revoke every queued ticket.
    public mutating func cancel() {
        generation &+= 1
        targetUID = nil
        deadline = nil
        attempts = 0
        queued = nil
        inFlight = nil
    }

    @discardableResult
    public mutating func expire(now: TimeInterval) -> Bool {
        guard isWaiting else { return false }
        if !now.isFinite || deadline.map({ now >= $0 }) == true {
            cancel()
            return true
        }
        return false
    }

    /// Multiple device-list notifications coalesce into one ticket. Missing devices do
    /// not consume attempts. A revoked permission cancels intent without prompting.
    public mutating func schedule(availableUIDs: [String], authorized: Bool,
                                  now: TimeInterval) -> Request? {
        if !authorized { cancel(); return nil }
        guard !expire(now: now), let uid = targetUID, availableUIDs.contains(uid),
              queued == nil, inFlight == nil, attempts < maximumAttempts else { return nil }
        serial &+= 1
        let request = Request(uid: uid, attempt: attempts + 1, generation: generation, serial: serial)
        queued = request
        return request
    }

    public func isPending(_ request: Request) -> Bool {
        queued == request && request.generation == generation
    }

    /// Recheck identity, intent, permission and deadline immediately before opening.
    public mutating func begin(_ request: Request, availableUIDs: [String], authorized: Bool,
                               now: TimeInterval) -> Bool {
        guard queued == request, request.generation == generation else { return false }
        queued = nil
        if !authorized { cancel(); return false }
        guard !expire(now: now), targetUID == request.uid,
              availableUIDs.contains(request.uid), attempts < maximumAttempts else { return false }
        attempts += 1
        inFlight = request
        return true
    }

    /// A failed start can schedule another bounded attempt; success clears waiting.
    /// Late completions from an obsolete session cannot affect a newer session.
    public mutating func finish(_ request: Request, succeeded: Bool) {
        guard inFlight == request, request.generation == generation else { return }
        inFlight = nil
        if succeeded || attempts >= maximumAttempts { cancel() }
    }
}
