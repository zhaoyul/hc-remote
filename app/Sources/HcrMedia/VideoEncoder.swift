import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class VideoEncoder {
  public struct EncodedFrame {
    public let data: Data
    public let keyframe: Bool
    public let timestampMs: UInt32
  }

  public var onEncoded: ((EncodedFrame) -> Void)?
  public var onError: ((String) -> Void)?

  private var session: VTCompressionSession?
  private var baseTime: CMTime?
  private var forceKeyframe = false
  private var frameCounter: UInt32 = 0

  public var isRunning: Bool { session != nil }

  public func start(width: Int, height: Int, fps: Int, bitrate: Int) {
    stop()
    var newSession: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: nil,
      refcon: nil,
      compressionSessionOut: &newSession)
    guard status == noErr, let created = newSession else {
      onError?("VTCompressionSessionCreate 失败: \(status)")
      return
    }
    session = created
    frameCounter = 0
    baseTime = nil

    VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(
      created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(
      created, key: kVTCompressionPropertyKey_ProfileLevel,
      value: kVTProfileLevel_H264_Main_AutoLevel)
    VTSessionSetProperty(
      created, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    VTSessionSetProperty(
      created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
      value: 2.0 as CFNumber)
    VTSessionSetProperty(
      created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
  }

  public func stop() {
    if let session {
      VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(session)
    }
    session = nil
    baseTime = nil
  }

  public func requestKeyframe() {
    forceKeyframe = true
  }

  public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
    guard let session else { return }
    if baseTime == nil {
      baseTime = presentationTime
    }
    let relative = CMTimeSubtract(presentationTime, baseTime!)
    var properties: [String: Any]?
    if forceKeyframe {
      forceKeyframe = false
      properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: kCFBooleanTrue as Any]
    }

    VTCompressionSessionEncodeFrame(
      session,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: relative,
      duration: .invalid,
      frameProperties: properties as CFDictionary?,
      infoFlagsOut: nil
    ) { [weak self] status, _, sampleBuffer in
      guard let self else { return }
      guard status == noErr, let sampleBuffer else {
        self.onError?("编码失败: \(status)")
        return
      }
      self.handle(sampleBuffer: sampleBuffer)
    }
  }

  private func handle(sampleBuffer: CMSampleBuffer) {
    guard
      let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
    else {
      return
    }
    let length = CMBlockBufferGetDataLength(dataBuffer)
    var sampleData = Data(count: length)
    let copyStatus = sampleData.withUnsafeMutableBytes { raw in
      CMBlockBufferCopyDataBytes(
        dataBuffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
    }
    guard copyStatus == noErr else {
      onError?("读取编码数据失败: \(copyStatus)")
      return
    }

    var keyframe = true
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, createIfNecessary: false) as? [[String: Any]],
      let first = attachments.first
    {
      let notSync = (first[kCMSampleAttachmentKey_NotSync as String] as? Bool) ?? false
      keyframe = !notSync
    }

    var parameterSets: (sps: Data, pps: Data)?
    if keyframe, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
      parameterSets = H264Payload.parameterSets(from: formatDescription)
    }

    var timestampMs: UInt32 = 0
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if pts.isValid {
      timestampMs = UInt32(max(0, CMTimeGetSeconds(pts) * 1000))
    }

    let payload = H264Payload.pack(
      parameterSets: parameterSets, sampleData: sampleData)
    frameCounter &+= 1
    onEncoded?(
      EncodedFrame(data: payload, keyframe: keyframe, timestampMs: timestampMs))
  }
}
