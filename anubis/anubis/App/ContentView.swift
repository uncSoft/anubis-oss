//
//  ContentView.swift
//  anubis
//
//  Created by J T on 1/25/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            DetailView()
        }
        .overlay(alignment: .topTrailing) {
            if DemoMode.isEnabled {
                DemoModeIndicator()
            }
        }
    }
}

// MARK: - Demo Mode Indicator

struct DemoModeIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.orange)
            Text("Demo Mode")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(Color.cardBackground)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                }
        }
        .padding(.top, 8)
        .padding(.trailing, 16)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @State private var glowPulse = false
    @AppStorage("showSandAnimation") private var showSandAnimation = false  // Persistent, default off
    @State private var sandClearTrigger = false
    @State private var sandParticleCount = 0
    @State private var sandMousePosition: CGPoint?
    @State private var sidebarSize: CGSize = .zero

    private var isActive: Bool {
        appState.inferenceService.isGenerating || appState.isArenaRunning
    }

    private let splashHeight: CGFloat = 131

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Main sidebar content
                VStack(spacing: 0) {
                    List(selection: $appState.selectedDestination) {
                        Section {
                            ForEach(NavigationDestination.allCases.filter { $0 != .settings }) { destination in
                                NavigationLink(value: destination) {
                                    Label(destination.rawValue, systemImage: destination.icon)
                                }
                            }
                        }

                        Section {
                            NavigationLink(value: NavigationDestination.settings) {
                                Label("Settings", systemImage: NavigationDestination.settings.icon)
                            }
                            Button {
                                Task {
                                    await appState.inferenceService.refreshAllModels()
                                }
                            } label: {
                                Label("Refresh Models", systemImage: "arrow.clockwise")
                            }
                        }

                        Section("Backend") {
                            BackendStatusView(
                                inferenceService: appState.inferenceService,
                                configManager: appState.configManager
                            )
                        }

                        // Sand animation controls
                        Section("Sands of Time") {
                            HStack {
                                Toggle("Sands of Time", isOn: $showSandAnimation)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)

                                Spacer()

                                if sandParticleCount > 0 {
                                    Text("\(sandParticleCount)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            if showSandAnimation && sandParticleCount > 0 {
                                Button {
                                    sandClearTrigger.toggle()
                                } label: {
                                    HStack {
                                        Image(systemName: "hourglass.bottomhalf.filled")
                                        Text("Clear Sands")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)

                    Spacer(minLength: 0)

                    // Splash image at bottom
                    Button {
                        openURL(Constants.URLs.website)
                    } label: {
                        if let nsImage = NSImage(named: "splash") {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 240, height: splashHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(
                                    color: .yellow.opacity(glowPulse ? 1.0 : 0.9),
                                    radius: glowPulse ? 20 : 10,
                                    y: glowPulse ? 0 : 2
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Visit anubis website")
                    .padding(.bottom, 4)
                }

                // Mouse tracking overlay (doesn't block clicks)
                if showSandAnimation {
                    MouseTrackingView(mousePosition: $sandMousePosition)
                }

                // Sand particle overlay - fills from top, lands above splash
                if showSandAnimation {
                    SandParticleView(
                        isRunning: isActive,
                        containerHeight: geometry.size.height,
                        containerWidth: geometry.size.width,
                        floorY: splashHeight + 8,  // Land just above splash image
                        clearTrigger: $sandClearTrigger,
                        particleCount: $sandParticleCount,
                        mousePosition: $sandMousePosition
                    )
                    .allowsHitTesting(false)  // Let clicks pass through to sidebar
                }
            }
            .onAppear {
                sidebarSize = geometry.size
            }
            .onChange(of: geometry.size) { _, newSize in
                sidebarSize = newSize
            }
        }
        .navigationTitle("Anubis")
        .onChange(of: isActive) { _, active in
            updateGlowAnimation(isActive: active)
        }
    }

    private func updateGlowAnimation(isActive: Bool) {
        if isActive {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                glowPulse = false
            }
        }
    }
}

// MARK: - Backend Status

struct BackendStatusView: View {
    @ObservedObject var inferenceService: InferenceService
    @ObservedObject var configManager: BackendConfigurationManager

    private var currentHealth: BackendHealth? {
        if inferenceService.currentBackend == .openai,
           let config = inferenceService.currentOpenAIConfig {
            return inferenceService.openAIBackendHealth[config.id]
        }
        return inferenceService.backendHealth[inferenceService.currentBackend]
    }

    private var currentBackendName: String {
        if inferenceService.currentBackend == .openai,
           let config = inferenceService.currentOpenAIConfig {
            return config.name
        }
        return inferenceService.currentBackend.displayName
    }

    private var currentBackendURL: String {
        switch inferenceService.currentBackend {
        case .ollama:
            return configManager.ollamaConfig?.baseURL ?? "http://localhost:11434"
        case .openai:
            return inferenceService.currentOpenAIConfig?.baseURL ?? "—"
        case .mlx:
            return configManager.configurations.first(where: { $0.type == .mlx })?.baseURL ?? "—"
        }
    }

    private var isOpenAISelected: Bool {
        inferenceService.currentBackend == .openai
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Combined backend selector
            Menu {
                // Ollama backend
                Section("Local") {
                    Button {
                        inferenceService.setBackend(.ollama)
                    } label: {
                        HStack {
                            Label("Ollama", systemImage: "server.rack")
                            Spacer()
                            if inferenceService.currentBackend == .ollama {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                // OpenAI-compatible servers section
                let openAIConfigs = configManager.openAIConfigs
                if !openAIConfigs.isEmpty {
                    Section("OpenAI-Compatible Servers") {
                        ForEach(openAIConfigs) { config in
                            Button {
                                inferenceService.setOpenAIBackend(config)
                            } label: {
                                HStack {
                                    Label(config.name, systemImage: "globe")
                                    Spacer()
                                    if inferenceService.currentOpenAIConfig?.id == config.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: currentBackendIcon)
                        .frame(width: 20)
                    Text(currentBackendName)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.cardBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.cardBorder, lineWidth: 1)
                        }
                }
            }
            .buttonStyle(.plain)

            // Status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(currentHealth?.isRunning == true ? Color.anubisSuccess : Color.anubisError)
                    .frame(width: 8, height: 8)
                    .shadow(color: (currentHealth?.isRunning == true ? Color.anubisSuccess : Color.anubisError).opacity(0.5), radius: 2)
                    .accessibilityHidden(true) // Status conveyed by text
                VStack(alignment: .leading, spacing: 1) {
                    Text(currentHealth?.isRunning == true ? "Connected" : "Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(currentBackendURL)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if let health = currentHealth, health.isRunning, let modelCount = health.modelCount {
                    Text("\(modelCount) models")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(currentBackendName) backend: \(currentHealth?.isRunning == true ? "Connected" : "Disconnected")")
        }
    }

    private var currentBackendIcon: String {
        switch inferenceService.currentBackend {
        case .ollama: return "server.rack"
        case .mlx: return "apple.logo"
        case .openai: return "globe"
        }
    }
}

// MARK: - Detail View

struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.selectedDestination {
            case .benchmark:
                BenchmarkView(
                    inferenceService: appState.inferenceService,
                    metricsService: appState.metricsService,
                    databaseManager: appState.databaseManager
                )
                .navigationTitle("Benchmark")
            case .arena:
                ArenaView(
                    appState: appState,
                    inferenceService: appState.inferenceService,
                    metricsService: appState.metricsService,
                    databaseManager: appState.databaseManager
                )
                .navigationTitle("Arena")
            case .vault:
                VaultView(inferenceService: appState.inferenceService)
                    .navigationTitle("Vault")
            case .settings:
                SettingsView()
            case .none:
                WelcomeView()
            }
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.xl)
                    .fill(Color.emptyStateBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.xl)
                            .strokeBorder(Color.cardBorder, lineWidth: 1)
                    }
                    .frame(width: 120, height: 100)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
            }

            Text("Welcome to Anubis")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Select a module from the sidebar to get started")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Placeholder Views

struct ArenaPlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Arena")
                .font(.title)
                .fontWeight(.bold)

            Text("Side-by-side model comparison")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Arena")
    }
}

struct VaultPlaceholderView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "archivebox")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Vault")
                .font(.title)
                .fontWeight(.bold)

            Text("Model management and inspection")
                .foregroundStyle(.secondary)

            if appState.inferenceService.allModels.isEmpty {
                Text("No models found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(appState.inferenceService.allModels) { model in
                    HStack {
                        Image(systemName: model.backend.icon)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(model.name)
                                .fontWeight(.medium)
                            Text("\(model.formattedSize) • \(model.formattedParameters)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.backend.displayName)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Vault")
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var updaterService: UpdaterService
    @State private var showAddBackend = false
    @State private var showAbout = false
    @State private var showHelp = false
    @State private var showContact = false
    @State private var editingConfig: BackendConfiguration?
    @State private var configToDelete: BackendConfiguration?
    @State private var refreshTrigger = false  // Force view refresh

    // Observe configManager directly for proper updates
    private var configurations: [BackendConfiguration] {
        appState.configManager.configurations
    }

    private var openAIConfigs: [BackendConfiguration] {
        configurations.filter { $0.type == .openaiCompatible }
    }

    var body: some View {
        Form {
            // Ollama Configuration
            Section("Ollama") {
                if let ollamaConfig = configurations.first(where: { $0.type == .ollama }) {
                    BackendConfigRow(
                        config: ollamaConfig,
                        health: appState.inferenceService.backendHealth[.ollama],
                        onEdit: { editingConfig = ollamaConfig }
                    )
                }
            }

            // MLX Status
            Section("MLX") {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundStyle(.secondary)
                    Text("MLX (Local)")
                    Spacer()
                    let health = appState.inferenceService.backendHealth[.mlx]
                    Circle()
                        .fill(health?.isRunning == true ? Color.anubisSuccess : Color.anubisError)
                        .frame(width: 8, height: 8)
                        .shadow(color: (health?.isRunning == true ? Color.anubisSuccess : Color.anubisError).opacity(0.4), radius: 2)
                    Text(health?.isRunning == true ? "Available" : "Not Available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // OpenAI-Compatible Backends
            Section {
                if openAIConfigs.isEmpty {
                    Text("No servers configured")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(openAIConfigs) { config in
                        BackendConfigRow(
                            config: config,
                            health: appState.inferenceService.openAIBackendHealth[config.id],
                            onEdit: { editingConfig = config },
                            onDelete: { configToDelete = config }
                        )
                    }
                }

                Button {
                    showAddBackend = true
                } label: {
                    Label("Add OpenAI-Compatible Server", systemImage: "plus.circle")
                }
            } header: {
                Text("OpenAI-Compatible Servers")
            } footer: {
                Text("Add servers that support the OpenAI API format (LM Studio, LocalAI, vLLM, etc.)")
            }

            // Actions
            Section {
                Button("Check All Backends") {
                    Task {
                        await appState.inferenceService.checkAllBackends()
                    }
                }

                Button("Refresh Models") {
                    Task {
                        await appState.inferenceService.refreshAllModels()
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")

                Button {
                    updaterService.checkForUpdates()
                } label: {
                    Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!updaterService.canCheckForUpdates)

                Button {
                    showAbout = true
                } label: {
                    Label("About Anubis", systemImage: "info.circle")
                }

                Button {
                    showHelp = true
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }

                Button {
                    showContact = true
                } label: {
                    Label("Report a Bug", systemImage: "ladybug")
                }

                Link(destination: Constants.URLs.privacyPolicy) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .id(refreshTrigger)  // Force refresh when trigger changes
        .sheet(isPresented: $showAddBackend) {
            BackendConfigEditor(
                config: BackendConfiguration(
                    id: UUID(),
                    name: "",
                    type: .openaiCompatible,
                    baseURL: "http://localhost:1234",
                    isEnabled: true
                ),
                isNew: true,
                onSave: { newConfig in
                    appState.configManager.addConfiguration(newConfig)
                    showAddBackend = false
                    triggerRefresh()
                },
                onCancel: { showAddBackend = false }
            )
        }
        .sheet(item: $editingConfig) { config in
            BackendConfigEditor(
                config: config,
                isNew: false,
                onSave: { updatedConfig in
                    appState.configManager.updateConfiguration(updatedConfig)
                    editingConfig = nil
                    triggerRefresh()
                },
                onCancel: { editingConfig = nil }
            )
        }
        .sheet(isPresented: $showAbout) {
            KeygenAboutView(onClose: { showAbout = false })
        }
        .sheet(isPresented: $showHelp) {
            HelpView(onClose: { showHelp = false })
        }
        .sheet(isPresented: $showContact) {
            ContactFormView(onClose: { showContact = false })
        }
        .alert("Delete Server?", isPresented: Binding(
            get: { configToDelete != nil },
            set: { if !$0 { configToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                configToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let config = configToDelete {
                    appState.configManager.removeConfiguration(config)
                    configToDelete = nil
                    triggerRefresh()
                }
            }
        } message: {
            if let config = configToDelete {
                Text("Are you sure you want to delete \"\(config.name)\"?")
            }
        }
    }

    private func triggerRefresh() {
        // Force view refresh and reload configurations
        Task {
            appState.inferenceService.reloadConfigurations()
            await appState.inferenceService.checkAllBackends()
            await MainActor.run {
                refreshTrigger.toggle()
            }
        }
    }
}

// MARK: - Backend Config Row

struct BackendConfigRow: View {
    let config: BackendConfiguration
    let health: BackendHealth?
    let onEdit: () -> Void
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: config.type.icon)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .fontWeight(.medium)
                Text(config.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status indicator
            Circle()
                .fill(health?.isRunning == true ? Color.anubisSuccess : Color.anubisError)
                .frame(width: 8, height: 8)
                .shadow(color: (health?.isRunning == true ? Color.anubisSuccess : Color.anubisError).opacity(0.4), radius: 2)

            // Edit button
            Button(action: onEdit) {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Delete button (only for OpenAI-compatible)
            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Backend Config Editor

struct BackendConfigEditor: View {
    @State var config: BackendConfiguration
    let isNew: Bool
    let onSave: (BackendConfiguration) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Details") {
                    TextField("Name", text: $config.name)
                        .textFieldStyle(.plain)

                    TextField("Base URL", text: $config.baseURL)
                        .textFieldStyle(.plain)

                    if config.type == .openaiCompatible {
                        SecureField("API Key (optional)", text: Binding(
                            get: { config.apiKey ?? "" },
                            set: { config.apiKey = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.plain)
                    }
                }

                if config.type == .openaiCompatible {
                    Section {
                        Toggle("Enabled", isOn: $config.isEnabled)
                    }
                }

                Section {
                    Text("Common Ports:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        QuickURLButton(label: "Ollama", url: "http://localhost:11434") { config.baseURL = $0 }
                        QuickURLButton(label: "LM Studio", url: "http://localhost:1234") { config.baseURL = $0 }
                        QuickURLButton(label: "MLX", url: "http://localhost:8080") { config.baseURL = $0 }
                        QuickURLButton(label: "vLLM", url: "http://localhost:8000") { config.baseURL = $0 }
                    }
                } header: {
                    Text("Quick Fill")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Add Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(config)
                    }
                    .disabled(config.name.isEmpty || config.baseURL.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 350)
    }
}

struct QuickURLButton: View {
    let label: String
    let url: String
    let action: (String) -> Void

    var body: some View {
        Button(label) {
            action(url)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
