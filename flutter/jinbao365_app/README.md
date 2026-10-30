# DaysWith Flutter 客户端

当前 Android/iOS 开发入口。启动、SDK 前提、用户自有 COS、安全存储、备份限制与升级边界见 [完整 onboarding](../../docs/ONBOARDING.md)。

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

默认 `JINBAO_TEST_BUILD=true`，真实连接使用测试路径也会访问 COS。请使用独立私有测试桶。

为兼容已有用户，包名/bundle ID `com.henrypann.jinbao365`、iOS `Application Support/Jinbao365/`、Keychain service 和原生 Android 升级桥保持不变。覆盖安装需要原签名，不要卸载或清数据。当前两种固定身份仍是爸爸／妈妈；没有自定义情侣署名。
