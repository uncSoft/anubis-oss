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
    @State private var showHelp = false

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
                .sheet(isPresented: $showHelp) {
                    HelpView(onClose: { showHelp = false })
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
                    showHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)
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
