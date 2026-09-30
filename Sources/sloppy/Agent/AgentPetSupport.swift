import Foundation
import Protocols

enum AgentPetSourceKind: String, Codable, Sendable {
    case agentSession = "agent_session"
    case externalChannel = "external_channel"
    case heartbeat
    case cron
}

enum AgentPetEventKind: String, Codable, Sendable {
    case userMessage = "user_message"
    case toolCall = "tool_call"
    case toolSuccess = "tool_success"
    case toolFailure = "tool_failure"
    case runCompleted = "run_completed"
    case runFailed = "run_failed"
    case runInterrupted = "run_interrupted"
}

struct AgentPetProgressionInput: Sendable {
    let sourceKind: AgentPetSourceKind
    let eventKind: AgentPetEventKind
    let channelId: String
    let sessionId: String?
    let timestamp: Date
    let userId: String?
    let content: String?

    init(
        sourceKind: AgentPetSourceKind,
        eventKind: AgentPetEventKind,
        channelId: String,
        sessionId: String? = nil,
        timestamp: Date = Date(),
        userId: String? = nil,
        content: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.eventKind = eventKind
        self.channelId = channelId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.userId = userId
        self.content = content
    }
}

struct AgentPetGeneratedRecord {
    let summary: AgentPetSummary
    let state: AgentPetProgressState
}

extension AgentPetGeneratedRecord: Codable, Sendable {}

private struct SplitMix64 {
    private(set) var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        return Double(next()) / Double(UInt64.max)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        guard range.upperBound >= range.lowerBound else {
            return range.lowerBound
        }
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        let value = next() % span
        return range.lowerBound + Int(value)
    }
}

enum AgentPetFactory {
    static let stageThresholds = [0, 120, 320]
    static let paletteIDs = ["mint", "violet", "coral", "amber", "sky", "rose", "lime", "graphite"]
    static let shapes = ["circle", "triangle", "diamond", "square"]

