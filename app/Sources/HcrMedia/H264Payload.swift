import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum H264Payload {
  // Wire container inside a media frame:
  //   u8  hasParams
  //   if hasParams: u16 spsSize, sps, u16 ppsSize, pps
  //   rest: AVCC (length-prefixed NAL units) sample data
  public static func pack(
    parameterSets: (sps: Data, pps: Data)?,
    sampleData: Data
  ) -> Data {
    var data = Data()
    if let sets = parameterSets {
      data.append(1)
      var spsSize = UInt16(sets.sps.count).littleEndian
      var ppsSize = UInt16(sets.pps.count).littleEndian
      withUnsafeBytes(of: &spsSize) { data.append(contentsOf: $0) }
      data.append(sets.sps)
      withUnsafeBytes(of: &ppsSize) { data.append(contentsOf: $0) }
      data.append(sets.pps)
    } else {
      data.append(0)
    }
    data.append(sampleData)
    return data
  }

  public static func unpack(_ data: Data) -> (
    sps: Data?, pps: Data?, sample: Data
  )? {
    guard data.count > 1 else { return nil }
    var offset = 1
    var sps: Data?
    var pps: Data?
    if data[0] == 1 {
      guard let spsSize = readU16(data, at: &offset) else { return nil }
      guard offset + Int(spsSize) <= data.count else { return nil }
      sps = data.subdata(in: offset..<offset + Int(spsSize))
      offset += Int(spsSize)
      guard let ppsSize = readU16(data, at: &offset) else { return nil }
      guard offset + Int(ppsSize) <= data.count else { return nil }
      pps = data.subdata(in: offset..<offset + Int(ppsSize))
      offset += Int(ppsSize)
    }
    return (sps, pps, data.subdata(in: offset..<data.count))
  }

  public static func formatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
    var formatDescription: CMFormatDescription?
    let status = sps.withUnsafeBytes { spsRaw in
      pps.withUnsafeBytes { ppsRaw in
        var pointers = [
          spsRaw.bindMemory(to: UInt8.self).baseAddress!,
          ppsRaw.bindMemory(to: UInt8.self).baseAddress!,
        ]
        var sizes = [sps.count, pps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault,
          parameterSetCount: 2,
          parameterSetPointers: &pointers,
          parameterSetSizes: &sizes,
          nalUnitHeaderLength: 4,
          formatDescriptionOut: &formatDescription)
      }
    }
    guard status == noErr else { return nil }
    return formatDescription
  }

  public static func parameterSets(from formatDescription: CMFormatDescription) -> (
    sps: Data, pps: Data
  )? {
    var spsPointer: UnsafePointer<UInt8>?
    var spsSize = 0
    var ppsPointer: UnsafePointer<UInt8>?
    var ppsSize = 0
    var count = 0
    var headerLength: Int32 = 0
    guard
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDescription,
        parameterSetIndex: 0,
        parameterSetPointerOut: &spsPointer,
        parameterSetSizeOut: &spsSize,
        parameterSetCountOut: &count,
        nalUnitHeaderLengthOut: &headerLength) == noErr,
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDescription,
        parameterSetIndex: 1,
        parameterSetPointerOut: &ppsPointer,
        parameterSetSizeOut: &ppsSize,
        parameterSetCountOut: &count,
        nalUnitHeaderLengthOut: &headerLength) == noErr,
      let spsAddress = spsPointer, let ppsAddress = ppsPointer
    else {
      return nil
    }
    return (
      Data(bytes: spsAddress, count: spsSize),
      Data(bytes: ppsAddress, count: ppsSize)
    )
  }

  private static func readU16(_ data: Data, at offset: inout Int) -> UInt16? {
    guard offset + 2 <= data.count else { return nil }
    let value = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    offset += 2
    return value
  }
}
