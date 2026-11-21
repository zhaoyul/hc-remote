# hc-remote 详细设计

## 1. 目标与边界

hc-remote 是一个不依赖网易服务的点对点网络 MVP。控制服务器只负责配对与信令交换，业务数据通过 WebRTC DataChannel 端到端传输。系统明确不部署 TURN，也不在服务器中转业务流量。

首版交付：

- C++20 原生库，封装 libdatachannel。
- 原生层统一的会话编排（`Session`），offerer/answerer 状态机只实现一次。
- 可直接运行的 C++ 信令服务器和双端命令行客户端。
- macOS 原生 UI 客户端（SwiftUI，经 C ABI 边界使用原生库）。
- 屏幕投屏：ScreenCaptureKit 捕获 → VideoToolbox H.264 → 帧协议分块 → `game` 通道 → 对端显示。
- 远程控制：`control` 通道 JSON 协议传输键鼠事件，接收端 CGEventPost 注入。
- 局域网真实双端连接，支持文本和二进制消息。
- 可选 STUN；无 TURN 配置入口。
- coturn 的 STUN-only 配置示例。

非目标：游戏透明代理、TUN 虚拟网卡、非 macOS 平台 GUI、账号系统、生产级 ICE 重启、TURN 兜底和 NAT 穿透成功率保证。录制远端屏幕流（MP4）已定方案（接收端 AVAssetWriter）但尚未实现。

## 2. 总体结构

```text
C++ CLI ───────────────┐
                       │
macOS UI (Swift) → C ABI
                       ▼
              hc_remote native library
              ├─ Session (offerer/answerer 编排)
              ├─ PeerConnection
              ├─ DataChannel
              ├─ WebSocket client
              └─ bounded event queue
                       │
          SDP / ICE candidates over WebSocket
                       │
                hc-remote-signal server
                       │
       coturn STUN-only（公网部署时可选）

A ═════════ DTLS + SCTP over ICE ═════════ B
```

上层（CLI、Swift UI）不直接接触 libdatachannel 网络线程。C++ 回调仅构造值并写入有界队列，调用方通过 `pollEvent` 主动取出事件。跨语言只经过 C ABI（`hcr_c.h`）：opaque handle、POD 事件结构、所有调用捕获异常。

## 3. 模块职责

### native Peer

- 创建 `rtc::PeerConnection`。
- 仅接受可选 STUN URL，不创建 TURN `IceServer`。
- Offerer 创建 `control` 与 `game` 两个通道；Answerer 自动接收。
- 交换 SDP 和 Trickle ICE candidates。
- `control` 使用默认可靠有序模式。
- `game` 使用 unordered、maxRetransmits=0。
- 将本地描述、candidate、连接状态、通道状态和入站消息统一转成事件。
- 所有 public 方法可从调用方线程使用，内部通过互斥锁保护对象和队列。

### native Session

- 持有 `SignalingClient` 与 `Peer`，编排 offerer/answerer 状态机（仅实现一次）。
- `pollEvent()` 内部泵两个事件源：远端 offer 触发 answer，远端 answer 完成协商，本地 SDP/candidate 自动转发。
- `local-description`、`local-candidate`、`remote-description`、`remote-candidate` 被状态机消费，不出现在对外事件流中。
- 单线程归属：同一 handle 的所有调用来自同一个线程（CLI 直接调用，Swift 侧经命令队列串行化到会话线程）。

### native SignalingClient

- 使用 WSS/WS 连接信令服务。
- 发送 join、description、candidate 和 leave。
- 将 joined、ready、description、candidate、peer-left、error 转成统一事件。
- JSON 解析仅停留在 C++ 层，jank 不需要 JSON 依赖。

### native Session（编排）

- 用纯函数风格的事件泵更新内部状态（role、remoteDescriptionSet）。
- 处理 offerer/answerer 角色，转发本地 SDP/candidate。
- 远端 offer 触发 answer；远端 answer 完成协商。
- 调用方轮询合并后的事件流，收到消息后输出/展示。

### hc-remote-signal

- 单进程、最多两个 peer 的房间模型。
- 第一个有效 join 是 offerer，第二个是 answerer。
- 只向同房间另一方转发 description 和 candidate。
- peer 断线后通知另一方，并释放其房间占用。
- 限制 ID、房间名、消息大小和房间人数。
- 可通过 `HCR_SIGNAL_TOKEN` 启用共享令牌检查。
- 开发模式使用 WS；公网部署应由反向代理终止 TLS，提供 WSS。

## 4. 信令协议

所有消息为 UTF-8 JSON。客户端 join：

```json
{"type":"join","room":"demo","peer":"a","token":"optional"}
```

服务端响应：

```json
{"type":"joined","room":"demo","peer":"a","role":"offerer"}
{"type":"ready","room":"demo","initiator":true}
```

SDP 与 candidate：

```json
{"type":"description","room":"demo","peer":"a","description":"v=0..."}
{"type":"candidate","room":"demo","peer":"a","candidate":"candidate:...","mid":"0"}
```

