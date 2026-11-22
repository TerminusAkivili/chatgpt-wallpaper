# ChatGPT Wallpaper

独立开发的 macOS 菜单栏工具。选一张本地图片，就能在 ChatGPT 桌面客户端的应用页面上铺一层壁纸。首次启动壁纸模式时，默认使用**深色外观和 30% 的壁纸不透明度**。深色底衬托浅色文字，较淡的壁纸能减少图片细节对阅读的干扰。已有用户手动保存的不透明度会继续生效。

壁纸直接绘制在页面内。拖动窗口时，壁纸和正文由同一个窗口合成器一起移动。画布会等比裁切以铺满视口，鼠标点击、滚动和键盘输入仍由原界面处理。

## 从源码构建

需要 macOS、带有 Swift 编译器和 macOS SDK 的 Xcode 或 Command Line Tools，以及安装在 `/Applications/ChatGPT.app` 的官方桌面客户端（应用标识 `com.openai.codex`）。工具使用该客户端随附的 Node.js，无需安装 npm 依赖。

```sh
git clone https://github.com/TerminusAkivili/chatgpt-wallpaper.git
cd chatgpt-wallpaper
./build.sh
open ".build/ChatGPT Wallpaper.app"
```

构建脚本为当前 Mac 的架构编译，并对生成的应用进行本机临时签名。v0.2.2 的构建验证环境为 Apple Silicon、macOS 27.0.1、Swift 6.4.2，配套 ChatGPT 版本为 `26.1117.41037`。客户端更新可能影响页面识别和运行时兼容性。

## 使用

1. 点击 macOS 菜单栏的照片图标，选「选择壁纸…」，打开一张本地图片。
2. 点「打开带壁纸的 ChatGPT」。如果 ChatGPT 已经以普通方式启动，请先保存工作并正常退出（⌘Q）。工具会接着打开带壁纸的会话。
3. 再点照片图标，拖动「壁纸不透明度」滑块，可在 0% 到 60% 之间调节。取消勾选「显示壁纸」可以暂时隐藏图片。取消勾选「深色外观」会恢复 ChatGPT 页面自己的配色，工具会记住这个选择。

工具将导入的图片缩放至最长边 3072 像素，保存为 `~/Library/Application Support/ChatGPT Wallpaper/Wallpaper.png`。导入后可以移动原图。

## 工作原理及覆盖范围

[菜单栏控件](Sources/main.swift)负责选图和调节不透明度。[客户端启动器](Sources/ClientWallpaper.swift)校验官方应用签名，启动带随机本机调试端口的会话，并核验监听地址和进程。[页面连接](Resources/bridge.mjs)跟踪新打开的应用页面，[壁纸画布](Resources/renderer.mjs)在各页面中绘图。拖动滑块只更新画布透明度，无需重新解码图片。

壁纸覆盖符合条件的 `app://-` 顶层页面。系统菜单、文件选择器、桌面宠物浮层和外部网页不在覆盖范围内。壁纸模式会开启 Chromium DevTools 本机端口；同一台 Mac 上的其他进程也可能访问它。正常退出该 ChatGPT 会话即可关闭端口。

## 许可证

本工具的源码采用 [MIT 许可证](LICENSE)。
