import CHcr
import Foundation

public struct SessionConfig {
  public var server: String
  public var room: String
  public var peer: String
  public var token: String
  public var stun: String
  public var greeting: String?

  public init(
    server: String = "ws://127.0.0.1:8080",
    room: String = "demo",
    peer: String,
    token: String = "",
    stun: String = "",
    greeting: String? = nil
  ) {
    self.server = server
    self.room = room
    self.peer = peer
    self.token = token
    self.stun = stun
    self.greeting = greeting
  }
}

public enum SessionStatus: Equatable {
  case idle
  case connecting
  case joined(role: String)
  case negotiating
  case connected
  case ended(reason: String)
  case failed(message: String)
}

public struct ChatMessage: Identifiable, Equatable {
  public let id = UUID()
  public let date: Date
  public let channel: String
  public let incoming: Bool
  public let text: String
  public let byteCount: Int?

  public init(
    date: Date, channel: String, incoming: Bool, text: String,
    byteCount: Int?
  ) {
    self.date = date
    self.channel = channel
    self.incoming = incoming
    self.text = text
    self.byteCount = byteCount
  }
}

public struct MediaFrame: Equatable {
  public let frameId: UInt32
  public let timestampMs: UInt32
  public let keyframe: Bool
  public let data: Data

  public init(frameId: UInt32, timestampMs: UInt32, keyframe: Bool, data: Data) {
    self.frameId = frameId
    self.timestampMs = timestampMs
    self.keyframe = keyframe
    self.data = data
  }
}

/// Thin wrapper around `hcr_session`. The offerer/answerer orchestration
/// lives in the native layer; this class only pumps events and marshals
/// sends through a command queue onto the session thread (the native
/// handle is single-threaded).
public final class SessionController {
  public var onStatus: ((SessionStatus) -> Void)?
  public var onLog: ((String) -> Void)?
  public var onChat: ((ChatMessage) -> Void)?
  public var onChannels: (([String: Bool]) -> Void)?
  public var onFrame: ((MediaFrame) -> Void)?

  private enum NativeEvent: Int {
    case none = 0
    case signalingOpen = 1
    case signalingClosed = 2
    case joined = 3
    case ready = 4
    case peerLeft = 5
    case localDescription = 6
    case localCandidate = 7
    case remoteDescription = 8
    case remoteCandidate = 9
    case peerState = 10
    case channelOpen = 11
    case channelClosed = 12
    case message = 13
    case binaryMessage = 14
    case error = 15
    case queueOverflow = 16
    case frameMessage = 17
  }

  private enum Command {
    case sendText(channel: String, text: String)
    case sendBinary(channel: String, data: Data)
    case sendFrame(frameId: UInt32, keyframe: Bool, timestampMs: UInt32, data: Data)
    case stop
  }

  private let callbackQueue: DispatchQueue
  private let lock = NSLock()
  private var commands: [Command] = []
  private var running = false
  private var greeting: String?

  public init(callbackQueue: DispatchQueue = .main) {
    self.callbackQueue = callbackQueue
  }

  public var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  public func connect(_ config: SessionConfig) {
    lock.lock()
    guard !running else {
      lock.unlock()
      return
    }
    running = true
    commands.removeAll()
    greeting = config.greeting
    lock.unlock()

    let thread = Thread { [weak self] in
      self?.run(config)
    }
    thread.name = "hcr-session"
    thread.start()
  }

  public func disconnect() {
    lock.lock()
    commands.append(.stop)
    lock.unlock()
  }

  public func sendText(channel: String, text: String) {
    lock.lock()
    commands.append(.sendText(channel: channel, text: text))
    lock.unlock()
  }

  public func sendBinary(channel: String, data: Data) {
    lock.lock()
    commands.append(.sendBinary(channel: channel, data: data))
    lock.unlock()
  }

  public func sendFrame(_ frame: MediaFrame) {
    lock.lock()
    commands.append(
      .sendFrame(
        frameId: frame.frameId, keyframe: frame.keyframe,
        timestampMs: frame.timestampMs, data: frame.data))
    lock.unlock()
  }

  private func emitStatus(_ status: SessionStatus) {
    callbackQueue.async { [weak self] in self?.onStatus?(status) }
  }

  private func emitLog(_ text: String) {
    callbackQueue.async { [weak self] in self?.onLog?(text) }
  }

  private func emitChat(_ message: ChatMessage) {
    callbackQueue.async { [weak self] in self?.onChat?(message) }
  }

  private func emitChannels(_ channels: [String: Bool]) {
    callbackQueue.async { [weak self] in self?.onChannels?(channels) }
  }

  private func emitFrame(_ frame: MediaFrame) {
    callbackQueue.async { [weak self] in self?.onFrame?(frame) }
  }

