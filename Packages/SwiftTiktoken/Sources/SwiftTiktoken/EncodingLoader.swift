import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Loader for OpenAI encodings that downloads and caches vocabulary data
public enum EncodingLoader {
  // MARK: - Encoding URLs

  /// URLs for different encodings (matching Python implementation)
  private static let encodingURLs: [String: String] = [
    "cl100k_base": "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken",
    "r50k_base": "https://openaipublic.blob.core.windows.net/encodings/r50k_base.tiktoken",
    "p50k_base": "https://openaipublic.blob.core.windows.net/encodings/p50k_base.tiktoken",
    "o200k_base": "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken",
  ]

  /// Expected SHA256 hashes for verification
  private static let expectedHashes: [String: String] = [
    "cl100k_base": "223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7",
    "r50k_base": "306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930",
    "p50k_base": "94b5ca7dff4d00767bc256fdd1b27e5b17361d7b8a5f968547f9f23eb70d2069",
    "o200k_base": "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d",
  ]

  // MARK: - Special Tokens

  /// Special tokens for different encodings
  private static let specialTokens: [String: [String: UInt32]] = [
    "cl100k_base": [
      "<|endoftext|>": 100_257,
      "<|fim_prefix|>": 100_258,
      "<|fim_middle|>": 100_259,
      "<|fim_suffix|>": 100_260,
      "<|endofprompt|>": 100_276,
    ],
    "r50k_base": [
      "<|endoftext|>": 50256,
    ],
    "p50k_base": [
      "<|endoftext|>": 50256,
    ],
    "p50k_edit": [
      "<|endoftext|>": 50256,
      "<|fim_prefix|>": 50281,
      "<|fim_middle|>": 50282,
      "<|fim_suffix|>": 50283,
    ],
    "o200k_base": [
      "<|endoftext|>": 199_999,
      "<|endofprompt|>": 200_018,
    ],
  ]

  // MARK: - Patterns

  /// Regex patterns for different encodings
  /// Note: Possessive quantifiers (++, *+, ?+) are converted to regular quantifiers
  /// by CoreBPE.convertPattern() since the tokenization behavior is equivalent.
  private static let patterns: [String: String] = [
    // Python: '(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}++|\p{N}{1,3}+| ?[^\s\p{L}\p{N}]++[\r\n]*+|\s++$|\s*[\r\n]|\s+(?!\S)|\s
    "cl100k_base": #"'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s+$|\s*[\r\n]|\s+(?!\S)|\s"#,
    // Python: '(?:[sdmt]|ll|ve|re)| ?\p{L}++| ?\p{N}++| ?[^\s\p{L}\p{N}]++|\s++$|\s+(?!\S)|\s
    "r50k_base": #"'(?:[sdmt]|ll|ve|re)| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+$|\s+(?!\S)|\s"#,
    "p50k_base": #"'(?:[sdmt]|ll|ve|re)| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+$|\s+(?!\S)|\s"#,
    "p50k_edit": #"'(?:[sdmt]|ll|ve|re)| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+$|\s+(?!\S)|\s"#,
    // o200k_base pattern is correct (ends with \s+ per Python source)
    "o200k_base": #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+"#,
  ]

  // MARK: - Cache Directory

  /// Custom cache directory (can be set for testing or custom locations)
  public nonisolated(unsafe) static var customCacheDirectory: URL?

