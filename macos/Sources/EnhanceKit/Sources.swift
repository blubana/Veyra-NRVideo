import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import QuartzCore

public protocol FrameSource: AnyObject {
    var name: String { get }
    var onFrame: ((CapturedFrame) -> Void)? { get set }
    func start() async throws
    func stop() async
}

// MARK: - 本機影片(AVPlayer + AVPlayerItemVideoOutput,音訊由 AVPlayer 播放)
public final class FileSource: FrameSource {
    public let name: String
    public let player: AVPlayer
    public var onFrame: ((CapturedFrame) -> Void)?
    private let output: AVPlayerItemVideoOutput
    private var timer: DispatchSourceTimer?
    private var loopObs: NSObjectProtocol?

    public init(url: URL) {
        name = url.lastPathComponent
        let item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat420v,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        loopObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero); self?.player.play()
        }
    }

    public func start() async throws {
        player.play()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "veyra.file", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let ht = self.output.itemTime(forHostTime: CACurrentMediaTime())
            guard self.output.hasNewPixelBuffer(forItemTime: ht) else { return }
            var display = CMTime.zero
            if let pb = self.output.copyPixelBuffer(forItemTime: ht, itemTimeForDisplay: &display) {
                self.onFrame?(CapturedFrame(buffer: pb, pts: display.seconds))
            }
        }
        t.resume(); timer = t
    }

    public func stop() async {
        timer?.cancel(); timer = nil
        player.pause()
        if let o = loopObs { NotificationCenter.default.removeObserver(o); loopObs = nil }
    }
}

// MARK: - 螢幕 / 視窗(ScreenCaptureKit)
public final class ScreenSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    public let name = "螢幕/視窗擷取"
    public var onFrame: ((CapturedFrame) -> Void)?
    private let filter: SCContentFilter
    private let maxWidth: Int, maxHeight: Int
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "veyra.screen", qos: .userInteractive)

    /// 擷取尺寸會縮到 maxWidth × maxHeight 以內(預設 1280×720,讓低延遲 ML 超解析度可用)。
    public init(filter: SCContentFilter, maxWidth: Int = 1280, maxHeight: Int = 720) {
        self.filter = filter; self.maxWidth = maxWidth; self.maxHeight = maxHeight
    }

    public func start() async throws {
        let r = filter.contentRect, k = CGFloat(filter.pointPixelScale)
        let pxW = max(2, r.width * k), pxH = max(2, r.height * k)
        let f = min(1, CGFloat(maxWidth) / pxW, CGFloat(maxHeight) / pxH)
        let cfg = SCStreamConfiguration()
        cfg.width = max(2, Int(pxW * f) & ~1); cfg.height = max(2, Int(pxH * f) & ~1)
        cfg.pixelFormat = pixelFormat420v
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 5
        cfg.showsCursor = true
        cfg.scalesToFit = true
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        log("screen capture \(cfg.width)x\(cfg.height)")
    }

    public func stop() async { try? await stream?.stopCapture(); stream = nil }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let st = arr.first?[.status] as? Int, st == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        onFrame?(CapturedFrame(buffer: pb, pts: CMSampleBufferGetPresentationTimeStamp(sb).seconds))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) { log("screen stream stopped: \(error)") }
}

// MARK: - 攝影機 / 採集卡(AVFoundation,UVC 裝置)
public final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    public let name: String
    public var onFrame: ((CapturedFrame) -> Void)?
    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "veyra.camera", qos: .userInteractive)

    public static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    public init(device: AVCaptureDevice) { self.device = device; name = device.localizedName }

    public func start() async throws {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw NSError(domain: "veyra", code: 10, userInfo: [NSLocalizedDescriptionKey: "沒有攝影機權限(系統設定 → 隱私權與安全性 → 相機)"])
        }
        session.beginConfiguration()
        session.addInput(try AVCaptureDeviceInput(device: device))
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        if out.availableVideoPixelFormatTypes.contains(pixelFormat420v) {
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat420v]
        }
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw NSError(domain: "veyra", code: 11, userInfo: [NSLocalizedDescriptionKey: "無法加入影像輸出"]) }
        session.addOutput(out)
        // 優先 720p,讓低延遲 ML 超解析度可用;不支援就維持裝置預設。
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        session.commitConfiguration()
        session.startRunning()
        log("camera \(name)")
    }

    public func stop() async { session.stopRunning() }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        onFrame?(CapturedFrame(buffer: pb, pts: CMSampleBufferGetPresentationTimeStamp(sb).seconds))
    }
}
