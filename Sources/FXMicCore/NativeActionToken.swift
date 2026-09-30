import Foundation

/// Serializes cancellation with the final native UI action. No action begins after cancel returns.
public final class NativeActionToken: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    public init() {}
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }
    /// The action must be bounded and must not call back into this token.
    public func performIfActive<T>(_ action: () -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        return action()
    }
}
