import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppState.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PixelpressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Pixelpress", id: "main") {
            ContentView().environmentObject(state)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { state.openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.keyboardShortcut("x")
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }.keyboardShortcut("c")
                Button("Paste") {
                    // Text fields get a normal paste; anywhere else, pasted files or images join the list.
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    } else {
                        state.paste()
                    }
                }
                .keyboardShortcut("v")
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }.keyboardShortcut("a")
            }
            CommandMenu("Convert") {
                Button("Convert All") { state.convertAll() }
                    .keyboardShortcut(.return)
                    .disabled(state.items.isEmpty || state.isConverting)
                Divider()
                Button("Remove Finished") { state.removeFinished() }.disabled(state.finishedCount == 0)
                Button("Clear List") { state.clear() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(state.items.isEmpty || state.isConverting)
            }
        }
    }
}

let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "convert" {
    exit(CLI.run(Array(arguments.dropFirst(2))))
}
PixelpressApp.main()
