import Foundation
import RegexBuilder

/// Specifies which special tokens should be disallowed (cause an error) during encoding.
///
/// This matches the Python tiktoken behavior where by default, special tokens in the input
/// text will raise an error to prevent accidental injection attacks.
public enum DisallowedSpecial: Equatable, Sendable {
  /// Disallow all special tokens that aren't explicitly allowed (default, safe behavior)
  case all
  /// Allow all special tokens to be encoded as regular text (no checking)
  case none
  /// Disallow only the specified special tokens
  case some(Set<String>)
}

/// Maximum input length for encoding operations.
/// This matches Python tiktoken's behavior where very large inputs are rejected
/// to prevent excessive memory usage and processing time.
public let maxInputLength = 1_000_000

/// Protocol defining the CoreBPE interface (matching the FFI wrapper API)
public protocol CoreBPEProtocol: AnyObject, Sendable {
  func decodeBytes(tokens: [UInt32]) throws -> [UInt8]
  func decode(tokens: [UInt32]) throws -> String?
  func encode(text: String, allowedSpecial: [String], disallowedSpecial: DisallowedSpecial) throws -> [UInt32]
  func encodeOrdinary(text: String) throws -> [UInt32]
  func encodeWithSpecialTokens(text: String) throws -> [UInt32]
}

/// Core BPE (Byte Pair Encoding) implementation
/// This is a faithful port of the Rust `CoreBPE` struct.
///
/// Thread-safe and designed for high performance tokenization.
public final class CoreBPE: CoreBPEProtocol, @unchecked Sendable {
  /// Mapping from token bytes to rank
  private let encoder: [ArraySlice<UInt8>: Rank]

  /// Mapping from special token strings to rank
  private let specialTokensEncoder: [String: Rank]

  /// Reverse mapping from rank to token bytes
  private let decoder: [Rank: [UInt8]]

  /// Reverse mapping from rank to special token bytes
  private let specialTokensDecoder: [Rank: [UInt8]]

  /// The maximum token value in the vocabulary
  public let maxTokenValue: Rank

  /// Compiled regex for tokenization.
  ///
  /// We use Swift's native Regex (iOS 16+/macOS 13+) instead of NSRegularExpression for:
  /// - Cleaner code with native String.Index ranges (no UTF-16 to UTF-8 conversion)
  /// - Better maintainability and type safety
  ///
  /// Performance characteristics (vs Python/Rust tiktoken):
  /// - Short text (~50 chars): ~1.3x slower - imperceptible in practice
  /// - Medium text (~1000 tokens): ~7-8x slower - still fast enough for most uses
  /// - Batch encoding: ~1.2x slower - parallelization helps amortize overhead
  ///
  /// The performance gap is primarily due to Swift's Regex being slower than Rust's
  /// regex crate. For applications requiring maximum throughput on large texts,
  /// consider using the Rust tiktoken library via FFI.
  private let regex: Regex<AnyRegexOutput>

  /// Compiled regex for special tokens
  private let specialRegex: Regex<AnyRegexOutput>?

  /// Sorted token bytes for binary search in unstable encoding
  private let sortedTokenBytes: [[UInt8]]

