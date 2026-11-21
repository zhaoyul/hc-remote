import Foundation
import HcrCore

struct SmokeOptions {
  var server = "ws://127.0.0.1:8080"
  var room = "demo"
  var peer = "smoke"
  var token = ""
  var stun = ""
  var message = "hello"
  var binaryDemo = false
  var frameDemo = 0
  var quitAfter = 0
  var timeout = 30
}

func parseSmokeOptions() -> SmokeOptions {
  var options = SmokeOptions()
  let args = Array(CommandLine.arguments.dropFirst())
  var index = 0
  while index < args.count {
    let arg = args[index]
    func value() -> String {
      precondition(index + 1 < args.count, "missing value for \(arg)")
      index += 1
      return args[index]
    }
    switch arg {
    case "--server": options.server = value()
    case "--room": options.room = value()
    case "--peer": options.peer = value()
    case "--token": options.token = value()
    case "--stun": options.stun = value()
    case "--message": options.message = value()
    case "--binary-demo": options.binaryDemo = true
    case "--frame-demo": options.frameDemo = Int(value()) ?? 30
    case "--quit-after": options.quitAfter = Int(value()) ?? 0
    case "--timeout": options.timeout = Int(value()) ?? 30
    default:
      FileHandle.standardError.write(Data("unknown option: \(arg)\n".utf8))
      exit(64)
    }
    index += 1
  }
  return options
}

func framePayload(frameId: UInt32, size: Int) -> Data {
  var data = Data(count: size)
  data.withUnsafeMutableBytes { raw in
    let bytes = raw.bindMemory(to: UInt8.self)
    for i in 0..<size {
      bytes[i] = UInt8(truncatingIfNeeded: frameId &* 31 &+ UInt32(i))
    }
  }
  return data
}

func frameMatches(_ frame: MediaFrame) -> Bool {
  let expectedSize =
    frame.frameId % 3 == 0 ? 40_000 : (frame.frameId % 3 == 1 ? 200_000 : 2_000)
  guard frame.data.count == expectedSize else { return false }
  return frame.data.elementsEqual(framePayload(frameId: frame.frameId, size: expectedSize))
}

let options = parseSmokeOptions()
let controller = SessionController(callbackQueue: DispatchQueue(label: "smoke"))
let semaphore = DispatchSemaphore(value: 0)
let doneLock = NSLock()
var done = false
var received = 0
var binarySent = false
var framesSent = false
var framesReceived = 0
var frameErrors = 0
var hadFailure = false

func finish() {
  doneLock.lock()
  let already = done
  done = true
  doneLock.unlock()
  if !already {
    semaphore.signal()
  }
}

controller.onStatus = { status in
  switch status {
  case .connected:
    print("connected")
  case .ended(let reason):
    print("ended: \(reason)")
    finish()
  case .failed(let message):
    print("failed: \(message)")
    hadFailure = true
    finish()
  default:
    break
  }
}

controller.onLog = { line in
  print(line)
}

controller.onChannels = { channels in
  if options.binaryDemo && !binarySent && channels["game"] == true {
    binarySent = true
    controller.sendBinary(channel: "game", data: Data([0, 1, 2, 255]))
  }
  if options.frameDemo > 0 && !framesSent && channels["game"] == true {
    framesSent = true
    for frameId in 0..<UInt32(options.frameDemo) {
      let size = frameId % 3 == 0 ? 40_000 : (frameId % 3 == 1 ? 200_000 : 2_000)
      controller.sendFrame(
        MediaFrame(
          frameId: frameId,
          timestampMs: frameId * 33,
          keyframe: frameId % 5 == 0,
          data: framePayload(frameId: frameId, size: size)))
    }
    print("sent \(options.frameDemo) frames")
  }
}

controller.onChat = { message in
  print(
    "received channel=\(message.channel) incoming=\(message.incoming) text=\(message.text)"
  )
  if message.incoming {
    received += 1
    if options.frameDemo == 0 && options.quitAfter > 0 && received >= options.quitAfter {
      finish()
    }
  }
}

controller.onFrame = { frame in
  framesReceived += 1
  if !frameMatches(frame) || frame.keyframe != (frame.frameId % 5 == 0) {
    frameErrors += 1
    print("frame mismatch: id=\(frame.frameId) size=\(frame.data.count)")
  }
  if framesReceived % 10 == 0 || framesReceived == options.frameDemo {
    print("frames verified: \(framesReceived)/\(options.frameDemo)")
  }
  if options.frameDemo > 0 && framesReceived >= options.frameDemo {
    finish()
  }
}

controller.connect(
  SessionConfig(
    server: options.server,
    room: options.room,
    peer: options.peer,
    token: options.token,
    stun: options.stun,
    greeting: options.message
  )
)

if semaphore.wait(timeout: .now() + .seconds(options.timeout)) == .timedOut {
  print("timed out: received \(received) messages, \(framesReceived)/\(options.frameDemo) frames")
  controller.disconnect()
  _ = semaphore.wait(timeout: .now() + 5)
  exit(2)
}

controller.disconnect()
_ = semaphore.wait(timeout: .now() + 5)
if hadFailure {
  exit(1)
}
if frameErrors > 0 {
  print("frame verification failed: \(frameErrors) mismatches")
  exit(3)
}
exit(0)
