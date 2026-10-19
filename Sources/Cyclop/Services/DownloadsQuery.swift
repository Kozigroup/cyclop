import AppKit
import CoreServices

/// New files anywhere inside the folders the user picked — Desktop, Documents,
/// whatever — including every subfolder. Catches what apps save through their
/// own "Save" dialog (Claude, Telegram, Slack…), which never touches Downloads
/// and often carries no "downloaded from" tag either.
///
/// Uses FSEvents: one stream for the whole tree, no polling. The folders are
/// handed over through an Open panel, which is the user's consent and saves a
/// Privacy prompt per folder.
@MainActor
final class DownloadsQuery {
    var onFile: ((URL) -> Void)?

    private let enabledKey = "downloadsEverywhere.enabled"
    private let pathsKey = "downloadsEverywhere.paths"
    private var stream: FSEventStreamRef?
    private var startedAt = Date()
    private var reported: Set<String> = []

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private var folders: [String] {
        UserDefaults.standard.stringArray(forKey: pathsKey) ?? []
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.title = localized("Choose Folders to Watch")
        panel.message = localized("Cyclop will put every new file saved in these folders, and in folders inside them, on the shelf.")
        panel.prompt = localized("Watch")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else {
                completion(false)
                return
            }
            UserDefaults.standard.set(panel.urls.map(\.path), forKey: self.pathsKey)
            UserDefaults.standard.set(true, forKey: self.enabledKey)
            self.start()
            completion(true)
        }
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: pathsKey)
        stop()
    }

    func resumeIfEnabled() {
        if isEnabled { start() }
    }

    func start() {
        stop()
        guard !folders.isEmpty else { return }
        startedAt = Date()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context,
            folders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        reported.removeAll()
    }

    /// FSEvents calls this on the queue set above — the main queue.
    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        var created: [String] = []
        for index in 0..<min(count, list.count) {
            let flag = Int(flags[index])
            let isFile = flag & kFSEventStreamEventFlagItemIsFile != 0
            let arrived = flag & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
            if isFile && arrived { created.append(list[index]) }
        }
        guard !created.isEmpty else { return }
        let watcherAddress = UInt(bitPattern: info)
        MainActor.assumeIsolated {
            guard let raw = UnsafeMutableRawPointer(bitPattern: watcherAddress) else { return }
            Unmanaged<DownloadsQuery>.fromOpaque(raw).takeUnretainedValue().handle(created)
        }
    }

    private func handle(_ paths: [String]) {
        for path in paths where !reported.contains(path) {
            let url = URL(fileURLWithPath: path)
            // Hidden files, anything inside a hidden folder or an app bundle,
            // and the browser's half-written files are noise, not saves.
            guard !url.pathComponents.contains(where: { $0.hasPrefix(".") }),
                  !url.pathComponents.contains(where: { $0.hasSuffix(".app") }),
                  !DownloadNames.isPartial(url),
                  FileManager.default.fileExists(atPath: path) else { continue }
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            let added = values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast
            guard added >= startedAt.addingTimeInterval(-5) else { continue }
            reported.insert(path)
            waitForStableSize(url, lastSize: -1, attempt: 0)
        }
    }

    private func waitForStableSize(_ url: URL, lastSize: Int, attempt: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else { return }
        if size == lastSize && size > 0 {
            onFile?(url)
            return
        }
        guard attempt < 50 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.waitForStableSize(url, lastSize: size, attempt: attempt + 1)
        }
    }
}

/// How browsers name a download that is still in progress.
enum DownloadNames {
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial"]

    static func isPartial(_ url: URL) -> Bool {
        partialExtensions.contains(url.pathExtension.lowercased())
    }

    /// `report.pdf.crdownload` → `report.pdf`. Chrome's "Unconfirmed 123"
    /// names have no final name inside them; the caller matches those by time.
    static func finalURL(for partial: URL) -> URL {
        partial.deletingPathExtension()
    }
}
