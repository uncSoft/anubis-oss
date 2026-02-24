//
//  UpdaterService.swift
//  anubis
//
//  Lightweight wrapper around Sparkle's SPUStandardUpdaterController
//  for SwiftUI integration. Provides automatic update checks on launch
//  and a user-initiated "Check for Updates" action.
//

import SwiftUI
import Combine
@preconcurrency import Sparkle

final class UpdaterService: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
