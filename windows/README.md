# 搞机灵 Windows 版

面向 Windows 10/11 x64 的独立版本。营销版本与当前 Mac 版同为 **1.16**，Windows 构建号为 **1**，界面和 `--version` 打印 `1.16+1`。Mac 版的 Swift 源码、签名、Bundle ID 和 `VERSION` 都不改。

界面在本机浏览器中打开。服务只监听 `127.0.0.1`。

## 选型

使用 **Python 3.12 标准库** 实现业务，界面是随程序打包的本地网页，安装包用 **PyInstaller** 在 `windows-latest` 上打成单个 exe。这与搞研究、搞节奏的 Windows 版相同。

Mac 版依赖 SwiftUI、AppKit、IOKit 和菜单栏。那些接口不能在 Windows 上原样运行。业务规则、资料校验和安全边界放在 Python 里，浏览器负责十个页面。没有做成 WinUI 或 Electron。

## 构建

在 Windows 10/11 x64 上安装 Python 3.12，然后：

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

脚本会安装开发依赖、运行单元测试，并在 `windows/dist/` 生成：

- `GaoJiLing.exe`：打开界面的窗口程序
- `GaoJiLing-cli.exe`：命令行，用于查看记录条数

GitHub Actions 工作流 `.github/workflows/windows.yml` 在 `windows-latest` 上执行同一套步骤。打包之后会用临时目录后台启动 `GaoJiLing.exe`（`--serve --no-browser --port --data-dir`，不打开浏览器），确认进程没有提前退出，轮询到本机 HTTP 200，再写入并读回一条名为 `CI smoke` 的任务，然后结束进程。两个 exe 作为 artifact `GaoJiLing-Windows-1.16` 上传。这个工作流不会创建 GitHub Release，也不会安装到运行器之外的电脑。它不替换、也不关闭 Mac 的构建。

只跑测试：

```powershell
cd windows
python -m pip install -r requirements-dev.txt
python -m pytest -q
```

在 Linux 或 macOS 上也可以跑同一套测试。开发时启动界面：

```sh
cd windows
PYTHONPATH=src python3 launch.py --data-dir /tmp/gaojiling-dev --no-browser --port 8765
```

然后用浏览器打开 `http://127.0.0.1:8765/`。

## 运行

不需要安装程序。把 `GaoJiLing.exe` 放到任意文件夹，双击运行。程序会打开系统浏览器。关闭浏览器标签不会结束进程；需要结束时，在任务管理器中结束 `GaoJiLing.exe`，或调用本机的关闭接口。这个 exe 没有 Authenticode 签名，也没有公证。

资料目录：

