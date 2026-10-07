# 搞机灵 V1.04

<img src="Assets/AppIcon.png" width="96" alt="搞机灵：黑底白字的机灵图标">

电脑的小动静，一眼就知道。

搞机灵是一款原生 macOS 边缘系统监控工具，使用 SwiftUI、AppKit、Mach/IOKit/libproc 和 SQLite。监控记录保存在本机，无第三方运行时，无 AI 和账号。

[下载最新版](https://github.com/UCASerYff/GaoJiLing/releases/latest) · [V1.04 发布页](https://github.com/UCASerYff/GaoJiLing/releases/tag/v1.04) · [使用说明](使用说明.txt) · [验证范围](VALIDATION.md)

## 安装

支持 Apple Silicon Mac，最低 macOS 14；当前安装包为 ARM64，不包含 Intel 版本。

从 GitHub Releases 下载 DMG，打开后将“搞机灵.app”拖入“Applications”。更新时先退出旧版，再替换应用；历史、任务和设置保存在独立的数据目录中。发布页同时提供安装包的 SHA-256 校验文件。

当前公开安装包使用本地 ad-hoc 签名，未作 Apple Developer ID 签名或公证，会受到 Gatekeeper 检查。也可以按下方步骤从源码构建。

## 功能

- **边缘面板**：可见细线支持点击、悬停呼出和拖动位置，可沿边及跨屏吸附，位置自动保存；支持菜单栏、全局快捷键和面板固定。
- **实时监控**：CPU、内存压力、压缩内存、Swap、网络与磁盘吞吐、应用排行，以及按机型可读取的传感器。
- **历史回看**：查看最近 24 小时趋势，定位异常事件前后的记录；较长的采样空档留白。
- **任务记录**：手动记录编译、渲染等工作的时长、平均与峰值指标，并导出结果。
- **数据管理**：按范围导出监控、事件和任务 CSV；完整 JSON 备份带 SHA-256 校验，恢复前自动保存安全副本；支持按类别清理记录。
- **日常设置**：主动网络诊断、登录启动、系统通知、深浅主题。独立设置窗口包含“模块设置、外观、数据、关于”。

主窗口左侧保留概览、应用、回看、任务和网络五个页面。点击右上角齿轮或按 ⌘, 打开设置；⇧⌘E 直达数据页。默认 ⌥⌘G 呼出面板，可在设置中切换为 ⌥⌘M。⌘W 关闭窗口后仍继续监控，⌘Q 完全退出。

## 数据与统计口径

本机数据目录：

    ~/Library/Application Support/GaoSeries/GaoJiLing/

普通监控不上传数据，也不读取浏览器历史、屏幕或剪贴板。网络诊断仅在主动执行时进行 DNS、默认网关探测和用户指定域名的 HTTPS HEAD 请求。备份与导出可能包含应用名称、任务名称和监控记录，请按自己的分享范围保管。

数据库默认保留 7 天，可在设置中调整。历史通常每 10 秒保存一次，较早记录按分钟降采样，因此导出记录数可能少于实时图表中的采样点。回看导出遵循所选时间范围；定位事件后，范围为事件前所选时长至事件后 5 分钟。

CPU 与应用 CPU 统一采用全机 0–100% 口径，与活动监视器的单进程百分比口径不同。缺失传感器显示不可用；异常规则提供观测线索，不保证判断因果。暂停、休眠或未运行期间不补造数据。

公开仓库包含源码、测试、图标及文档；运行数据、导出、凭据和构建中间产物不进入版本库。安装包及其校验文件通过 GitHub Releases 提供。

## 从源码构建

需要 Apple Silicon Mac、完整 Xcode 及其命令行工具、macOS 14 或更新 SDK，以及 Python 3。

    ./Scripts/test.sh
    ./Scripts/build.sh

构建输出为 Release/GaoJiLing-1.04.dmg 及对应的 .sha256 文件。构建使用专属临时目录，并在退出时清理。

如需使用项目安装脚本：

    ./Scripts/install.sh

脚本需要对 /Applications 有写权限。它会校验应用标识、版本和签名，暂存新应用，退出旧进程，替换应用并验证启动；成功后清理本项目的旧应用和过期安装包，保留用户数据与设置。

版本以 VERSION 文件为准。后续正式发布运行：

    python3 Scripts/bump-version.py

每次准确增加 0.01；同一未交付版本的修复和重新构建不递增版本。DMG 不提交到 Git 历史。

## V1.04

应用图标更新为黑底白字、竖排“机灵”，整理公开源码及发布文档。监控、回看、任务和独立设置延续 V1.03 行为。本版实际验证状态见 [VALIDATION.md](VALIDATION.md)。

## 致谢与第三方许可

部分采集实现参考 [Glance](https://github.com/lulu-loopp/glance)，部分传感器信息参考 [Stats](https://github.com/exelban/stats)。相关来源与 MIT 许可文本见 [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt)。这些许可声明适用于所列第三方内容，不代表本项目整体已采用 MIT 许可；项目当前未提供单独的整体授权许可文件。
