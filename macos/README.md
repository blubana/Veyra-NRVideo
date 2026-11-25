# Veyra for macOS (Apple Silicon port)

A native Swift port of Veyra's core idea — **a real-time enhancement chain in front of any video source** —
built on Apple's own frameworks instead of Direct3D 12 / NVIDIA NGX / AMD HIP. It is a clean Swift
re-implementation, not a line-by-line translation of the Windows C++ code. Licensed GPL-3.0 like the rest of this fork.

```
source ──► denoise ──► frame interpolation ──► super resolution ──► display
 file / screen / camera   Core Image            VideoToolbox          VideoToolbox ML (≤1280 wide)
                                                low-latency FI        or Core Image Lanczos ×2
```

## Sources
| Source | API |
|---|---|
| Local video (audio via AVPlayer) | AVFoundation `AVPlayerItemVideoOutput` |
| Screen / window | ScreenCaptureKit (system content picker, own app excluded) |
| Camera / UVC capture card | AVFoundation `AVCaptureSession` (needs Camera permission) |

## Enhancement
| Feature | Implementation | Measured on M2 |
|---|---|---|
| Super resolution 720p→1080p | `VTLowLatencySuperResolutionScaler` ×1.5 (≤540p: ×2) | ~3 ms |
| Super resolution >1280 wide | Core Image Lanczos ×2 | 1080p→4K ~9 ms |
| 30→60 fps | `VTLowLatencyFrameInterpolation` | 720p ~4 ms, 1080p ~14 ms |
| Denoise | Core Image `CINoiseReduction` | 1080p ~4.5 ms |

Whole chain: 720p30 → 1080p60 ≈ 20 ms per source frame; 1080p30 → 4K60 (+interp) ≈ 30 ms (at the 33 ms budget).

Not usable in real time on M2 (measured): `VTSuperResolutionScaler` (×4 only, 0.1–1.6 s/frame — offline export only),
and `VTTemporalNoiseFilter` reports `isSupported == false` here (may work on newer chips).

## Build
Requires macOS 26+ and Xcode Command Line Tools.
```bash
cd macos
./build.sh            # build/VeyraMac.app
./build.sh install    # also copy to /Applications
swift run -c release MakeTestVideo out.mp4 30 8 1280 720   # test clip with grid + moving ball
```
Permissions (Screen Recording / Camera) are tied to a fixed code-signing requirement, so rebuilding keeps them.

## CLI flags (for testing)
`--open file --stats --no-sr --no-fi --force-fi --nr --dump <prefix> --screen-main --quit-after <sec>`

## Not ported (Windows-only or out of scope for v1)
PS5/Xbox/Moonlight streaming, DirectShow/Magewell/Elgato vendor capture, NVIDIA/AMD NR models, RTX Video HDR,
Dolby Vision, HDMI bitstream, virtual camera, export, node editor, QML UI.
