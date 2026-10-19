import Foundation

/// A few live lines about the file watchers, shown at the bottom of Settings —
/// enough to tell "not listening" from "listening but filtering" without a
/// debugger.
@MainActor
final class Diag: ObservableObject {
    static let shared = Diag()
    @Published private(set) var lines: [String: String] = [:]

    func set(_ key: String, _ value: String) {
        lines[key] = value
    }
}
