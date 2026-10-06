import Foundation

/// Type alias for token rank (matching Rust implementation)
public typealias Rank = UInt32

// MARK: - Performance Notes

//
// The original Rust tiktoken implementation uses a simple array with O(n) removals
// via `parts.remove(i + 1)`. This works well in Rust due to its efficient Vec
// operations and memory model.
//
// In Swift, array removal is particularly expensive because:
// 1. Swift arrays have copy-on-write semantics with reference counting overhead
// 2. Element shifts after removal have poor cache behavior
// 3. For large arrays (e.g., 10,000 elements), each O(n) removal becomes costly
//
// For "catastrophically repetitive" input (e.g., 10,000 identical characters),
// the naive approach took ~68 seconds in Swift vs ~0.4 seconds in Python/Rust.
//
// The optimization below uses a virtual linked list (parallel arrays of prev/next
// indices) to achieve O(1) removal while maintaining O(mn) overall complexity.
// This brought the time down to ~8 seconds - still slower than Rust, but 8x faster
// than the naive Swift implementation.
//
// Note: The remaining performance gap vs Rust is primarily due to:
// 1. Swift's Dictionary with ArraySlice keys has higher hashing overhead
// 2. Swift's bounds checking and safety features add overhead
// 3. ContiguousArray operations are still slower than Rust's Vec

/// Core byte pair merge algorithm using linked-list style traversal.
///
/// This implementation uses a virtual linked list to avoid O(n) array removals.
/// The original algorithm matches Rust's tiktoken but was optimized for Swift's
/// different performance characteristics.
///
/// Algorithm complexity:
/// - Time: O(mn) where m = number of merges, n = number of parts
/// - Space: O(n) for the parallel arrays
///
/// - Parameters:
///   - ranks: Dictionary mapping byte sequences to their ranks
///   - piece: The byte sequence to merge
/// - Returns: Array of (start_index, rank) tuples representing merge points
@inline(__always)
func bytePairMerge(ranks: [ArraySlice<UInt8>: Rank], piece: ArraySlice<UInt8>) -> [(Int, Rank)] {
  // Virtual linked list using parallel arrays for O(1) removal.
  // This avoids Swift's expensive array element shifting.
  //
  // Structure:
  // - partStart: the starting byte index for this part
  // - partRank: the rank of merging this part with the next
  // - partNext: index of the next active part (-1 = end of list)
  // - partPrev: index of the previous active part (-1 = start of list)
  let n = piece.count
  let partStart = ContiguousArray<Int>(unsafeUninitializedCapacity: n + 1) { buffer, count in
    for i in 0 ... n {
      buffer[i] = i
    }
    count = n + 1
  }
  var partRank = ContiguousArray<Rank>(repeating: Rank.max, count: n + 1)
  var partNext = ContiguousArray<Int>(unsafeUninitializedCapacity: n + 1) { buffer, count in
    for i in 0 ..< n {
      buffer[i] = i + 1
    }
    buffer[n] = -1 // end marker
    count = n + 1
  }
  var partPrev = ContiguousArray<Int>(unsafeUninitializedCapacity: n + 1) { buffer, count in
    buffer[0] = -1 // start marker
    for i in 1 ... n {
      buffer[i] = i - 1
    }
    count = n + 1
  }

  let pieceStartIndex = piece.startIndex
  var minRank = Rank.max
  var minIdx: Int = -1

  // Initialize ranks for adjacent pairs
  for i in 0 ..< (n - 1) {
    let sliceStart = pieceStartIndex + i
    let sliceEnd = pieceStartIndex + i + 2
    let rank = ranks[piece[sliceStart ..< sliceEnd]] ?? Rank.max
    partRank[i] = rank
    if rank < minRank {
      minRank = rank
      minIdx = i
    }
  }

  // Get rank for merging part at index i with the part two steps ahead
  @inline(__always)
  func getRank(_ i: Int) -> Rank {
    let next1 = partNext[i]
    if next1 < 0 { return Rank.max }
    let next2 = partNext[next1]
    if next2 < 0 { return Rank.max }
    let next3 = partNext[next2]
    if next3 < 0 { return Rank.max }
    let start = pieceStartIndex + partStart[i]
    let end = pieceStartIndex + partStart[next3]
    return ranks[piece[start ..< end]] ?? Rank.max
  }

  // Main merge loop - O(mn) work but with O(1) removal instead of O(n)
  while minRank != Rank.max {
    let i = minIdx
    let next1 = partNext[i]

    // Update ranks for affected parts before "removing" next1
    let prev = partPrev[i]
    if prev >= 0 {
      partRank[prev] = getRank(prev)
    }
    partRank[i] = getRank(i)

    // "Remove" next1 by updating linked list pointers (O(1) instead of O(n))
    let next2 = partNext[next1]
    partNext[i] = next2
    if next2 >= 0 {
      partPrev[next2] = i
    }

    // Find new minimum by traversing active parts
    minRank = Rank.max
    minIdx = -1
    var curr = 0
    while curr >= 0 {
      let nextCurr = partNext[curr]
      if nextCurr >= 0, partRank[curr] < minRank {
        minRank = partRank[curr]
        minIdx = curr
      }
      curr = nextCurr
    }
  }

  // Collect active parts into result array
  var result: [(Int, Rank)] = []
  var curr = 0
  while curr >= 0 {
    result.append((partStart[curr], partRank[curr]))
    curr = partNext[curr]
  }
  return result
}

/// Encode a byte sequence using byte pair encoding
/// This is a faithful port of the Rust `byte_pair_encode` function.
///
/// - Parameters:
///   - piece: The byte sequence to encode
///   - ranks: Dictionary mapping byte sequences to their ranks
/// - Returns: Array of token ranks
@inline(__always)
func bytePairEncode(piece: ArraySlice<UInt8>, ranks: [ArraySlice<UInt8>: Rank]) -> [Rank] {
  if piece.count == 1 {
    return [ranks[piece]!]
  }
  let parts = bytePairMerge(ranks: ranks, piece: piece)
  let pieceStartIndex = piece.startIndex

  var result: [Rank] = []
  result.reserveCapacity(parts.count - 1)

  for i in 0 ..< (parts.count - 1) {
    let start = pieceStartIndex + parts[i].0
    let end = pieceStartIndex + parts[i + 1].0
    result.append(ranks[piece[start ..< end]]!)
  }
  return result
}

/// Split a byte sequence into tokens using byte pair encoding
/// This is a faithful port of the Rust `byte_pair_split` function.
///
/// - Parameters:
///   - piece: The byte sequence to split
///   - ranks: Dictionary mapping byte sequences to their ranks
/// - Returns: Array of byte slices representing tokens
func bytePairSplit(piece: ArraySlice<UInt8>, ranks: [ArraySlice<UInt8>: Rank]) -> [ArraySlice<UInt8>] {
  assert(piece.count > 1)
  let parts = bytePairMerge(ranks: ranks, piece: piece)
  let pieceStartIndex = piece.startIndex

  var result: [ArraySlice<UInt8>] = []
  result.reserveCapacity(parts.count - 1)

  for i in 0 ..< (parts.count - 1) {
    let start = pieceStartIndex + parts[i].0
    let end = pieceStartIndex + parts[i + 1].0
    result.append(piece[start ..< end])
  }
  return result
}