  /// Cache directory for storing downloaded vocabularies
  private static var cacheDirectory: URL {
    if let custom = customCacheDirectory {
      return custom
    }

    // Try standard caches directory first
    if let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
      let dir = cachesPath.appendingPathComponent("tiktoken", isDirectory: true)
      // Check if we can write to this directory
      let testPath = dir.appendingPathComponent(".test")
      do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: testPath)
        try FileManager.default.removeItem(at: testPath)
        return dir
      } catch {
        // Fall through to temp directory
      }
    }

    // Fallback to temp directory (works in sandboxed environments)
    let tempPath = FileManager.default.temporaryDirectory
    return tempPath.appendingPathComponent("tiktoken", isDirectory: true)
  }

  // MARK: - Load Encoder

  /// Load an encoder for the specified encoding name
  ///
  /// - Parameter encodingName: Name of the encoding (e.g., "cl100k_base")
  /// - Returns: Configured CoreBPE instance
  /// - Throws: LoadError if loading fails
  public static func loadEncoder(named encodingName: String) async throws -> CoreBPE {
    // Special handling for o200k_harmony
    if encodingName == "o200k_harmony" {
      return try await loadO200kHarmony()
    }

    // Special handling for p50k_edit (uses p50k_base vocab with different special tokens)
    if encodingName == "p50k_edit" {
      return try await loadP50kEdit()
    }

    // Check if we have a cached version
    let cacheURL = cacheDirectory.appendingPathComponent("\(encodingName).tiktoken")

    if FileManager.default.fileExists(atPath: cacheURL.path) {
      return try await loadFromFile(cacheURL, encodingName: encodingName)
    }

    // Download if not cached
    guard let urlString = encodingURLs[encodingName],
          let url = URL(string: urlString)
    else {
      throw LoadError.unsupportedEncoding(encodingName)
    }

    // Create cache directory if needed
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

    // Download the data
    let (data, _) = try await URLSession.shared.data(from: url)

    // Verify hash if available
    #if canImport(CryptoKit)
    if let expectedHash = expectedHashes[encodingName] {
      let hash = SHA256.hash(data: data)
      let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

      if hashString != expectedHash {
        throw LoadError.hashMismatch(expected: expectedHash, actual: hashString)
      }
    }
    #endif

    // Save to cache
    try data.write(to: cacheURL)

    // Load and return
    return try await loadFromData(data, encodingName: encodingName)
  }

  /// Load encoder from cached file
  private static func loadFromFile(_ url: URL, encodingName: String) async throws -> CoreBPE {
    let data = try Data(contentsOf: url)
    return try await loadFromData(data, encodingName: encodingName)
  }

  /// Load encoder from data
  private static func loadFromData(_ data: Data, encodingName: String) async throws -> CoreBPE {
    // Parse the tiktoken format
    let mergeableRanks = try parseTiktokenBpe(data)

    // Get special tokens and pattern for this encoding
    let specialTokens = specialTokens[encodingName] ?? [:]
    let pattern = patterns[encodingName] ?? patterns["cl100k_base"]!

    // Create the encoder
    return try CoreBPE(
      encoder: mergeableRanks,
      specialTokensEncoder: specialTokens,
      pattern: pattern,
    )
  }

  /// Load p50k_edit encoding (based on p50k_base with FIM special tokens)
  private static func loadP50kEdit() async throws -> CoreBPE {
    // Make sure p50k_base is downloaded
    let cacheURL = cacheDirectory.appendingPathComponent("p50k_base.tiktoken")

    if !FileManager.default.fileExists(atPath: cacheURL.path) {
      // Download p50k_base
      _ = try await loadEncoder(named: "p50k_base")
    }

    // Load the raw data
    let data = try Data(contentsOf: cacheURL)
    let mergeableRanks = try parseTiktokenBpe(data)
    let pattern = patterns["p50k_edit"]!
    let editSpecialTokens = specialTokens["p50k_edit"]!

    return try CoreBPE(
      encoder: mergeableRanks,
      specialTokensEncoder: editSpecialTokens,
      pattern: pattern
    )
  }

  /// Load o200k_harmony encoding (based on o200k_base with additional special tokens)
  private static func loadO200kHarmony() async throws -> CoreBPE {
    // Make sure o200k_base is downloaded
    let cacheURL = cacheDirectory.appendingPathComponent("o200k_base.tiktoken")

    if !FileManager.default.fileExists(atPath: cacheURL.path) {
      // Download o200k_base
      _ = try await loadEncoder(named: "o200k_base")
    }

    // Load the raw data
    let data = try Data(contentsOf: cacheURL)
    let mergeableRanks = try parseTiktokenBpe(data)
    let pattern = patterns["o200k_base"] ?? patterns["cl100k_base"]!

    // Build harmony special tokens
    var harmonySpecialTokens: [String: UInt32] = [
      "<|startoftext|>": 199_998,
      "<|endoftext|>": 199_999,
      "<|reserved_200000|>": 200_000,
      "<|reserved_200001|>": 200_001,
      "<|return|>": 200_002,
      "<|constrain|>": 200_003,
      "<|reserved_200004|>": 200_004,
      "<|channel|>": 200_005,
      "<|start|>": 200_006,
      "<|end|>": 200_007,
      "<|message|>": 200_008,
      "<|reserved_200009|>": 200_009,
      "<|reserved_200010|>": 200_010,
      "<|reserved_200011|>": 200_011,
      "<|call|>": 200_012,
      "<|endofprompt|>": 200_018,
    ]

    // Add reserved tokens from 200013 to 201087
    for i in 200_013 ... 201_087 {
      harmonySpecialTokens["<|reserved_\(i)|>"] = UInt32(i)
    }

    return try CoreBPE(
      encoder: mergeableRanks,
      specialTokensEncoder: harmonySpecialTokens,
      pattern: pattern,
    )
  }

  // MARK: - Parse Format

  /// Parse tiktoken BPE format
  /// The format is: base64-encoded token followed by space and rank
  private static func parseTiktokenBpe(_ data: Data) throws -> [[UInt8]: UInt32] {
    guard let content = String(data: data, encoding: .utf8) else {
      throw LoadError.invalidData
    }

    var encoder: [[UInt8]: UInt32] = [:]

    // Split by lines and parse each line
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }

      // Each line has format: "base64_token rank"
      let parts = trimmed.split(separator: " ", maxSplits: 1)
      guard parts.count == 2,
            let rank = UInt32(parts[1])
      else {
        continue
      }

      // Decode the base64 token
      guard let tokenData = Data(base64Encoded: String(parts[0])) else {
        continue
      }

      // Store as byte array
      encoder[Array(tokenData)] = rank
    }

    return encoder
  }

  // MARK: - Cache Management

  /// Clear the cache directory
  public static func clearCache() throws {
    if FileManager.default.fileExists(atPath: cacheDirectory.path) {
      try FileManager.default.removeItem(at: cacheDirectory)
    }
  }

  /// Get cache size in bytes
  public static func cacheSize() -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
      at: cacheDirectory,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles],
    ) else {
      return 0
    }

    var totalSize: Int64 = 0
    for case let fileURL as URL in enumerator {
      if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        totalSize += Int64(fileSize)
      }
    }

    return totalSize
  }

  // MARK: - Errors

  /// Errors that can occur during loading
  public enum LoadError: LocalizedError {
    case unsupportedEncoding(String)
    case downloadFailed(Error)
    case invalidData
    case hashMismatch(expected: String, actual: String)

    public var errorDescription: String? {
      switch self {
        case let .unsupportedEncoding(name):
          "Unsupported encoding: \(name)"
        case let .downloadFailed(error):
          "Download failed: \(error.localizedDescription)"
        case .invalidData:
          "Invalid tiktoken data format"
        case let .hashMismatch(expected, actual):
          "Hash mismatch - expected: \(expected), actual: \(actual)"
      }
    }
  }
}

