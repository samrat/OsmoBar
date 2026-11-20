import SwiftUI
import AppKit
import OsmoCore

@main
struct OsmoBarApp: App {
    @StateObject private var viewModel = OsmoControllerViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(vm: viewModel)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: menuBarImage)
                if let battery = viewModel.battery {
                    Text("\(battery.percent)%")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("OsmoBar", id: "control-window") {
            ControlWindowView(vm: viewModel)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 660, height: 740)
    }

    private var isConnected: Bool {
        viewModel.uvcConnected || viewModel.udpState.isConnected || viewModel.bleState.isConnected
    }

    private var menuBarImage: NSImage {
        if !isConnected {
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
