// 產生測試影片:移動的圖形 + 細格線 + 文字,用來肉眼檢查放大與補幀。
// 用法: MakeTestVideo out.mp4 [fps] [seconds] [width] [height]
import Foundation
import AVFoundation
import CoreGraphics
import CoreText

let a = CommandLine.arguments
let out = URL(fileURLWithPath: a.count > 1 ? a[1] : "test.mp4")
let fps = a.count > 2 ? Int(a[2])! : 30, secs = a.count > 3 ? Int(a[3])! : 6
let W = a.count > 4 ? Int(a[4])! : 1280, H = a.count > 5 ? Int(a[5])! : 720
try? FileManager.default.removeItem(at: out)
let w = try AVAssetWriter(url: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
for i in 0..<(fps * secs) {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let t = CGFloat(i) / CGFloat(fps)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.12 + 0.1 * sin(t), blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5)); ctx.setLineWidth(1)          // 細格線:看放大品質
    for x in stride(from: 0, to: W, by: 40) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)) }
    for y in stride(from: 0, to: H, by: 40) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)) }
    ctx.strokePath()
    let cx = CGFloat(W) * (0.1 + 0.8 * (0.5 + 0.5 * sin(t * 2.4))), cy = CGFloat(H) * 0.5 + 120 * cos(t * 3)   // 快速移動的球:看補幀
    ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: cx - 50, y: cy - 50, width: 100, height: 100))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Veyra macOS  frame \(i)", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 36, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
    ctx.textPosition = CGPoint(x: 40, y: CGFloat(H) - 80); CTLineDraw(line, ctx)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
}
input.markAsFinished(); let sem = DispatchSemaphore(value: 0); w.finishWriting { sem.signal() }; sem.wait()
print("wrote", out.path)
