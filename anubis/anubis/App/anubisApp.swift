//
//  anubisApp.swift
//  anubis
//
//  Created by J T on 1/25/26.
//

import SwiftUI

@main
struct AnubisApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updaterService = UpdaterService()
    @State private var showAbout = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(updaterService)
                .task {
                    await appState.initialize()
                }
                .sheet(isPresented: $showAbout) {
                    KeygenAboutView(onClose: { showAbout = false })
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Anubis") {
                    showAbout = true
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterService.checkForUpdates()
                }
                .disabled(!updaterService.canCheckForUpdates)
            }
            CommandGroup(replacing: .help) {
                Button("Anubis Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/uncSoft/anubis-oss")!)
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Report an Issue") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/uncSoft/anubis-oss/issues")!)
                }
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(updaterService)
        }
        #endif
    }
}
