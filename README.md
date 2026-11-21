# hc-remote

开源的点对点屏幕共享与远程控制工具。两端通过 WebRTC DataChannel 直接通信，信令服务器只负责配对和 SDP/ICE 交换——**没有中转服务器，不部署 TURN，业务数据不出现在任何服务器上**。

> 本项目与网易 UU 远程等商业产品无任何关联。

## 功能

- **屏幕投屏**：ScreenCaptureKit 捕获 → H.264 硬编 → WebRTC 直传 → 对端低延迟显示（捕获自动排除本应用窗口，无镜中镜）
- **远程控制**：鼠标/键盘/滚轮注入（观看模式可只看不控）
- **文件传输**：可靠通道分块传输（含完成确认），进度条显示，200MB 级文件实测一致
- **全屏观看**：沉浸式全屏（⌘F / ESC），浮动工具条
- **设备列表**：本机设备模式驻留房间待连，在线状态探测，一键远控（类似主流远控的设备模型）
- **画质档**：流畅优先 720p30 / 平衡 1080p30 / 清晰优先 1080p60
- **文本消息**：control（可靠有序）/ game（无序零重传）双通道
- **菜单栏常驻**：显示主界面 / 安全锁定（一键断开远控并禁止注入）/ 退出
- 两人房间、对端离开通知、可选 STUN、演示共享令牌

## 下载

见 [Releases](../../releases)：

| 产物 | 说明 |
|---|---|
| `hc-remote-macos.zip` | macOS 客户端（universal，Intel + Apple Silicon） |
| `hc-remote-signal-*.zip` | 信令服务器 + 命令行客户端（Linux / Windows / macOS） |

## 快速开始

1. 任意一台双方可达的机器上启动信令服务器：

   ```bash
   ./hc-remote-signal --port 8080
   ```

2. 两端启动客户端（macOS 图形界面，或任意平台的 `hc-remote-peer` CLI），填入：
   - 服务器：`ws://<服务器IP>:8080`
   - 房间号：两端相同
   - 昵称：各自不同

3. 点击「发起连接」→「开始投屏」，或在「我的设备」里添加对端设备房间一键远控。

命令行示例：

```bash
./hc-remote-peer --server ws://127.0.0.1:8080 --room demo --peer a --message hello
```

## macOS 使用须知

- **首次运行**：从网络下载的 app 需右键「打开」，或执行 `xattr -dr com.apple.quarantine hc-remote.app`
- **投屏**需在 系统设置 > 隐私与安全性 > 屏幕与系统录音 中允许
- **远程控制注入**需在 系统设置 > 隐私与安全性 > 辅助功能 中允许
- 客户端为 ad-hoc 签名的测试版，正式签名/公证在路线图中

## 构建

依赖：CMake ≥ 3.24、Ninja、C++20 编译器、OpenSSL、Swift 5.10+（仅客户端）。

```bash
# 原生库 + server + CLI
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j4

# macOS 客户端（universal）
export HCR_NATIVE_BUILD="$PWD/build"
./deploy/build-openssl-universal.sh   # 首次：构建 universal 静态 OpenSSL
./app/make-app.sh                     # 产出 build/hc-remote.app
```

各平台 CI 构建细节见 [.github/workflows/ci.yml](.github/workflows/ci.yml)，开发文档见 [DESIGN.md](DESIGN.md)。

## 网络边界

| 场景 | 预期 |
|---|---|
| 同一局域网 | 直连 |
| 跨 NAT / 公网 | 需配置 STUN；对称 NAT/CGNAT 可能无法直连 |
| 中继兜底 | **没有**。无 TURN 是安全与成本上的刻意设计 |

公网部署信令服务器时，请用反向代理终止 TLS 提供 `wss://`。

## 路线图

- 终端 / 端口映射（界面已预留）
- 录制远端屏幕流为 MP4
- Windows/Linux 图形客户端
- 正式签名与公证

## 许可证

[MPL-2.0](LICENSE)。第三方组件许可见 [deploy/THIRD-PARTY-LICENSES.txt](deploy/THIRD-PARTY-LICENSES.txt)。
