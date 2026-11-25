import Cocoa
import WebKit
import ScreenCaptureKit
import EnhanceKit

/// Xbox Remote Play(網頁版)的視窗。畫面由 ScreenCaptureKit 擷取 → 處理鏈 → 疊加視窗顯示;
/// 疊加視窗不攔截滑鼠,所以鍵盤/手把/滑鼠仍然直接進到網頁。
final class XboxSession: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    static let startURL = URL(string: ProcessInfo.processInfo.environment["VEYRA_XBOX_URL"] ?? "https://play.xbox.com/remoteplay")!
    let window: NSWindow
    let webView: WKWebView
    let overlay = OverlayWindow()
    var onClose: (() -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()                       // 保留登入
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"   // 讓網站視為 Safari
        if let url = Bundle.main.url(forResource: "gamepad-shim", withExtension: "js"),
           let js = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        webView.uiDelegate = self; webView.navigationDelegate = self
        window.title = "Xbox Remote Play"
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.contentView = webView
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.setFrameAutosaveName("XboxWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func show() {
        if webView.url == nil { webView.load(URLRequest(url: Self.startURL)) }
        window.center(); window.makeKeyAndOrderFront(nil)
    }

    /// 取得這個視窗的擷取來源(視窗必須已經在螢幕上)。
    func makeSource(maxHeight: Int) async throws -> ScreenSource {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = await MainActor.run { CGWindowID(window.windowNumber) }
        guard let w = content.windows.first(where: { $0.windowID == id }) else {
            throw NSError(domain: "veyra", code: 20, userInfo: [NSLocalizedDescriptionKey: "找不到 Xbox 視窗(是否被最小化?)"])
        }
        return ScreenSource(filter: SCContentFilter(desktopIndependentWindow: w),
                            maxWidth: maxHeight * 16 / 9, maxHeight: maxHeight, showsCursor: false)
    }

    func attachOverlay() { overlay.attach(to: window) }
    func detachOverlay() { overlay.detach() }

    // 手把 / 鍵盤模擬
    func togglePad() { webView.evaluateJavaScript("window.__vpad && (window.__vpad.on = !window.__vpad.on)") }
    func toggleLook() { webView.evaluateJavaScript("window.__vpad && (window.__vpad.look = !window.__vpad.look)") }
    func reload() { webView.reload() }
    func home() { webView.load(URLRequest(url: Self.startURL)) }
    func clearLogin(_ done: @escaping () -> Void) {
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { done() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.title + ' | ' + location.href + ' | textLen=' + (document.body ? document.body.innerText.length : -1)") { r, _ in
            log("web didFinish: \(r ?? "?")")
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { log("web didFail: \(error)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { log("web didFailProvisional: \(error)") }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // 登入流程的 popup 改在同一個 view 載入
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    // 語音聊天麥克風
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.grant) }
}