    static func identitySeed(for agentID: String) -> UInt32 {
        agentID.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    static func makePet(agentID: String = "sloppy", createdAt: Date = Date()) -> AgentPetGeneratedRecord {
        makePet(genome: UInt64.random(in: .min ... .max), createdAt: createdAt, agentID: agentID)
    }

    static func makePet(genome: UInt64, createdAt: Date = Date(), agentID: String? = nil) -> AgentPetGeneratedRecord {
        var rng = SplitMix64(seed: genome)
        let stats = AgentPetStats(
            wisdom: 18 + Int(rng.next() % 19),
            debugging: 18 + Int(rng.next() % 19),
            patience: 18 + Int(rng.next() % 19),
            snark: 18 + Int(rng.next() % 19),
            chaos: 18 + Int(rng.next() % 19)
        )
        let shapeSeed = agentID.map { UInt64(identitySeed(for: $0)) } ?? genome
        let shape = shapes[Int(shapeSeed % UInt64(shapes.count))]
        let palette = paletteIDs[Int((genome >> 8) % UInt64(paletteIDs.count))]
        let summary = AgentPetSummary(
            petId: "pet_" + String(UUID().uuidString.lowercased().prefix(12)),
            genomeHex: String(format: "%016llx", genome),
            parts: parts(for: shape),
            partRarities: .init(head: .common, body: .common, legs: .common, face: .common, accessory: .common),
            rarity: .common,
            baseStats: stats,
            currentStats: stats,
            transferable: true,
            visual: visual(for: shape, totalXp: 0, paletteID: palette),
            evolution: evolutionSummary(totalXp: 0),
            stageAssets: assets(for: shape)
        )
        return AgentPetGeneratedRecord(
            summary: summary,
            state: AgentPetProgressState(currentStats: stats, totalXp: 0, createdAt: createdAt, updatedAt: createdAt)
        )
    }

    /// Replaces legacy artwork while preserving the pet's identity, stats and XP.
    static func summary(
        _ summary: AgentPetSummary,
        applying state: AgentPetProgressState,
        agentID: String? = nil
    ) -> AgentPetSummary {
        let seed = agentID.map { UInt64(identitySeed(for: $0)) } ?? UInt64(summary.genomeHex, radix: 16) ?? 0
        let shape = shapes[Int(seed % UInt64(shapes.count))]
        let genome = UInt64(summary.genomeHex, radix: 16) ?? seed
        let persisted = summary.visual?.paletteId
        let palette = persisted.flatMap { paletteIDs.contains($0) ? $0 : nil }
            ?? paletteIDs[Int((genome >> 8) % UInt64(paletteIDs.count))]
        return AgentPetSummary(
            petId: summary.petId,
            genomeHex: summary.genomeHex,
            parts: parts(for: shape),
            partRarities: summary.partRarities,
            rarity: summary.rarity,
            baseStats: summary.baseStats,
            currentStats: state.currentStats,
            transferable: summary.transferable,
            visual: visual(for: shape, totalXp: state.totalXp, paletteID: palette),
            evolution: evolutionSummary(totalXp: state.totalXp),
            stageAssets: assets(for: shape)
        )
    }

    private static func parts(for shape: String) -> AgentPetParts {
        .init(headId: "none", bodyId: shape, legsId: "none", faceId: "eyes-\(shape)", accessoryId: "none")
    }

    private static func visual(for shape: String, totalXp: Int, paletteID: String) -> AgentPetVisualSummary {
        .init(
            speciesId: shape,
            displayName: shape.capitalized + " Bot",
            source: "bundled_png",
            assetBaseURL: "/pets/bots",
            currentStage: stage(for: totalXp),
            stageCount: stageThresholds.count,
            terminalFaceSet: .init(idle: "(o o)", happy: "(^ ^)", sad: "(. .)", sleep: "(- -)"),
            paletteId: paletteID
        )
    }

    private static func assets(for shape: String) -> [AgentPetStageAsset] {
        let ranges = Dictionary(uniqueKeysWithValues:
            ["idle", "walk", "happy", "sad", "interacted", "sleep", "avatar"].map {
                ($0, AgentPetFrameRange(start: 0, end: 0, fps: 0, loop: false))
            }
        )
        return (1...stageThresholds.count).map {
            .init(stage: $0, spriteSheetPath: "/pets/bots/bot-\(shape).png", frameSize: .init(width: 1254, height: 1254), stateFrameRanges: ranges)
        }
    }

    static func evolutionSummary(totalXp: Int) -> AgentPetEvolutionSummary {
        let stage = stage(for: totalXp)
        let stageStart = stageThresholds[max(0, stage - 1)]
        let next: Int? = stage < stageThresholds.count ? stageThresholds[stage] : nil
        return AgentPetEvolutionSummary(
            totalXp: max(totalXp, 0),
            stageXp: max(totalXp - stageStart, 0),
            nextStageXp: next,
            isMaxStage: next == nil
        )
    }

    static func stage(for totalXp: Int) -> Int {
        if totalXp >= stageThresholds[2] {
            return 3
        }
        if totalXp >= stageThresholds[1] {
            return 2
        }
        return 1
    }

}

struct AgentPetProgressionTuning {
    var perChannelDailyCap: AgentPetStats
    var globalDailyCap: AgentPetStats
    var growthMultiplier: Double
    var sourceWeights: [AgentPetSourceKind: Double]
    var decayProbability: Double
    var decayMagnitudeRange: ClosedRange<Int>
    var maxDecayAxes: Int

    static let `default` = AgentPetProgressionTuning(
        perChannelDailyCap: AgentPetStats(
            wisdom: 8,
            debugging: 10,
            patience: 7,
            snark: 6,
            chaos: 7
        ),
        globalDailyCap: AgentPetStats(
            wisdom: 18,
            debugging: 22,
            patience: 16,
            snark: 14,
            chaos: 16
        ),
        growthMultiplier: 0.35,
        sourceWeights: [
            .agentSession: 0.8,
            .externalChannel: 0.8,
            .heartbeat: 0.25,
            .cron: 0.25
        ],
        decayProbability: 0.35,
        decayMagnitudeRange: 1...3,
        maxDecayAxes: 3
    )
}

enum AgentPetProgressionEngine {
    private static let tuning = AgentPetProgressionTuning.default

