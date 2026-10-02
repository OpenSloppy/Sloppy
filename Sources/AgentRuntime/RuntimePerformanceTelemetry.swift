import Foundation
import Metrics

public struct RuntimePerformanceSample: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var recordedAt: Date
    public var channelId: String
    public var model: String
    public var timeToFirstTokenMs: Int?
    public var generationDurationMs: Int
    public var outputCharacters: Int
    public var streamChunks: Int
    public var averageDeltaIntervalMs: Int?
    public var maxDeltaIntervalMs: Int?
    public var charactersPerSecond: Double
    public var toolCallCount: Int
    public var toolBatchCount: Int
    public var maxParallelToolCalls: Int
    public var averageToolDurationMs: Int?
    public var failedToolCalls: Int

    public init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        channelId: String,
        model: String,
        timeToFirstTokenMs: Int?,
        generationDurationMs: Int,
        outputCharacters: Int,
        streamChunks: Int,
        averageDeltaIntervalMs: Int?,
        maxDeltaIntervalMs: Int?,
        charactersPerSecond: Double,
        toolCallCount: Int,
        toolBatchCount: Int,
        maxParallelToolCalls: Int,
        averageToolDurationMs: Int?,
        failedToolCalls: Int
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.channelId = channelId
        self.model = model
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.generationDurationMs = generationDurationMs
        self.outputCharacters = outputCharacters
        self.streamChunks = streamChunks
        self.averageDeltaIntervalMs = averageDeltaIntervalMs
        self.maxDeltaIntervalMs = maxDeltaIntervalMs
        self.charactersPerSecond = charactersPerSecond
        self.toolCallCount = toolCallCount
        self.toolBatchCount = toolBatchCount
        self.maxParallelToolCalls = maxParallelToolCalls
        self.averageToolDurationMs = averageToolDurationMs
        self.failedToolCalls = failedToolCalls
    }
}

public struct RuntimePerformanceSummary: Codable, Sendable, Equatable {
    public var sampleCount: Int
    public var averageTimeToFirstTokenMs: Int?
    public var p95TimeToFirstTokenMs: Int?
    public var averageDeltaIntervalMs: Int?
    public var averageGenerationDurationMs: Int?
    public var averageCharactersPerSecond: Double
    public var totalToolCalls: Int
    public var peakParallelToolCalls: Int
    public var failedToolCalls: Int
}

public struct RuntimePerformanceSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var summary: RuntimePerformanceSummary
    public var samples: [RuntimePerformanceSample]
}

public actor RuntimePerformanceTelemetry {
    private let capacity: Int
    private var samples: [RuntimePerformanceSample] = []

    public init(capacity: Int = 240) {
        self.capacity = max(1, capacity)
    }

    public func record(_ sample: RuntimePerformanceSample) {
        // Keep dimensions bounded: session/channel IDs and model output never become labels.
        Metrics.Timer(label: "sloppy.model.generation.duration", dimensions: [("unit", "s")]).recordMilliseconds(sample.generationDurationMs)
        if let ttft = sample.timeToFirstTokenMs {
            Metrics.Timer(label: "sloppy.model.time_to_first_token", dimensions: [("unit", "s")]).recordMilliseconds(ttft)
        }
        if let gap = sample.averageDeltaIntervalMs {
            Metrics.Timer(label: "sloppy.model.delta.interval", dimensions: [("unit", "s")]).recordMilliseconds(gap)
        }
        Counter(label: "sloppy.tool.calls").increment(by: sample.toolCallCount)
        Counter(label: "sloppy.tool.errors").increment(by: sample.failedToolCalls)
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public func snapshot(limit: Int = 60) -> RuntimePerformanceSnapshot {
        let selected = Array(samples.suffix(max(1, min(limit, capacity))))
        let ttft = selected.compactMap(\.timeToFirstTokenMs).sorted()
        let deltaIntervals = selected.compactMap(\.averageDeltaIntervalMs)
        let generationDurations = selected.map(\.generationDurationMs)
        let throughput = selected.map(\.charactersPerSecond)
        let percentileIndex = ttft.isEmpty ? 0 : min(ttft.count - 1, Int((Double(ttft.count) * 0.95).rounded(.up)) - 1)

        return RuntimePerformanceSnapshot(
            generatedAt: Date(),
            summary: RuntimePerformanceSummary(
                sampleCount: selected.count,
                averageTimeToFirstTokenMs: average(ttft),
                p95TimeToFirstTokenMs: ttft.isEmpty ? nil : ttft[percentileIndex],
                averageDeltaIntervalMs: average(deltaIntervals),
                averageGenerationDurationMs: average(generationDurations),
                averageCharactersPerSecond: throughput.isEmpty ? 0 : throughput.reduce(0, +) / Double(throughput.count),
                totalToolCalls: selected.reduce(0) { $0 + $1.toolCallCount },
                peakParallelToolCalls: selected.map(\.maxParallelToolCalls).max() ?? 0,
                failedToolCalls: selected.reduce(0) { $0 + $1.failedToolCalls }
            ),
            samples: selected
        )
    }

    private func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }
}
