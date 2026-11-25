import Foundation
import AppKit
import AVFoundation
import CoreMedia

/// 顯示處理後影像的 View(AVSampleBufferDisplayLayer),含統計 HUD。
public final class DisplayView: NSView {
    public let display = AVSampleBufferDisplayLayer()
    public let hud = CATextLayer()

    public override init(frame: NSRect) { super.init(frame: frame); setup() }
    public required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        display.frame = bounds
        display.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(display)
        hud.fontSize = 12; hud.foregroundColor = NSColor.green.cgColor
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hud.frame = CGRect(x: 8, y: 8, width: 520, height: 20); hud.contentsScale = 2; hud.isHidden = true
        layer?.addSublayer(hud)
    }

    public func present(_ pb: CVPixelBuffer) {
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
        guard let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb, let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0 else { return }
        let d = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        if display.status == .failed { display.flush() }
        display.enqueue(sb)
    }

    public func clear() { display.flushAndRemoveImage() }
}

public struct EngineStats: Sendable {
    public var inputFPS = 0, outputFPS = 0, interpolatedPerSec = 0
    public var processMs = 0.0
    public init(inputFPS: Int = 0, outputFPS: Int = 0, interpolatedPerSec: Int = 0, processMs: Double = 0) {
        self.inputFPS = inputFPS; self.outputFPS = outputFPS; self.interpolatedPerSec = interpolatedPerSec; self.processMs = processMs
    }
}

/// 來源 → 管線 → 顯示。只保留最新一幀,處理來不及就丟舊幀,避免延遲累積。
public final class Engine: @unchecked Sendable {
    public let pipeline = EnhancePipeline()
    public weak var view: DisplayView?
    public private(set) var source: FrameSource?
    public var onStats: ((EngineStats) -> Void)?
    public var dumpPrefix: String?          // 測試:存下輸入/輸出畫面

    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    private var worker: Task<Void, Never>?
    private var timer: Timer?
    private let lock = NSLock()
    private var inCount = 0, outCount = 0, interpCount = 0, msSum = 0.0, msN = 0
    private var total = 0, dumped = false

    public init() {}

    public func use(_ newSource: FrameSource) async throws {
        await stop()
        source = newSource
        pipeline.reset()
        var cont: AsyncStream<CapturedFrame>.Continuation!
        let frames = AsyncStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont
        newSource.onFrame = { [weak self] f in
            guard let self else { return }
            self.lock.withLock { self.inCount += 1; self.total += 1 }
            self.continuation?.yield(f)
        }
        worker = Task { [weak self] in await self?.run(frames) }
        await MainActor.run {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        }
        try await newSource.start()
    }

    public func stop() async {
        await source?.stop(); source = nil
        continuation?.finish(); continuation = nil
        worker?.cancel(); worker = nil
        await MainActor.run { timer?.invalidate(); timer = nil; view?.clear() }
    }

    private func run(_ frames: AsyncStream<CapturedFrame>) async {
        for await f in frames {
            if Task.isCancelled { break }
            let t0 = nowNs()
            do {
                let outs = try await pipeline.process(f)
                for (i, o) in outs.enumerated() {
                    let wait = max(0, Double(f.arrival &+ UInt64(o.delay * 1e9)) - Double(nowNs())) / 1e9
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.view?.present(o.buffer) }
                    lock.withLock { outCount += 1; if i == 0 && outs.count > 1 { interpCount += 1 } }
                }
                if let p = dumpPrefix, !dumped, total > 60 {
                    dumped = true
                    savePNG(f.buffer, to: p + "-input.png"); savePNG(outs.last!.buffer, to: p + "-output.png")
                }
            } catch {
                log("process error: \(error)")
                let raw = f.buffer; DispatchQueue.main.async { [weak self] in self?.view?.present(raw) }
            }
            let ms = Double(nowNs() - t0) / 1e6; lock.withLock { msSum += ms; msN += 1 }
        }
    }

    private func tick() {
        let s: EngineStats = lock.withLock {
            let s = EngineStats(inputFPS: inCount, outputFPS: outCount, interpolatedPerSec: interpCount, processMs: msN > 0 ? msSum / Double(msN) : 0)
            inCount = 0; outCount = 0; interpCount = 0; msSum = 0; msN = 0
            return s
        }
        onStats?(s)
    }
}
