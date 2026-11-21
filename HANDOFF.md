# hc-remote 交接文档

## 1. 项目定位

hc-remote 当前是一个可运行的 C++ / Swift 点对点网络 MVP。它不是网易 UU 的逆向客户端，也不依赖网易服务。

核心目标：

- 两端通过 WebRTC DataChannel 直接通信。
- 信令服务器只负责配对、SDP 和 ICE candidate 交换。
- 不提供高速转发，不部署 TURN，不在服务器中转业务数据。
- C++ 负责 ICE、DTLS、SCTP、WebSocket、连接编排（`Session`）和原生线程；上层客户端是 C++ CLI 与 macOS Swift UI。
- 无可用直连路径时明确失败，不自动回退中继。

历史：项目最初以 jank 作为控制面、C++ 作为数据面；2026 年 11 月移除 jank，编排逻辑下沉到原生 `Session` 类，只保留 C++ 与 Swift 两条客户端线。

完整设计见 `DESIGN.md`。

## 2. 当前完成度

已完成：

- C++ 原生动态库 `hcr_native`，含统一编排 `hcr::Session`。
- C ABI shim（`hcr_c.h`），跨语言只经过这一层。
- C++ 信令服务器 `hc-remote-signal`。
- C++ 命令行客户端 `hc-remote-peer`。
- macOS 原生 UI 客户端 `hc-remote.app`（SwiftUI + Swift 会话引擎 + `HcrSmoke` 无头测试入口）。
- 设备模型（参照 UU远程）：本地设备列表 + 信令房间在线探测（probe）+ 设备模式（驻留房间待连、被连自动投屏、被控中横幅）+ 一键连接/仅观看。
- 应用图标与菜单栏常驻图标：显示主界面 / 安全锁定（断开远控并禁止注入）/ 帮助与反馈 / 退出 ⌘Q。
- 屏幕投屏链路：ScreenCaptureKit 捕获 → VideoToolbox H.264 硬编 → 分块帧协议 → `game` 通道 → 对端 `AVSampleBufferDisplayLayer` 显示。
- 远程控制：`control` 通道 JSON 协议（键鼠事件/关键帧请求/投屏开关），接收端 `CGEventPost` 注入。
- `control` 与 `game` 两个 DataChannel。
- 文本与二进制消息。
- 双人房间、第三人拒绝、对端离开通知。
- 可选 STUN 和 coturn STUN-only 配置。
- Linux Docker 构建与验证环境。

未完成或非目标：

- 录制远端屏幕流为 MP4（已定方案：接收端 AVAssetWriter mux，未实现）。
- 非 macOS 平台 UI。
- UI 代码签名、公证、安装包和自动更新。
- TUN/Wintun/utun 游戏流量透明接管。
- 用户账号体系和长期设备密钥管理。
- 生产级 WSS、重连、ICE restart 和多实例信令服务。
- 公网对称 NAT/CGNAT 测试矩阵。
- TURN 中继，当前是刻意排除而非遗漏。

## 3. 技术栈与依赖

- C++20。
- libdatachannel v0.24.6，由 CMake FetchContent 获取并构建。
- nlohmann/json，最低 3.11.3，使用系统 CMake package。
- CMake >= 3.24、Ninja。
- Swift 5.10+ / SwiftUI（macOS 13+）与 SwiftPM，用于 macOS UI 客户端。
- OpenSSL 3.x：自建 universal 静态库（`deploy/build-openssl-universal.sh`），静态编入 libdatachannel，不依赖 Homebrew。
- macOS 构建为 universal 二进制（x86_64 + arm64），M 系列与 Intel 通用。
- coturn，仅作为独立 STUN 服务。
- Docker 镜像基于 Ubuntu 26.04（Linux C++ 构建验证）。

首次 CMake 配置需要克隆 libdatachannel 及其子模块，网络较慢时会明显耗时；后续构建复用 `build/` 或 `build-linux/`。

## 4. 文件地图