// MARK: - Model to Encoding Mapping

/// Mapping from model names to encoding names
/// Based on OpenAI's tiktoken model.py
public enum ModelEncoding {
  /// Model prefix to encoding mapping
  private static let modelPrefixToEncoding: [(String, String)] = [
    // reasoning
    ("o1-", "o200k_base"),
    ("o3-", "o200k_base"),
    ("o4-mini-", "o200k_base"),
    // chat
    ("gpt-5-", "o200k_base"),
    ("gpt-4.5-", "o200k_base"),
    ("gpt-4.1-", "o200k_base"),
    ("chatgpt-4o-", "o200k_base"),
    ("gpt-4o-", "o200k_base"),
    ("gpt-4-", "cl100k_base"),
    ("gpt-3.5-turbo-", "cl100k_base"),
    ("gpt-35-turbo-", "cl100k_base"), // Azure deployment name
    // open-weight
    ("gpt-oss-", "o200k_harmony"),
    // fine-tuned
    ("ft:gpt-4o", "o200k_base"),
    ("ft:gpt-4", "cl100k_base"),
    ("ft:gpt-3.5-turbo", "cl100k_base"),
    ("ft:davinci-002", "cl100k_base"),
    ("ft:babbage-002", "cl100k_base"),
  ]

  /// Exact model name to encoding mapping
  private static let modelToEncoding: [String: String] = [
    // reasoning
    "o1": "o200k_base",
    "o3": "o200k_base",
    "o4-mini": "o200k_base",
    // chat
    "gpt-5": "o200k_base",
    "gpt-4.1": "o200k_base",
    "gpt-4o": "o200k_base",
    "gpt-4": "cl100k_base",
    "gpt-3.5-turbo": "cl100k_base",
    "gpt-3.5": "cl100k_base",
    "gpt-35-turbo": "cl100k_base", // Azure deployment name
    // base
    "davinci-002": "cl100k_base",
    "babbage-002": "cl100k_base",
    // embeddings
    "text-embedding-ada-002": "cl100k_base",
    "text-embedding-3-small": "cl100k_base",
    "text-embedding-3-large": "cl100k_base",
    // DEPRECATED MODELS
    // text (DEPRECATED)
    "text-davinci-003": "p50k_base",
    "text-davinci-002": "p50k_base",
    "text-davinci-001": "r50k_base",
    "text-curie-001": "r50k_base",
    "text-babbage-001": "r50k_base",
    "text-ada-001": "r50k_base",
    "davinci": "r50k_base",
    "curie": "r50k_base",
    "babbage": "r50k_base",
    "ada": "r50k_base",
    // code (DEPRECATED)
    "code-davinci-002": "p50k_base",
    "code-davinci-001": "p50k_base",
    "code-cushman-002": "p50k_base",
    "code-cushman-001": "p50k_base",
    "davinci-codex": "p50k_base",
    "cushman-codex": "p50k_base",
    // edit (DEPRECATED)
    "text-davinci-edit-001": "p50k_edit",
    "code-davinci-edit-001": "p50k_edit",
    // old embeddings (DEPRECATED)
    "text-similarity-davinci-001": "r50k_base",
    "text-similarity-curie-001": "r50k_base",
    "text-similarity-babbage-001": "r50k_base",
    "text-similarity-ada-001": "r50k_base",
    "text-search-davinci-doc-001": "r50k_base",
    "text-search-curie-doc-001": "r50k_base",
    "text-search-babbage-doc-001": "r50k_base",
    "text-search-ada-doc-001": "r50k_base",
    "code-search-babbage-code-001": "r50k_base",
    "code-search-ada-code-001": "r50k_base",
    // open source
    "gpt2": "gpt2",
    "gpt-2": "gpt2",
  ]

