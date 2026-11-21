import SwiftUI
import AppKit
import Combine
import OsmoCore

@MainActor
final class StudioWindowController {
    static let shared = StudioWindowController()
    private var window: NSWindow?

    func show(viewModel: OsmoControllerViewModel) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: ControlWindowView(vm: viewModel))
        let win = NSWindow(contentViewController: hosting)
        win.title = "OsmoBar"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 660, height: 740))
        win.minSize = NSSize(width: 560, height: 480)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

@MainActor
final class OsmoBarAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let viewModel = OsmoControllerViewModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: MenuBarPopoverView(
                vm: viewModel,
                onOpenStudioWindow: { [weak self] in
                    guard let self else { return }
                    self.popover.performClose(nil)
                    StudioWindowController.shared.show(viewModel: self.viewModel)
                }
            )
        )
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "com.osmobar.statusItem"
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        statusItem = item

        // React immediately whenever connection state, mic source, battery, or auto-hide preference changes.
        Publishers.CombineLatest4(
            viewModel.$uvcConnected,
            viewModel.$selectedCameraID,
            viewModel.$bleState,
            viewModel.$udpState
        )
        .combineLatest(
            Publishers.CombineLatest3(
                viewModel.$hideMenuBarWhenDisconnected,
                viewModel.$detectedMicSource,
                viewModel.$battery
            )
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.syncStatusItem()
        }
        .store(in: &cancellables)

        syncStatusItem()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            StudioWindowController.shared.show(viewModel: viewModel)
        }
        return true
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func syncStatusItem() {
        guard let item = statusItem else { return }

        let shouldShow = viewModel.isMenuBarIconVisible
        if item.isVisible != shouldShow {
            if !shouldShow && popover.isShown {
                popover.performClose(nil)
            }
            item.isVisible = shouldShow
        }

        guard let button = item.button else { return }
        button.image = currentMenuBarImage()
        if let battery = viewModel.battery {
            button.title = " \(battery.percent)%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        } else {
            button.title = ""
        }
    }

    private func currentMenuBarImage() -> NSImage {
        if !viewModel.isAnyTransportConnected {
            return MenuBarIconFactory.singleSymbol("web.camera")
        }
        switch viewModel.detectedMicSource {
        case .djiMicWireless, .djiMicUSBReceiver:
            return MenuBarIconFactory.cameraAndMicIcon
        case .cameraMic, .unknown:
            return MenuBarIconFactory.singleSymbol("web.camera.fill")
        }
    }
}

@main
struct OsmoBarApp: App {
    @NSApplicationDelegateAdaptor(OsmoBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Renders crisp template NSImages for the macOS menu bar so composite icons
/// (webcam + active DJI Mic) tint natively in both light and dark menu bars.
private enum MenuBarIconFactory {
    static let cameraAndMicIcon: NSImage = makeComposite(left: "web.camera.fill", right: "mic.fill")

    static func singleSymbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "OsmoBar")?
            .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 18, height: 18))
        img.isTemplate = true
        return img
    }

    private static func makeComposite(left: String, right: String) -> NSImage {
        let leftConfig = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
        let rightConfig = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
        let leftImg = NSImage(systemSymbolName: left, accessibilityDescription: nil)?
            .withSymbolConfiguration(leftConfig)
        let rightImg = NSImage(systemSymbolName: right, accessibilityDescription: nil)?
            .withSymbolConfiguration(rightConfig)

        let leftSize = leftImg?.size ?? NSSize(width: 16, height: 16)
        let rightSize = rightImg?.size ?? NSSize(width: 12, height: 14)
        let spacing: CGFloat = 3
        let height: CGFloat = 18
        let totalWidth = ceil(leftSize.width + spacing + rightSize.width)

        let composite = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            if let leftImg {
                let y = (height - leftSize.height) / 2
                leftImg.draw(in: NSRect(x: 0, y: y, width: leftSize.width, height: leftSize.height))
            }
            if let rightImg {
                let y = (height - rightSize.height) / 2
                rightImg.draw(in: NSRect(x: leftSize.width + spacing, y: y, width: rightSize.width, height: rightSize.height))
            }
            return true
        }
        composite.isTemplate = true
        return composite
    }
}