    static func apply(
        state: inout AgentPetProgressState,
        input: AgentPetProgressionInput,
        baseStats: AgentPetStats
    ) {
        pruneOldBuckets(state: &state, referenceDate: input.timestamp)

        let rawDelta = delta(for: input, counters: state.counters)
        let adjustedDelta = applyVariance(to: rawDelta, seed: varianceSeed(for: input))
        let positiveDelta = adjustedDelta.positiveComponents()
        let negativeDelta = adjustedDelta.negativeComponents()
        let dayKey = dayBucket(for: input.timestamp)
        let channelBucketKey = dayKey + "|" + input.channelId
        let existingChannelGain = state.dailyChannelGainBuckets[channelBucketKey] ?? .init()
        let existingGlobalGain = state.dailyGlobalGainBuckets[dayKey] ?? .init()
        let cappedDelta = cap(
            delta: positiveDelta,
            channelGain: existingChannelGain,
            globalGain: existingGlobalGain
        )

        guard !cappedDelta.isZero || !negativeDelta.isZero else {
            state.processedWatermark = AgentPetProgressWatermark(
                sourceKind: input.sourceKind.rawValue,
                channelId: input.channelId,
                sessionId: input.sessionId,
                eventKind: input.eventKind.rawValue,
                processedAt: input.timestamp
            )
            state.updatedAt = input.timestamp
            return
        }

        state.currentStats = (state.currentStats + cappedDelta).clamped()
        state.totalXp = max(0, state.totalXp + cappedDelta.xpValue)
        state.dailyChannelGainBuckets[channelBucketKey] = existingChannelGain + cappedDelta
        state.dailyGlobalGainBuckets[dayKey] = existingGlobalGain + cappedDelta
        if !negativeDelta.isZero {
            state.currentStats = (state.currentStats + negativeDelta).clamped()
        }
        state.processedWatermark = AgentPetProgressWatermark(
            sourceKind: input.sourceKind.rawValue,
            channelId: input.channelId,
            sessionId: input.sessionId,
            eventKind: input.eventKind.rawValue,
            processedAt: input.timestamp
        )
        state.updatedAt = input.timestamp
        updateCounters(state: &state, input: input)
        state.currentStats = mergeMinimum(base: baseStats, current: state.currentStats).clamped()
    }

    private static func delta(for input: AgentPetProgressionInput, counters: AgentPetProgressCounters) -> AgentPetStats {
        var delta = AgentPetStats()
        let normalizedText = input.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let length = normalizedText.count
        let lower = normalizedText.lowercased()

        // scaling logic remains unchanged to preserve per-event weight;
        // only downstream tuning adjusts effective growth.
        switch input.eventKind {
        case .userMessage:
            if length >= 120 {
                delta.wisdom += 3
                delta.patience += 2
            } else if length >= 48 {
                delta.wisdom += 2
                delta.patience += 1
            } else if length >= 16 {
                delta.wisdom += 1
            }

            if isTechnical(lower) {
                delta.debugging += length >= 24 ? 2 : 1
            }

            if isSnarky(lower) {
                delta.snark += 2
            }

            if isChaotic(lower) {
                delta.chaos += 1
            }

            if length > 0 && length < 12 {
                delta = delta.scaled(by: 0.35)
            }
        case .toolCall:
            delta.debugging += 2
        case .toolSuccess:
            delta.debugging += 2
            delta.wisdom += 1
        case .toolFailure:
            delta.debugging += 1
            delta.chaos += counters.toolFailureCount >= 3 ? 1 : 2
        case .runCompleted:
            delta.wisdom += 2
            delta.patience += 2
        case .runFailed:
            delta.debugging += 1
            delta.chaos += counters.failedRunCount >= 3 ? 1 : 2
        case .runInterrupted:
            delta.snark += 1
            delta.chaos += counters.interruptedRunCount >= 2 ? 1 : 2
        }

        let weighted = delta.scaled(by: weight(for: input.sourceKind))
        return weighted.clamped()
    }

    private static func applyVariance(to delta: AgentPetStats, seed: UInt64) -> AgentPetStats {
        var rng = SplitMix64(seed: seed)
        let dampened = delta.scaledDown(by: tuning.growthMultiplier)
        guard rng.nextDouble() < tuning.decayProbability else {
            return dampened
        }
        let adjusted = dampened + randomDecayDelta(using: &rng)
        if !dampened.isZero && adjusted.positiveComponents().isZero {
            return dampened
        }
        return adjusted
    }

