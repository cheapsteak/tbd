import Foundation
import Testing
@testable import TBDShared

/// Deterministic RNG so a failing random case reproduces from its seed
/// (SplitMix64).
private struct PlacementRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A stable, readable ID per small integer, so expectations read as letters.
private func id(_ n: Int) -> UUID {
    let digits = String(n)
    let padded = String(repeating: "0", count: max(0, 12 - digits.count)) + digits
    return UUID(uuidString: "00000000-0000-0000-0000-\(padded)") ?? UUID()
}

private let a = id(1)
private let b = id(2)
private let c = id(3)
private let d = id(4)
private let e = id(5)
private let x = id(24)
private let y = id(25)
private let z = id(26)

@Suite struct SiblingPlacementTests {
    @Test func placesBeforeTarget() {
        let result = SiblingPlacement.place(group: [a, b, c, d], carried: [d], before: b)
        #expect(result == [a, d, b, c])
    }

    @Test func appendsWhenBeforeNil() {
        let result = SiblingPlacement.place(group: [a, b, c], carried: [a], before: nil)
        #expect(result == [b, c, a])
    }

    @Test func keepsCarriedOrder() {
        let result = SiblingPlacement.place(group: [a, b, c, d, e], carried: [e, b], before: c)
        #expect(result == [a, e, b, c, d])
    }

    @Test func insertsRowsJoiningTheGroup() {
        let result = SiblingPlacement.place(group: [a, b], carried: [x, y], before: b)
        #expect(result == [a, x, y, b])
    }

    @Test func appendsWhenBeforeMissing() {
        let result = SiblingPlacement.place(group: [a, b], carried: [x], before: z)
        #expect(result == [a, b, x])
    }

    /// A carried ID named twice still lands once, so the daemon never writes
    /// two sort orders for one row.
    @Test func placesADuplicatedCarriedIDOnce() {
        let result = SiblingPlacement.place(group: [a, b, c], carried: [c, a, c], before: b)
        #expect(result == [c, a, b])
    }

    /// For any group, carried set and target, the rows not carried keep their
    /// relative order, every carried row appears exactly once, contiguous and
    /// in the order given, and the block sits right before `before` when
    /// `before` survives, or at the end otherwise.
    @Test func preservesRelativeOrderOfOthers() {
        for seed in UInt64(1)...200 {
            var rng = PlacementRNG(seed: seed)
            let groupSize = Int.random(in: 0...10, using: &rng)
            let group = (0..<groupSize).map { id(100 + $0) }
            let joining = (0..<Int.random(in: 0...2, using: &rng)).map { id(500 + $0) }
            let fromGroup = group.filter { _ in Bool.random(using: &rng) }
            let carried = (fromGroup + joining).shuffled(using: &rng)
            let candidates: [UUID?] = [nil, id(999)] + group.map { Optional($0) }
            let before: UUID? = candidates.randomElement(using: &rng).flatMap { $0 }

            let result = SiblingPlacement.place(group: group, carried: carried, before: before)

            let carriedSet = Set(carried)
            let others = group.filter { !carriedSet.contains($0) }
            let kept = result.filter { !carriedSet.contains($0) }
            #expect(kept == others, "seed \(seed)")
            #expect(result.count == others.count + carried.count, "seed \(seed)")
            #expect(Set(result).count == result.count, "seed \(seed)")

            guard let start = result.firstIndex(where: { carriedSet.contains($0) }) else {
                #expect(carried.isEmpty, "seed \(seed)")
                continue
            }
            let block = Array(result[start...].prefix(carried.count))
            #expect(block == carried, "seed \(seed)")
            let after = start + carried.count
            if let before, others.contains(before) {
                #expect(after < result.count, "seed \(seed)")
                if after < result.count {
                    #expect(result[after] == before, "seed \(seed)")
                }
            } else {
                #expect(after == result.count, "seed \(seed)")
            }
        }
    }
}
