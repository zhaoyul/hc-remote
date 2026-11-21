import Combine
import Foundation
import HcrCore
import HcrMedia
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  enum Quality: String, CaseIterable, Identifiable {
    case smooth
    case balanced
    case sharp

    var id: String { rawValue }

    var label: String {
      switch self {
      case .smooth: return "流畅优先"
      case .balanced: return "平衡"
      case .sharp: return "清晰优先"
      }
    }

    var preset: (width: Int, height: Int, fps: Int) {
      switch self {
      case .smooth: return (1280, 720, 30)
      case .balanced: return (1920, 1080, 30)
      case .sharp: return (1920, 1080, 60)
      }
    }
  }

  @Published var server = "ws://127.0.0.1:8080"
  @Published var token = ""
  @Published var stun = ""
  @Published var room = ""
  @Published var peerName = "mac-a"

  @Published var devices: [Device] = DeviceStore.load()
  @Published var probeResults: [String: Int] = [:]
  @Published var selectedDeviceID: UUID?
  @Published var viewOnly = false
  @Published var deviceMode = false
  @Published var deviceRoom = ""

  @Published var statusText = "未连接"
  @Published var statusColor: Color = .secondary
  @Published var isActive = false
  @Published var controlOpen = false
  @Published var gameOpen = false
  @Published var roleText = "-"

  @Published var isStreaming = false
  @Published var isViewing = false
  @Published var allowRemoteControl = true
  @Published var statsText = ""
  @Published var quality: Quality = .balanced

  @Published var messages: [ChatMessage] = []
  @Published var logs: [String] = []
  @Published var draft = ""
  @Published var sendChannel = "control"

  let controller = SessionController(callbackQueue: .main)
  let stream: StreamController
  let screenBox = ScreenBox()
  private let probe = ProbeService()
  private var autoconnect = false
  private var autostream = false
  private var devicemodeArg = false
  private var deviceHost = false
  private var activeRoom: String = ""

  init() {
    setbuf(stdout, nil)
    print("AppModel init args=\(CommandLine.arguments)")
    stream = StreamController(session: controller)

    controller.onStatus = { [weak self] status in
      self?.apply(status)
    }
    controller.onLog = { [weak self] text in
      self?.appendLog(text)
    }
    controller.onChat = { [weak self] message in
      self?.handle(message)
    }
    controller.onChannels = { [weak self] channels in
      self?.controlOpen = channels["control"] ?? false
      self?.gameOpen = channels["game"] ?? false
    }
    controller.onFrame = { [weak self] frame in
      self?.stream.handleFrame(frame)
    }

    stream.onLog = { [weak self] text in
      self?.appendLog(text)
    }
    stream.onSample = { [weak self] sample in
      self?.screenBox.enqueue(sample)
    }
    stream.onStateChange = { [weak self] in
      guard let self else { return }
      self.isStreaming = self.stream.isStreaming
      self.isViewing = self.stream.isViewing
    }
    stream.onStats = { [weak self] text in
      self?.statsText = text
    }

    probe.onResult = { [weak self] results in
      DispatchQueue.main.async {
        self?.probeResults = results
      }
    }
    probe.update(
      server: server, token: token, rooms: devices.map(\.room))
    probe.start()

    if deviceRoom.isEmpty {
      deviceRoom = "device-\(peerName)"
    }

    applyArguments()
    DispatchQueue.main.async { [weak self] in
      self?.startIfConfigured()
    }
  }

  var selectedDevice: Device? {
    devices.first { $0.id == selectedDeviceID }
  }

  func addDevice(name: String, room: String) {
    let device = Device(name: name, room: room)
    devices.append(device)
    DeviceStore.save(devices)
    refreshProbeTargets()
    selectedDeviceID = device.id
  }

  func removeDevice(_ device: Device) {
    devices.removeAll { $0.id == device.id }
    DeviceStore.save(devices)
    if selectedDeviceID == device.id {
      selectedDeviceID = nil
    }
    refreshProbeTargets()
  }

  func refreshProbeTargets() {
    probe.update(server: server, token: token, rooms: devices.map(\.room))
    probe.probeOnce()
  }

  func deviceStatus(_ device: Device) -> (text: String, color: Color) {
    switch probeResults[device.room] {
    case 1: return ("在线", Brand.online)
    case 2: return ("使用中", .orange)
    case 0: return ("离线", .gray)
    default: return ("未知", .gray.opacity(0.5))
    }
  }

  func connect() {
    connect(to: room, viewOnly: false)
  }

  func connect(to targetRoom: String, viewOnly: Bool) {
    guard !isActive else { return }
    let trimmedRoom = targetRoom.trimmingCharacters(in: .whitespaces)
    guard !trimmedRoom.isEmpty else { return }
    self.viewOnly = viewOnly
    activeRoom = trimmedRoom
    room = trimmedRoom
    let config = SessionConfig(
      server: server.trimmingCharacters(in: .whitespaces),
      room: trimmedRoom,
      peer: peerName.trimmingCharacters(in: .whitespaces),
      token: token.trimmingCharacters(in: .whitespaces),
      stun: stun.trimmingCharacters(in: .whitespaces)
    )
    isActive = true
    statusText = "连接中…"
    statusColor = .orange
    controller.connect(config)
    probe.probeOnce()
  }

  func toggleDeviceMode() {
    if deviceMode {
      disconnect()
      deviceMode = false
      deviceHost = false
    } else {
      let target = deviceRoom.trimmingCharacters(in: .whitespaces)
      guard !target.isEmpty else { return }
      deviceMode = true
      deviceHost = true
      connect(to: target, viewOnly: false)
    }
  }

  func disconnect() {
    stream.stopStreaming()
    controller.disconnect()
  }

  func securityLock() {
    disconnect()
    allowRemoteControl = false
    stream.allowRemoteControl = false
    appendLog("安全锁定: 已断开所有远控并禁止远程控制")
  }

  func toggleStreaming() {
    if isStreaming {
      stream.stopStreaming()
    } else {
      let preset = quality.preset
      stream.startStreaming(
        width: preset.width, height: preset.height, fps: preset.fps)
    }
    isStreaming = stream.isStreaming
    isViewing = stream.isViewing
  }

  func sendInput(_ message: MediaProtocol) {
    guard !viewOnly else { return }
    stream.sendInput(message)
  }

  func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    controller.sendText(channel: sendChannel, text: text)
    messages.append(
      ChatMessage(
        date: Date(), channel: sendChannel, incoming: false, text: text,
        byteCount: nil)
    )
    draft = ""
  }

  func startIfConfigured() {
    print("startIfConfigured devicemodeArg=\(devicemodeArg) autoconnect=\(autoconnect)")
    if devicemodeArg {
      devicemodeArg = false
      if !room.isEmpty {
        deviceRoom = room
      }
      toggleDeviceMode()
      return
    }
    guard autoconnect else { return }
    autoconnect = false
    connect()
    if autostream {
      autostream = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
        guard let self, self.isActive, !self.isStreaming else { return }
        self.toggleStreaming()
      }
    }
  }

  private func handle(_ message: ChatMessage) {
    if message.incoming, message.channel == "control",
      let protocolMessage = MediaProtocol.decode(message.text)
    {
      stream.handleControl(protocolMessage)
      return
    }
    messages.append(message)
  }

  private func appendLog(_ text: String) {
    if (text.hasPrefix("收到 [control] {") || text.hasPrefix("已发送 [control] {")),
      let start = text.firstIndex(of: "{"),
      let end = text.lastIndex(of: "}"),
      MediaProtocol.decode(String(text[start...end])) != nil
    {
      return
    }
    print("[\(Self.timestamp())] \(text)")
    logs.append("[\(Self.timestamp())] \(text)")
    if logs.count > 500 {
      logs.removeFirst(logs.count - 500)
    }
  }

  private func apply(_ status: SessionStatus) {
    switch status {
    case .idle:
      statusText = "未连接"
      statusColor = .secondary
      isActive = false
    case .connecting:
      statusText = "连接信令中…"
      statusColor = .orange
    case .joined(let role):
      roleText = role == "offerer" ? "发起方" : (role == "answerer" ? "响应方" : role)
      statusText = "已加入房间"
      statusColor = .blue
    case .negotiating:
      statusText = "连接协商中…"
      statusColor = .orange
    case .connected:
      statusText = "已连接"
      statusColor = .green
      if deviceHost, !isStreaming {
        toggleStreaming()
      }
    case .ended(let reason):
      statusText = "已结束: \(reason)"
      statusColor = .secondary
      isActive = false
      controlOpen = false
      gameOpen = false
    case .failed(let message):
      statusText = "失败: \(message)"
      statusColor = .red
      appendLog("连接失败: \(message)")
      isActive = false
      controlOpen = false
      gameOpen = false
    }
    if !isActive {
      roleText = "-"
      stream.stopStreaming()
      isStreaming = false
      isViewing = false
      if deviceHost {
        deviceMode = false
        deviceHost = false
      }
    } else {
      probe.probeOnce()
    }
  }

  private func applyArguments() {
    let args = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < args.count {
      let arg = args[index]
      func value() -> String? {
        guard index + 1 < args.count else { return nil }
        index += 1
        return args[index]
      }
      switch arg {
      case "--server":
        if let v = value() { server = v }
      case "--room":
        if let v = value() { room = v }
      case "--peer":
        if let v = value() { peerName = v }
      case "--token":
        if let v = value() { token = v }
      case "--stun":
        if let v = value() { stun = v }
      case "--autoconnect":
        autoconnect = true
      case "--autostream":
        autostream = true
      case "--devicemode":
        devicemodeArg = true
      default:
        break
      }
      index += 1
    }
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
  }
}
