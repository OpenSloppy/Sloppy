import Foundation

/// Errors that can occur during tiktoken operations
public enum TiktokenError: Error, Equatable, Hashable, LocalizedError {
  /// Error during regex compilation or matching
  case regexError(message: String)
  /// Error during token decoding
  case decodeError(message: String)
  /// Error when a token cannot be found in the decoder
  case decodeKeyError(token: Rank)
  /// Error during encoding
  case encodeError(message: String)
  /// Error when a disallowed special token is found in the input text
  case disallowedSpecialToken(token: String)
  /// Error when input text exceeds maximum allowed length
  case inputTooLarge(length: Int, maxLength: Int)

  public var errorDescription: String? {
    switch self {
      case let .regexError(message):
        "Regex error: \(message)"
      case let .decodeError(message):
        "Decode error: \(message)"
      case let .decodeKeyError(token):
        "Invalid token for decoding: \(token)"
      case let .encodeError(message):
        "Encode error: \(message)"
      case let .disallowedSpecialToken(token):
        """
        Encountered text corresponding to disallowed special token \(token).
        If you want this text to be encoded as a special token, \
        pass it to `allowedSpecial`, e.g. `allowedSpecial: [\"\(token)\"]`.
        If you want this text to be encoded as normal text, \
        pass `disallowedSpecial: []` to disable the check.
        """
      case let .inputTooLarge(length, maxLength):
        "Input text length \(length) exceeds maximum allowed length \(maxLength)"
    }
  }
}
