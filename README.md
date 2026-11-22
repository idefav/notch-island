# NotchIsland · 菜单栏灵动岛

NotchIsland 是一个独立的 macOS 菜单栏工具。菜单栏太挤时，被刘海挤出可见区域的应用图标可以在刘海下方的浮层里重新访问。

[下载 DMG](https://github.com/idefav/notch-island/releases) · [报告问题](https://github.com/idefav/notch-island/issues)

## 体验

- **贴合刘海、全区触发。** 应用读取 macOS 提供的刘海尺寸，圆角外壳沿边外扩 1 pt。整个物理刘海区域（含屏幕上沿）均为触发热区，不再向下侵占其他应用窗口顶部；展开时顶部保持 T 形热区，刘海两侧菜单栏点击自动穿透。指针进入或打开时播放 Retina 清晰边缘流光，系统启用「减少动态效果」时使用短淡入淡出。
- **换行或滚动自由切换。** 默认采用「换行展示」多行自动排布（超过 4 行支持纵向滚动），鼠标悬停图标时在底栏即时显示真实应用名；右键岛面「图标排列」可切换回「横向滚动」（支持鼠标滚轮横向滚动）。固定面板后支持方向键切换图标，`Enter` / `Space` 打开原应用，`Esc` 或点击外部收起。
- **按习惯展开与全屏隐藏。** 默认开启「悬停展开」（移入 200ms 预览、移出 320ms 自动收起，点预览空白区或「固定面板」可常驻）与「全屏时隐藏」，右键（或 `Control + 左键`）岛面可随时调整，配置自动持久化。
- **极低待机能耗与合盖友好。** 通过 `NSTrackingArea` 替代全局鼠标移动监听，收起态不运行后台轮询定时器；未检测到刘海屏（如合盖外接显示器）时自动退居后台并在系统菜单栏显示临时退出入口。
- **可选开机启动。** 右键岛面可切换「开机启动」。默认关闭，开启后在登录 macOS 时启动。

## 安装

需要带实体刘海的 Apple Silicon Mac 和 macOS 26 及以上系统。使用外接显示器时，浮层仍在可用的刘海屏上显示。

1. 从 [Releases](https://github.com/idefav/notch-island/releases) 下载 `NotchIsland-<版本>-arm64.dmg`。
2. 打开 DMG，把 `NotchIsland.app` 拖到「应用程序」，再从「应用程序」打开。
3. 将鼠标移入刘海或点击刘海展开。需要读取真实图标或打开原菜单时，可通过面板的「授权设置」或右键菜单开启权限。

> 当前 Release 中的 DMG 为预览版，使用 ad hoc 签名，尚未经过 Apple 公证。macOS 可能拦截从网络下载的应用。遇到拦截时可从下文的「从源码构建」入口在本机生成应用。[Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

可选的文件校验方式。在同一目录下载 DMG 和对应的 `.sha256` 后运行下列命令，将版本号换成所下载的版本。

```sh
shasum -a 256 -c NotchIsland-0.2.2-arm64.dmg.sha256
```

## 权限和兼容性

| macOS 权限 | 用途 |
| --- | --- |
| 屏幕与系统音频录制 | 读取隐藏菜单栏窗口图标，自动还原暗淡透明度并适配浅色壁纸/浅色模式下的暗色图标。 |
| 辅助功能 | 反查真实应用归属并触发原生菜单，对自定义状态栏视图按外接屏镜像点击或唤起外层主应用兜底。 |

菜单栏窗口查询、图标处理和菜单请求均在本机完成。隐藏图标捕获在运行时通过私有的 `SkyLight.framework` 接口按需加载，接口不可用或未授权时自动降级为应用图标或占位图标。有匹配的外接屏图标时，原菜单可能在外接屏打开。

## 从源码构建

需要 Apple Silicon Mac、macOS 26 与 Xcode 26 或更新的 Swift 6.2 工具链。

```sh
git clone https://github.com/idefav/notch-island.git
cd notch-island
swift test
sh build-app.sh --force
open dist/NotchIsland.app
```

`build-app.sh` 会优先自动使用本机钥匙串中的 `Apple Development` / `Developer ID Application` 证书签名（后续重编覆盖安装不会重置屏幕录制和辅助功能权限），仅在本机无证书时回退为临时签名（`-`），也可通过 `CODESIGN_IDENTITY` 手动指定证书指纹。

生成带安装快捷方式的 DMG 和 SHA-256 校验文件：

```sh
sh build-dmg.sh
```

应用使用 SwiftUI 和 AppKit。可编辑的程序图标源位于 [Artwork/AppIcon.swift](Artwork/AppIcon.swift)，构建时生成包含 Retina 尺寸的 `.icns`。

## Release 打包

[Release 工作流](.github/workflows/release.yml) 在 GitHub 的 macOS arm64 运行器上执行测试、构建 DMG，并进行只读挂载、应用签名和安装目录校验。手动运行可在该次构建日志所在页面下载产物。推送与 `Info.plist` 中应用版本一致的 `v<版本>` 标签会发布 GitHub 预发行版，并附带通过校验的 DMG 和对应的 SHA-256 文件。
