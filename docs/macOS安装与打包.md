# macOS 安装与打包

适用于当前本地开发版：生成、安装 Mac Release App，并按用户选择将 kited 安装成当前用户的后台服务。暂不发布到公共下载渠道；安装包尚未进行 Developer ID 签名与 Apple 公证。

## 从源码一键安装

在仓库根目录运行，或在 Finder 双击 `install.command`：

```bash
./install.command
```

完整 App 的构建机需要 Apple Silicon Mac、macOS 26 或更新版本、完整 Xcode、Go、Git 和网络。首次使用 Xcode 应先打开它完成初始化；提示缺少 Metal Toolchain 时运行 `xcodebuild -downloadComponent MetalToolchain`。

入口自动准备项目工具与依赖，构建并安装 Release App，成功后打开。所需 Bun 经过下载校验并缓存于仓库内，不修改全局 Bun 或 shell 配置。所有安装操作使用当前登录用户，不使用 `sudo`。

工作机只需要后台服务时：

```bash
./install.command --service-only
```

该模式不编译或安装 App，因此不需要完整 Xcode；源码构建仍需 Go、Git 和 macOS 命令行工具，后者也用于首次读取 PDF 时编译转换程序。已安装的 App 不受仅服务升级影响。

## 生成 Mac 安装包

```bash
./package-mac.command
# 仅服务安装包
./package-mac.command --service-only
```

也可使用 `./install.command --package`。只打包，不安装、启动或替换正在使用的服务。

产物在 `build/Kite-macOS-<架构>/` 和同名 `.zip`，仅服务版本使用 `kited-macOS-<架构>`。完整包包含 `Kite.app`、`安装.command` 和安装说明；可选服务运行目录嵌在 App 资源中。Bun、ripgrep、生产依赖、沙箱与 Claude 适配资源随包携带，安装后不依赖源码仓库，也不依赖打包机上的依赖目录。包中不含开发依赖、`.env`、登录凭据或用户数据库。

完整 App 仅支持 `arm64`。仅服务安装包按构建机架构生成 `arm64` 或 `x64`，不同架构分别构建。解压后双击 `安装.command`，目标机器需要 Git，完整包还需要 Apple Silicon Mac 和 macOS 26 或更新版本；无需安装 Bun、Go 或完整 Xcode。缺少 Git 时先运行 `xcode-select --install`。安装成功后可移走解压目录与源码仓库。

App 使用临时签名，打包时验证签名完整性。此签名适合本机使用，不代表获得 Apple 信任；跨机器传送后可能被 Gatekeeper 拦截。正式分发前还需配置 Developer ID 签名、公证并验证整个安装包，不通过移除隔离属性或关闭安全检查绕过。

## 安装位置与生命周期

| 内容 | 默认位置 |
|---|---|
| Mac App | `~/Applications/Kite.app` |
| 服务运行文件与安装记录 | `~/Library/Application Support/Kite/` |
| 登录自启配置 | `~/Library/LaunchAgents/com.sainner.kited.plist` |
| 命令入口 | `~/.local/bin/kite`、`~/.local/bin/kite-service` |
| 标准输出、错误日志 | `~/Library/Logs/Kite/kited.log`、`kited.error.log` |
| 自动更新的暂存与安装日志 | `~/Library/Application Support/Kite/updates/` |
| 数据与模型登录 | `~/.kite`，沿用 `KITE_HOME` |

完整包初次安装只复制 App。首次配置时选择本机执行才安装 kited；仅远程控制不安装服务。服务由当前用户的 launchd 托管，安装后立即启动、登录后自动启动，进程退出后会重新拉起；退出 Mac App 不停止服务。它只监听 `127.0.0.1`，默认端口 5483。各设备登录 Tailscale 入网，组网与授权见 [身份与设备](身份与设备.md)。launchd 的用户 Agent 生命周期参考 [Apple 官方说明](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)。

后台环境显式提供随包的 Bun 与 ripgrep（代理的 shell 用它搜索）、常见开发工具目录和用户的 `~/.local/bin`，不读取 shell 配置，也不保存发起安装的终端中的密钥或代理环境。项目使用额外工具链时，仍须让其在这些路径中可访问。

