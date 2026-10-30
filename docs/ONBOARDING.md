# DaysWith 开始使用与开发

## 1. 准备环境

先阅读根目录 README 的平台现状。Flutter 是当前客户端入口；原生工程仍保留，不应把历史原生版的验收结论作为 Flutter 版的验证结果。

- Flutter 所带 Dart 必须满足各 `pubspec.yaml` 的 `^3.13.7`；仓库未固定 Flutter SDK 版本，先核对 `flutter --version`。不要通过降低约束掩盖依赖不兼容。
- Android：JDK 17、Android SDK Platform 37、Build Tools 36.0.0。通过本机 `local.properties` 的 `sdk.dir` 或 `ANDROID_HOME` 配置 SDK。Gradle wrapper 下载依赖需要网络或已准备的缓存。
- iOS：macOS、Xcode、CocoaPods，目标 iOS 16+。模拟器无需真机分发签名；真机和覆盖升级需自己的签名团队及正确 provisioning。
- Release 签名沿用 `JINBAO_RELEASE_STORE_FILE`、`JINBAO_RELEASE_STORE_PASSWORD`、`JINBAO_RELEASE_KEY_ALIAS`、`JINBAO_RELEASE_KEY_PASSWORD`，仅在本机或私有 CI 中设置；不将 keystore、密码或 `local.properties` 提交。

## 2. 开发与检查

```sh
cd flutter/jinbao_core
dart pub get
dart analyze
dart test
cd ../jinbao365_app
flutter pub get
flutter analyze
flutter test
flutter run
```

Flutter 默认为测试构建（`JINBAO_TEST_BUILD=true`），使用 `life/v1/test/`，可在连接页使用占位模式进行本地界面检查。真实连接会发出网络请求，不等于无副作用沙箱。不要在本轮切换正式家庭写入。

原生 Android 验证：

```sh
cd android-app
./gradlew testDebugUnitTest assembleDebug
```

缓存完整时可加 `--offline`；Robolectric SDK 的缓存另受测试运行器管理，Gradle 离线不保证测试运行时无需网络。可用 `ROBOLECTRIC_DEPENDENCY_DIR` 指定准备好的 SDK jar 目录。

Swift 核心检查在有 Swift 工具链的机器上运行：

```sh
cd ios-app
swift test
```

iOS UI、Keychain、媒体授权和覆盖升级需在 Xcode/模拟器或隔离真机执行。`flutter build ios --release --no-codesign` 只能验证编译，不能替代安装或运行验收。禁止将测试日志、设备资料和截图原样提交到公共仓库。

## 3. 首次运行

1. 选择本机固定署名「爸爸／妈妈」，确认后当前界面不能改。情侣场景的自定义姓名尚未实现。
2. 进入云连接页，输入自己控制的 COS 桶名、地域、密钥编号和密钥。未提供共享的生产桶或默认密钥。测试构建可使用占位连接；空表单在占位模式中只生成合成桶/地域元数据，不保存密钥、不发起上传，真实连接仍要求用户填写自己的桶。正式流程仍要求云连接，不能宣传为完整离线首次使用。
3. 验证连接后创建一条合成文字或媒体记录，观察备份状态，再在隔离设备检查云端读取。
4. 新档案的纪念日是三个虚拟公共节日。编辑后才保存用户覆盖项，删除保存 tombstone；重复打开或初始化不会新增数据库行。

节日采用模型既有的 `0004-MM-DD` 无年份哨兵（年份 4 是闰年），不把它解释为出生年。三个新固定 ID 与私人旧预置 ID 分离：未编辑的旧虚拟预置不再出现；已有用户保存、删除、迁移或云端读取的旧记录仍按普通记录保留，不用公共节日覆盖。没有执行用户档案清理或历史重写。

## 4. 自有 COS 和凭据

使用独立私有测试桶，不要公开读写。`example-1234567890` 等仅是合成测试字符串。地域必须与自己桶的实际地域一致；界面的地域初值只是可编辑提示，不构成生产配置。

应用直接向 COS 发出签名 HTTPS 请求，读取清单和媒体、写入记录链/快照/对象，并在验证连接时执行所需探测；并非通过 DaysWith 托管服务器中转。对象权限需要允许客户端实际执行的列举、读、写及相关探测，按选定路径授予最小必要权限；不要使用云账号主密钥或向所有桶授权。原生 Android 与 Flutter/Swift 对临时 token 的支持不同，应按运行客户端验证；不要宣传统一的 STS 服务或自动续期。

密钥在手机连接界面输入。Flutter 使用安全存储；Android 兼容旧版 Keystore 加密连接，iOS 兼容原 Keychain service，保护级别 `WhenUnlockedThisDeviceOnly`。凭据不应进入档案 JSON、日志、测试附件、issue、截图、命令行参数或版本库。断开连接不代表自动删除云端内容，也不撤销已经发出的云密钥；撤销和轮换需要在自己的云账号执行。

## 5. 数据流与权限边界

本机选择媒体/写文字 → 本地档案与媒体目录 → 校验并排队 → 前台网络条件允许时传 COS → 其他设备刷新读取。预览与媒体对象分开保存，不能只复制记录清单就视为完整备份。

| 内容 | 路径 |
| --- | --- |
| 正式设备记录链/快照 | `life/v1/<dad或mom>/<deviceID>/` |
| 同身份共享媒体对象 | `life/v1/<dad或mom>/objects/` |
| 测试设备记录链 | `life/v1/test/<deviceID>/` |
| 测试共享媒体对象 | `life/v1/test/objects/` |

测试共享对象不按设备隔离，不能依靠设备 ID 防止误写同桶；用独立测试桶与云端权限共同隔离。旧根目录读取保留兼容，不移动或删除旧对象。

档案与媒体中可能含文字、原始文件名、拍摄时间、位置与原图 EXIF。只有选择媒体才导入；系统相册/相机授权按客户端和系统版本申请，缺少地点信息不应阻止记录。不要假定所有平台均已通过部分照片授权或视频全流程验收。

本机可编辑自己的记录；其他身份和其他设备的云端记录通常只读。相同身份和同桶本身不是安全授权，云端 IAM 才控制谁能访问。当前没有任意成员权限管理或端到端加密；COS 服务端加密也不能替代端到端加密。

## 6. 备份、恢复与升级

备份状态描述本机传输，不证明另一台设备已刷新。前台传输、校验和失败重试已有实现，但不承诺锁屏、后台或进程被杀后持续传输。云端读取不等于完整恢复到新设备并继续编辑。

本地档案读取失败时提供重新读取/恢复有效副本；恢复副本不代替媒体文件或独立备份。回收站只覆盖实现支持的删除恢复，不是无限期历史版本。请保留原手机和独立原文件副本，直到在隔离设备核验媒体数量、哈希、文字、纪念日和编辑权限。

Android Flutter 覆盖升级读取旧原生身份、设备 ID、Room 和媒体，校验后写入 Flutter 档案；旧源保留，已有 Flutter 档案不重复迁移。迁移的旧数据不自动继承备份任务。iOS 沿用 `Application Support/Jinbao365/`，读取旧 Keychain；不能更改 package/bundle ID、Keychain service 或存储路径来完成改名。覆盖安装还必须使用原签名，实际迁移需另做平台验收。

## 7. 公开之前

按 [公开前审查](OPEN_SOURCE_REVIEW.md) 完成测试、历史与二进制附件检查、密钥轮换判断、图像来源与许可核对。本地修改不会自动让旧仓库历史变得可公开。不要把家庭数据用于 demo、issue 或公开真机验收。