在线探测（不占用房间，用于设备列表状态）：

```json
{"type":"probe","room":"demo","token":"optional"}
{"type":"probe","room":"demo","peers":1}
```

服务端转发时保留类型并添加 `from`，不解析 SDP 或 candidate。错误统一为：

```json
{"type":"error","code":"room_full","message":"room already has two peers"}
```

## 5. 原生事件模型

```text
none
signaling-open / signaling-closed
joined / ready / peer-left
local-description / local-candidate
remote-description / remote-candidate
peer-state / channel-open / channel-closed
message / binary-message
error / queue-overflow
frame-message
```

`Event` 是 C++ 值类型，只含枚举、字符串和二进制 vector。空队列返回 `none`，避免上层处理 `std::optional` 或输出参数。

`frame-message` 携带重组完成的编码帧（frameId、timestampMs、keyframe 标志）。帧协议：每块 16 字节头（魔数/版本/关键帧/帧 id/时间戳/块序号）+ 16 KiB 负载；原生层重组，与裸二进制消息以魔数区分，非帧消息原样透传为 `binary-message`。不完整的帧直接丢弃（直播语义），接收端缺 SPS/PPS 时经 control 通道请求关键帧。

## 6. 连接时序

1. 两端连接信令服务器并 join 同一 room。
2. 两端建立 PeerConnection，注册本地回调。
3. 第二端加入后，服务器发送 ready；offerer 创建两个通道，自动生成 offer。
4. 本地 description/candidate 通过信令服务发给对端。
5. answerer 设置 remote offer，自动生成 answer。
6. offerer 设置 remote answer；双方持续交换 candidates。
7. ICE 选择 host、IPv6 或 server-reflexive 直连路径。
8. DTLS 握手完成，DataChannel 打开，开始端到端消息传输。
9. 无可用路径时进入 failed/closed，不尝试 relay。

## 7. 并发与生命周期

- 网络回调不打印、不调用上层代码，也不持有队列锁调用外部代码。
- 事件队列上限 4096；溢出时记录 `queue-overflow`，防止远端造成无限内存增长。
- 每条信令消息上限 256 KiB；DataChannel 二进制消息上限 256 KiB。
- close 幂等；先关闭 channel，再关闭 PeerConnection/WebSocket。
- 高频路径不将每个包转换为上层持久化结构；二进制只暴露字节数和原生表示。

## 8. 安全

- 端到端传输由 WebRTC DTLS 保护。
- SDP 中的 DTLS fingerprint 必须经认证信令传递；生产环境需要账号级认证，而非共享 token。
- 校验 room/peer 字符集和长度，限制房间与消息大小。
- 默认不关闭 TLS 校验，不接受任意 TURN 配置。
- 日志不输出 token，不输出完整业务消息。
- 信令服务不是开放代理，无法访问或转发 DataChannel 数据。

## 9. 构建与运行

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j4

./build/hc-remote-signal --port 8080
./build/hc-remote-peer --server ws://127.0.0.1:8080 --room demo --peer a --message hello-from-a
./build/hc-remote-peer --server ws://127.0.0.1:8080 --room demo --peer b --message hello-from-b
```

公网 STUN：

```bash
turnserver -c deploy/coturn.conf
./build/hc-remote-peer ... --stun stun:stun.example.org:3478
```

macOS UI 客户端：

```bash
export HCR_NATIVE_BUILD="$PWD/build"
swift build --package-path app
./app/make-app.sh
open build/hc-remote.app
```

自动化双端验证可增加 `--binary-demo --quit-after 3 --timeout 20`；Swift 引擎提供无头入口 `HcrSmoke`（`--quit-after 2` 等待两个通道的消息）。UI 客户端经 C ABI（`hcr_c.h`）使用原生库，`hcr_session_*` 是唯一互操作面；编排逻辑只存在于原生 `Session`，CLI 与 Swift 不重复实现。

Linux 构建验证可使用项目内 Docker 工具链：

```bash
docker build -t hc-remote-linux -f deploy/Dockerfile .
docker run --rm -it -v "$PWD":/work hc-remote-linux bash
```

容器内使用 `build-linux` 构建原生库。动态库搜索路径需要包含 `build-linux` 和 `build-linux/_deps/libdatachannel-build`。

## 10. 验证标准

- 信令服务接受两个 peer，拒绝第三个。
- offer/answer 与 candidates 能双向转发。
- 两个独立进程建立真实 DataChannel，双向各收到对方消息。
- control 与 game 通道均打开。
- 断开一端后另一端收到 peer-left。
- 不配置 TURN，服务器无业务数据转发路径。
- Swift 引擎与 C++ CLI 可混合连接，UI 客户端可与 CLI 完成同一连接流程。

## 11. 已知限制

- 对称 NAT、CGNAT 和 UDP 被禁用时可能无法直连。
- 首版房间仅支持两人，重连需要重新加入。
- 不包含 ICE restart、数据持久化、WSS 内置证书管理和水平扩展。
- 共享 token 仅用于本地/受信网络演示，不是完整身份系统。