首次使用模型需在这台工作机完成设备登录，见 [工作机授权说明](kited.md#终端试用)。安装包不携带其他机器的登录。App 的本机执行模式使用本机 5483；自定义端口的独立服务目前不由 App 初始配置管理。

## 管理、升级和卸载

```bash
~/.local/bin/kite-service status
~/.local/bin/kite-service restart
~/.local/bin/kite-service stop
~/.local/bin/kite-service start
~/.local/bin/kite projects
```

`stop` 停止当前服务，保留登录自启。`status` 显示系统中的服务状态；安装、启动和重启在 HTTP 接口可用后才报告成功。`~/.local/bin` 已在 PATH 中时可省略路径；安装器不会自动修改 shell 配置。

手动升级前结束正在执行的任务并退出已安装的 App，然后重新运行源码安装入口或新安装包中的 `安装.command`；其他工作机随后自动跟上，见 [自动更新](#自动更新)。后台服务升级失败时恢复旧运行文件和自启配置。新装的 App 第一次启动时，本机执行模式把它带的服务装上；此后服务以发布的版本为准，App 不再用自己带的旧版覆盖。沿用数据、凭据及安装记录中的路径和端口；这是运行文件回退，不是数据库或业务副作用回退。已有同标识的手工 launchd 服务可以被替换；命令目录里若存在其他来源的 `kite`，安装器会报出冲突，须先自行移走或指定其他命令目录。

如果安装了 kited，退出 App 后卸载服务：

```bash
~/.local/bin/kite-service uninstall
```

移除服务运行文件、命令入口和登录自启，保留数据库、工作区、对话、登录及日志。App 可从安装目录移到废纸篓；仅远程控制模式直接移除 App 即可。

## 自动更新

各工作机的 kited 跟着最近一次发布的版本走，不经服务器。原则与兼容边界见 [分布式架构](分布式架构.md#版本)，App 的锁定见 [App](App.md#版本)。

- **版本。** 打包时按运行文件的内容生成构建号，并记下协议号与源码提交。构建号相同就是同一份运行文件。
- **发布。** 在一台工作机上手动安装（源码安装入口、安装包，或新 App 第一次启动时装上它带的服务）就是发布：新服务起来并运行 30 秒后，把版本写进账号级数据，后写的为准。装回旧版同样是一次发布。源码前台运行的 kited 与检查起的实例没有安装记录，不发布也不更新。
- **传播。** 其他工作机同步到新的发布后，从组网里正在运行这一版的工作机取运行文件：先取文件清单与哈希，本机已有的相同内容直接复用，其余按段传输（小文件凑成一批、大文件切段，几路同时取，卡住的换连接重取，见 [分布式架构](分布式架构.md#组网与发现)），逐个校验后放进暂存目录。只在平台与架构都相同的工作机之间传播；不同的工作机标为需要手动安装。
- **换上。** 准备好的新版等这台工作机空闲才换：没有进行中的回合、运行中的终端与后台命令、准备中的工作区、进行中的流转、工作区操作与项目操作。App 的设备页列出在等什么，用户可以选择现在更新、打断它们。换的时候 kited 起一个脱离服务进程组的安装进程，由它停掉服务、换上运行目录、再启动；新服务 15 秒内没有就绪，或就绪后 20 秒内退出，就恢复旧运行文件并记下失败。失败的版本不再自动重试，手动安装可以覆盖。服务停止与重启不算离开，不触发换机。
- **Mac App。** 服务由 App 装上的 Mac，同时从运行这一版、服务也由 App 装上的工作机取 App 的文件，在暂存目录组好新 App 并校验签名；本机服务换上这一版之后，App 才提示重启以更新，用户确认后替换并重新打开。Debug 版不带服务，不提示更新。

## 自定义位置

首次安装可设置下列环境变量。路径均可包含空格；数据目录必须位于服务安装目录之外。

| 变量 | 用途 |
|---|---|
| `KITE_HOME`、`KITE_PORT` | 数据目录和服务端口；升级时可显式修改，否则保留 |
| `KITE_INSTALL_ROOT` | 运行文件与安装记录目录；后续命令入口会记住它 |
| `KITE_APPLICATIONS_DIR` | 放置 `Kite.app` 的目录 |
| `KITE_BIN_DIR` | `kite` 和 `kite-service` 命令目录 |
| `KITE_LOG_DIR` | 服务日志目录 |
| `KITE_SERVICE_LABEL` | launchd 服务标识，默认 `com.sainner.kited` |
| `KITE_LAUNCH_AGENTS_DIR` | 自启配置目录；只有用户的 `~/Library/LaunchAgents` 会被系统在登录时自动读取 |
| `KITE_NO_OPEN=1` | 安装后不打开 App，适合手动验证 |

安装记录存在后，除显式指定的数据目录和端口外，管理和升级沿用已保存的位置。修改其他位置应先卸载再安装；不要手动移动运行目录。验证独立实例时，安装目录、数据、端口、服务标识、命令目录、App 目录、日志和 plist 目录均应与日常实例分开。
