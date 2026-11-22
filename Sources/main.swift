import AppKit
import Darwin
import UniformTypeIdentifiers

@MainActor
private final class WallpaperApp: NSObject, NSApplicationDelegate {
    private let wallpaper = ClientWallpaper()
    private let defaults = UserDefaults.standard
    private let opacityKey = "WallpaperOpacity"
    private let defaultOpacity = 0.30
    private let enabledKey = "WallpaperEnabled"
    private let darkKey = "WallpaperDarkAppearance"
    private var image: CGImage?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSButton(checkboxWithTitle: "显示壁纸", target: nil, action: nil)
    private let darkToggle = NSButton(checkboxWithTitle: "深色外观", target: nil, action: nil)
    private var slider = NSSlider()
    private var percentage = NSTextField(labelWithString: "")
    private var imageVersion = 0
    private var connectionStatus = ""
    private var isChoosing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [opacityKey: defaultOpacity, enabledKey: true, darkKey: true])
        if image == nil { image = WallpaperImage.saved() }
        wallpaper.statusChanged = { [weak self] status in
            self?.connectionStatus = status
            self?.updateStatus()
        }
        setUpControls()
        refreshWallpaper()
        wallpaper.startObserving()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showControls()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { installImage(url) }
    }

    private func setUpControls() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                     accessibilityDescription: "ChatGPT Wallpaper")
        item.button?.toolTip = "ChatGPT Wallpaper"
        item.button?.target = self
        item.button?.action = #selector(toggleControls)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2

        let choose = NSButton(title: "选择壁纸…", target: self, action: #selector(chooseImage))
        let launch = NSButton(title: "打开带壁纸的 ChatGPT", target: self, action: #selector(openChatGPT))
        let quit = NSButton(title: "退出", target: self, action: #selector(quit))

        let label = NSTextField(labelWithString: "壁纸不透明度")
        percentage.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let opacityRow = NSStackView(views: [label, NSView(), percentage])
        opacityRow.orientation = .horizontal

        slider = NSSlider(value: opacity, minValue: 0, maxValue: 0.60,
                          target: self, action: #selector(changeOpacity(_:)))
        slider.isContinuous = true
        slider.setAccessibilityLabel("壁纸不透明度")

        toggle.target = self
        toggle.action = #selector(toggleWallpaper)
        darkToggle.target = self
        darkToggle.action = #selector(toggleDarkAppearance)
        let buttons = NSStackView(views: [toggle, darkToggle, NSView(), quit])
        buttons.orientation = .horizontal
        let actions = NSStackView(views: [launch, choose])
        actions.orientation = .horizontal
        actions.spacing = 8

        let hint = NSTextField(wrappingLabelWithString: "深色搭配 30% 不透明度，正文更容易看清。")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [status, actions, opacityRow, slider, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(15, after: actions)

        let controller = NSViewController()
        let content = NSView()
        controller.view = content
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            opacityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.widthAnchor.constraint(equalToConstant: 280)
        ])
        popover.contentViewController = controller
        popover.contentSize = content.fittingSize
        popover.behavior = .transient
    }

    @objc private func toggleControls() {
        if popover.isShown { popover.performClose(nil) }
        else { showControls() }
    }

    private func showControls() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private var opacity: Double { min(0.60, max(0, defaults.double(forKey: opacityKey))) }

    private func updateStatus() {
        let on = defaults.bool(forKey: enabledKey)
        toggle.state = on ? .on : .off
        toggle.isEnabled = image != nil
        percentage.stringValue = "\(Int((opacity * 100).rounded()))%"
        if image == nil {
            status.stringValue = "尚未选择壁纸"
        } else if !on || opacity == 0 {
            status.stringValue = "壁纸已隐藏"
        } else {
            status.stringValue = connectionStatus
        }
    }

    private func refreshWallpaper() {
        let dark = defaults.bool(forKey: darkKey)
        darkToggle.state = dark ? .on : .off
        popover.appearance = dark ? NSAppearance(named: .darkAqua) : nil
        wallpaper.configure(hasImage: image != nil, imageVersion: imageVersion,
                            opacity: defaults.bool(forKey: enabledKey) ? opacity : 0, darkAppearance: dark)
        updateStatus()
    }

    @objc private func changeOpacity(_ control: NSSlider) {
        defaults.set((control.doubleValue * 100).rounded() / 100, forKey: opacityKey)
        refreshWallpaper()
    }

    @objc private func toggleWallpaper() {
        defaults.set(!defaults.bool(forKey: enabledKey), forKey: enabledKey)
        refreshWallpaper()
    }

    @objc private func toggleDarkAppearance() {
        defaults.set(darkToggle.state == .on, forKey: darkKey)
        refreshWallpaper()
    }

    @objc private func chooseImage() {
        guard !isChoosing else { return }
        isChoosing = true
        popover.performClose(nil)
        let picker = NSOpenPanel()
        picker.title = "选择 ChatGPT 壁纸"
        picker.prompt = "设为壁纸"
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard let self else { return }
            self.isChoosing = false
            if response == .OK, let url = picker.url { self.installImage(url) }
        }
    }

    private func installImage(_ url: URL) {
        do {
            image = try WallpaperImage.save(url)
            imageVersion += 1
            defaults.set(true, forKey: enabledKey)
            if opacity == 0 {
                defaults.set(defaultOpacity, forKey: opacityKey)
                slider.doubleValue = opacity
            }
            refreshWallpaper()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法设置壁纸"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openChatGPT() {
        popover.performClose(nil)
        wallpaper.open()
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaper.stop()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    signal(SIGPIPE, SIG_IGN)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = WallpaperApp()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