  /// Initialize a CoreBPE instance
  ///
  /// - Parameters:
  ///   - encoder: Dictionary mapping byte arrays to their token ranks
  ///   - specialTokensEncoder: Dictionary mapping special token strings to their ranks
  ///   - pattern: Regex pattern for tokenization
  /// - Throws: TiktokenError if the regex pattern is invalid
  public init(
    encoder: [[UInt8]: Rank],
    specialTokensEncoder: [String: Rank],
    pattern: String,
  ) throws {
    // Convert encoder to use ArraySlice keys for efficient slicing
    var sliceEncoder: [ArraySlice<UInt8>: Rank] = [:]
    sliceEncoder.reserveCapacity(encoder.count)
    for (key, value) in encoder {
      sliceEncoder[ArraySlice(key)] = value
    }
    self.encoder = sliceEncoder

    self.specialTokensEncoder = specialTokensEncoder

    // Build decoder (reverse mapping)
    var decoderMap: [Rank: [UInt8]] = [:]
    decoderMap.reserveCapacity(encoder.count)
    for (key, value) in encoder {
      decoderMap[value] = key
    }
    decoder = decoderMap

    // Verify encoder and decoder are same size (no duplicate ranks)
    assert(
      encoder.count == decoderMap.count,
      "Encoder and decoder must be of equal length. Encoder length: \(encoder.count), decoder length: \(decoderMap.count). Maybe you had duplicate token indices in your encoder?",
    )

    // Build special tokens decoder
    var specialDecoderMap: [Rank: [UInt8]] = [:]
    specialDecoderMap.reserveCapacity(specialTokensEncoder.count)
    for (key, value) in specialTokensEncoder {
      specialDecoderMap[value] = Array(key.utf8)
    }
    specialTokensDecoder = specialDecoderMap

    // Compute max token value
    let maxEncoderValue = encoder.values.max() ?? 0
    let maxSpecialValue = specialTokensEncoder.values.max() ?? 0
    maxTokenValue = max(maxEncoderValue, maxSpecialValue)

    // Compile the main regex using Swift's native Regex
    let convertedPattern = Self.convertPattern(pattern)
    do {
      regex = try Regex(convertedPattern)
    } catch {
      throw TiktokenError.regexError(message: "Failed to compile pattern: \(error.localizedDescription)")
    }

    // Compile special tokens regex
    if !specialTokensEncoder.isEmpty {
      let escapedTokens = specialTokensEncoder.keys.map { Self.escapeForRegex($0) }
      let specialPattern = escapedTokens.joined(separator: "|")
      do {
        specialRegex = try Regex(specialPattern)
      } catch {
        throw TiktokenError.regexError(message: "Failed to compile special tokens pattern: \(error.localizedDescription)")
      }
    } else {
      specialRegex = nil
    }

    // Sort token bytes for binary search
    let sorted = encoder.keys.sorted { $0.lexicographicallyPrecedes($1) }
    sortedTokenBytes = sorted
  }

  /// Escape special regex characters in a string
  private static func escapeForRegex(_ string: String) -> String {
    let specialCharacters = #"\.+*?^${}()[]|"#
    var result = ""
    for char in string {
      if specialCharacters.contains(char) {
        result.append("\\")
      }
      result.append(char)
    }
    return result
  }

  /// Convert tiktoken regex pattern to Swift Regex compatible pattern
  ///
  /// Note: Swift Regex fully supports possessive quantifiers (++, *+, ?+, {n,m}+)
  /// as specified in Swift Evolution proposals SE-0350, SE-0355, and SE-0363.
  /// We convert them to greedy quantifiers here because:
  /// 1. The tokenization output is identical (possessive only affects backtracking behavior)
  /// 2. Some patterns in EncodingLoader are already stored without possessive markers
  /// 3. This keeps the conversion logic simple and consistent
  private static func convertPattern(_ pattern: String) -> String {
    var result = pattern

    // Convert possessive quantifiers to greedy equivalents
    // For tokenization, results are the same - possessive is just a performance optimization
    result = result.replacingOccurrences(of: "++", with: "+")
    result = result.replacingOccurrences(of: "*+", with: "*")
    result = result.replacingOccurrences(of: "?+", with: "?")

    return result
  }

  /// Get all special tokens
  public func specialTokens() -> Set<String> {
    Set(specialTokensEncoder.keys)
  }

  /// Get the vocabulary size (max_token_value + 1)
  /// For backwards compatibility with Python tiktoken's `n_vocab` property.
  public var nVocab: Int {
    Int(maxTokenValue) + 1
  }

  /// Get the end-of-text token value, if available
  /// Returns nil if no <|endoftext|> special token is defined.
  public var eotToken: Rank? {
    specialTokensEncoder["<|endoftext|>"]
  }

  /// Check if a token is a special token
  ///
  /// - Parameter token: Token rank to check
  /// - Returns: true if the token is a special token
  public func isSpecialToken(_ token: Rank) -> Bool {
    specialTokensDecoder[token] != nil
  }

  // MARK: - Decoding

  /// Decode tokens to bytes
  ///
  /// - Parameter tokens: Array of token ranks to decode
  /// - Returns: Decoded byte array
  /// - Throws: TiktokenError if a token is not found in the decoder
  public func decodeBytes(tokens: [Rank]) throws -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(tokens.count * 2)

