import SwiftUI
import AppKit

// 桌面悬浮歌词应用的入口。
// 创建透明无边框 NSPanel，在所有窗口之上显示歌词内容。
@main
struct LyricApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private let viewModel = LyricsViewModel()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createOverlay()
        setupMenuBar()
        viewModel.startMonitoring()
    }

    // 创建菜单栏图标和退出菜单
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Lyrics Overlay")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func quitApp() {
        viewModel.stopMonitoring()
        NSApplication.shared.terminate(nil)
    }

    // 创建透明浮窗，底部居中，覆盖在所有窗口之上
    private func createOverlay() {
        guard let screen = NSScreen.main else { return }
        let width = min(screen.visibleFrame.width - 40, 1200)
        let height: CGFloat = 180
        let x = (screen.visibleFrame.width - width) / 2
        let y: CGFloat = 80

        let contentView = LyricsDisplayView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: contentView)

        panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.fullSizeContentView, .borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        guard let panel else { return }

        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = hostingView
        panel.ignoresMouseEvents = true          // 鼠标穿透，不阻挡桌面操作
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.orderFrontRegardless()
    }
}
