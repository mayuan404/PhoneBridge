# PhoneBridge

把安卓手机的通知（短信、微信、验证码…）直接送到 Mac 菜单栏，**不经过任何服务器**。
顺带内置 TOTP 验证器（Google Authenticator 那类），验证码在 Mac 上生成。

## 为什么不用 KDE Connect

KDE Connect 依赖局域网 UDP 广播 + 直连，而很多 Wi-Fi 做了三层隔离（AP isolation），
手机和 Mac 明明在同一个 SSID 也互相不可见。PhoneBridge 走 **蓝牙 BLE**，
不经过 IP 网络，隔离与否都不影响。

## 架构

```
安卓：NotificationListenerService ──► BLE GATT server（广播 + 通知特性）
                                   └─► TCP 127.0.0.1:8765（adb reverse 联调用）
Mac：菜单栏 App（CoreBluetooth central）──► 通知列表 / 横幅 / 一键复制验证码
                                      └─► TOTP 生成器（本地）
```

- 数据格式：每行一个 JSON（`pkg/app/title/text/time`），\n 分隔；
- 不落盘、不上传，Mac 端只在本地保留最近 100 条；
- 手机端可按包名白名单过滤，避免被无关推送刷屏。

## 安装

### Mac 端

```bash
cd tools/PhoneBridge/mac && ./build.sh
# 生成并安装到 ~/Applications/PhoneBridge.app
open ~/Applications/PhoneBridge.app
```

首次启动会请求「蓝牙」权限；菜单栏出现手机图标即表示在扫描。

### 安卓端（小米 14 / HyperOS）

1. 用本仓库的 GitHub Actions 构建 APK（`.github/workflows/android.yml`），
   在 Actions 页面下载 `phonebridge-apk` 产物；
2. 安装后打开 PhoneBridge：
   - 点「授予通知读取权限」→ 在系统列表里勾选 PhoneBridge；
   - 点「启动后台服务」；
3. 省电设置（关键，否则后台会被杀）：
   - 设置 → 应用设置 → 应用管理 → PhoneBridge → 省电策略 → **无限制**
   - 设置 → 应用设置 → 应用管理 → PhoneBridge → 自启动 → 允许
   - 最近任务里给 PhoneBridge 加锁。

### 联调（没有蓝牙时）

```bash
adb reverse tcp:8765 tcp:8765
```

手机端只要服务在跑，就会自动走 TCP 连到 Mac。

## 验证器（TOTP）

Mac 端「验证器」页 →「添加验证器…」，粘贴：

- `otpauth://totp/Issuer:name?secret=BASE32&digits=6&period=30`，或
- 直接粘贴 Base32 密钥。

Google Authenticator 本身不导出，需要手动录入一次；或者之前用 Aegis 等能导出二维码的工具。

## 图标

`assets/icon-1024.png` 是唯一源文件，`assets/AppIcon.icns` 与
`android/app/src/main/res/mipmap-*/ic_launcher.png` 都由它生成，两端视觉一致。

## 已知限制

- BLE 单包 180 字节切片，长通知会分片，Mac 端按 `\n` 重组；
- 微信通知的内容取决于手机端「显示消息详情」是否打开；
- HyperOS 对后台蓝牙广播限制较严，若长时间收不到，重启一次服务。

## 应用层加密（配对码）

链路层要求配对只能挡住「别的设备连上来」，挡不住拿到你蓝牙链路的攻击者。所以再加一层：

1. Mac 菜单栏 → **配对码** → 「复制」；
2. 手机 PhoneBridge → 粘贴到「配对码」输入框 → **保存配对码**；
3. 两端用 `SHA-256(code + "|PhoneBridge|v1")` 派生 32 字节密钥，消息体用 **AES-256-GCM**（12 字节随机 nonce）加密，
   外层是 `E1:` + base64(nonce‖密文‖tag)；
4. 配对码不一致时 Mac 顶部会显示「配对码不一致」，消息不会被渲染。

> 手机端未设置配对码时会退回明文发送（App 内会提示），只建议在联调时这么用。

## 安全模型

1. **蓝牙链路必须配对**：手机端把 GATT 特征值与 CCCD 的权限设成 `ENCRYPTED_MITM`，
   未配对的设备**连通知订阅都会被拒绝**（返回 `INSUFFICIENT_AUTHENTICATION`）；
   手机在收到连接时会主动发起 `createBond()`，两端确认后才会发送数据。
2. **只用 BLE，不连 IP 网络**：数据不经过路由器、服务器，也不受 Wi-Fi 隔离影响。
3. **本地存储**：Mac 端只在 `~/Library/Application Support/PhoneBridge/` 保存最近 100 条通知
   与验证器密钥（目录 0700，密钥文件不加密——如果这台机器需要多人共用，请告诉我，我可以加钥匙串存储）。
4. **可裁剪**：手机端可以只选要转发的 App；不选则全部转发。

## 验证器：从 Google Authenticator 迁移

Google Authenticator（GA）**没有导出文件**，它的「转移账号」是**二维码**。做法：

1. 手机上打开 GA → 右上角 ⋮ → **转移账号** → **导出账号**；
2. 勾选要迁移的账号 → **导出**，GA 会显示一个（或分批多个）二维码；
3. **截图**（每个二维码各截一张；GA 一批最多 20 个账号，10 多个通常一张就够）；
4. 把截图传到 Mac（隔空投送 / 微信文件传输助手都行）；
5. Mac 菜单栏图标 → **验证器** 页 → **「导入验证器…」** → 选中截图；
6. 识别成功会提示「已导入 N 个验证器账户」，之后每 30 秒刷新一次验证码，点一下复制。

识别失败时：

- 确认截的是 GA 的二维码页面（不是列表页）；
- 二维码被截断/缩放模糊会识别不出，尽量原图、别裁掉四周白边；
- GA 分批显示多个二维码时，把每张都选上（导入对话框支持多选）。

## 通知列表

- **按 App 分组，默认全部折叠**，点组标题展开；
- 每组**最多保留 5 条**，超出自动丢最老的（这是提示工具，不是收件箱）；
- 每条消息右上角 `×` 可单条删除；
- 底部「自动复制」开关：收到带验证码的消息时直接写进系统剪贴板；
- 手机端「选择要转发的 App」可只转发短信/微信，不选则全部转发。
