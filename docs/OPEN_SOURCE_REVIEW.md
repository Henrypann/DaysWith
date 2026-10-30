# DaysWith 公开前审查

本次只做本地准备，未推送、发布、合并、修改仓库可见性或重写旧历史。

## 仓库与导入边界

核实的目标 `Henrypann/DaysWith` 初始提交仅包含 README。最终准备分支在独立 Git 目录中直接基于该提交，导入脱敏后的源文件快照；不继承旧工作区的历史或对象库。

未导入历史 `docs/`、`artifacts/`、品牌评审附件和家庭真机截图。设计 token 是测试必要的通用颜色/间距合同，单独保留。应用标识与当前 launcher 图片均使用代码生成的通用几何占位，框架标准模板资源按原许可保留；见 [图像来源](asset-provenance.json)。移除了私人家庭读档案/生日截图专用 Android 验收文件与私有设备交换脚本。旧原件仍留在私人源目录。

## 已完成

- Flutter、Swift、原生 Android 三套默认纪念日统一为儿童节、国庆节、元旦，无年份哨兵沿用现有模型。
- 新节日使用新固定 ID；用户旧保存项、覆盖项和 tombstone 不被公共预置覆写；未触碰的旧虚拟默认项不再显示。
- 去掉固定儿童生日和年龄显示；年龄计算仅接受显式日期，当前没有提供生日配置界面。
- 默认 COS 桶名为空，恢复仍优先读取已有用户连接；合成测试显式配置示例桶。
- 产品显示名称、README 和 onboarding 更新；package/bundle ID、Keychain service、协议身份、存储路径、签名变量名保持兼容。
- `.gitignore` 覆盖密钥文件、签名材料、环境配置、构建产物和私有附件，不再误忽略应公开的源码与合成测试合同。

## 验证

2026-10-30，在 Linux 云环境执行原生 Android：

```sh
JAVA_TOOL_OPTIONS=-Duser.home=/workspace/.java-home \
ANDROID_USER_HOME=/workspace/.android \
GRADLE_USER_HOME=/workspace/.gradle \
JAVA_HOME=/workspace/.jdk17 \
ANDROID_HOME=/workspace/.android-sdk \
android-app/gradlew -p android-app -Duser.home=/workspace/.java-home \
  testDebugUnitTest assembleDebug --offline -Pksp.incremental=false
```

结果：**674 项通过，0 失败，0 跳过，Debug APK 构建成功**。本机路径只描述此次缓存环境，其他机器按 onboarding 配置。关闭 KSP 增量用于避开一次本地缓存损坏；前序失败已修复并重跑。

覆盖公共节日无年份/跨年、重复显示、用户覆盖/删除、旧固定 ID 保存记录保留，以及无隐含生日；已有合同、备份、Room 和 UI 单测一并执行。Dart 与 Swift 增补同类升级保护用例，但本机没有 Flutter/Dart/Swift 工具链，**未运行**；Flutter Android 桥接测试、iOS 编译、真机 UI、签名覆盖升级及真实 COS 操作也**未运行**。不得把原生 Android 的结果解释为 Flutter/Swift 全平台验收。

不运行真实家庭桶测试。原始构建日志与生成截图留在本机被忽略目录，不随公共提交上传。汇总结果见 [validation.json](validation.json)。

## 仍需完成的隐私与发布检查

1. 本次检查覆盖导入文件中的已知私人姓名/生日/桶配置、常见密钥模式与可公开文件类型；没有声称完成所有历史与附件的机密检测。旧仓库历史包含私人默认值与验收资料，应继续保持私有，不能因工作树脱敏就直接公开旧仓库。
2. 发布前对最终待推送分支运行独立 secret scanner，检查所有 Git blob、LFS、release 附件、issue、截图、媒体 EXIF 和二进制产物。若确认真实凭据曾进入任何可访问历史或附件，先撤销/轮换；删除当前文件不能撤销密钥。本次没有添加外部持久凭据，也没有操作云账号。
3. 最终图像由独立生成的几何占位与经过官方包字节校验的 Flutter 模板组成。所有代码贡献及第三方依赖/Gradle wrapper 的版权与许可仍需按其原条款保留，不能用主许可证覆盖第三方义务。
4. Flutter/Dart 和 Swift 检查、两平台覆盖安装、凭据兼容、部分照片授权、回收站恢复和隔离 COS 端到端验收尚待有对应工具链/设备的环境执行。
5. 确认当前产品仍是爸爸/妈妈固定身份；情侣可自定义署名、通用成员、实时协作、通用存储服务、端到端加密、完整换机继承均不可作为已实现能力宣传。

## 许可证与范围

用户已选择 MIT。本次加入标准完整 [MIT License](../LICENSE)，版权标识为 `2026 Henrypann`。原始源码和项目文档按 MIT 提供，第三方组件保留自身许可与版权声明。原始品牌权利不随源码授权；标准模板图片保留其第三方许可，通用几何占位由项目脚本独立生成，详见 [NOTICE](../NOTICE.md)。个人档案、照片、凭据与身份权利不属于项目演示或代码许可内容。

依据：[MIT 官方许可文本](https://opensource.org/license/mit)。
