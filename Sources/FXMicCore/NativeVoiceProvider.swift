/// Consumer apps whose native voice controls were inspected on the development Mac.
/// These descriptors do not represent API model providers or model subscriptions.
public enum NativeVoiceProvider: String, CaseIterable, Codable, Sendable {
    case claude, grok

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .grok: return "Grok Bot"
        }
    }

    public var bundleID: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .grok: return "com.anysphere.sand"
        }
    }

    /// Exact accessible button labels observed in the installed English interfaces.
    public var startVoiceButtonLabel: String {
        switch self {
        case .claude: return "Use voice mode"
        case .grok: return "Start voice chat"
        }
    }

    public func matchesStartVoiceButton(title: String?, description: String?) -> Bool {
        title == startVoiceButtonLabel || description == startVoiceButtonLabel
    }
}
