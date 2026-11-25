import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import VideoToolbox

public struct EnhanceOptions: Equatable, Sendable {
    public var denoise = false
    public var denoiseStrength: Float = 0.5
    public var superResolution = true
    public var interpolate = true
    public var forceInterpolate = false     // 測試用:對 60fps 來源也補幀
    public init() {}
}

public struct PipelineInfo: Sendable {
    public var input = "-", output = "-", denoise = "off", superRes = "off", interpolation = "off"
}

struct PipelineError: LocalizedError { let message: String; var errorDescription: String? { message } }

/// 共用的 Core Image 環境(Metal)。
let sharedCI = CIContext(options: [.cacheIntermediates: false])
let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!

// MARK: - 降噪(Core Image)
// 註:VTTemporalNoiseFilter 在 M2 上 isSupported == false,所以這一版只用 Core Image。
final class Denoiser {
    private let pool: CVPixelBufferPool
    init?(width: Int, height: Int) {
        guard let p = makePool(width: width, height: height) else { return nil }
        pool = p
    }
    func run(_ src: CVPixelBuffer, strength: Float) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { throw PipelineError(message: "denoise pool") }
        let f = CIFilter.noiseReduction()
        f.inputImage = CIImage(cvPixelBuffer: src)
        f.noiseLevel = 0.005 + 0.045 * max(0, min(1, strength))
        f.sharpness = 0.4
        guard let img = f.outputImage else { throw PipelineError(message: "denoise filter") }
        sharedCI.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(out), height: CVPixelBufferGetHeight(out)), colorSpace: rec709)
        tag709(out)
        return out
    }
}

// MARK: - 補幀(VideoToolbox 低延遲)
final class Interpolator {
    private let proc = VTFrameProcessor()
    private let cfg: VTLowLatencyFrameInterpolationConfiguration
    private let pool: CVPixelBufferPool

    init?(width: Int, height: Int) {
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let c = VTLowLatencyFrameInterpolationConfiguration(frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1),
              let p = makePool(attributes: c.destinationPixelBufferAttributes as [String: Any]) else { return nil }
        do { try proc.startSession(configuration: c) } catch { log("FI session: \(error)"); return nil }
        cfg = c; pool = p
    }
    deinit { proc.endSession() }

    func run(prev: VTFrameProcessorFrame, cur: VTFrameProcessorFrame, at t: CMTime) async throws -> VTFrameProcessorFrame {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out, let df = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: t) else { throw PipelineError(message: "FI pool") }
        guard let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: cur, previousFrame: prev, interpolationPhase: [0.5], destinationFrames: [df]) else {
            throw PipelineError(message: "FI params")
        }
        try await proc.run(params)
        tag709(out)
        return df
    }
}

// MARK: - 超解析度
// ≤1280 寬:VideoToolbox 低延遲 ML 超解析度(720p→1080p 為 1.5×,≤540p 可 2×)
// 更大的輸入:Core Image Lanczos 2×(VT 一般版 ×4 在 M2 上每幀 0.1–1.6 秒,不適合即時)
final class Upscaler {
    enum Backend { case machineLearning(VTFrameProcessor, VTLowLatencySuperResolutionScalerConfiguration), lanczos(scale: CGFloat) }
    let backend: Backend
    let pool: CVPixelBufferPool
    let outWidth: Int, outHeight: Int
    let label: String

