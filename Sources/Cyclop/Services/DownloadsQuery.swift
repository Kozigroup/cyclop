import AppKit

/// Every downloaded file, wherever it was saved — not just the Downloads
/// folder. Apps that ask "where to save?" (Claude, Telegram, Slack…) put files
/// anywhere, but the system tags anything that came from the internet with
/// where it came from (`kMDItemWhereFroms`) or when (`kMDItemDownloadedDate`).
/// Spotlight indexes both, so a live query sees a download land in any folder.
@MainActor
final class DownloadsQuery {
    var onFile: ((URL) -> Void)?

    private let enabledKey = "downloadsEverywhere.enabled"
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    /// Files present when the query started are history, not news.
    private var known: Set<String> = []
    private var startedAt = Date()

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            newValue ? start() : stop()
        }
    }

    func resumeIfEnabled() {
        if isEnabled { start() }
    }

    func start() {
        stop()
        startedAt = Date()
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "%K LIKE '*' OR %K > %@",
            "kMDItemWhereFroms", "kMDItemDownloadedDate", startedAt.addingTimeInterval(-60) as NSDate
        )
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 0.5

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.remember() }
        })
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.collect() }
        })
        self.query = query
        query.start()
    }

    func stop() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        known.removeAll()
    }

    private func paths() -> [String] {
        guard let query else { return [] }
        query.disableUpdates()
        defer { query.enableUpdates() }
        return (0..<query.resultCount).compactMap {
            (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
        }
    }

    private func remember() {
        known = Set(paths())
    }

    private func collect() {
        for path in paths() where !known.contains(path) {
            known.insert(path)
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            guard !["crdownload", "download", "part", "partial", "tmp"].contains(ext) else { continue }
            // Old files can re-enter the results when Spotlight re-indexes
            // them; only things that appeared since the query started count.
            let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? .distantPast
            guard added >= startedAt.addingTimeInterval(-5) else { continue }
            onFile?(url)
        }
    }
}
