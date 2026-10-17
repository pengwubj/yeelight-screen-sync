import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let onColor: @Sendable (RGB) -> Void
    let onError: @Sendable (String) -> Void
    init(onColor: @escaping @Sendable (RGB) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.onColor = onColor; self.onError = onError
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let image = sampleBuffer.imageBuffer else { return }
        guard CVPixelBufferLockBaseAddress(image,.readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(image,.readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return }
        let color = ColorAnalysis.dominant(bgra:base.assumingMemoryBound(to:UInt8.self),width:CVPixelBufferGetWidth(image),height:CVPixelBufferGetHeight(image),stride:CVPixelBufferGetBytesPerRow(image))
        onColor(color)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error.localizedDescription) }
}

@MainActor protocol ScreenSampling: AnyObject {
    func start(display: SCDisplay, fps: Int, onColor: @escaping @Sendable (RGB) -> Void, onError: @escaping @Sendable (String) -> Void) async throws
    func stop() async
}

@MainActor final class ScreenSampler: ScreenSampling {
    private var stream: SCStream?
    private var receiver: FrameReceiver?

    static func displays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        return content.displays.sorted { ($0.displayID == CGMainDisplayID() ? 0 : $0.displayID) < ($1.displayID == CGMainDisplayID() ? 0 : $1.displayID) }
    }

    func start(display: SCDisplay, fps: Int, onColor: @escaping @Sendable (RGB) -> Void, onError: @escaping @Sendable (String) -> Void) async throws {
        guard (1...20).contains(fps), display.width > 0, display.height > 0 else {
            throw LightFailure("屏幕参数或更新频率无效")
        }
        let config = SCStreamConfiguration()
        config.width = 128
        config.height = max(16,Int(Double(display.height)/Double(display.width)*128))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value:1,timescale:CMTimeScale(fps))
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 3
        let receiver = FrameReceiver(onColor:onColor,onError:onError)
        // Omit this app so its colour preview cannot feed back into the sampled colour.
        let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display:display,excludingApplications:ownApps,exceptingWindows:[])
        let stream = SCStream(filter:filter,configuration:config,delegate:receiver)
        try stream.addStreamOutput(receiver,type:.screen,sampleHandlerQueue:DispatchQueue(label:"yeelight.capture",qos:.userInitiated))
        self.receiver = receiver; self.stream = stream
        do { try await stream.startCapture() }
        catch { self.stream = nil; self.receiver = nil; throw error }
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil; receiver = nil
    }
}
