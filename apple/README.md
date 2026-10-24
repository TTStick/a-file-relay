# FileSwitch 原生客户端（macOS / iOS）

这是用 SwiftUI 写的原生客户端，macOS 和 iOS 共用一套代码，界面采用 Apple 的 Liquid Glass 设计（macOS 26 / iOS 26）。
Android 和 Windows 继续使用 `../client` 里的 Flutter 客户端，这里不涉及。

## 目录

```
apple/
├── project.yml              XcodeGen 工程描述（FileSwitch.xcodeproj 由它生成，已一并提交）
├── Shared/
│   ├── Core/                协议与加密：HTTP + 证书固定、局域网直连、中转端到端加密（XChaCha20-Poly1305）、传输队列
│   ├── UI/                  共享界面：连接、文件树、时间线、分类、传输、回收站、设备与安全
│   │                        （Mac 和宽窗口的 iPad 用侧边栏布局，iPhone 和窄窗口用标签栏布局）
│   └── App/                 入口；DemoHooks.swift 只在 Debug 下编译，用于自动化测试
├── macOS/StatusBar.swift    菜单栏常驻、拖文件靠近右上角弹出的分类投递面板
├── Tests/                   单元测试
├── iOS/                     iOS 的 Info.plist
└── Resources/               图标与强调色
```

## 构建

需要 Xcode 26 及以上。

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

可以直接打开 `FileSwitch.xcodeproj`，选择 `FileSwitch-macOS` 或 `FileSwitch-iOS` 运行。也可以用命令行构建：

```bash
xcodebuild -project FileSwitch.xcodeproj -scheme FileSwitch-macOS -configuration Release build
```

单元测试（安全相关的检查，部分用例需要联网）：

```bash
xcodebuild test -project FileSwitch.xcodeproj -scheme FileSwitch-macOS
```

改了 `project.yml` 之后，用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 重新生成工程：

```bash
xcodegen generate --spec project.yml
```

- **macOS**：默认用 ad-hoc 签名，没有公证。第一次打开时右键 →「打开」；或者在 Xcode 里换成你自己的 Developer ID。
- **iOS 真机**：需要在 Xcode 的 Signing & Capabilities 里选择你的开发团队；模拟器不需要签名。

## 安全说明

- 服务器使用自签证书，客户端在代码中固定（pin）证书的 SHA-256 指纹。因此 Info.plist 里放开了 ATS，
  这样系统不会拦截自签证书；所有连接仍然必须匹配固定的指纹。
- 登录令牌和中转密钥保存在钥匙串（`com.fileswitch.app`）。
- 经过中转站的文件、目录快照和操作都在客户端端到端加密，中转站只能看到密文。
