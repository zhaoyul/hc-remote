import CoreGraphics
import CoreMedia
import Foundation
import HcrCore

public final class StreamController {
  public var onLog: ((String) -> Void)?
  public var onSample: ((CMSampleBuffer) -> Void)?
  public var onStateChange: (() -> Void)?
  public var onStats: ((String) -> Void)?
  public var allowRemoteControl = true

  public private(set) var isStreaming = false
  public private(set) var isViewing = false

  private let session: SessionController
  private let capture = ScreenCapture()
  private let encoder = VideoEncoder()
  private let factory = DisplaySampleFactory()
  private let lock = NSLock()

  private var frameCounter: UInt32 = 0
  private var sentFrames = 0
  private var sentBytes = 0
  private var receivedFrames = 0
  private var receivedBytes = 0
  private var lastKeyframeRequest: TimeInterval = 0
  private var lastMoveSent: TimeInterval = 0
  private var accessibilityPrompted = false
  private var statsTimer: Timer?

  public init(session: SessionController) {
    self.session = session
    encoder.onEncoded = { [weak self] frame in
      self?.send(frame)
    }
    encoder.onError = { [weak self] message in
      self?.onLog?("编码: \(message)")
    }
    capture.onFrame = { [weak self] pixelBuffer, presentationTime in
      self?.encoder.encode(pixelBuffer, presentationTime: presentationTime)
    }
    capture.onError = { [weak self] message in
      self?.onLog?("捕获: \(message)")
    }
  }

  deinit {
    statsTimer?.invalidate()
  }

  public func startStreaming(width: Int, height: Int, fps: Int, bitrate: Int = 4_000_000) {
    guard !isStreaming else { return }
    guard Permissions.screenCaptureGranted() else {
      Permissions.requestScreenCapture()
      onLog?("需要屏幕录制权限: 请在系统设置 > 隐私与安全性 > 屏幕录制 中允许, 然后重试")
      return
    }
    isStreaming = true
    encoder.start(width: width, height: height, fps: fps, bitrate: bitrate)
    Task { [weak self] in
      await self?.capture.start(width: width, height: height, fps: fps)
    }
    sendControl(.streamStart(width: width, height: height, fps: fps))
    onLog?("开始投屏 \(width)x\(height)@\(fps)")
    startStatsTimer()
    onStateChange?()
  }

  public func stopStreaming() {
    guard isStreaming else { return }
    isStreaming = false
    sendControl(.streamStop)
    Task { [weak self] in
      await self?.capture.stop()
    }
    encoder.stop()
    onLog?("停止投屏")
    stopStatsTimerIfIdle()
    onStateChange?()
  }

  public func handleControl(_ message: MediaProtocol) {
    switch message {
    case .streamStart(let width, let height, let fps):
      isViewing = true
      factory.reset()
      onLog?("对端开始投屏 \(width)x\(height)@\(fps)")
      sendControl(.keyframeRequest)
      startStatsTimer()
      onStateChange?()
    case .streamStop:
      isViewing = false
      factory.reset()
      onLog?("对端停止投屏")
      stopStatsTimerIfIdle()
      onStateChange?()
    case .keyframeRequest:
      encoder.requestKeyframe()
    default:
      guard allowRemoteControl, isStreaming else { return }
      if !Permissions.accessibilityGranted(prompt: false) {
        if !accessibilityPrompted {
          accessibilityPrompted = true
          _ = Permissions.accessibilityGranted(prompt: true)
          onLog?("需要辅助功能权限: 请在系统设置 > 隐私与安全性 > 辅助功能 中允许 hc-remote")
        }
        return
      }
      InputInjector.inject(
        message, displayBounds: CGDisplayBounds(CGMainDisplayID()))
    }
  }

  public func handleFrame(_ frame: MediaFrame) {
    lock.lock()
    receivedFrames += 1
    receivedBytes += frame.data.count
    lock.unlock()

    if let sample = factory.makeSample(
      from: frame.data, timestampMs: frame.timestampMs)
    {
      onSample?(sample)
    } else {
      requestKeyframeIfNeeded()
    }
  }

  public func sendInput(_ message: MediaProtocol) {
    if case .mouseMove = message {
      let now = ProcessInfo.processInfo.systemUptime
      guard now - lastMoveSent >= 1.0 / 60.0 else { return }
      lastMoveSent = now
    }
    sendControl(message)
  }

  private func sendControl(_ message: MediaProtocol) {
    session.sendText(channel: "control", text: message.encode())
  }

  private func send(_ frame: VideoEncoder.EncodedFrame) {
    let media = MediaFrame(
      frameId: frameCounter, timestampMs: frame.timestampMs,
      keyframe: frame.keyframe, data: frame.data)
    frameCounter &+= 1
    session.sendFrame(media)

    lock.lock()
    sentFrames += 1
    sentBytes += frame.data.count
    lock.unlock()
  }

  private func requestKeyframeIfNeeded() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastKeyframeRequest >= 1.0 else { return }
    lastKeyframeRequest = now
    sendControl(.keyframeRequest)
  }

  private func startStatsTimer() {
    guard statsTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.reportStats()
    }
    RunLoop.main.add(timer, forMode: .common)
    statsTimer = timer
  }

  private func stopStatsTimerIfIdle() {
    guard !isStreaming, !isViewing else { return }
    statsTimer?.invalidate()
    statsTimer = nil
  }

  private func reportStats() {
    lock.lock()
    let sent = sentFrames
    let sentKb = sentBytes / 1024
    let received = receivedFrames
    let receivedKb = receivedBytes / 1024
    sentFrames = 0
    sentBytes = 0
    receivedFrames = 0
    receivedBytes = 0
    lock.unlock()
    onStats?("发送 \(sent) fps/\(sentKb) KB · 接收 \(received) fps/\(receivedKb) KB")
  }
}