    private static func randomDecayDelta(using rng: inout SplitMix64) -> AgentPetStats {
        var penalties = AgentPetStats()
        let axes = AgentPetStatAxis.allCases
        guard !axes.isEmpty else {
            return penalties
        }
        let selectionCount = min(axes.count, max(1, rng.nextInt(in: 1...tuning.maxDecayAxes)))
        var usedIndexes: Set<Int> = []
        while usedIndexes.count < selectionCount {
            let index = rng.nextInt(in: 0...(axes.count - 1))
            if usedIndexes.insert(index).inserted {
                let amount = -rng.nextInt(in: tuning.decayMagnitudeRange)
                switch axes[index] {
                case .wisdom:
                    penalties.wisdom += amount
                case .debugging:
                    penalties.debugging += amount
                case .patience:
                    penalties.patience += amount
                case .snark:
                    penalties.snark += amount
                case .chaos:
                    penalties.chaos += amount
                }
            }
        }
        return penalties
    }

    private static func varianceSeed(for input: AgentPetProgressionInput) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(input.channelId)
        hasher.combine(input.sessionId)
        hasher.combine(input.timestamp.timeIntervalSince1970)
        hasher.combine(input.userId)
        hasher.combine(input.eventKind.rawValue)
        hasher.combine(input.sourceKind.rawValue)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private enum AgentPetStatAxis: CaseIterable {
        case wisdom
        case debugging
        case patience
        case snark
        case chaos
    }

    private static func cap(
        delta: AgentPetStats,
        channelGain: AgentPetStats,
        globalGain: AgentPetStats
    ) -> AgentPetStats {
        AgentPetStats(
            wisdom: maxCapped(delta.wisdom, channelGain.wisdom, tuning.perChannelDailyCap.wisdom, globalGain.wisdom, tuning.globalDailyCap.wisdom),
            debugging: maxCapped(delta.debugging, channelGain.debugging, tuning.perChannelDailyCap.debugging, globalGain.debugging, tuning.globalDailyCap.debugging),
            patience: maxCapped(delta.patience, channelGain.patience, tuning.perChannelDailyCap.patience, globalGain.patience, tuning.globalDailyCap.patience),
            snark: maxCapped(delta.snark, channelGain.snark, tuning.perChannelDailyCap.snark, globalGain.snark, tuning.globalDailyCap.snark),
            chaos: maxCapped(delta.chaos, channelGain.chaos, tuning.perChannelDailyCap.chaos, globalGain.chaos, tuning.globalDailyCap.chaos)
        )
    }

    private static func maxCapped(
        _ delta: Int,
        _ channelCurrent: Int,
        _ channelCap: Int,
        _ globalCurrent: Int,
        _ globalCap: Int
    ) -> Int {
        guard delta > 0 else {
            return 0
        }
        let remainingChannel = max(channelCap - channelCurrent, 0)
        let remainingGlobal = max(globalCap - globalCurrent, 0)
        return min(delta, remainingChannel, remainingGlobal)
    }

    private static func updateCounters(state: inout AgentPetProgressState, input: AgentPetProgressionInput) {
        switch input.eventKind {
        case .userMessage:
            switch input.sourceKind {
            case .agentSession:
                state.counters.directMessageCount += 1
            case .externalChannel:
                state.counters.externalMessageCount += 1
            case .heartbeat, .cron:
                state.counters.automatedMessageCount += 1
            }
        case .toolCall:
            state.counters.toolCallCount += 1
        case .toolSuccess:
            break
        case .toolFailure:
            state.counters.toolFailureCount += 1
        case .runCompleted:
            state.counters.successfulRunCount += 1
        case .runFailed:
            state.counters.failedRunCount += 1
        case .runInterrupted:
            state.counters.interruptedRunCount += 1
        }
    }

    private static func weight(for sourceKind: AgentPetSourceKind) -> Double {
        max(tuning.sourceWeights[sourceKind] ?? 1.0, 0)
    }

    private static func pruneOldBuckets(state: inout AgentPetProgressState, referenceDate: Date) {
        let calendar = Calendar(identifier: .gregorian)
        let earliestDate = calendar.date(byAdding: .day, value: -2, to: referenceDate) ?? referenceDate
        let earliestKey = dayBucket(for: earliestDate)
        state.dailyChannelGainBuckets = state.dailyChannelGainBuckets.filter { key, _ in
            String(key.prefix(10)) >= earliestKey
        }
        state.dailyGlobalGainBuckets = state.dailyGlobalGainBuckets.filter { key, _ in
            key >= earliestKey
        }
    }