  private func stopRequested() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return commands.contains { command in
      if case .stop = command {
        return true
      }
      return false
    }
  }

  private func drainCommands(_ session: OpaquePointer) {
    while true {
      lock.lock()
      guard !commands.isEmpty else {
        lock.unlock()
        return
      }
      let command = commands.removeFirst()
      lock.unlock()

      switch command {
      case .stop:
        break
      case .sendText(let channel, let text):
        let ok = text.withCString { cText in
          channel.withCString { cChannel in
            hcr_session_send_text(session, cChannel, cText)
          }
        }
        if ok {
          emitLog("已发送 [\(channel)] \(text)")
        } else {
          emitLog("发送失败 [\(channel)]: \(String(cString: hcr_last_error()))")
        }
      case .sendBinary(let channel, let data):
        let ok = data.withUnsafeBytes { raw in
          channel.withCString { cChannel in
            hcr_session_send_binary(session, cChannel, raw.baseAddress, raw.count)
          }
        }
        if ok {
          emitLog("已发送 [\(channel)] 二进制 \(data.count) 字节")
        } else {
          emitLog("发送失败 [\(channel)] 二进制: \(String(cString: hcr_last_error()))")
        }
      case .sendFrame(let frameId, let keyframe, let timestampMs, let data):
        let ok = data.withUnsafeBytes { raw in
          hcr_session_send_frame(
            session, frameId, keyframe, timestampMs, raw.baseAddress, raw.count)
        }
        if !ok {
          emitLog("发送帧失败 #\(frameId): \(String(cString: hcr_last_error()))")
        }
      }
    }
  }

  private func run(_ config: SessionConfig) {
    defer {
      lock.lock()
      running = false
      commands.removeAll()
      lock.unlock()
    }

    let session: OpaquePointer? = config.token.withCString { cToken in
      config.server.withCString { cServer in
        config.room.withCString { cRoom in
          config.peer.withCString { cPeer in
            config.stun.withCString { cStun in
              hcr_session_create(cServer, cRoom, cPeer, cToken, cStun)
            }
          }
        }
      }
    }
    guard let handle = session else {
      emitStatus(.failed(message: String(cString: hcr_last_error())))
      return
    }
    defer { hcr_session_destroy(handle) }

    emitStatus(.connecting)
    hcr_session_connect(handle)

    var channelStates: [String: Bool] = [:]
    var finished = false

    while !finished && !stopRequested() {
      drainCommands(handle)

      var progressed = false
      while true {
        var event = hcr_event()
        guard hcr_session_poll_event(handle, &event) else {
          break
        }
        progressed = true
        handleEvent(event, channelStates: &channelStates, finished: &finished)
      }

      if !progressed {
        Thread.sleep(forTimeInterval: 0.005)
      }
    }
  }

  private func handleEvent(
    _ event: hcr_event,
    channelStates: inout [String: Bool],
    finished: inout Bool
  ) {
    guard let type = NativeEvent(rawValue: Int(event.type.rawValue)) else {
      return
    }
    switch type {
    case .signalingOpen:
      emitLog("信令已连接")
    case .signalingClosed:
      emitLog("信令连接已关闭")
    case .joined:
      let role = String(cString: event.role)
      emitLog("已加入房间 role=\(role)")
      emitStatus(.joined(role: role))
    case .ready:
      emitLog("对端已就绪 initiator=\(event.initiator)")
      emitStatus(.negotiating)
    case .peerLeft:
      emitLog("对端已离开")
      emitStatus(.ended(reason: "对端离开"))
      finished = true
    case .peerState:
      let state = String(cString: event.state)
      emitLog("连接状态: \(state)")
      if state == "failed" || state == "closed" {
        emitStatus(.ended(reason: "连接状态 \(state)"))
        disconnect()
      }
    case .channelOpen:
      let channel = String(cString: event.channel)
      channelStates[channel] = true
      emitChannels(channelStates)
      emitLog("通道已打开: \(channel)")
      if let greeting = greeting {
        sendText(channel: channel, text: greeting)
      }
      if channelStates["control"] == true && channelStates["game"] == true {
        emitStatus(.connected)
      }
    case .channelClosed:
      let channel = String(cString: event.channel)
      channelStates[channel] = false
      emitChannels(channelStates)
      emitLog("通道已关闭: \(channel)")
    case .message:
      let channel = String(cString: event.channel)
      let text = String(cString: event.text)
      emitLog("收到 [\(channel)] \(text)")
      emitChat(
        ChatMessage(
          date: Date(), channel: channel, incoming: true, text: text,
          byteCount: nil)
      )
    case .binaryMessage:
      let channel = String(cString: event.channel)
      let size = event.binary_size
      emitLog("收到 [\(channel)] 二进制 \(size) 字节")
      emitChat(
        ChatMessage(
          date: Date(), channel: channel, incoming: true,
          text: "[二进制 \(size) 字节]", byteCount: size)
      )
    case .error, .queueOverflow:
      let code = String(cString: event.code)
      let text = String(cString: event.text)
      emitLog("错误: \(code) \(text)")
      emitStatus(.failed(message: "\(code) \(text)"))
      finished = true
    case .frameMessage:
      let data = Data(bytes: event.binary, count: event.binary_size)
      emitFrame(
        MediaFrame(
          frameId: event.frame_id, timestampMs: event.timestamp_ms,
          keyframe: event.keyframe, data: data))
    default:
      break
    }
  }
}
