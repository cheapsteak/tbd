import Foundation

/// Fits one list into one frame: the items, in order, whose encoded bytes fit
/// what is left of a byte budget.
///
/// Each item costs its bytes under `PhoneAppCoding.makeEncoder()`, and a
/// comma unless it is the first kept, so the kept items encode as a JSON array
/// to exactly the bytes counted. An item that does not encode costs more than
/// any budget. A list sent across several frames is chunked elsewhere; this
/// is for a list that must fit the one frame of a reply.
enum PhoneFrameFit {
    /// What fitting does at an item that does not fit.
    enum Misfit: Sendable {
        /// Leave the item out and try the next one, so one oversized item
        /// drops only itself.
        case skip
        /// Leave the item and every one after it out, so what is kept is a
        /// prefix of the list.
        case stop
    }

    /// The items of `items`, in order, that fit `budget` bytes once `used`
    /// bytes are spent, `used` being the enclosing value encoded with the list
    /// empty. `onMisfit` says what happens at an item that does not fit.
    static func fitted<Item: Encodable>(
        _ items: [Item], used: Int, budget: Int, onMisfit: Misfit
    ) -> [Item] {
        let encoder = PhoneAppCoding.makeEncoder()
        var used = used
        var kept: [Item] = []
        for item in items {
            let cost = ((try? encoder.encode(item).count) ?? Int.max / 2) + (kept.isEmpty ? 0 : 1)
            guard used + cost <= budget else {
                switch onMisfit {
                case .skip:
                    continue
                case .stop:
                    return kept
                }
            }
            used += cost
            kept.append(item)
        }
        return kept
    }
}