```text
CMakeLists.txt                  C++ 依赖、动态库和三个构建目标
DESIGN.md                       详细架构和协议设计
HANDOFF.md                     本交接文档

native/include/hcr/hcr.hpp   Peer、SignalingClient、Session、Event 公共接口
native/include/hcr/hcr_c.h   C ABI shim 接口（Swift 等语言互操作）
native/src/c_api.cpp           C ABI shim 实现，异常不越过 C 边界
native/src/session.cpp         offerer/answerer 编排（唯一一份状态机）
native/src/frame_codec.hpp     帧协议：分块/重组/魔数区分（透明层）
native/src/frame_codec.cpp     帧协议实现
native/src/event_queue.hpp     有界线程安全事件队列
native/src/event_queue.cpp     事件名称、错误、计时和休眠
native/src/peer.cpp            WebRTC、DataChannel 和原生回调
native/src/signaling.cpp       WebSocket 客户端和 JSON 信令
native/src/signal_server.cpp   双人房间信令服务器
native/src/peer_main.cpp       C++ CLI（消费 Session 事件流）

app/Package.swift               SwiftPM 工程（HcrCore/HcrMedia/HcrApp/HcrSmoke）
app/Sources/CHcuu/              hcr_c.h 的 modulemap
app/Sources/HcrCore/Session.swift  Swift 会话引擎（薄封装 + 命令队列）
app/Sources/HcrCore/Devices.swift  设备存储 + 房间在线探测服务
app/Sources/HcrMedia/          媒体栈：捕获/编码/显示/输入注入/控制协议
app/Sources/HcrApp/            SwiftUI 界面（设备列表/远程协助/会话，UU 风格）
app/Sources/HcrSmoke/          无头冒烟/集成测试可执行（含 --frame-demo）
app/icon/gen-icon.swift          图标源（可重新生成 AppIcon.icns）
app/Resources/AppIcon.icns       应用图标（make-app.sh 装入 bundle）
app/make-app.sh                 组装自包含 hc-remote.app bundle

deploy/coturn.conf             STUN-only 配置
deploy/Dockerfile              Ubuntu C++ 验证环境
```

生成目录 `build/`、`build-linux/`、`app/.build/` 均已忽略，不属于源代码。

## 5. 关键架构约定

### 网络线程不得直接进入上层

libdatachannel 回调只创建 C++ `Event` 并写入有界队列。调用方通过 `pollEvent` 主动取事件。不要在回调里直接执行上层代码。

### 编排只在原生层实现一次

offerer/answerer 状态机在 `hcr::Session`（`native/src/session.cpp`）中实现：远端 offer 触发 answer、远端 answer 完成协商、本地 SDP/candidate 自动转发。`local-description`、`local-candidate`、`remote-description`、`remote-candidate` 被状态机消费，不出现在对外事件流中。CLI 和 Swift 都只消费合并后的事件流，不要在上层重写编排逻辑。

### UI 客户端只经过 C ABI 边界

Swift 不直接接触 C++ 类。`hcr_c.h` 是唯一互操作面：opaque handle、POD 事件结构、所有调用捕获异常。`Session` 句柄是单线程归属：Swift 侧用会话线程 + 命令队列串行化所有调用。修改 `hcr.hpp` 接口时必须同步更新 `hcr_c.h` 与 `c_api.cpp`。

### 高频数据留在原生层

事件 map 对二进制只暴露 `binary-size`，没有把每个包转换成上层持久化结构。后续实现 TUN 时也应保持这一原则。

### 媒体帧走帧协议，与裸二进制共存于 game 通道

编码帧经 `Session::sendFrame` 分块（16 KiB/块，16 字节头：魔数/版本/关键帧/帧 id/时间戳/块序号）发送；原生层重组后以 `frame-message` 事件交付完整帧。非帧协议的二进制消息原样透传为 `binary-message`（CLI `--binary-demo` 兼容）。丢帧不重传，不完整的帧直接丢弃；接收端缺参数集时经 `control` 请求关键帧。

### 媒体管线在 Swift，传输在原生

捕获（ScreenCaptureKit）、编码（VideoToolbox）、显示（AVSampleBufferDisplayLayer）和输入注入（CGEventPost）在 `HcrMedia`；跨 C ABI 的只有编码后的帧数据。控制协议是 `control` 通道上的 JSON 文本（stream-start/stop、keyframe-request、键鼠事件），与聊天文本以 `type` 字段区分。

### 两个通道语义不同

- `control`：可靠、有序。
- `game`：无序、`maxRetransmits=0`。

### 明确禁止 TURN

`Peer` 只接受 STUN URL；传入 `turn:` 或 `turns:` 会抛出异常。不要为了“提高连通率”悄悄增加 relay，若产品策略改变，需要重新评审架构和安全边界。

## 6. 本机 C++ 构建与运行

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j4
```

终端一：

```bash
./build/hc-remote-signal --port 8080
```

终端二、三：

```bash
./build/hc-remote-peer --server ws://127.0.0.1:8080 \
  --room demo --peer a --message hello-from-a \
  --binary-demo --quit-after 3 --timeout 20

./build/hc-remote-peer --server ws://127.0.0.1:8080 \
  --room demo --peer b --message hello-from-b \
  --binary-demo --quit-after 3 --timeout 20
