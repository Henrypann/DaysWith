# DaysWith

**Keep the days we share. 留住一起度过的日子。**

用照片、视频和文字记录共同生活，在时间线里回看日常，记住重要的日子。

- **Days with you｜与你的日子**：旅行、普通的晚饭，以及两个人想留下的片刻。
- **Days with family｜与家人的日子**：相聚、成长，以及每个人眼中的日常。

这是产品面向的两种场景。当前实现仍使用固定的「爸爸／妈妈」身份和对应存储目录；尚未提供通用成员管理、邀请、情侣署名或实时多人协作。

## 当前代码

| 目录 | 现状 |
| --- | --- |
| `flutter/jinbao365_app` | Android/iOS Flutter 客户端，版本 `3.0.0+11`，当前开发入口 |
| `flutter/jinbao_core` | Dart 档案模型、合并合同、COS 客户端及备份队列 |
| `android-app` | 原生 Android 2.2.7 实现，保留兼容与迁移参照 |
| `ios-app` | 原生 SwiftUI 客户端及 Swift 核心，保留兼容与测试参照 |
| `spec/fixtures` | 合成测试向量，不含可用生产凭据 |

实现包括本地记录与草稿、媒体导入、时间线、纪念日、回收站及用户自有腾讯云 COS 连接。新安装仅提供儿童节（6 月 1 日）、国庆节（10 月 1 日）、元旦（1 月 1 日）三个年度纪念日；不预填私人生日。节日不显示虚构年龄或周年数。首页采用通用日期，不再内置某位孩子的出生日期。

COS 是用户配置的底层对象存储。当前没有其他存储服务适配、端到端加密或完整换机继承保证。云端可见内容与本机可编辑记录有边界；详见 [开始使用与开发](docs/ONBOARDING.md)。

## 快速开始

需要支持 Dart `^3.13.7` 的 Flutter SDK；Android 构建需要 JDK 17、Android SDK 37 / Build Tools 36.0.0，iOS 需要 macOS、Xcode、CocoaPods 和 iOS 16+。

```sh
cd flutter/jinbao_core
dart pub get
dart test
cd ../jinbao365_app
flutter pub get
flutter test
flutter run
```

首次运行选择身份，然后连接自己的 COS；测试构建也支持界面中的占位连接。默认桶名为空。不要使用真实家庭桶进行开发测试。详细前提、权限、路径与恢复限制见 [onboarding](docs/ONBOARDING.md)。

## 兼容与发布状态

DaysWith 沿用既有 package/bundle ID、Keychain service、档案路径及 `dad`/`mom` 协议字段，避免改品牌造成旧档案失联。修改显示名称不等于已完成各平台覆盖升级验收；不要卸载旧 App 或清除原资料来测试升级。

本分支是公开前准备，不代表已发布或完成真机验收。检查结果、未完成项及许可范围见 [公开前审查](docs/OPEN_SOURCE_REVIEW.md)。源码与项目文档采用 [MIT License](LICENSE)，版权标识为 `2026 Henrypann`。第三方组件、品牌与图片的范围见 [NOTICE](NOTICE.md)。

独立复核的扫描范围、修复与限制见 [复核记录](docs/INDEPENDENT_REVIEW.md)。

应用标识使用代码生成的通用几何占位；标准框架图片来源与许可见 [图像清单](docs/asset-provenance.json)。