`%APPDATA%\GaoSeries\GaoJiLing\`

也可以用环境变量 `GAOJILING_DATA_DIR` 或参数 `--data-dir` 改到别的目录。数据库打不开、设置行损坏、清理或交接记录对不上时，程序停止写入，不用空资料覆盖。

| 参数 | 作用 |
| --- | --- |
| `--data-dir` | 资料目录。不设时使用 `%APPDATA%\GaoSeries\GaoJiLing\` |
| `--serve` | 启动只监听 `127.0.0.1` 的本地服务。无其他命令时也会启动服务 |
| `--no-browser` | 不调用系统浏览器 |
| `--port` | 服务端口。`0` 表示由系统分配 |
| `--inspect` | 只打印采样、事件、任务的条数，不打印名称或路径 |
| `--version` | 打印 `1.16+1` |

## 数据

| 位置 | 内容 |
| --- | --- |
| `monitor.sqlite` | 与 Mac 版相同的四张表：`samples`、`events`、`sessions`、`preferences`。`t` 列是 Unix 秒，JSON 里的日期是 Cocoa 秒（自 2001-01-01 UTC 起） |
| `panel.json` | 悬浮位置的竖向比例，以及可选的横向比例 |
| `Cleanup/journal.json` | 清理恢复记录。这是业务资料，不是备份 |
| `Duplicates/journal.json` 与 `Duplicates.initialized` | 重复文件恢复记录 |
| `Uninstall/journal.json` | 独立目录移入废纸篓的记录 |
| `Exchange/inbox.json` 与 `Exchange.initialized` | GaoAction 收件箱 |

Mac 上监控库位于 `~/Library/Application Support/GaoSeries/GaoJiLing/`。Windows 不会读取那个 macOS 路径。可以把 `monitor.sqlite` 复制到上面的 Windows 目录再打开；两边不要同时写入同一份文件。完整 JSON 备份的格式字符串是 `com.gaoseries.GaoJiLing.backup`，schema 1，SHA-256 是完整性校验，不是签名。恢复前不会自动做一份备份。

满 7 天（可在 1–30 天之间调整）的采样和事件会删掉。超过 24 小时的采样按分钟只保留最早的一条真实记录，不补造中间的点。任务记录不随这个保留期删除；可以在数据页按类别单独清除。

## 功能对齐

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 十个页面：概览、应用、回看、任务、网络、清理、存储、维护、应用管理、交接 | 已对齐 | 浏览器里切换。设置页有模块设置、外观、数据、关于 |
| 采样、异常事件、任务峰值和中断 | 已对齐 | CPU 持续 30 秒超过 85%、内存压力、磁盘、散热和 Swap 的规则与 Mac 相同。采样空档超过 15 秒会重新计时，不把休眠补进去。未正常结束的任务用最后一次真实采样收尾，并标成中断 |
| 全机 CPU 0–100%，初次基线不显示 0 | 部分 | Linux 采样按这个口径计算。Windows 的整机 CPU 用 `GetSystemTimes`，第一次没有基线时留空。进程列表目前只列出名称，不打开进程句柄，CPU 不填 0 |
| 内存、磁盘、电池、传感器 | 部分 | 读不到就显示不可用，不填 0。Windows 内存压力是按负载估算的，来源文字写明它不是 macOS 内存压力。温度、风扇、GPU、功率没有已验证接口 |
| 历史回看和空档 | 已对齐 | 最近 24 小时。空档单独标出，不连成一条假曲线 |
| CSV 与完整 JSON | 已对齐 | CSV 为 UTF-8 BOM、CRLF，公式前缀会被中和。备份超过 256 MB、摘要不符或版本不是 1 时拒绝，原库不动 |
| 恢复不自动备份，横向位置不被侧边选择覆盖 | 已对齐 | 备份里没有横向比例时，保留本机已经保存的横向位置 |
| 清理候选、7 天缓存、30 天轮转日志、恢复记录 | 部分 | 规则、默认不选、先写记录再移动、不覆盖、不把废纸篓字节说成已释放空间，这些都在。Windows 路径是 `%LOCALAPPDATA%` 下的反向域名缓存，以及 npm、pip、Poetry、Gradle 的已知缓存。没有 Xcode，也不会去扫 Visual Studio 中间目录。归属或进程状态不能确认就跳过 |
| 存储分析、排除目录、30 次同范围比较 | 已对齐 | 只读元数据，不跟随符号链接，不跨卷，不删除。未完成扫描不画成增减。Docker 目录不往下走进虚拟机磁盘 |
| 重复文件 | 已对齐 | 必须另行确认才读内容。大小、分段摘要、完整 SHA-256 和逐字节确认。硬链接只计一次。每组至少留一个。文档、数据库、系统目录和搞系列资料只展示或跳过。相似图片不做 |
| 本机卷 | 部分 | Windows 用 `GetDriveType`。可移除、网络、光驱和未知类型不读容量，缺项保持空白。它分不出“报告为固定盘的外接盘”和内置盘 |
| 普通 NTFS 镜像 | 部分 | 单选 `.ntfs/.img/.raw/.dd` 并再次同意后，只读、有界地看 MFT 文件名链。可提取明确的驻留默认数据流到新文件，不覆盖。不挂载、不修复、不打开原始设备。非常驻、压缩、加密、稀疏和命名流不提取。父路径不是完整目录索引 |
| 网络诊断 | 已对齐 | 只有点击后才做 DNS、网关探测和指定主机的 HTTPS HEAD。不接受带协议或路径的输入 |
| 维护页来源与过期 | 部分 | 采样结果带来源说明。读失败保留“不可用”，不造数 |
| 电池提醒与风扇 | 未实现写入 | 电量能读到就显示。不写充电上限，不控制风扇，也不把通知当成充电控制 |
| 自动退出 | 部分 | 策略与 Mac 相同：默认关闭，前台、保护名单、保存状态不明、冷却和观察间隔都会跳过。Windows 读不到未保存状态，必须本人标明“已确认没有未保存内容”才会继续。真正退出只对可见窗口发送 `WM_CLOSE`，不使用强制结束 |
| 应用管理 | 部分 | 注册表卸载项只展示厂商命令，不代为执行，不改注册表。用户选定的独立目录可以在确认进程已退出后移入废纸篓，并按记录恢复，不覆盖新文件 |
| GaoAction | 已对齐接收规则 | manifest 1MiB，条目合计 256，载荷声明 2GiB，有效期 120 秒。只接收 `storage.inspect`、`cleanup.review`、`apps.uninstall.review`。打开页面是 pending，不是 completed。相同请求不重复执行，内容变了就拒绝 |
| 本进程内存回收 | 部分 | 读数失败则什么都不做。Windows 没有 `malloc_zone_pressure_relief`，只尝试收缩本进程工作集，且不把前后差值称作释放量 |
| 系统文件缓存回收 | 未实现 | 没有与 `/usr/sbin/purge` 对应、可以固定调用的工具。不申请管理员权限，也不分配内存制造压力 |
| 悬浮面板的吸附、宽限和外部点击 | 部分 | 几何和收回状态机与 Mac 相同，但只作用于页面里的紧凑读数。没有桌面边缘的常驻竖线，也没有全局热键 |
| 登录启动、通知、菜单栏、`⌘,` | 未实现 | 设置里的开关会保存。不写启动项，不弹 Windows 通知，没有菜单栏图标 |
| 深浅色 | 已对齐 | 跟随系统、浅色或深色 |

## 已知限制

- 关掉浏览器标签不会退出进程。
- 扫描和镜像解析的时间、条目上限在两次系统调用之间才生效，不能打断已经发出的调用。
- Windows 上移入废纸篓调用 `SHFileOperationW`，并且固定带上“允许撤销”。系统没有确认回收站里的新路径时，操作停止，不会改成永久删除。Linux 上的测试使用注入的移动，不调用这个 Windows 接口。
- 同一份 `monitor.sqlite` 不要同时被 Mac 版和 Windows 版打开写入。
- 完整备份的 SHA-256 按排序后的 JSON 重新计算。摘要不符就拒绝恢复。
- 这个目录里的程序不会上传监控、清理或镜像报告。CSV 和报告里有本机路径，不要放进公开仓库或 Release。