```

每端应收到两条文本和一条四字节二进制消息。不加 `--quit-after` 时，客户端运行到超时、收到对端离开或用户中断。

可通过 `HCR_SIGNAL_TOKEN` 给服务端和客户端配置相同的演示共享令牌。它不是生产级身份认证。

## 7. macOS UI 客户端构建与运行

原生库必须先构建（见第 6 节）。UI 是 SwiftPM 工程，`HCR_NATIVE_BUILD` 指向原生库构建目录（默认 `build/`）：

```bash
export HCR_NATIVE_BUILD="$PWD/build"
swift build --package-path app      # 开发构建
./app/make-app.sh                   # 组装自包含 bundle: build/hc-remote.app
```

`make-app.sh` 把 `libhcr_native.dylib` 和 `libdatachannel.0.dylib`（均 universal，OpenSSL 已静态编入）拷入 bundle 的 `Contents/Frameworks` 并改写为 `@loader_path` 引用，附证书签名。SwiftPM 以 `--arch arm64 --arch x86_64` 构建；CMake 以 `CMAKE_OSX_ARCHITECTURES=arm64;x86_64` 构建，需 `OPENSSL_ROOT_DIR=build-openssl-universal`、`OPENSSL_USE_STATIC_LIBS=ON`、`FETCHCONTENT_SOURCE_DIR_LIBDATACHANNEL=build-deps-src`（后者复用已克隆源码；`OPENSSL_USE_STATIC_LIBS` 不设时 libdatachannel 会硬找 `.dylib` 而报 OpenSSL 目标缺失）。

```bash
open build/hc-remote.app
```

界面采用 UU远程 的功能模型（左侧设备列表 + 状态点，远程协助，被控中横幅，设备动作栏）。启动参数：

```bash
open build/hc-remote.app --args \
  --server ws://127.0.0.1:8080 --room demo --peer mac \
  --autoconnect --autostream   # autostream: 连接后 3 秒自动开始投屏

# 设备机（被控端）开机自启，驻留房间待连、被连自动投屏：
open build/hc-remote.app --args --server ws://127.0.0.1:8080 \
  --room device-demo --peer mac-device --devicemode
```

无头集成测试入口（不启动 UI，验收标准与 CLI 一致）：

```bash
swift run --package-path app HcrSmoke \
  --server ws://127.0.0.1:8080 --room demo --peer smoke \
  --message hello --quit-after 2 --timeout 20
```

## 8. Linux Docker 路线

```bash
docker build -t hc-remote-linux -f deploy/Dockerfile .
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -v "$PWD":/work \
  hc-remote-linux bash
```

容器内：

```bash
cmake -S . -B build-linux -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-linux -j4
```

动态库运行时搜索路径必须包含原生库目录和 libdatachannel 构建目录：

```bash
export LD_LIBRARY_PATH="$PWD/build-linux:$PWD/build-linux/_deps/libdatachannel-build"
```

macOS 对应使用 `DYLD_LIBRARY_PATH`。

## 9. C++ 与 Swift 混合验收

信令服务器 + C++ CLI + Swift 无头入口：

```bash
./build/hc-remote-signal --port 18082 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
sleep 0.5

./build/hc-remote-peer \
  --server ws://127.0.0.1:18082 --room mixed --peer cpp \
  --message hello-from-cpp --quit-after 2 --timeout 20 &
cpp=$!

sleep 0.5

swift run --package-path app HcrSmoke \
  --server ws://127.0.0.1:18082 --room mixed --peer swift \
  --message hello-from-swift --quit-after 2 --timeout 20 &
swift=$!

