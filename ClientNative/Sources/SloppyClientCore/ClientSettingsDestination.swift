public enum ClientSettingsDestination: String, Sendable, Equatable, Identifiable {
    case account
    case general
    case providers
    case migrations

    public var id: String { rawValue }
}
