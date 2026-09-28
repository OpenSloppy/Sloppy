import AgentRuntime
import PluginSDK

/// The host-independent settings required to construct Sloppy's model loop.
public struct SloppyRuntimeConfiguration: Sendable {
    public var defaultModel: String?
    public var visorBulletinMaxWords: Int
    public var compactorConfiguration: CompactorConfiguration
    public var compactorRetryPolicy: CompactorRetryPolicy
    public var preResponseMemoryLimit: Int

    public init(
        defaultModel: String? = nil,
        visorBulletinMaxWords: Int = 300,
        compactorConfiguration: CompactorConfiguration = .default,
        compactorRetryPolicy: CompactorRetryPolicy = .default,
        preResponseMemoryLimit: Int = 8
    ) {
        self.defaultModel = defaultModel
        self.visorBulletinMaxWords = visorBulletinMaxWords
        self.compactorConfiguration = compactorConfiguration
        self.compactorRetryPolicy = compactorRetryPolicy
        self.preResponseMemoryLimit = preResponseMemoryLimit
    }
}

/// Constructs the shared agent loop for desktop and future embedded hosts.
public enum SloppyRuntimeBootstrap {
    public static func makeSystem(
        modelProvider: (any ModelProvider)?,
        memoryStore: any MemoryStore,
        configuration: SloppyRuntimeConfiguration,
        visorCompletionProvider: (@Sendable (String, Int) async -> String?)? = nil,
        visorStreamingProvider: (@Sendable (String, Int) -> AsyncStream<String>)? = nil
    ) -> RuntimeSystem {
        RuntimeSystem(
            modelProvider: modelProvider,
            defaultModel: configuration.defaultModel,
            memoryStore: memoryStore,
            visorCompletionProvider: visorCompletionProvider,
            visorStreamingProvider: visorStreamingProvider,
            visorBulletinMaxWords: configuration.visorBulletinMaxWords,
            compactorConfiguration: configuration.compactorConfiguration,
            compactorRetryPolicy: configuration.compactorRetryPolicy,
            preResponseMemoryLimit: configuration.preResponseMemoryLimit
        )
    }
}
