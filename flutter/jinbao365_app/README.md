# DaysWith Flutter 客户端

当前 Android/iOS 开发入口。启动、SDK 前提、用户自有 COS、安全存储、备份限制与升级边界见 [完整 onboarding](../../docs/ONBOARDING.md)。

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

默认 `JINBAO_TEST_BUILD=true`，真实连接使用测试路径也会访问 COS。请使用独立私有测试桶。

## 4.0 新增

- 首次使用：介绍页 → 选择署名 → 连接 COS 或「先在这台手机记录」。本地优先的选择和宝宝档案保存在本机偏好设置里，不进入 `archive.json`，也不上传。
- 连接前留下的记录是 `localOnly`，不会自动上传。验证连接后，在「云备份」里确认「加入云备份」，它们才进入本机的备份范围（`AppSession.adoptLocalOnlyRecords`）；加入后不能改回仅本机。
- 宝宝档案（小名、生日）、每条记录的年龄标签、「那年今天」、回顾页拼图和成长卡片分享（`share_plus`）。
- `promo/` 是演示与宣传渲染：合成插画、虚构档案，以及在 `flutter test` 里逐帧导出视频的脚本，说明见 [promo/README.md](../../promo/README.md)。它不属于应用包。

为兼容已有用户，包名/bundle ID `com.henrypann.jinbao365`、iOS `Application Support/Jinbao365/`、Keychain service 和原生 Android 升级桥保持不变。覆盖安装需要原签名，不要卸载或清数据。当前两种固定身份仍是爸爸／妈妈；没有自定义情侣署名。