    for token in tokens {
      if let bytes = decoder[token] {
        result.append(contentsOf: bytes)
      } else if let bytes = specialTokensDecoder[token] {
        result.append(contentsOf: bytes)
      } else {
        throw TiktokenError.decodeKeyError(token: token)
      }
    }
    return result
  }

  /// Decode tokens to string
  ///
  /// - Parameter tokens: Array of token ranks to decode
  /// - Returns: Decoded string, or nil if the bytes are not valid UTF-8
  /// - Throws: TiktokenError if a token is not found in the decoder
  public func decode(tokens: [Rank]) throws -> String? {
    let bytes = try decodeBytes(tokens: tokens)
    return String(bytes: bytes, encoding: .utf8)
  }

  /// Decode a list of tokens into individual byte arrays
  /// Useful for visualizing how a string is tokenized.
  ///
  /// - Parameter tokens: Array of token ranks to decode
  /// - Returns: Array of byte arrays, one per token
  /// - Throws: TiktokenError if a token is not found in the decoder
  ///
  /// Example:
  /// ```
  /// let bytes = try encoder.decodeTokensBytes(tokens: [31373, 995])
  /// // Returns [[104, 101, 108, 108, 111], [32, 119, 111, 114, 108, 100]]
  /// // Which is [b"hello", b" world"]
  /// ```
  public func decodeTokensBytes(tokens: [Rank]) throws -> [[UInt8]] {
    try tokens.map { token in
      try decodeSingleTokenBytes(token: token)
    }
  }

  /// Decode tokens to string with character offsets
  /// Returns the decoded string along with the character offset where each token starts.
  ///
  /// - Parameter tokens: Array of token ranks to decode
  /// - Returns: Tuple of (decoded string, array of character offsets)
  /// - Throws: TiktokenError if a token is not found in the decoder
  ///
  /// Performance: O(n) where n is total bytes. We build a byte→char index map in one pass,
  /// then look up each token's offset in O(1). This avoids the naive O(n²) approach of
  /// repeatedly creating string prefixes to count characters.
  public func decodeWithOffsets(tokens: [Rank]) throws -> (String, [Int]) {
    let bytes = try decodeBytes(tokens: tokens)
    guard let fullText = String(bytes: bytes, encoding: .utf8) else {
      throw TiktokenError.decodeError(message: "Invalid UTF-8 sequence")
    }

    // Build byte offset → character index map in O(n)
    // Each position in the array maps a byte offset to the character count at that point
    var byteToCharIndex = Array(repeating: 0, count: bytes.count + 1)
    var charIdx = 0
    var byteIdx = 0
    for scalar in fullText.unicodeScalars {
      let scalarByteLen = scalar.utf8.count
      for _ in 0 ..< scalarByteLen {
        byteToCharIndex[byteIdx] = charIdx
        byteIdx += 1
      }
      charIdx += 1
    }
    byteToCharIndex[byteIdx] = charIdx

    // Compute token byte offsets and map to char offsets in O(n)
    var offsets: [Int] = []
    offsets.reserveCapacity(tokens.count)

    var currentByteOffset = 0
    for token in tokens {
      offsets.append(byteToCharIndex[currentByteOffset])

      // Advance by the byte length of this token
      if let tokenBytes = decoder[token] {
        currentByteOffset += tokenBytes.count
      } else if let tokenBytes = specialTokensDecoder[token] {
        currentByteOffset += tokenBytes.count
      }
    }

    return (fullText, offsets)
  }

  // MARK: - Encoding

  /// Encode text without handling special tokens
  /// This is the core encoding function - simpler and faster when special tokens aren't needed.
  ///
  /// - Parameter text: Text to encode
  /// - Returns: Array of token ranks
  /// - Throws: TiktokenError.inputTooLarge if text exceeds maxInputLength
  ///
  /// Performance notes:
  /// - We allocate `Array(substring.utf8)` per match rather than pre-building a byte array
  ///   with index mapping. Testing showed the index mapping approach (using Dictionary<String.Index, Int>)
  ///   was actually slower due to String.Index hashing overhead.
  /// - `reserveCapacity` provides ~7-10% speedup by avoiding array reallocations.
  public func encodeOrdinary(text: String) throws -> [Rank] {
    guard text.count <= maxInputLength else {
      throw TiktokenError.inputTooLarge(length: text.count, maxLength: maxInputLength)
    }

    var result: [Rank] = []
    result.reserveCapacity(text.count / 4) // Estimate: ~4 chars per token

    for match in text.matches(of: regex) {
      let matchedSubstring = text[match.range]
      let piece = Array(matchedSubstring.utf8)
      let pieceSlice = ArraySlice(piece)

      if let token = encoder[pieceSlice] {
        result.append(token)
      } else {
        result.append(contentsOf: bytePairEncode(piece: pieceSlice, ranks: encoder))
      }
    }
    return result
  }

  /// Check if text contains any disallowed special tokens
  ///
  /// - Parameters:
  ///   - text: Text to check
  ///   - disallowedTokens: Set of special tokens that should cause an error
  /// - Throws: TiktokenError.disallowedSpecialToken if a disallowed token is found
  private func checkForDisallowedSpecialTokens(text: String, disallowedTokens: Set<String>) throws {
    guard !disallowedTokens.isEmpty, let specialRegex else { return }

    var searchIndex = text.startIndex
    while searchIndex < text.endIndex {
      let searchRange = searchIndex ..< text.endIndex
      if let match = text[searchRange].firstMatch(of: specialRegex) {
        let matchedString = String(text[match.range])
        if disallowedTokens.contains(matchedString) {
          throw TiktokenError.disallowedSpecialToken(token: matchedString)
        }
        // Move past this match and continue searching
        searchIndex = text.index(after: match.range.lowerBound)
      } else {
        break
      }
    }
  }

  /// Encode text with special token handling
  ///
  /// Special tokens are artificial tokens used to unlock capabilities from a model,
  /// such as fill-in-the-middle. By default, encoding will raise an error if it encounters
  /// text that corresponds to a special token. This prevents accidental injection of special
  /// tokens that could manipulate model behavior.
  ///
  /// - Parameters:
  ///   - text: Text to encode
  ///   - allowedSpecial: Set of special tokens that are allowed to be encoded as special tokens
  ///   - disallowedSpecial: Which special tokens should cause an error if found (default: `.all`)
  /// - Returns: Tuple of (tokens, lastPieceTokenLen)
  /// - Throws: TiktokenError.disallowedSpecialToken if a disallowed token is found
  ///
  /// Example:
  /// ```swift
  /// // Default behavior - throws if special token found
  /// try encoder.encode(text: "<|endoftext|>", allowedSpecial: [])  // throws!
  ///
  /// // Allow specific special token
  /// try encoder.encode(text: "<|endoftext|>", allowedSpecial: ["<|endoftext|>"])  // OK
  ///
  /// // Disable check entirely (encode special tokens as regular text)
  /// try encoder.encode(text: "<|endoftext|>", allowedSpecial: [], disallowedSpecial: .none)  // OK
  /// ```
  public func encode(
    text: String,
    allowedSpecial: Set<String>,
    disallowedSpecial: DisallowedSpecial = .all
  ) throws -> ([Rank], Int) {
    guard text.count <= maxInputLength else {
      throw TiktokenError.inputTooLarge(length: text.count, maxLength: maxInputLength)
    }

    // Compute actual set of disallowed tokens
    let disallowedTokens: Set<String> = switch disallowedSpecial {
      case .all:
        specialTokens().subtracting(allowedSpecial)
      case .none:
        []
      case let .some(tokens):
        tokens
    }

    // Check for disallowed special tokens
    try checkForDisallowedSpecialTokens(text: text, disallowedTokens: disallowedTokens)

    guard let specialRegex else {
      // No special tokens defined, use ordinary encoding
      let tokens = try encodeOrdinary(text: text)
      return (tokens, tokens.isEmpty ? 0 : 1)
    }

    var result: [Rank] = []
    var startIndex = text.startIndex
    var lastPieceTokenLen = 0

    while startIndex < text.endIndex {
      // Find next allowed special token
      var nextSpecialMatch: Regex<AnyRegexOutput>.Match?
      var searchIndex = startIndex

      while searchIndex < text.endIndex {
        let searchRange = searchIndex ..< text.endIndex
        if let match = text[searchRange].firstMatch(of: specialRegex) {
          let matchedString = String(text[match.range])
          if allowedSpecial.contains(matchedString) {
            nextSpecialMatch = match
            break
          }
          // Move past this match and continue searching
          searchIndex = text.index(after: match.range.lowerBound)
        } else {
          break
        }
      }

      let endIndex = nextSpecialMatch?.range.lowerBound ?? text.endIndex

      // Encode text between startIndex and endIndex
      if startIndex < endIndex {
        let segment = text[startIndex ..< endIndex]

        for match in segment.matches(of: regex) {
          let matchedSubstring = segment[match.range]
          let piece = Array(matchedSubstring.utf8)
          let pieceSlice = ArraySlice(piece)

          if let token = encoder[pieceSlice] {
            lastPieceTokenLen = 1
            result.append(token)
          } else {
            let tokens = bytePairEncode(piece: pieceSlice, ranks: encoder)
            lastPieceTokenLen = tokens.count
            result.append(contentsOf: tokens)
          }
        }
      }

      // Handle special token
      if let match = nextSpecialMatch {
        let specialToken = String(text[match.range])
        let token = specialTokensEncoder[specialToken]!
        result.append(token)
        startIndex = match.range.upperBound
        lastPieceTokenLen = 0
      } else {
        break
      }
    }

    return (result, lastPieceTokenLen)
  }

  /// Encode text with all special tokens allowed
  ///
  /// This is a convenience method that allows all special tokens.
  ///
  /// - Parameter text: Text to encode
  /// - Returns: Array of token ranks
  /// - Throws: TiktokenError.inputTooLarge if text exceeds maxInputLength
  public func encodeWithSpecialTokens(text: String) throws -> [Rank] {
    let allowedSpecial = specialTokens()
    return try encode(text: text, allowedSpecial: allowedSpecial, disallowedSpecial: .none).0
  }

  /// Convenience encoding method with default safe behavior
  ///
  /// By default, this method will throw an error if it encounters any special tokens
  /// in the input text that aren't in `allowedSpecial`. This prevents accidental
  /// injection of special tokens.
  ///
  /// - Parameters:
  ///   - text: Text to encode
  ///   - allowedSpecial: Array of allowed special tokens
  ///   - disallowedSpecial: Which special tokens should cause an error (default: `.all`)
  /// - Returns: Array of token ranks
  /// - Throws: TiktokenError.disallowedSpecialToken if a disallowed token is found
  public func encode(
    text: String,
    allowedSpecial: [String],
    disallowedSpecial: DisallowedSpecial = .all
  ) throws -> [Rank] {
    let allowedSet = Set(allowedSpecial)
    return try encode(text: text, allowedSpecial: allowedSet, disallowedSpecial: disallowedSpecial).0
  }

  // MARK: - Single Token Operations

  /// Encode a single piece to exactly one token
  /// This will error if the piece does not encode to exactly one token.
  ///
  /// - Parameter piece: Byte array to encode
  /// - Returns: Single token rank
  /// - Throws: TiktokenError if piece doesn't encode to exactly one token
  public func encodeSingleToken(piece: [UInt8]) throws -> Rank {
    if let token = encoder[ArraySlice(piece)] {
      return token
    }
    if let pieceStr = String(bytes: piece, encoding: .utf8),
       let token = specialTokensEncoder[pieceStr]
    {
      return token
    }
    throw TiktokenError.encodeError(message: "Piece does not encode to a single token")
  }

  /// Encode a single piece (may return multiple tokens)
  ///
  /// - Parameter piece: Byte array to encode
  /// - Returns: Array of token ranks
  public func encodeSinglePiece(piece: [UInt8]) -> [Rank] {
    let pieceSlice = ArraySlice(piece)
    if let token = encoder[pieceSlice] {
      return [token]
    }
    return bytePairEncode(piece: pieceSlice, ranks: encoder)
  }

  /// Decode a single token to bytes
  ///
  /// - Parameter token: Token rank to decode
  /// - Returns: Byte array for this token
  /// - Throws: TiktokenError if token is not found
  public func decodeSingleTokenBytes(token: Rank) throws -> [UInt8] {
    if let bytes = decoder[token] {
      return bytes
    }
    if let bytes = specialTokensDecoder[token] {
      return bytes
    }
    throw TiktokenError.decodeKeyError(token: token)
  }

  /// Get all token byte values in sorted order
  ///
  /// - Returns: Array of all token byte arrays, sorted lexicographically
  public func tokenByteValues() -> [[UInt8]] {
    sortedTokenBytes
  }

  // MARK: - Batch Operations

  /// Encode multiple texts in parallel using Swift Concurrency
  ///
  /// - Parameters:
  ///   - texts: Array of texts to encode
  ///   - allowedSpecial: Set of special tokens allowed in encoding
  ///   - disallowedSpecial: Which special tokens should cause an error (default: `.all`)
  /// - Returns: Array of token arrays, one per input text
  /// - Throws: TiktokenError.disallowedSpecialToken if a disallowed token is found in any text
  public func encodeBatch(
    _ texts: [String],
    allowedSpecial: Set<String> = Set(),
    disallowedSpecial: DisallowedSpecial = .all
  ) async throws -> [[Rank]] {
    try await withThrowingTaskGroup(of: (Int, [Rank]).self, returning: [[Rank]].self) { group in
      for (index, text) in texts.enumerated() {
        group.addTask {
          let tokens = try self.encode(
            text: text,
            allowedSpecial: allowedSpecial,
            disallowedSpecial: disallowedSpecial
          ).0
          return (index, tokens)
        }
      }

      var results = Array(repeating: [Rank](), count: texts.count)
      for try await (index, tokens) in group {
        results[index] = tokens
      }
      return results
    }
  }

  /// Encode multiple texts in parallel (convenience overload with array)
  ///
  /// - Parameters:
  ///   - texts: Array of texts to encode
  ///   - allowedSpecial: Array of special tokens allowed in encoding
  ///   - disallowedSpecial: Which special tokens should cause an error (default: `.all`)
  /// - Returns: Array of token arrays, one per input text
  /// - Throws: TiktokenError.disallowedSpecialToken if a disallowed token is found in any text
  public func encodeBatch(
    _ texts: [String],
    allowedSpecial: [String],
    disallowedSpecial: DisallowedSpecial = .all
  ) async throws -> [[Rank]] {
    try await encodeBatch(texts, allowedSpecial: Set(allowedSpecial), disallowedSpecial: disallowedSpecial)
  }

  /// Encode multiple texts in parallel without special token handling
  ///
  /// - Parameter texts: Array of texts to encode
  /// - Returns: Array of token arrays, one per input text
  /// - Throws: TiktokenError.inputTooLarge if any text exceeds maxInputLength
  public func encodeOrdinaryBatch(_ texts: [String]) async throws -> [[Rank]] {
    try await withThrowingTaskGroup(of: (Int, [Rank]).self, returning: [[Rank]].self) { group in
      for (index, text) in texts.enumerated() {
        group.addTask {
          try (index, self.encodeOrdinary(text: text))
        }
      }

      var results = Array(repeating: [Rank](), count: texts.count)
      for try await (index, tokens) in group {
        results[index] = tokens
      }
      return results
    }
  }

  /// Decode multiple token arrays in parallel
  ///
  /// - Parameter tokenBatches: Array of token arrays to decode
  /// - Returns: Array of decoded strings
  /// - Throws: TiktokenError if any token is not found
  public func decodeBatch(_ tokenBatches: [[Rank]]) async throws -> [String] {
    try await withThrowingTaskGroup(of: (Int, String).self, returning: [String].self) { group in
      for (index, tokens) in tokenBatches.enumerated() {
        group.addTask {
          let decoded = try self.decode(tokens: tokens) ?? ""
          return (index, decoded)
        }
      }

      var results = Array(repeating: "", count: tokenBatches.count)
      for try await (index, text) in group {
        results[index] = text
      }
      return results
    }
  }

  // MARK: - Synchronous Batch Operations (for compatibility)

  /// Encode multiple texts synchronously (blocking)
  /// Prefer the async version for better performance.
  ///
  /// - Parameters:
  ///   - texts: Array of texts to encode
  ///   - allowedSpecial: Set of special tokens allowed in encoding
  ///   - disallowedSpecial: Which special tokens should cause an error (default: `.all`)
  /// - Returns: Array of token arrays, one per input text
  /// - Throws: TiktokenError.disallowedSpecialToken if a disallowed token is found in any text
  public func encodeBatchSync(
    _ texts: [String],
    allowedSpecial: Set<String> = Set(),
    disallowedSpecial: DisallowedSpecial = .all
  ) throws -> [[Rank]] {
    try texts.map { text in
      try encode(text: text, allowedSpecial: allowedSpecial, disallowedSpecial: disallowedSpecial).0
    }
  }

  /// Decode multiple token arrays synchronously (blocking)
  /// Prefer the async version for better performance.
  ///
  /// - Parameter tokenBatches: Array of token arrays to decode
  /// - Returns: Array of decoded strings
  /// - Throws: TiktokenError if any token is not found
  public func decodeBatchSync(_ tokenBatches: [[Rank]]) throws -> [String] {
    try tokenBatches.map { tokens in
      try decode(tokens: tokens) ?? ""
    }
  }

  // MARK: - Raw Bytes Encoding

  /// Encode raw bytes (handles invalid UTF-8)
  /// This is useful when you have raw bytes that may not be valid UTF-8.
  ///
  /// - Parameter bytes: Raw bytes to encode
  /// - Returns: Array of token ranks
  /// - Throws: TiktokenError.inputTooLarge if input exceeds maxInputLength
  public func encodeBytes(_ bytes: [UInt8]) throws -> [Rank] {
    guard bytes.count <= maxInputLength else {
      throw TiktokenError.inputTooLarge(length: bytes.count, maxLength: maxInputLength)
    }

    // Try to decode as UTF-8 first
    if let text = String(bytes: bytes, encoding: .utf8) {
      return try encodeOrdinary(text: text)
    }

    // Handle invalid UTF-8 by finding the valid prefix
    var validUpTo = 0
    var tempBytes = bytes
    while !tempBytes.isEmpty {
      if String(bytes: tempBytes, encoding: .utf8) != nil {
        validUpTo = bytes.count - (bytes.count - tempBytes.count)
        break
      }
      tempBytes = Array(tempBytes.dropLast())
    }

    // If we found no valid UTF-8, just encode all bytes directly
    if validUpTo == 0 {
      let pieceSlice = ArraySlice(bytes)
      if let token = encoder[pieceSlice] {
        return [token]
      }
      return bytePairEncode(piece: pieceSlice, ranks: encoder)
    }

    // Encode the valid UTF-8 prefix
    let validText = String(bytes: bytes[..<validUpTo], encoding: .utf8)!
    let (tokens, lastPieceTokenLen) = try encode(text: validText, allowedSpecial: Set())
    var (resultTokens, adjustedLastPieceTokenLen) = increaseLastPieceTokenLen(
      tokens: tokens,
      lastPieceTokenLen: lastPieceTokenLen,
    )

    var unstableBytes: [UInt8]
    if !resultTokens.isEmpty, adjustedLastPieceTokenLen > 0 {
      // Lop off tokens from last piece and run BPE on remaining bytes
      unstableBytes = (try? decodeBytes(tokens: Array(resultTokens[(resultTokens.count - adjustedLastPieceTokenLen)...]))) ?? []
      unstableBytes.append(contentsOf: bytes[validUpTo...])
      resultTokens.removeLast(adjustedLastPieceTokenLen)
    } else {
      unstableBytes = Array(bytes[validUpTo...])
    }

    if !unstableBytes.isEmpty {
      let unstableSlice = ArraySlice(unstableBytes)
      if let token = encoder[unstableSlice] {
        resultTokens.append(token)
      } else {
        resultTokens.append(contentsOf: bytePairEncode(piece: unstableSlice, ranks: encoder))
      }
    }

    return resultTokens
  }

  // MARK: - Advanced Encoding (Unstable tokens)

  /// Increase the last piece token length to handle unstable regex splits
  private func increaseLastPieceTokenLen(tokens: [Rank], lastPieceTokenLen: Int) -> ([Rank], Int) {
    let resultTokens = tokens
    var adjustedLastPieceTokenLen = lastPieceTokenLen

    // Helper to check if a token is all whitespace
    let tokenIsAllSpace: (Rank) -> Bool = { token in
      guard let bytes = self.decoder[token] else { return false }
      return bytes.reversed().allSatisfy { [UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\t")].contains($0) }
    }

    if adjustedLastPieceTokenLen > 0, tokenIsAllSpace(resultTokens[resultTokens.count - adjustedLastPieceTokenLen]) {
      while adjustedLastPieceTokenLen < resultTokens.count,
            tokenIsAllSpace(resultTokens[resultTokens.count - adjustedLastPieceTokenLen - 1])
      {
        adjustedLastPieceTokenLen += 1
      }
    }

    assert(adjustedLastPieceTokenLen <= resultTokens.count)
    return (resultTokens, adjustedLastPieceTokenLen)
  }

  /// Encode with unstable token boundary detection
  ///
  /// - Parameters:
  ///   - text: Text to encode
  ///   - allowedSpecial: Set of allowed special tokens
  /// - Returns: Tuple of (stable tokens, set of possible completions)
  public func encodeUnstableNative(text: String, allowedSpecial: Set<String>) -> ([Rank], Set<[Rank]>) {
    guard let (initialTokens, initialLastPieceTokenLen) = try? encode(text: text, allowedSpecial: allowedSpecial) else {
      return ([], Set())
    }

    if initialLastPieceTokenLen == 0 {
      // Last token was a special token, no unstable bytes
      return (initialTokens, Set())
    }

    let (adjustedTokens, adjustedLastPieceTokenLen) = increaseLastPieceTokenLen(
      tokens: initialTokens,
      lastPieceTokenLen: initialLastPieceTokenLen,
    )

    var workingTokens = adjustedTokens
    let workingLastPieceTokenLen = adjustedLastPieceTokenLen

    guard let unstableBytes = try? decodeBytes(tokens: Array(workingTokens[(workingTokens.count - workingLastPieceTokenLen)...])) else {
      return (workingTokens, Set())
    }

    workingTokens.removeLast(workingLastPieceTokenLen)

    var completions: Set<[Rank]> = []
    if unstableBytes.isEmpty {
      return (workingTokens, completions)
    }

    // Find all single tokens that start with unstable_bytes
    var point = sortedTokenBytes.binarySearchPartitionPoint { $0.lexicographicallyPrecedes(unstableBytes) }

    while point < sortedTokenBytes.count,
          sortedTokenBytes[point].starts(with: unstableBytes)
    {
      completions.insert([encoder[ArraySlice(sortedTokenBytes[point])]!])
      point += 1
    }

    // Brute force additional possibilities
    for i in 1 ..< unstableBytes.count {
      let prefix = Array(unstableBytes[..<i])
      let suffix = Array(unstableBytes[i...])

      var innerPoint = sortedTokenBytes.binarySearchPartitionPoint { $0.lexicographicallyPrecedes(suffix) }

      while innerPoint < sortedTokenBytes.count,
            sortedTokenBytes[innerPoint].starts(with: suffix)
      {
        let possibility = prefix + sortedTokenBytes[innerPoint]

        let encoded: [Rank] = if let str = String(bytes: possibility, encoding: .utf8) {
          // Use try? as possibility is always small, but handle edge cases gracefully
          (try? encodeOrdinary(text: str)) ?? bytePairEncode(piece: ArraySlice(possibility), ranks: encoder)
        } else {
          bytePairEncode(piece: ArraySlice(possibility), ranks: encoder)
        }

        var seq: [Rank] = []
        var seqLen = 0
        for token in encoded {
          seq.append(token)
          seqLen += decoder[token]?.count ?? 0
          if seqLen >= unstableBytes.count {
            break
          }
        }
        completions.insert(seq)
        innerPoint += 1
      }
    }

    // Handle unstable regex splits with whitespace
    if unstableBytes.count > 1 {
      if let (lastChar, lastCharLen) = decodeLastUtf8(unstableBytes),
         lastCharLen > 0,
         lastChar.isWhitespace
      {
        let prefixLen = unstableBytes.count - lastCharLen
        if prefixLen > 0 {
          var reencoded = bytePairEncode(
            piece: ArraySlice(unstableBytes[..<prefixLen]),
            ranks: encoder,
          )
          reencoded.append(contentsOf: bytePairEncode(
            piece: ArraySlice(unstableBytes[prefixLen...]),
            ranks: encoder,
          ))
          completions.insert(reencoded)
        }
      }
    }

    return (workingTokens, completions)
  }

  /// Decode the last UTF-8 character from a byte array
  private func decodeLastUtf8(_ bytes: [UInt8]) -> (Character, Int)? {
    guard !bytes.isEmpty else { return nil }

    // Try to decode 1-4 bytes from the end
    for len in 1 ... min(4, bytes.count) {
      let start = bytes.count - len
      let slice = bytes[start...]
      if let str = String(bytes: slice, encoding: .utf8), let char = str.first {
        return (char, len)
      }
    }
    return nil
  }
}

// MARK: - Array extensions

extension Array {
  /// Find the partition point where predicate changes from true to false
  /// Binary search to find the first element for which predicate returns false
  func binarySearchPartitionPoint(predicate: (Element) -> Bool) -> Int {
    var low = 0
    var high = count
    while low < high {
      let mid = low + (high - low) / 2
      if predicate(self[mid]) {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }
}

extension [UInt8] {
  /// Check if this array starts with another array
  func starts(with prefix: [UInt8]) -> Bool {
    guard count >= prefix.count else { return false }
    return zip(self, prefix).allSatisfy { $0 == $1 }
  }
}

// MARK: - Factory function (matching FFI API)

/// Create a new CoreBPE instance (matching the FFI wrapper API)
///
/// - Parameters:
///   - encoder: Dictionary mapping byte arrays to their token ranks
///   - specialTokensEncoder: Dictionary mapping special token strings to their ranks
///   - pattern: Regex pattern for tokenization
/// - Returns: Configured CoreBPE instance
/// - Throws: TiktokenError if the regex pattern is invalid
public func newCoreBPE(
  encoder: [[UInt8]: UInt32],
  specialTokensEncoder: [String: UInt32],
  pattern: String,
) throws -> CoreBPE {
  try CoreBPE(
    encoder: encoder,
    specialTokensEncoder: specialTokensEncoder,
    pattern: pattern,
  )
}