    init?(width: Int, height: Int) {
        if width <= 1280, VTLowLatencySuperResolutionScalerConfiguration.isSupported {
            let factors = VTLowLatencySuperResolutionScalerConfiguration
                .supportedScaleFactors(frameWidth: width, frameHeight: height).map { Float(truncating: $0 as NSNumber) }
            if let s = factors.max() {
                let c = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: s)
                let p = VTFrameProcessor()
                if (try? p.startSession(configuration: c)) != nil,
                   let pool = makePool(attributes: c.destinationPixelBufferAttributes as [String: Any]) {
                    backend = .machineLearning(p, c); self.pool = pool
                    outWidth = Int((Float(width) * s).rounded()); outHeight = Int((Float(height) * s).rounded())
                    label = "VideoToolbox ML ×\(s)"
                    return
                }
            }
        }
        guard width <= 1920 else { return nil }   // 4K 以上不再放大
        let ow = width * 2, oh = height * 2
        guard let pool = makePool(width: ow, height: oh) else { return nil }
        backend = .lanczos(scale: 2); self.pool = pool
        outWidth = ow; outHeight = oh; label = "Lanczos ×2"
    }
    deinit { if case .machineLearning(let p, _) = backend { p.endSession() } }

    func run(_ src: VTFrameProcessorFrame) async throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { throw PipelineError(message: "SR pool") }
        switch backend {
        case .machineLearning(let proc, _):
            guard let df = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: src.presentationTimeStamp) else { throw PipelineError(message: "SR frame") }
            try await proc.run(VTLowLatencySuperResolutionScalerParameters(sourceFrame: src, destinationFrame: df))
        case .lanczos(let scale):
            let lz = CIFilter.lanczosScaleTransform()
            lz.inputImage = CIImage(cvPixelBuffer: src.buffer); lz.scale = Float(scale); lz.aspectRatio = 1
            guard let img = lz.outputImage else { throw PipelineError(message: "SR filter") }
            sharedCI.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: outWidth, height: outHeight), colorSpace: rec709)
        }
        tag709(out)
        return out
    }
}

// MARK: - 管線:降噪 → 補幀(原解析度)→ 超解析度
public final class EnhancePipeline: @unchecked Sendable {
    public var options = EnhanceOptions()
    public private(set) var info = PipelineInfo()

    private let normalizer = FormatNormalizer()
    private var size = (0, 0)
    private var denoiser: Denoiser?
    private var interpolator: Interpolator?
    private var upscaler: Upscaler?
    private var builtFor = EnhanceOptions()
    private var prev: VTFrameProcessorFrame?
    private var lastPTS = 0.0

    public init() {}

    public func reset() { prev = nil; lastPTS = 0 }

    private func rebuild(width: Int, height: Int) {
        size = (width, height)
        denoiser = Denoiser(width: width, height: height)
        interpolator = Interpolator(width: width, height: height)
        upscaler = Upscaler(width: width, height: height)
        prev = nil
        info.input = "\(width)×\(height)"
        info.interpolation = interpolator == nil ? "不支援" : "VideoToolbox 低延遲"
        info.superRes = upscaler?.label ?? "off"
        info.output = upscaler.map { "\($0.outWidth)×\($0.outHeight)" } ?? "\(width)×\(height)"
        log("pipeline \(info)")
    }

    public func process(_ f: CapturedFrame) async throws -> [OutputFrame] {
        guard let src = normalizer.normalize(f.buffer) else { throw PipelineError(message: "format") }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if (w, h) != size { rebuild(width: w, height: h) }
        let o = options

        var cur = src
        if o.denoise, let d = denoiser { cur = try d.run(src, strength: o.denoiseStrength); info.denoise = "Core Image NR" } else { info.denoise = "off" }
        guard let curF = VTFrameProcessorFrame(buffer: cur, presentationTimeStamp: CMTime(seconds: f.pts, preferredTimescale: 600)) else { throw PipelineError(message: "frame") }

        let dt = f.pts - lastPTS
        let minDT = o.forceInterpolate ? 0.008 : 0.022
        var outs: [OutputFrame] = []
        if o.interpolate, let fi = interpolator, let p = prev, dt > minDT, dt < 0.12 {
            let mid = try await fi.run(prev: p, cur: curF, at: CMTime(seconds: f.pts - dt / 2, preferredTimescale: 600))
            outs.append(OutputFrame(buffer: try await enhance(mid, o), delay: 0))
            outs.append(OutputFrame(buffer: try await enhance(curF, o), delay: min(dt / 2, 0.05)))
        } else {
            outs.append(OutputFrame(buffer: try await enhance(curF, o), delay: 0))
        }
        info.output = (o.superResolution ? upscaler.map { "\($0.outWidth)×\($0.outHeight)" } : nil) ?? "\(w)×\(h)"
        prev = curF; lastPTS = f.pts
        return outs
    }

    private func enhance(_ f: VTFrameProcessorFrame, _ o: EnhanceOptions) async throws -> CVPixelBuffer {
        if o.superResolution, let up = upscaler { return try await up.run(f) }
        return f.buffer
    }
}
