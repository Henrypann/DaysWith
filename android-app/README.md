# DaysWith 原生 Android

原生 Kotlin/Compose 客户端，版本 2.2.7；当前跨平台开发入口是 `flutter/jinbao365_app`。保留原包名、Room 和存储格式以支持 Flutter 覆盖升级。

需要 JDK 17、Android SDK 37 和 Build Tools 36.0.0：

```sh
./gradlew testDebugUnitTest assembleDebug
```

本机 SDK 配置放在被忽略的 `local.properties`；签名、COS、升级和测试桶约定见 [完整 onboarding](../docs/ONBOARDING.md)。`preview` 包使用 `.preview` 后缀，但仍需独立测试桶防止云端误操作。

公共版本用通用品牌启动页替代私人家庭插画；原有用户数据没有因此删除。
