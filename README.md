# wallpaper-engine-ui-fix

> Fix Wallpaper Engine not opening - no tray icon, main window never shows up.

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D6)](#)
[![Shell](https://img.shields.io/badge/shell-PowerShell%205.1%2B-5391FE)](#)
[![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)](#)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

Wallpaper Engine 的界面（`wallpaperui.exe`）由一个内置的 Chromium（`libcef.dll`）渲染。在部分显卡 / 驱动组合下，UI 的**硬件加速**路径会让 `wallpaperui.exe` 一启动就崩（异常码 `0x80000003`）。表现就是：后台服务还活着，但**托盘图标不出来、主窗口也打不开**，壁纸跟着消失。

这个脚本把 UI 硬件加速关掉，并给 CEF 加上 `--disable-gpu`，然后重启 Wallpaper Engine。

## 症状对照

| 现象 | 是否是本工具能修的 |
| --- | --- |
| 托盘没有 Wallpaper Engine 图标，主窗口双击不出来 | ✅ 能修 |
| 进程列表里只剩 `wallpaperservice64`，`wallpaperui` 起不来或起来就退 | ✅ 能修 |
| 只有 Web 类壁纸黑屏、报错 | ❌ 那是缺 WebView2，装 WebView2 Runtime |
| 托盘有图标，但壁纸被暂停了 | ❌ 右键托盘图标，取消「暂停 / 静音」 |

## 用法

1. 下载本仓库，解压到一个固定目录。
2. **右键 `run-fix.bat` → 以管理员身份运行**（停止服务需要管理员权限，脚本会自动提权）。
3. 窗口里会显示自动检测到的安装路径、将要做的改动，然后停服务、备份配置、打补丁、重启。
4. 看到 `[ok] Done. Check the system tray...` 后，看右下角托盘有没有 WE 图标、壁纸回来没有。

只想先看看会改什么、不实际动手：

```powershell
.\fix-wallpaper-ui.ps1 -DryRun
```

### 参数

| 参数 | 说明 |
| --- | --- |
| `-InstallDir <path>` | 手动指定 Wallpaper Engine 安装目录（自动检测失败时用） |
| `-ConfigPath <path>` | 直接指定要改的 `config.json`（优先于自动检测） |
| `-DryRun` | 只报告会改什么，不碰任何文件和服务 |
| `-FileOnly` | 只改 `config.json`，不停服务、不重启 |
| `-NoRestart` | 改完不重启 Wallpaper Engine |

示例：

```powershell
# 预览
.\fix-wallpaper-ui.ps1 -DryRun

# 正常修复（管理员）
.\fix-wallpaper-ui.ps1

# 安装目录不在默认位置
.\fix-wallpaper-ui.ps1 -InstallDir "D:\SteamLibrary\steamapps\common\wallpaper_engine"
```

## 它到底改了什么

只改 `config.json` 里的两个值（其余内容一个字节都不动）：

```jsonc
// 关掉 UI 的硬件加速
"uihardwareacceleration" : false

// 给内置 Chromium 加禁用 GPU 的参数
"cefcommandline" : "--disable-gpu"
```

改之前会自动备份成 `config.json.bak.<时间戳>`，想还原直接拿备份覆盖回去。

## 为什么是这个原因

排查这条链路的顺序（也是本工具的判断依据）：

1. **它不是程序崩溃**。`wallpaper64.exe` 和 `wallpaperservice64` 进程可能都在，只是界面进程 `wallpaperui.exe` 起不来。
2. **不是缺 WebView2**。WebView2 只影响 Web 类壁纸，装了也未必能解决界面崩溃。
3. **去 Windows 事件日志看崩溃模块**才是有效的一步。日志里会明确写出崩溃的模块是 `libcef.dll`，异常代码 `0x80000003`（断点 / 断言）。`libcef.dll` 是 Wallpaper Engine 内置的 Chromium，UI 全靠它渲染。
4. **验证假设**：手工用 `--disable-gpu` 启动 `wallpaperui.exe`，进程能稳定存活，说明崩在 GPU 硬件加速路径上。
5. **固化成配置**：把上面两个值写进 `config.json`，让每次启动都走禁用 GPU 的路。

> 崩溃模块是 `libcef.dll` 时，先怀疑 GPU 硬件加速，再去查显卡驱动。这条路在多个「界面打不开、后台还在跑」的案例里都成立。

## 注意

- 需要管理员权限才能停止 Wallpaper Engine 的 Windows 服务，`run-fix.bat` 会自动请求提权。
- 关闭 UI 硬件加速后，界面滑动可能有极轻微的掉帧——这是关掉 GPU 渲染的正常代价，壁纸本身的渲染不受影响。
- 脚本是幂等的：已经打过补丁的配置再跑一次不会有任何改动。
- 如果修复后仍然崩溃，问题可能在显卡驱动，建议更新到最新版驱动；显卡驱动更新后如果复发，重跑一次本脚本即可。

## 免责声明

本工具只修改 Wallpaper Engine 自己的 `config.json`，并在修改前自动备份。请自行确认适用于你的环境。Wallpaper Engine 是 Kristjan Skutta 的产品，本工具与其官方无关。

## License

[MIT](./LICENSE)
