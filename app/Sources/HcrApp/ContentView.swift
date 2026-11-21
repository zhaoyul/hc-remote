import HcrCore
import HcrMedia
import SwiftUI

enum Brand {
  static let accent = Color(red: 0.18, green: 0.42, blue: 1.0)
  static let online = Color(red: 0.20, green: 0.78, blue: 0.35)
  static let canvas = Color(red: 0.95, green: 0.96, blue: 0.97)
  static let danger = Color(red: 0.92, green: 0.28, blue: 0.28)
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @State private var showSettings = false
  @State private var showAddDevice = false
  @State private var newDeviceName = ""
  @State private var newDeviceRoom = ""
  @State private var showDrawer = true

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      VStack(spacing: 0) {
        topBar
        if let device = model.selectedDevice {
          devicePage(device)
        } else {
          assistPage
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Brand.canvas)
    }
    .frame(minWidth: 1020, minHeight: 640)
    .onAppear { model.startIfConfigured() }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: "desktopcomputer")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(Brand.accent)
        Text("hc-remote 远程")
          .font(.headline)
      }
      .padding(.bottom, 14)

      sectionHeader("我的设备")
      ForEach(model.devices) { device in
        deviceRow(device)
      }
      Button {
        showAddDevice = true
      } label: {
        Label("添加设备", systemImage: "plus.circle")
          .font(.callout)
          .foregroundStyle(Brand.accent)
          .padding(.vertical, 7)
          .padding(.horizontal, 12)
      }
      .buttonStyle(.plain)

      sectionHeader("远程协助")
      sidebarRow(
        "开始协助", icon: "bolt.horizontal.circle",
        selected: model.selectedDeviceID == nil
      ) {
        model.selectedDeviceID = nil
      }

      Spacer()

      HStack(spacing: 6) {
        Circle()
          .fill(model.isActive ? Brand.online : Color.gray.opacity(0.4))
          .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 1) {
          Text(model.peerName)
            .font(.callout.weight(.medium))
          Text(model.deviceMode ? "设备模式 · 房间 \(model.deviceRoom)" : model.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.top, 8)
    }
    .padding(14)
    .frame(width: 208)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color.white.opacity(0.65))
    .sheet(isPresented: $showAddDevice) { addDeviceSheet }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.top, 12)
      .padding(.bottom, 4)
      .padding(.horizontal, 12)
  }

  private func sidebarRow(
    _ title: String, icon: String, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .frame(width: 20)
        Text(title)
        Spacer()
      }
      .font(.callout.weight(selected ? .semibold : .regular))
      .foregroundStyle(selected ? Brand.accent : .primary)
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .background(
        selected ? Brand.accent.opacity(0.10) : Color.clear,
        in: RoundedRectangle(cornerRadius: 9)
      )
    }
    .buttonStyle(.plain)
  }

  private func deviceRow(_ device: Device) -> some View {
    Button {
      model.selectedDeviceID = device.id
    } label: {
      HStack(spacing: 8) {
        let status = model.deviceStatus(device)
        Circle()
          .fill(status.color)
          .frame(width: 8, height: 8)
        Text(device.name)
          .lineLimit(1)
        Spacer()
        Text(status.text)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .font(.callout)
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .background(
        model.selectedDeviceID == device.id
          ? Brand.accent.opacity(0.10) : Color.clear,
        in: RoundedRectangle(cornerRadius: 9)
      )
    }
    .buttonStyle(.plain)
  }

  private var addDeviceSheet: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("添加设备")
        .font(.headline)
      TextField("设备名称", text: $newDeviceName)
        .textFieldStyle(.roundedBorder)
      TextField("房间号 (对端设备模式的房间)", text: $newDeviceRoom)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("取消") { showAddDevice = false }
        Button("添加") {
          let name = newDeviceName.trimmingCharacters(in: .whitespaces)
          let room = newDeviceRoom.trimmingCharacters(in: .whitespaces)
          guard !name.isEmpty, !room.isEmpty else { return }
          model.addDevice(name: name, room: room)
          newDeviceName = ""
          newDeviceRoom = ""
          showAddDevice = false
        }
        .buttonStyle(.borderedProminent)
        .tint(Brand.accent)
        .disabled(
          newDeviceName.trimmingCharacters(in: .whitespaces).isEmpty
            || newDeviceRoom.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 340)
  }

  private var topBar: some View {
    HStack(spacing: 10) {
      Text(model.selectedDevice?.name ?? "远程协助")
        .font(.title3.weight(.semibold))
      if let device = model.selectedDevice {
        let status = model.deviceStatus(device)
        HStack(spacing: 5) {
          Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
          Text(status.text)
            .font(.callout)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(status.color.opacity(0.12), in: Capsule())
      }
      Spacer()
      Button {
        showSettings.toggle()
      } label: {
        Image(systemName: "gearshape")
      }
      .popover(isPresented: $showSettings) { settingsForm }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 11)
    .background(.white)
  }

  private var settingsForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("连接设置")
        .font(.headline)
      smallField("服务器", text: $model.server)
      smallField("令牌(可选)", text: $model.token)
      smallField("STUN(可选)", text: $model.stun)
      Text("修改后对新连接生效")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 300)
  }

  private func devicePage(_ device: Device) -> some View {
    VStack(spacing: 14) {
      if model.isActive && model.room == device.room {
        connectionBanner
        sessionView
      } else {
        deviceCard(device)
      }
    }
    .padding(18)
  }

  private var connectionBanner: some View {
    HStack(spacing: 12) {
      Image(systemName: "display")
        .foregroundStyle(Brand.accent)
      if model.deviceMode && model.isStreaming {
        Text("被控中")
          .font(.headline)
          .foregroundStyle(Brand.accent)
        Text("本机正在被远端观看和控制")
          .foregroundStyle(.secondary)
      } else {
        Text("已建立远程连接")
          .font(.headline)
          .foregroundStyle(Brand.accent)
        Text(model.viewOnly ? "观看模式 · 仅观看不控制" : "可观看并控制对端")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("断开所有远控") {
        model.disconnect()
      }
      .buttonStyle(.bordered)
      .tint(Brand.danger)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Brand.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }

  private func deviceCard(_ device: Device) -> some View {
    VStack(spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          Text(device.name)
            .font(.title2.weight(.semibold))
          HStack(spacing: 8) {
            let status = model.deviceStatus(device)
            Circle()
              .fill(status.color)
              .frame(width: 9, height: 9)
            Text("房间 \(device.room) · \(status.text)")
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button {
          model.removeDevice(device)
        } label: {
          Image(systemName: "trash")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("移除设备")
      }

      HStack(spacing: 12) {
        Button {
          model.connect(to: device.room, viewOnly: false)
        } label: {
          Label("连接并控制", systemImage: "cursorarrow.rays")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(Brand.accent)
        .controlSize(.large)

        Button {
          model.connect(to: device.room, viewOnly: true)
        } label: {
          Label("仅观看", systemImage: "eye")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      }

      HStack(spacing: 0) {
        actionItem("文件传输", icon: "doc.on.doc", enabled: false)
        divider
        actionItem("观看模式", icon: "play.rectangle", enabled: true) {
          model.connect(to: device.room, viewOnly: true)
        }
        divider
        actionItem("终端", icon: "terminal", enabled: false)
        divider
        actionItem("端口映射", icon: "point.3.connected.trianglepath.dotted", enabled: false)
      }
      .padding(.vertical, 12)
      .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
    .padding(22)
    .background(.white, in: RoundedRectangle(cornerRadius: 14))
    .frame(maxWidth: .infinity, alignment: .top)
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.gray.opacity(0.2))
      .frame(width: 1, height: 22)
  }

  private func actionItem(
    _ title: String, icon: String, enabled: Bool,
    action: @escaping () -> Void = {}
  ) -> some View {
    Button(action: action) {
      VStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 17))
        Text(title)
          .font(.callout)
        if !enabled {
          Text("规划中")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .foregroundStyle(enabled ? Brand.accent : Color.secondary)
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .help(enabled ? title : "\(title)（规划中）")
  }

  private var assistPage: some View {
    Group {
      if model.isActive {
        VStack(spacing: 14) {
          connectionBanner
          sessionView
        }
        .padding(18)
      } else {
        ScrollView {
          assistCards
            .padding(18)
        }
      }
    }
  }

  private var assistCards: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 16) {
        Label("发起远程协助", systemImage: "bolt.horizontal.circle")
          .font(.headline)
        bigField("房间号", text: $model.room, placeholder: "与对端相同的房间号")
        bigField("昵称", text: $model.peerName, placeholder: "你的昵称")
        Button {
          model.connect()
        } label: {
          Text("发起连接")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(Brand.accent)
        .controlSize(.large)
        HStack(spacing: 6) {
          Circle()
            .fill(model.statusColor == .green ? Brand.online : model.statusColor)
            .frame(width: 8, height: 8)
          Text(model.statusText)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(22)
      .background(.white, in: RoundedRectangle(cornerRadius: 14))
      .frame(maxWidth: .infinity)

      VStack(alignment: .leading, spacing: 12) {
        Label("本机设备模式", systemImage: "desktopcomputer")
          .font(.headline)
        Text("开启后本机驻留在指定房间等待被连，对方在设备列表中可见并可一键远控。")
          .font(.callout)
          .foregroundStyle(.secondary)
        smallField("设备房间号", text: $model.deviceRoom)
        Button {
          model.toggleDeviceMode()
        } label: {
          Label(
            model.deviceMode ? "关闭设备模式" : "开启设备模式",
            systemImage: model.deviceMode ? "stop.circle" : "desktopcomputer"
          )
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.deviceMode ? Brand.danger : Brand.accent)
        if model.deviceMode {
          HStack(spacing: 6) {
            Circle()
              .fill(model.isStreaming ? Brand.danger : Brand.online)
              .frame(width: 8, height: 8)
            Text(model.isStreaming ? "被控中 · 对方可观看控制本机" : "等待对方连接…")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(18)
      .background(.white, in: RoundedRectangle(cornerRadius: 14))
      .frame(width: 300)
    }
  }

  private var sessionView: some View {
    VStack(spacing: 8) {
      toolbar
      ZStack(alignment: .topTrailing) {
        ZStack {
          ScreenView(box: model.screenBox) { message in
            model.sendInput(message)
          }
          .background(Color.black)
          if !model.isViewing {
            VStack(spacing: 8) {
              Image(systemName: "display")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.7))
              Text(model.isStreaming ? "正在共享本机屏幕" : "点击\"开始投屏\"共享本机屏幕")
                .foregroundStyle(.white.opacity(0.85))
              Text(model.viewOnly ? "观看模式 · 不会向对端注入键鼠" : "点击画面可注入键鼠（需辅助功能权限）")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
            }
          }
        }
        if showDrawer {
          drawer
            .frame(width: 300)
            .padding(10)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
    }
    .animation(.easeInOut(duration: 0.18), value: showDrawer)
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Button {
        model.toggleStreaming()
      } label: {
        Label(
          model.isStreaming ? "停止投屏" : "开始投屏",
          systemImage: model.isStreaming ? "stop.circle" : "play.circle"
        )
      }
      .buttonStyle(.borderedProminent)
      .tint(model.isStreaming ? Brand.danger : Brand.accent)

      Picker("画质", selection: $model.quality) {
        ForEach(AppModel.Quality.allCases) { preset in
          Text(preset.label).tag(preset)
        }
      }
      .frame(width: 150)

      Toggle("允许远程控制", isOn: $model.allowRemoteControl)
        .toggleStyle(.switch)
        .onChange(of: model.allowRemoteControl) { value in
          model.stream.allowRemoteControl = value
          if value {
            _ = Permissions.accessibilityGranted(prompt: true)
          }
        }

      Spacer()

      Text(model.statsText)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)

      Button {
        showDrawer.toggle()
      } label: {
        Image(systemName: "sidebar.right")
      }

      Button {
        model.disconnect()
      } label: {
        Label("断开", systemImage: "power")
      }
      .buttonStyle(.bordered)
      .tint(Brand.danger)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.white, in: RoundedRectangle(cornerRadius: 12))
  }

  private var drawer: some View {
    VStack(spacing: 8) {
      chatPanel
      logPanel
    }
  }

  private var chatPanel: some View {
    VStack(spacing: 6) {
      HStack {
        Label("消息", systemImage: "bubble.left.and.bubble.right")
          .font(.callout.weight(.semibold))
        Spacer()
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(model.messages) { message in
              messageRow(message)
                .id(message.id)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 140)
        .onChange(of: model.messages.count) { _ in
          if let last = model.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
      HStack(spacing: 6) {
        Picker("通道", selection: $model.sendChannel) {
          Text("control").tag("control")
          Text("game").tag("game")
        }
        .pickerStyle(.segmented)
        .frame(width: 120)
        TextField("消息…", text: $model.draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { model.send() }
        Button {
          model.send()
        } label: {
          Image(systemName: "paperplane.fill")
        }
        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(10)
    .background(.white, in: RoundedRectangle(cornerRadius: 12))
  }

  private var logPanel: some View {
    VStack(spacing: 6) {
      HStack {
        Label("事件日志", systemImage: "list.bullet.rectangle")
          .font(.callout.weight(.semibold))
        Spacer()
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.logs.enumerated()), id: \.offset) { index, line in
              Text(line)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(index)
            }
          }
        }
        .frame(minHeight: 120)
        .onChange(of: model.logs.count) { _ in
          proxy.scrollTo(model.logs.count - 1, anchor: .bottom)
        }
      }
    }
    .padding(10)
    .background(.white, in: RoundedRectangle(cornerRadius: 12))
  }

  private func bigField(_ label: String, text: Binding<String>, placeholder: String)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.callout)
        .foregroundStyle(.secondary)
      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.title3)
        .padding(12)
        .background(Brand.canvas, in: RoundedRectangle(cornerRadius: 10))
        .disabled(model.isActive)
    }
  }

  private func smallField(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField(label, text: text)
        .textFieldStyle(.roundedBorder)
        .disabled(model.isActive)
    }
  }

  private func messageRow(_ message: ChatMessage) -> some View {
    HStack {
      if !message.incoming {
        Spacer(minLength: 30)
      }
      VStack(alignment: message.incoming ? .leading : .trailing, spacing: 2) {
        Text("\(message.incoming ? "收到" : "发送") [\(message.channel)]")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(message.text)
          .font(.callout)
          .padding(6)
          .background(
            message.incoming
              ? Brand.accent.opacity(0.10)
              : Brand.online.opacity(0.12)
          )
          .cornerRadius(8)
      }
      if message.incoming {
        Spacer(minLength: 30)
      }
    }
  }
}
