# NotchIsland · 菜单栏灵动岛

NotchIsland 是一个独立的 macOS 菜单栏工具。菜单栏太挤时，被刘海挤出可见区域的应用图标可以在刘海下方的浮层里重新访问。

[下载 DMG](https://github.com/idefav/notch-island/releases) · [报告问题](https://github.com/idefav/notch-island/issues)

## 体验

- **贴合刘海。** 应用读取 macOS 提供的刘海尺寸，圆角外壳沿边外扩 1 pt。指针进入或打开时播放边缘流光，系统启用「减少动态效果」时使用短淡入淡出。
- **直接访问隐藏图标。** 点刘海下边缘展开。面板支持横向滚动，方向键切换图标，回车请求打开原应用菜单，按 Esc 或点外部收起。
- **按习惯展开。** 右键岛面，在「展开方式」中选择点击或悬停。悬停打开的是临时预览，可点「固定面板」。设置会保留到下次启动。
- **可选开机启动。** 右键岛面可切换「开机启动」。默认关闭，开启后在登录 macOS 时启动。

## 安装

需要带实体刘海的 Apple Silicon Mac 和 macOS 26。使用外接显示器时，浮层仍在可用的刘海屏上显示。找不到刘海屏时，应用会提示不支持。

1. 从 [Releases](https://github.com/idefav/notch-island/releases) 下载 `NotchIsland-<版本>-arm64.dmg`。
2. 打开 DMG，把 `NotchIsland.app` 拖到「应用程序」，再从「应用程序」打开。
3. 点击刘海下边缘展开。需要读取真实图标或打开原菜单时，可通过面板的「授权设置」开启权限。

> 当前 DMG 为预览版，使用 ad hoc 签名，尚未经过 Apple 公证。macOS 可能拦截从网络下载的应用。遇到拦截时可从下文的「从源码构建」入口在本机生成应用。 [Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

可选的文件校验方式。在同一目录下载 DMG 和对应的 `.sha256` 后运行下列命令，将版本号换成所下载的版本。

```sh
shasum -a 256 -c NotchIsland-0.2.0-arm64.dmg.sha256
```

## 权限和兼容性

| macOS 权限 | 用途 |
| --- | --- |
| 屏幕与系统音频录制 | 读取已识别的菜单栏窗口图标。 |
| 辅助功能 | 请求与图标匹配的辅助功能元素打开原应用菜单。 |

菜单栏窗口查询、图标处理和菜单请求均在本机完成。macOS 26 的隐藏图标捕获依赖系统窗口行为和私有的 SkyLight 捕获接口。捕获失败时面板会使用可取得的应用图标或占位图标。部分第三方菜单可能无法唤起，有匹配的外接屏图标时菜单也可能在外接屏打开。

## 从源码构建

需要 Apple Silicon Mac、macOS 26 与 Xcode 26 或更新的 Swift 6.2 工具链。

```sh
git clone https://github.com/idefav/notch-island.git
cd notch-island
swift test
sh build-app.sh
open dist/NotchIsland.app
```

生成带安装快捷方式的 DMG 和 SHA-256 校验文件。

```sh
sh build-dmg.sh
```

应用使用 SwiftUI 和 AppKit。可编辑的程序图标源位于 [Artwork/AppIcon.swift](Artwork/AppIcon.swift)，构建时生成包含 Retina 尺寸的 `.icns`。

## Release 打包

[Release 工作流](.github/workflows/release.yml) 在 GitHub 的 macOS arm64 运行器上执行测试、构建 DMG，并进行只读挂载、应用签名和安装目录校验。手动运行可在该次构建日志所在页面下载产物。推送与 `Info.plist` 中应用版本一致的 `v<版本>` 标签会发布 GitHub 预发行版，并附带通过校验的 DMG 和对应的 SHA-256 文件。
