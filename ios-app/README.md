# DaysWith 原生 iOS

保留 SwiftUI 客户端和 Swift 核心作为兼容与测试参照；当前跨平台客户端位于 `flutter/jinbao365_app`。包名、Keychain service 与应用支持目录仍沿用旧标识，不能仅为品牌更名修改。

核心测试需要 Swift 5.9+ 工具链：

```sh
swift test
```

App 构建与设备测试需要 macOS / Xcode 和签名配置。COS 连接、权限、恢复与覆盖升级边界见 [完整 onboarding](../docs/ONBOARDING.md)。历史家庭验收材料未随本次快照导入，不能据此声明本分支已通过真机测试。