    private static func dayBucket(for date: Date) -> String {
        AgentPetDateFormatter.day.string(from: date)
    }

    private static func isTechnical(_ text: String) -> Bool {
        let keywords = [
            "bug", "debug", "stack", "trace", "test", "build", "compile", "error",
            "swift", "react", "typescript", "sql", "crash", "fix", "refactor"
        ]
        return keywords.contains(where: text.contains)
    }

    private static func isSnarky(_ text: String) -> Bool {
        text.contains("???") ||
        text.contains("wtf") ||
        text.contains("seriously") ||
        text.contains("sure.") ||
        text.contains("obviously") ||
        text.contains("ага")
    }

    private static func isChaotic(_ text: String) -> Bool {
        text.contains("!!!") ||
        text.contains("panic") ||
        text.contains("urgent") ||
        text.contains("asap") ||
        text.contains("сломалось") ||
        text.contains("пожар")
    }

    private static func mergeMinimum(base: AgentPetStats, current: AgentPetStats) -> AgentPetStats {
        AgentPetStats(
            wisdom: max(base.wisdom, current.wisdom),
            debugging: max(base.debugging, current.debugging),
            patience: max(base.patience, current.patience),
            snark: max(base.snark, current.snark),
            chaos: max(base.chaos, current.chaos)
        )
    }
}

private enum AgentPetDateFormatter {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension AgentPetStats {
    var xpValue: Int {
        max(wisdom, 0) + max(debugging, 0) + max(patience, 0) + max(snark, 0) + max(chaos, 0)
    }

    var isZero: Bool {
        wisdom == 0 && debugging == 0 && patience == 0 && snark == 0 && chaos == 0
    }

    func clamped() -> AgentPetStats {
        AgentPetStats(
            wisdom: min(max(wisdom, 0), 100),
            debugging: min(max(debugging, 0), 100),
            patience: min(max(patience, 0), 100),
            snark: min(max(snark, 0), 100),
            chaos: min(max(chaos, 0), 100)
        )
    }

    func scaled(by factor: Double) -> AgentPetStats {
        guard factor > 0 else {
            return .init()
        }

        func scale(_ value: Int) -> Int {
            guard value > 0 else {
                return 0
            }
            let scaled = Int((Double(value) * factor).rounded(.toNearestOrAwayFromZero))
            return max(scaled, 1)
        }

        return AgentPetStats(
            wisdom: scale(wisdom),
            debugging: scale(debugging),
            patience: scale(patience),
            snark: scale(snark),
            chaos: scale(chaos)
        )
    }

    static func + (lhs: AgentPetStats, rhs: AgentPetStats) -> AgentPetStats {
        AgentPetStats(
            wisdom: lhs.wisdom + rhs.wisdom,
            debugging: lhs.debugging + rhs.debugging,
            patience: lhs.patience + rhs.patience,
            snark: lhs.snark + rhs.snark,
            chaos: lhs.chaos + rhs.chaos
        )
    }

    func scaledDown(by factor: Double) -> AgentPetStats {
        guard factor > 0 else {
            return .init()
        }

        func scale(_ value: Int) -> Int {
            guard value > 0 else {
                return 0
            }
            let scaled = Int((Double(value) * factor).rounded(.down))
            return max(scaled, 1)
        }

        return AgentPetStats(
            wisdom: scale(wisdom),
            debugging: scale(debugging),
            patience: scale(patience),
            snark: scale(snark),
            chaos: scale(chaos)
        )
    }

    func positiveComponents() -> AgentPetStats {
        AgentPetStats(
            wisdom: max(wisdom, 0),
            debugging: max(debugging, 0),
            patience: max(patience, 0),
            snark: max(snark, 0),
            chaos: max(chaos, 0)
        )
    }

    func negativeComponents() -> AgentPetStats {
        AgentPetStats(
            wisdom: wisdom < 0 ? wisdom : 0,
            debugging: debugging < 0 ? debugging : 0,
            patience: patience < 0 ? patience : 0,
            snark: snark < 0 ? snark : 0,
            chaos: chaos < 0 ? chaos : 0
        )
    }
}
