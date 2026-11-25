import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox

public let pixelFormat420v: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

@inline(__always) public func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

public func log(_ s: String) { FileHandle.standardError.write(Data(("[Veyra] " + s + "\n").utf8)) }

public struct CapturedFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let pts: Double        // 來源時間(秒)
    public let arrival: UInt64    // 單調時鐘 ns
    public init(buffer: CVPixelBuffer, pts: Double, arrival: UInt64 = nowNs()) {
        self.buffer = buffer; self.pts = pts; self.arrival = arrival
    }
}

public struct OutputFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let delay: Double      // 相對於輸入幀抵達時間,要延後多少秒再顯示
}

public func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat420v,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    return pool
}

public func makePool(attributes: [String: Any]) -> CVPixelBufferPool? {
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    return pool
}

public func tag709(_ pb: CVPixelBuffer) {
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
}

/// 把任意格式/尺寸的輸入轉成 420v(VideoToolbox 各處理器都吃這個格式)。
public final class FormatNormalizer {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    public init() { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) }
    deinit { if let s = session { VTPixelTransferSessionInvalidate(s) } }

    public func normalize(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(src) == pixelFormat420v,
           CVPixelBufferGetIOSurface(src) != nil { return src }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if pool == nil || poolSize != (w, h) { pool = makePool(width: w, height: h); poolSize = (w, h) }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let out, let session,
              VTPixelTransferSessionTransferImage(session, from: src, to: out) == noErr else { return nil }
        return out
    }
}

/// 除錯用:把任意像素緩衝存成 PNG(用 VideoToolbox 轉換,色彩正確)。
public func savePNG(_ pb: CVPixelBuffer, to path: String) {
    var cg: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
    guard let cg, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
        log("savePNG failed"); return
    }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    log("saved \(path) (\(cg.width)x\(cg.height))")
}

extension VTFrameProcessor {
    /// 一般版處理器的 async 版本會回傳需要逐項讀取的串流,這裡統一用 completionHandler 版本。
    func run(_ params: VTFrameProcessorParameters) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            self.process(parameters: params, completionHandler: { _, e in
                if let e { k.resume(throwing: e) } else { k.resume() }
            })
        }
    }
}
