import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public final class ScreenCapture: NSObject, SCStreamOutput {
  public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
  public var onError: ((String) -> Void)?

  private var stream: SCStream?
  private let outputQueue = DispatchQueue(label: "hcr-capture")

  public var isRunning: Bool { stream != nil }

  public func start(width: Int, height: Int, fps: Int) async {
    do {
      let content = try await SCShareableContent.current
      guard let display = content.displays.first else {
        onError?("没有可用的显示器")
        return
      }
      let ownWindows = content.windows.filter { window in
        window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
      }
      let configuration = SCStreamConfiguration()
      configuration.width = width
      configuration.height = height
      configuration.minimumFrameInterval = CMTime(
        value: 1, timescale: CMTimeScale(max(1, fps)))
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.queueDepth = 5
      configuration.showsCursor = true

      let filter = SCContentFilter(
        display: display, excludingWindows: ownWindows)
      let newStream = SCStream(
        filter: filter, configuration: configuration, delegate: nil)
      try newStream.addStreamOutput(
        self, type: .screen, sampleHandlerQueue: outputQueue)
      try await newStream.startCapture()
      stream = newStream
    } catch {
      onError?("屏幕捕获启动失败: \(error.localizedDescription)")
    }
  }

  public func stop() async {
    guard let current = stream else { return }
    stream = nil
    do {
      try await current.stopCapture()
    } catch {
      // Already stopped; nothing to do.
    }
  }

  public func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen,
      CMSampleBufferDataIsReady(sampleBuffer),
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else {
      return
    }
    onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
  }
}