wait "$cpp"
wait "$swift"
```

成功标准：双方进入 `connected`，两个通道都打开，并分别收到对方的两条文本。

## 10. 已完成的实际验证

- macOS C++ 构建通过。
- Linux C++ 构建通过。
- macOS C++ ↔ C++ 双进程连接通过（含二进制消息）。
- Linux C++ ↔ C++ 双进程连接通过。
- `control` 和 `game` 均验证打开并收发文本。
- C++ 双端验证四字节二进制消息。
- 第三人连接收到 `room_full`。
- 对端离开、通道关闭和 peer 状态事件已观察。
- 传入 TURN URL 会拒绝。
- Session 下沉后 C++ ↔ C++ 回归通过（文本 + 二进制）。
- 帧协议回环通过（HcrSmoke --frame-demo 30 帧双向逐字节校验，含跨块大帧和关键帧标志）。
- Swift 引擎双进程互连通过（HcrSmoke ↔ HcrSmoke）。
- Swift 引擎 ↔ C++ CLI 混合连接通过（双向文本、两个通道）。
- GUI 客户端 ↔ C++ CLI 端到端通过（真实窗口截图人工核对）。
- `hc-remote.app` bundle 自包含运行，不依赖 Homebrew dylib 路径。
- universal 架构检查通过（app、libhcr_native、libdatachannel、hc-remote-signal 均 x86_64+arm64）；x86_64 切片回归通过（smoke/smoke、smoke/CLI、GUI 投屏）。

当前没有独立自动化测试目录；上述验收通过真实进程和真实 WebRTC 连接完成，不是仅 import、编译或 mock。历史上的 jank 运行时/Leiningen 验证已随 jank 移除作废。

## 11. STUN 部署

```bash
turnserver -c deploy/coturn.conf
```

配置只启用 STUN。公网服务器需要开放 UDP 3478，客户端增加：

```bash
--stun stun:stun.example.org:3478
```

尚未完成真实跨运营商、对称 NAT 和 CGNAT 验证。无中继模式下，这些网络可能合法地连接失败。

## 12. 已知工程限制与风险

- 信令房间只支持两人，断线后通常重新加入，不支持无缝 ICE restart。
- 开发模式使用 WS；公网部署必须由反向代理终止 TLS 并提供 WSS。
- 共享 token 只能用于受信演示环境。
- 信令服务当前为单进程内存状态，不支持水平扩展。
- 项目目录不是 Git 仓库，没有提交历史。
- 许可证未定（早期 `project.clj` 曾声明 MPL 2.0，已随 jank 移除）；正式分发前需确认项目及所有依赖的许可证和 NOTICE 要求。
- UI 客户端仅 macOS 13+，不能直接分发。
- 代码签名使用固定自签名证书 `build/sign/hcr-dev`（私钥不入库，重建目录即换身份）；证书必须在钥匙串中设为受信，否则 TCC 无法把运行进程映射到 `org.hcremote.mac` 授权上。ad-hoc 签名每次构建换 cdhash，TCC 授权会随之作废，是已踩过的坑。
- 投屏需要“屏幕录制”权限，键鼠注入需要“辅助功能”权限；授权后 `tccutil` 可重置（调试时用过）。
- universal 构建下仅验证了 x86_64 切片；arm64 切片需在 M 系列机器实测（拷 `build/hc-remote-macos.zip`、`xattr -dr com.apple.quarantine hc-remote.app`、授权屏幕录制/辅助功能）。
- UI 二进制消息只显示字节数（与 CLI 一致），未做二进制发送界面。
- 设备动作栏中 文件传输/终端/端口映射 为占位（标注“规划中”），未实现；设备列表为本地存储，无账号体系。
- 启动参数（--devicemode/--autoconnect）由 AppModel 初始化后异步触发，不依赖窗口 onAppear（曾因窗口场景生命周期导致无头启动无动作）；关闭主窗口后菜单栏图标和设备模式继续运行。
- 投屏和远程控制需要 TCC 权限（屏幕录制、辅助功能），ad-hoc 签名应用首次使用时会弹系统授权框。
- 录制远端屏幕流（MP4）尚未实现。
- 键鼠注入按主显示器坐标映射；多显示器和分辨率不匹配场景未处理。
- `hcr_c.h`/`c_api.cpp` 必须与 `hcr.hpp` 手工同步，目前没有自动生成或一致性检查。

## 13. 建议的后续优先级

1. 将当前手工验收流程固化为项目认可的自动化集成测试（HcrSmoke 与 hc-remote-peer 已具备脚本化条件）。
2. 增加会话超时、重复 join、断线重连和 ICE restart。
3. 完成 WSS、设备级密钥和短期会话凭证。
4. 在多种家庭宽带、企业网、移动热点和 CGNAT 下记录直连成功率。
5. 如确需透明游戏代理，再单独设计 TUN/Wintun/utun 数据面，保持控制面与 C++ 高频数据面的边界。
6. GUI 后续：二进制发送界面、连接历史与预设、错误提示细化；最后再考虑安装包、签名、公证和自动更新。

## 14. 交接时的环境状态

- 构建产物保留在 `build/`、`build-linux/` 和 `app/.build/`；macOS UI bundle 位于 `build/hc-remote.app`，传输包 `build/hc-remote-macos.zip`。
- 生成目录 `build-openssl-universal/`（universal 静态 OpenSSL）和 `build-deps-src/`（libdatachannel 源码，复用避免克隆）保留用于增量构建，均已 gitignore。
- Docker 镜像建议名 `hc-remote-linux`（旧镜像 `hc-remote-jank` 含 jank 工具链，已无用，可删除）。
- 没有遗留后台信令服务或构建任务。
- 没有需要交接的账号、密码、证书或私有令牌。
