public struct AgentStreamDuration: Equatable {
    public let seconds: Int?

    public var isPersistent: Bool { seconds == nil }

    public init?(argument: Int) {
        guard (0...30).contains(argument) else { return nil }
        seconds = argument == 0 ? nil : argument
    }
}
