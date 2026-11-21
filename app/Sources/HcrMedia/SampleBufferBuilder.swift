import CoreMedia
import Foundation

public final class DisplaySampleFactory {
  private var formatDescription: CMFormatDescription?

  public init() {}

  public func reset() {
    formatDescription = nil
  }

  public func makeSample(from payload: Data, timestampMs: UInt32) -> CMSampleBuffer? {
    guard let unpacked = H264Payload.unpack(payload) else { return nil }
    if let sps = unpacked.sps, let pps = unpacked.pps {
      formatDescription = H264Payload.formatDescription(sps: sps, pps: pps)
    }
    guard let formatDescription else { return nil }
    return Self.makeSample(
      sampleData: unpacked.sample, formatDescription: formatDescription,
      timestampMs: timestampMs)
  }

  public static func makeSample(
    sampleData: Data, formatDescription: CMFormatDescription, timestampMs: UInt32
  ) -> CMSampleBuffer? {
    var blockBuffer: CMBlockBuffer?
    let createStatus = sampleData.withUnsafeBytes { raw in
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: raw.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: raw.count,
        flags: 0,
        blockBufferOut: &blockBuffer)
    }
    guard createStatus == noErr, let buffer = blockBuffer else { return nil }

    let copyStatus = sampleData.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(
        with: raw.baseAddress!, blockBuffer: buffer, offsetIntoDestination: 0,
        dataLength: raw.count)
    }
    guard copyStatus == noErr else { return nil }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sampleSize = sampleData.count
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: buffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer)
    guard status == noErr else { return nil }
    return sampleBuffer
  }
}
