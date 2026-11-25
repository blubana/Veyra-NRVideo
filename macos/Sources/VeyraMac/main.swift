// Veyra for macOS — 本機影片 / 螢幕與視窗擷取 / 攝影機與採集卡 → 即時畫質增強
import Cocoa
import AVFoundation
import ScreenCaptureKit
import EnhanceKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate, SCContentSharingPickerObserver {
    let engine = Engine()
    var window: NSWindow!
    let view = DisplayView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    var showStats = false
    var lastStats = EngineStats()
    var cameraMenu = NSMenu(title: "攝影機 / 採集卡")
    var sourceName = "-"

    func applicationDidFinishLaunching(_ n: Notification) {
        engine.view = view
        engine.onStats = { [weak self] s in DispatchQueue.main.async { self?.updateHUD(s) } }
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Veyra for macOS"
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.setFrameAutosaveName("VeyraMain")
        window.center(); window.makeKeyAndOrderFront(nil)
        setupMenu()
        NSApp.activate(ignoringOtherApps: true)
        handleArguments()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: 命令列(測試/自動化)
    func handleArguments() {
        var a = Array(CommandLine.arguments.dropFirst())
        func take(_ k: String) -> String? { if let i = a.firstIndex(of: k), i + 1 < a.count { return a[i + 1] }; return nil }
        func has(_ k: String) -> Bool { a.contains(k) }
        if has("--no-sr") { engine.pipeline.options.superResolution = false }
        if has("--no-fi") { engine.pipeline.options.interpolate = false }
        if has("--force-fi") { engine.pipeline.options.forceInterpolate = true }
        if has("--nr") { engine.pipeline.options.denoise = true }
        if has("--stats") { showStats = true; view.hud.isHidden = false }
        engine.dumpPrefix = take("--dump")
        if let f = take("--open") { open(URL(fileURLWithPath: f)) }
        if has("--screen-main") {   // 測試:不經選擇器,直接擷取主螢幕(排除本 App)
            Task {
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { log("no screen-recording permission"); return }
                do {
                    let c = try await SCShareableContent.current
                    guard let d = c.displays.first else { return }
                    let me = c.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                    await MainActor.run { self.start(ScreenSource(filter: SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []))) }
                } catch { log("screen-main: \(error)") }
            }
        }
        if let q = take("--quit-after"), let s = Double(q) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { NSApp.terminate(nil) } }
        a.removeAll()
    }

    func updateHUD(_ s: EngineStats) {
        lastStats = s
        guard showStats else { return }
        let i = engine.pipeline.info
        view.hud.string = "\(i.input)→\(i.output) · 輸入 \(s.inputFPS)fps → 顯示 \(s.outputFPS)fps · 處理 \(String(format: "%.1f", s.processMs))ms · SR:\(i.superRes) · NR:\(i.denoise) · FI:\(i.interpolation)"
        if ProcessInfo.processInfo.environment["VEYRA_DEBUG"] != nil {
            FileHandle.standardError.write(Data(((view.hud.string as? String) ?? "" + "\n").utf8))
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    // MARK: 來源
    func start(_ s: FrameSource) {
        Task {
            do { try await engine.use(s); await MainActor.run { sourceName = s.name; window.title = "Veyra — \(s.name)" } }
            catch { await MainActor.run { let a = NSAlert(); a.messageText = "無法開啟來源"; a.informativeText = error.localizedDescription; a.runModal() } }
        }
    }

    func open(_ url: URL) { start(FileSource(url: url)) }

    @objc func openFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    @objc func pickScreen() {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            let a = NSAlert(); a.messageText = "需要「螢幕錄製」權限"
            a.informativeText = "請到 系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製 勾選 VeyraMac,然後重新開啟。"; a.runModal(); return
        }
        let picker = SCContentSharingPicker.shared
        var cfg = SCContentSharingPickerConfiguration()
        cfg.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? ""]   // 不擷取自己,避免遞迴
        picker.defaultConfiguration = cfg
        picker.add(self); picker.isActive = true; picker.present()
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        picker.remove(self); picker.isActive = false
        start(ScreenSource(filter: filter))
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) { picker.remove(self); picker.isActive = false }
    func contentSharingPickerStartDidFailWithError(_ error: Error) { log("picker error: \(error)") }

    @objc func pickCamera(_ item: NSMenuItem) {
        guard let d = item.representedObject as? AVCaptureDevice else { return }
        start(CameraSource(device: d))
    }
    @objc func stopSource() { Task { await engine.stop(); await MainActor.run { window.title = "Veyra for macOS" } } }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === cameraMenu else { return }
        menu.removeAllItems()
        let devs = CameraSource.devices()
        if devs.isEmpty { menu.addItem(withTitle: "(沒有偵測到裝置)", action: nil, keyEquivalent: "") }
        for d in devs {
            let i = NSMenuItem(title: d.localizedName, action: #selector(pickCamera(_:)), keyEquivalent: "")
            i.representedObject = d; i.target = self; menu.addItem(i)
        }
    }

    // MARK: 增強設定
    @objc func toggleSR() { engine.pipeline.options.superResolution.toggle() }
    @objc func toggleFI() { engine.pipeline.options.interpolate.toggle() }
    @objc func toggleNR() { engine.pipeline.options.denoise.toggle() }
    @objc func setNRStrength(_ i: NSMenuItem) { engine.pipeline.options.denoiseStrength = Float(i.tag) / 100 }
    @objc func toggleStats() { showStats.toggle(); view.hud.isHidden = !showStats }

    // MARK: 播放
    @objc func playPause() {
        guard let p = (engine.source as? FileSource)?.player else { return }
        p.timeControlStatus == .paused ? p.play() : p.pause()
    }
    @objc func seek(_ i: NSMenuItem) {
        guard let p = (engine.source as? FileSource)?.player else { return }
        p.seek(to: CMTimeAdd(p.currentTime(), CMTime(seconds: Double(i.tag), preferredTimescale: 600)))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let o = engine.pipeline.options
        switch item.action {
        case #selector(toggleSR): item.state = o.superResolution ? .on : .off
        case #selector(toggleFI): item.state = o.interpolate ? .on : .off
        case #selector(toggleNR): item.state = o.denoise ? .on : .off
        case #selector(toggleStats): item.state = showStats ? .on : .off
        case #selector(setNRStrength(_:)): item.state = abs(o.denoiseStrength - Float(item.tag) / 100) < 0.01 ? .on : .off
        case #selector(playPause), #selector(seek(_:)): return engine.source is FileSource
        default: break
        }
        return true
    }

    // MARK: 選單
    func setupMenu() {
        let main = NSMenu(); NSApp.mainMenu = main
        func add(_ title: String, _ items: [NSMenuItem]) {
            let it = NSMenuItem(); main.addItem(it)
            let m = NSMenu(title: title); it.submenu = m; items.forEach { m.addItem($0) }
        }
        func mi(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.tag = tag
            if a != nil, a != #selector(NSApplication.terminate(_:)), a != #selector(NSApplication.hide(_:)) { i.target = self }
            return i
        }
        add("App", [mi("隱藏 Veyra", #selector(NSApplication.hide(_:)), "h"), .separator(), mi("結束", #selector(NSApplication.terminate(_:)), "q")])
        let cam = NSMenuItem(title: "攝影機 / 採集卡", action: nil, keyEquivalent: ""); cam.submenu = cameraMenu; cameraMenu.delegate = self
        add("來源", [mi("開啟影片…", #selector(openFile), "o"), mi("擷取螢幕 / 視窗…", #selector(pickScreen), "s", [.command, .shift]), cam, .separator(), mi("停止", #selector(stopSource), ".")])
        let strength = NSMenuItem(title: "降噪強度", action: nil, keyEquivalent: "")
        let sm = NSMenu(); strength.submenu = sm
        for (t, v) in [("弱", 25), ("中", 50), ("強", 80)] { sm.addItem(mi(t, #selector(setNRStrength(_:)), tag: v)) }
        add("增強", [mi("超解析度", #selector(toggleSR), "1"), mi("補幀 (×2)", #selector(toggleFI), "2"), mi("降噪", #selector(toggleNR), "3"), strength, .separator(), mi("顯示統計", #selector(toggleStats), "i")])
        add("播放", [mi("播放 / 暫停", #selector(playPause), "p"), mi("倒退 5 秒", #selector(seek(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [], tag: -5), mi("前進 5 秒", #selector(seek(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [], tag: 5)])
        add("視窗", [mi("全螢幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]), mi("關閉", #selector(NSWindow.performClose(_:)), "w")])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
