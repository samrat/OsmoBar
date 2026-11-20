import SwiftUI

@main
struct OsmoBarApp: App {
    @StateObject private var viewModel = OsmoControllerViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(vm: viewModel)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: menuBarIcon)
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

    private var menuBarIcon: String {
        if viewModel.uvcConnected || viewModel.udpState.isConnected || viewModel.bleState.isConnected {
            return "web.camera.fill"
        }
        return "web.camera"
    }
}
