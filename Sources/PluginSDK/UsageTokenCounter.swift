import Foundation
import SwiftTiktoken
import Protocols

public actor UsageTokenCounter {
    public static let shared = UsageTokenCounter()
    private var encoders: [String: CoreBPE] = [:]
    private var failedEncodings: Set<String> = []
    public static let revision = "b4310ee520995ddff45b055de19e6605e0f8e5b6"

    // Deliberately allowlisted: a new model must never silently inherit an encoding.
    public static func encoding(for model: String) -> String? {
        if model.contains(":"), !model.hasPrefix("openai-api:"), !model.hasPrefix("openai-oauth:") { return nil }
        let name = model.split(separator: ":", maxSplits: 1).last.map(String.init) ?? model
        let cl = ["gpt-4", "gpt-4-0613", "gpt-4-turbo", "gpt-4-turbo-2024-04-09", "gpt-3.5-turbo", "gpt-3.5-turbo-0125"]
        let o = ["gpt-4o", "gpt-4o-2024-05-13", "gpt-4o-2024-08-06", "gpt-4o-mini", "gpt-4o-mini-2024-07-18", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-5", "gpt-5-mini", "gpt-5-nano", "o1", "o3", "o3-mini", "o4-mini"]
        return cl.contains(name) ? "cl100k_base" : o.contains(name) ? "o200k_base" : nil
    }

    public func count(_ text: String, model: String) -> (tokens: Int, method: UsageCountingMethod, encoding: String?) {
        if let encoding = Self.encoding(for: model), let encoder = load(encoding),
           let tokens = try? encoder.encodeOrdinary(text: text) {
            return (tokens.count, .tokenizer, "\(encoding)@\(Self.revision)")
        }
        return (text.isEmpty ? 0 : max(1, Int(ceil(Double(text.count) / 4))), .estimate, nil)
    }

    private func load(_ name: String) -> CoreBPE? {
        if let encoder = encoders[name] { return encoder }
        guard !failedEncodings.contains(name) else { return nil }
        do {
            guard let url = Bundle.module.url(forResource: name, withExtension: "tiktoken", subdirectory: "Tokenizers") else {
                failedEncodings.insert(name); return nil
            }
            let data = try String(contentsOf: url, encoding: .utf8)
            var ranks: [[UInt8]: UInt32] = [:]
            for line in data.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let bytes = Data(base64Encoded: String(parts[0])), let rank = UInt32(parts[1]) else { continue }
                ranks[Array(bytes)] = rank
            }
            guard ranks.count == (name == "cl100k_base" ? 100_256 : 199_998) else {
                failedEncodings.insert(name); return nil
            }
            let pattern = name == "cl100k_base"
                ? #"'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}++|\p{N}{1,3}+| ?[^\s\p{L}\p{N}]++[\r\n]*+|\s++$|\s*[\r\n]|\s+(?!\S)|\s"#
                : #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
            let encoder = try CoreBPE(encoder: ranks, specialTokensEncoder: [:], pattern: pattern)
            encoders[name] = encoder
            return encoder
        } catch { failedEncodings.insert(name); return nil }
    }
}
