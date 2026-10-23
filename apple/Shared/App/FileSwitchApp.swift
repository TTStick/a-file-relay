import SwiftUI

@main
struct FileSwitchApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    #endif
    @State private var model = AppModel.shared
    @State private var transfers = Transfers.shared
    @State private var nav = Nav.shared

    var body: some Scene {
        #if os(macOS)
        Window("FileSwitch", id: "main") {
            root
                .frame(minWidth: 900, minHeight: 560)
                .background(WindowBridge())
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands { CommandGroup(replacing: .newItem) {} }
        #else
        WindowGroup { root }
        #endif
    }

    private var root: some View {
        RootView()
            .environment(model)
            .environment(transfers)
            .environment(nav)
            .onOpenURL { model.openPairLink($0) }
            .task {
                if !model.ready { await model.start() }
                #if DEBUG
                DemoHooks.afterStart()
                #endif
            }
    }
}
