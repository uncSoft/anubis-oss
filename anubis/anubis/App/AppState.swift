//
//  AppState.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import SwiftUI
import Combine
import os

/// Navigation destinations in the app
enum NavigationDestination: String, CaseIterable, Identifiable {
    case benchmark = "Benchmark"
    case arena = "Arena"
    case monitor = "Monitor"
    case reports = "Reports"
    case vault = "Vault"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .benchmark: return "gauge.with.dots.needle.67percent"
        case .arena: return "square.split.2x1"
        case .monitor: return "waveform.path.ecg"
        case .reports: return "chart.bar.doc.horizontal"
        case .vault: return "archivebox"
        case .settings: return "gearshape"
        }
    }

    var description: String {
        switch self {
        case .benchmark: return "Performance testing and hardware metrics"
        case .arena: return "Side-by-side model comparison"
        case .monitor: return "Live system metrics dashboard"
        case .reports: return "Compare model performance across all runs"
        case .vault: return "Model management and inspection"
        case .settings: return "App configuration"
        }
    }
}

/// Global application state
@MainActor
final class AppState: ObservableObject {
    // MARK: - Navigation

    /// Current navigation selection
    @Published var selectedDestination: NavigationDestination? = .benchmark

    /// Navigation path for detail views
    @Published var navigationPath = NavigationPath()

    // MARK: - Services

    /// Backend configuration manager
    let configManager: BackendConfigurationManager

    /// Inference service for model communication
    let inferenceService: InferenceService

    /// Metrics collection service
    let metricsService: MetricsService

    /// Database manager for persistence
    let databaseManager: DatabaseManager

    /// Floating monitor HUD controller
    let floatingHUD = FloatingMonitorWindowController()

    // MARK: - App State

    /// Whether the app has completed initial setup
    @Published var isInitialized = false

    /// Whether onboarding should be shown
    @Published var showOnboarding = false

    /// Whether Arena is currently running a comparison (for sidebar glow animation)
    @Published var isArenaRunning = false

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(
        configManager: BackendConfigurationManager? = nil,
        inferenceService: InferenceService? = nil,
        metricsService: MetricsService? = nil,
        databaseManager: DatabaseManager? = nil
    ) {
        self.configManager = configManager ?? BackendConfigurationManager()
        self.inferenceService = inferenceService ?? InferenceService(configManager: self.configManager)
        self.metricsService = metricsService ?? MetricsService()
        self.databaseManager = databaseManager ?? DatabaseManager.shared

        // Initialize database synchronously - it's a critical dependency
        do {
            try self.databaseManager.initialize()
        } catch {
            // Log will work since Logger doesn't need initialization
            Log.database.error("Failed to initialize database: \(error.localizedDescription)")
        }

        // Forward inferenceService changes to trigger view updates
        // This fixes nested ObservableObject observation issues
        self.inferenceService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Also forward configManager changes
        self.configManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Initialize the app state on launch
    func initialize() async {
        // Check backend health
        await inferenceService.checkAllBackends()

        // Load models
        await inferenceService.refreshAllModels()

        // Check if this is first launch
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !hasCompletedOnboarding {
            showOnboarding = true
        }

        isInitialized = true
    }

    /// Complete the onboarding flow
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        showOnboarding = false
    }

    // MARK: - Navigation Helpers

    /// Navigate to a specific destination
    func navigate(to destination: NavigationDestination) {
        selectedDestination = destination
    }

    /// Pop to root of navigation stack
    func popToRoot() {
        navigationPath = NavigationPath()
    }
}
