import AppKit
import Security

@MainActor
final class ClientWallpaper {
    private let bundleURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    private let identifier = "com.openai.codex"
    private let defaults = UserDefaults.standard
    private var worker: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var pendingLaunch = false
    private var launching = false
    private var configuration: [String: Any] = ["opacity": 0, "imageVersion": NSNull(), "darkAppearance": true]
    private var observer: NSObjectProtocol?
    var statusChanged: ((String) -> Void)?

    func startObserving() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingLaunch, self.running.isEmpty else { return }
                self.pendingLaunch = false
                self.open()
            }
        }
        reconnect()
    }

    private var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated }
    }

    func configure(hasImage: Bool, imageVersion: Int, opacity: Double, darkAppearance: Bool) {
        configuration = ["opacity": opacity, "imageVersion": hasImage ? imageVersion as Any : NSNull(),
                         "darkAppearance": darkAppearance]
        send(configuration)
    }

    func open() {
        guard !launching else { return }
        if worker?.isRunning == true {
            running.first(where: { $0.bundleURL == bundleURL })?.activate(options: [])
            return
        }
        if !running.isEmpty {
            if pendingLaunch {
                pendingLaunch = false
                statusChanged?("已取消等待")
            } else {
                pendingLaunch = true
                statusChanged?("等待 ChatGPT 正常退出后自动打开")
            }
            return
        }
        guard verifyClient() else {
            statusChanged?("未找到已签名的 ChatGPT 客户端")
            return
        }
        launching = true
        statusChanged?("正在打开带壁纸的 ChatGPT…")
        let port = Int.random(in: 49152...65535)
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--remote-debugging-address=127.0.0.1", "--remote-debugging-port=\(port)"]
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { [weak self] app, _ in
            let pid = app?.processIdentifier
            Task { @MainActor in
                guard let self else { return }
                guard let pid else {
                    self.launching = false
                    self.statusChanged?("ChatGPT 启动失败")
                    return
                }
                self.defaults.set(port, forKey: "ManagedPort")
                self.defaults.set(Int(pid), forKey: "ManagedPID")
                await self.connect(port: port, pid: pid)
            }
        }
    }

    private func verifyClient() -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = #"anchor apple generic and identifier "com.openai.codex" and certificate leaf[subject.OU] = "2DC432GLL2""#
        return SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess &&
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess &&
            code.map { SecStaticCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
    }

    private func reconnect() {
        let port = defaults.integer(forKey: "ManagedPort")
        let storedPID = defaults.integer(forKey: "ManagedPID")
        guard let pid = pid_t(exactly: storedPID), port > 0,
              running.contains(where: { $0.processIdentifier == pid && $0.bundleURL == bundleURL }),
              verifyClient() else {
            statusChanged?("从这里打开 ChatGPT 以启用壁纸")
            return
        }
        launching = true
        Task { await connect(port: port, pid: pid) }
    }

    private func connect(port: Int, pid: pid_t) async {
        defer { launching = false }
        for _ in 0..<32 {
            guard running.contains(where: { $0.processIdentifier == pid && $0.bundleURL == bundleURL }) else { break }
            if await Self.listensLocally(port: port, pid: pid) {
                startWorker(port: port)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        statusChanged?("ChatGPT 已打开，壁纸会话连接失败")
    }

    nonisolated private static func listensLocally(port: Int, pid: pid_t) async -> Bool {
        await Task.detached {
            let lookup = Process()
            let pipe = Pipe()
            lookup.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lookup.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
            lookup.standardOutput = pipe
            lookup.standardError = FileHandle.nullDevice
            do { try lookup.run() } catch { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lookup.waitUntilExit()
            let addresses = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .filter { $0.hasPrefix("n") }
            return lookup.terminationStatus == 0 && !addresses.isEmpty &&
                addresses.allSatisfy { $0 == "n127.0.0.1:\(port)" }
        }.value
    }

    private func startWorker(port: Int) {
        guard let script = Bundle.main.url(forResource: "bridge", withExtension: "mjs") else {
            statusChanged?("壁纸组件缺失")
            return
        }
        let bridge = Process()
        let incoming = Pipe()
        let outgoing = Pipe()
        bridge.executableURL = bundleURL.appending(path: "Contents/Resources/node")
        bridge.arguments = [script.path, String(port), WallpaperImage.fileURL.path]
        bridge.standardInput = incoming
        bridge.standardOutput = outgoing
        bridge.standardError = FileHandle.nullDevice
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in self?.receive(data) }
        }
        bridge.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.worker = nil
                self?.input = nil
                self?.statusChanged?("壁纸会话已结束")
            }
        }
        do {
            try bridge.run()
            worker = bridge
            input = incoming.fileHandleForWriting
            outputBuffer.removeAll()
            send(configuration)
        } catch {
            statusChanged?("无法启动壁纸组件")
        }
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: end)
            if let update = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                if let error = update["error"] as? String { statusChanged?(error) }
                else if let windows = update["windows"] as? Int {
                    statusChanged?(windows > 0 ? "已连接 \(windows) 个 ChatGPT 页面" : "已连接，壁纸未显示")
                }
            }
            outputBuffer.removeSubrange(...end)
        }
    }

    private func send(_ message: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? input.write(contentsOf: data + Data([10]))
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        send(["quit": true])
        try? input?.close()
        input = nil
    }
}
