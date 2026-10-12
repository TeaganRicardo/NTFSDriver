// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FSKit

@MainActor
final class ManagerDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "正在查询扩展状态…")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NTFSDriver 开发预览"
        let title = NSTextField(labelWithString: "NTFSDriver 只读开发预览")
        title.font = .boldSystemFont(ofSize: 18)
        let details = NSTextField(wrappingLabelWithString:
            "此版本用于验证只读文件系统。系统加载需要匹配的 FSKit 签名与配置文件；当前预览包不提供自动挂载或写入。")
        let refresh = NSButton(title: "刷新状态", target: self, action: #selector(refreshStatus))
        let settings = NSButton(title: "打开文件系统扩展设置", target: self, action: #selector(openSettings))
        let buttons = NSStackView(views: [refresh, settings])
        buttons.orientation = .horizontal
        let content = NSStackView(views: [title, details, status, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        refreshStatus()
    }

    @objc private func refreshStatus() {
        FSClient.shared.fetchInstalledExtensions { [weak self] modules, error in
            let text: String
            if let error { text = "扩展查询失败：\(error.localizedDescription)" }
            else if let module = modules?.first(where: { $0.bundleIdentifier == "io.github.TeaganRicardo.NTFSDriver.preview.fskit" }) {
                text = module.isEnabled ? "扩展已被系统发现并启用；卷挂载仍需独立验证。" : "扩展已被系统发现，尚未启用。"
            } else { text = "系统尚未发现本项目的文件系统扩展。" }
            DispatchQueue.main.async { self?.status.stringValue = text }
        }
    }

    @objc private func openSettings() {
        if !FSClient.shared.openFileSystemExtensionsSettings() {
            status.stringValue = "无法打开扩展设置，请从系统设置的登录项与扩展进入。"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
@MainActor
enum NTFSManager {
    static func main() {
        let application = NSApplication.shared
        let delegate = ManagerDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