  /// Get encoding name for a model
  ///
  /// - Parameter modelName: Name of the model
  /// - Returns: Encoding name, or nil if unknown
  public static func encodingName(forModel modelName: String) -> String? {
    // Check exact match first
    if let encoding = modelToEncoding[modelName] {
      return encoding
    }

    // Check prefix matches
    for (prefix, encoding) in modelPrefixToEncoding {
      if modelName.hasPrefix(prefix) {
        return encoding
      }
    }

    return nil
  }
}

/// Load encoder for a specific model
///
/// - Parameter modelName: Name of the model (e.g., "gpt-4", "gpt-3.5-turbo")
/// - Returns: Configured CoreBPE instance
/// - Throws: LoadError if the model is unknown or loading fails
///
/// - Note: The "gpt2" encoding maps to r50k_base. In Python tiktoken, gpt2 uses a different
///   source format (vocab.bpe + encoder.json) which may have subtle differences. For most
///   use cases this mapping is equivalent, but if exact GPT-2 compatibility is required,
///   use the Python tiktoken library directly.
public func encodingForModel(_ modelName: String) async throws -> CoreBPE {
  guard let encodingName = ModelEncoding.encodingName(forModel: modelName) else {
    throw EncodingLoader.LoadError.unsupportedEncoding("Unknown model: \(modelName)")
  }

  // gpt2 maps to r50k_base (same pattern and special tokens, likely same vocabulary)
  // Python tiktoken uses different source files but the result should be equivalent
  let actualEncoding = encodingName == "gpt2" ? "r50k_base" : encodingName

  return try await EncodingLoader.loadEncoder(named: actualEncoding)
}

// MARK: - CoreBPE Convenience Extensions

public extension CoreBPE {
  /// Load a standard OpenAI encoding by name
  static func loadEncoding(named name: String) async throws -> CoreBPE {
    try await EncodingLoader.loadEncoder(named: name)
  }

  /// Load encoder for a specific model
  ///
  /// - Parameter modelName: Name of the model (e.g., "gpt-4", "gpt-3.5-turbo")
  /// - Returns: Configured CoreBPE instance
  /// - Throws: LoadError if the model is unknown or loading fails
  static func forModel(_ modelName: String) async throws -> CoreBPE {
    try await encodingForModel(modelName)
  }

  /// Load cl100k_base encoding (GPT-3.5/4)
  static func cl100kBase() async throws -> CoreBPE {
    try await loadEncoding(named: "cl100k_base")
  }

  /// Load r50k_base encoding (GPT-2)
  static func r50kBase() async throws -> CoreBPE {
    try await loadEncoding(named: "r50k_base")
  }

  /// Load p50k_base encoding (Codex)
  static func p50kBase() async throws -> CoreBPE {
    try await loadEncoding(named: "p50k_base")
  }

  /// Load p50k_edit encoding (Codex edit models with FIM tokens)
  static func p50kEdit() async throws -> CoreBPE {
    try await loadEncoding(named: "p50k_edit")
  }

  /// Load o200k_base encoding (GPT-4o)
  static func o200kBase() async throws -> CoreBPE {
    try await loadEncoding(named: "o200k_base")
  }

  /// Load o200k_harmony encoding (gpt-oss)
  static func o200kHarmony() async throws -> CoreBPE {
    try await loadEncoding(named: "o200k_harmony")
  }
}
