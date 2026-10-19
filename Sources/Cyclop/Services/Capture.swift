import AppKit
import WebKit

/// Two ways to make a picture without leaving the panel: a region of the
/// screen (the system's own crosshair) and a whole web page, top to bottom,
/// without scrolling through it by hand. Both land in `ScreenshotVault`.
enum RegionCapture {
    /// Runs `screencapture -i`, the same crosshair as ⌘⇧4. Esc cancels and
    /// leaves no file, which is reported as `nil`.
    static func run() async -> URL? {
        let path = ScreenshotVault.nextURL().path
        let saved: Bool = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", path]
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return FileManager.default.fileExists(atPath: path)
        }.value
        return saved ? URL(fileURLWithPath: path) : nil
    }
}

/// Renders a page in an invisible browser and photographs all of it.
///
/// The page is loaded fresh, without the cookies of the user's own browser —
/// public pages come out exactly as seen, pages behind a login come out as
/// their login screen.
@MainActor
final class PageCapture: NSObject, WKNavigationDelegate {
    static let shared = PageCapture()

    private let width: CGFloat = 1440
    /// Beyond this a single PNG gets too heavy to open comfortably.
    private let maxHeight: CGFloat = 20000

    private var window: NSWindow?
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Bool, Never>?

    /// The address of the front tab in Chrome, Arc, Safari or Brave — whichever
    /// answers first. Asking a browser goes through Automation, so macOS asks
    /// once per browser. Falls back to a link sitting in the clipboard.
    static func currentURL() -> URL? {
        let scripts = [
            ("com.google.Chrome", "tell application \"Google Chrome\" to get URL of active tab of front window"),
            ("company.thebrowser.Browser", "tell application \"Arc\" to get URL of active tab of front window"),
            ("com.brave.Browser", "tell application \"Brave Browser\" to get URL of active tab of front window"),
            ("com.apple.Safari", "tell application \"Safari\" to get URL of front document"),
        ]
        // The browser the user was in last, not just any running one.
        let order = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidates = scripts.sorted { a, b in
            (a.0 == frontmost ? 0 : 1) < (b.0 == frontmost ? 0 : 1)
        }
        for (bundle, source) in candidates where order.contains(bundle) {
            var error: NSDictionary?
            if let text = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue,
               let url = webURL(text) {
                return url
            }
        }
        return NSPasteboard.general.string(forType: .string).flatMap(webURL)
    }

    private static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    func capture(_ url: URL) async -> URL? {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        webView.navigationDelegate = self
        // Off every screen but still a real window: WebKit stops painting a
        // view that has none, and the snapshot would come out blank.
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: width, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        self.window = window
        self.webView = webView
        defer { teardown() }

        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            loaded = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 30))
        }
        guard ok else { return nil }

        // Walk the page once so lazy images and infinite sections load,
        // then come back to the top before measuring.
        _ = try? await webView.callAsyncJavaScript("""
            const h = () => Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
            for (let y = 0; y < Math.min(h(), \(Int(maxHeight))); y += 800) {
              window.scrollTo(0, y); await new Promise(r => setTimeout(r, 120));
            }
            window.scrollTo(0, 0);
            return 1;
            """, contentWorld: .page)
        try? await Task.sleep(for: .milliseconds(1200))

        let measured = (try? await webView.evaluateJavaScript(
            "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
        )) as? Double ?? 900
        let height = min(max(CGFloat(measured), 900), maxHeight)
        window.setContentSize(NSSize(width: width, height: height))
        webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        try? await Task.sleep(for: .milliseconds(800))

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return ScreenshotVault.save(png, prefix: url.host() ?? localized("Page"))
    }

    private func teardown() {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil
        window = nil
        finish(false)
    }

    private func finish(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}
