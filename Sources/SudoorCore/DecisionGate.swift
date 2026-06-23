import Foundation

/// Ensures a permission decision is emitted at most once (stdout contract).
public final class DecisionGate: @unchecked Sendable {
    private var decided = false
    private let lock = NSLock()

    public init() {}

    /// Runs `action` only on the first call; returns whether this call won the race.
    @discardableResult
    public func runOnce(_ action: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !decided else { return false }
        decided = true
        action()
        return true
    }
}

/// Clamp island timeout to a sensible positive range.
public func clampTimeout(_ raw: Double) -> Double {
    guard raw.isFinite, raw > 0 else { return 30 }
    return min(max(raw, 1), 300)
}

/// Safe token for Makefile targets / package.json script names (no shell metacharacters).
public func safeRunToken(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let ok = trimmed.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
    }
    return ok ? trimmed : nil
}
