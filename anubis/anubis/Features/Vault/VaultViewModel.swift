//
//  VaultViewModel.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation
import Combine
import os

/// ViewModel for the Vault module - model management and inspection
@MainActor
class VaultViewModel: ObservableObject {
    // MARK: - Published State

    @Published private(set) var models: [ModelInfo] = []
    @Published private(set) var runningModels: [RunningModel] = []
    @Published private(set) var selectedModel: ModelInfo?
    @Published private(set) var detailedInfo: OllamaModelInfo?
    @Published private(set) var isLoadingInfo = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var error: Error?

    // Pull state
    @Published var isPulling = false
    @Published var pullStatus: String = ""
    @Published var pullProgress: Double = 0
    @Published var pullModelName: String = ""
    @Published var showPullSheet = false

    // Delete confirmation
    @Published var modelToDelete: ModelInfo?
    @Published var showDeleteConfirmation = false

    // MARK: - Dependencies

    private let inferenceService: InferenceService
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(inferenceService: InferenceService) {
        self.inferenceService = inferenceService

        // Subscribe to model updates from InferenceService
        inferenceService.$allModels
            .receive(on: DispatchQueue.main)
            .assign(to: &$models)
    }

    // MARK: - Model Loading

    func loadModels() async {
        isLoadingModels = true
        error = nil

        await inferenceService.refreshAllModels()

        // Also load running models if Ollama is available
        await loadRunningModels()

        isLoadingModels = false
    }

    func loadRunningModels() async {
        var combined: [RunningModel] = []

        // Ollama (open /api/ps)
        do {
            combined += try await inferenceService.ollamaClient.listRunningModels()
        } catch {
            Log.vault.warning("Failed to load Ollama running models: \(error.localizedDescription)")
        }

        // oMLX (admin API — loaded state + real sizes)
        for configId in omlxConfigIds {
            guard let client = inferenceService.openAIClient(for: configId) else { continue }
            if let managed = try? await client.managedModels() {
                combined += managed.filter { $0.loaded }.map { m in
                    RunningModel(
                        name: m.id,
                        sizeBytes: m.sizeBytes ?? 0,
                        sizeVRAM: m.sizeBytes ?? 0,
                        expiresAt: nil,
                        backend: .openai,
                        openAIConfigId: configId
                    )
                }
            }
        }

        runningModels = combined
    }

    /// Config IDs that resolve to an oMLX server — either the built-in stock
    /// config or any config whose models report `owned_by: omlx`.
    private var omlxConfigIds: [UUID] {
        var ids = Set(
            models
                .filter { ($0.ownedBy?.lowercased().contains("omlx")) == true }
                .compactMap { $0.openAIConfigId }
        )
        if let stock = inferenceService.configManager.configurations.first(
            where: { $0.id == BackendConfiguration.defaultOMLX.id && $0.isEnabled }
        ) {
            ids.insert(stock.id)
        }
        return Array(ids)
    }

    /// Whether a model lives on an oMLX backend (supports load/unload).
    func isOMLXModel(_ model: ModelInfo) -> Bool {
        guard model.backend == .openai else { return false }
        if (model.ownedBy?.lowercased().contains("omlx")) == true { return true }
        return model.openAIConfigId == BackendConfiguration.defaultOMLX.id
    }

    /// Whether the Vault can load/unload this model (Ollama unload, oMLX both).
    func supportsUnload(_ model: ModelInfo) -> Bool {
        model.backend == .ollama || isOMLXModel(model)
    }

    func supportsLoad(_ model: ModelInfo) -> Bool {
        isOMLXModel(model)
    }

    // MARK: - Model Selection

    func selectModel(_ model: ModelInfo?) {
        selectedModel = model
        detailedInfo = nil

        if let model = model, model.backend == .ollama {
            Task {
                await loadModelDetails(model)
            }
        }
    }

    private func loadModelDetails(_ model: ModelInfo) async {
        let ollamaClient = inferenceService.ollamaClient

        isLoadingInfo = true
        error = nil

        do {
            detailedInfo = try await ollamaClient.showModelInfo(model.id)
        } catch {
            Log.vault.error("Failed to load model details: \(error.localizedDescription)")
            self.error = error
        }

        isLoadingInfo = false
    }

    // MARK: - Model Actions

    func confirmDelete(_ model: ModelInfo) {
        modelToDelete = model
        showDeleteConfirmation = true
    }

    func deleteModel() async {
        guard let model = modelToDelete else { return }
        guard model.backend == .ollama else {
            error = AnubisError.invalidOperation(reason: "Can only delete Ollama models")
            return
        }

        let ollamaClient = inferenceService.ollamaClient

        do {
            try await ollamaClient.deleteModel(model.id)

            // Clear selection if deleted model was selected
            if selectedModel?.id == model.id {
                selectedModel = nil
                detailedInfo = nil
            }

            // Refresh models list
            await loadModels()
        } catch {
            Log.vault.error("Failed to delete model: \(error.localizedDescription)")
            self.error = error
        }

        modelToDelete = nil
        showDeleteConfirmation = false
    }

    func unloadModel(_ model: ModelInfo) async {
        do {
            if isOMLXModel(model), let configId = model.openAIConfigId,
               let client = inferenceService.openAIClient(for: configId) {
                try await client.unloadModel(model.id)
            } else if model.backend == .ollama {
                try await inferenceService.ollamaClient.unloadModel(model.id)
            } else {
                return
            }
            await loadRunningModels()
        } catch let e as OMLXAdminError where e.isBenignNotLoaded {
            await loadRunningModels()  // already unloaded — refresh, no error
        } catch let e as OMLXAdminError {
            self.error = AnubisError.backendMessage(e.errorDescription ?? "Failed to unload model.")
        } catch {
            Log.vault.error("Failed to unload model: \(error.localizedDescription)")
            self.error = error
        }
    }

    /// Load a model into memory (oMLX only — Ollama loads lazily on first use).
    func loadModel(_ model: ModelInfo) async {
        guard isOMLXModel(model), let configId = model.openAIConfigId,
              let client = inferenceService.openAIClient(for: configId) else { return }
        do {
            try await client.loadModel(model.id)
            await loadRunningModels()
        } catch {
            Log.vault.error("Failed to load model: \(error.localizedDescription)")
            self.error = error
        }
    }

    func unloadRunningModel(_ model: RunningModel) async {
        do {
            switch model.backend {
            case .openai:
                if let configId = model.openAIConfigId,
                   let client = inferenceService.openAIClient(for: configId) {
                    try await client.unloadModel(model.name)
                }
            default:
                try await inferenceService.ollamaClient.unloadModel(model.name)
            }
            await loadRunningModels()
        } catch let e as OMLXAdminError where e.isBenignNotLoaded {
            await loadRunningModels()
        } catch let e as OMLXAdminError {
            self.error = AnubisError.backendMessage(e.errorDescription ?? "Failed to unload model.")
        } catch {
            Log.vault.error("Failed to unload model: \(error.localizedDescription)")
            self.error = error
        }
    }

    // MARK: - Model Pull

    func startPull() {
        showPullSheet = true
        pullModelName = ""
        pullStatus = ""
        pullProgress = 0
    }

    func pullModel() async {
        guard !pullModelName.isEmpty else { return }

        let ollamaClient = inferenceService.ollamaClient

        isPulling = true
        pullStatus = "Starting..."
        pullProgress = 0

        let modelName = pullModelName

        do {
            let stream = await ollamaClient.pullModel(modelName)
            for try await progress in stream {
                pullStatus = progress.status
                if let percent = progress.percentComplete {
                    pullProgress = percent
                }

                if progress.status == "success" {
                    break
                }
            }

            // Refresh models after successful pull
            await loadModels()
            showPullSheet = false
            pullModelName = ""
        } catch {
            Log.vault.error("Failed to pull model: \(error.localizedDescription)")
            pullStatus = "Error: \(error.localizedDescription)"
            self.error = error
        }

        isPulling = false
    }

    func cancelPull() {
        // Note: Ollama doesn't support canceling pulls mid-stream
        // We can only close the sheet
        showPullSheet = false
        pullModelName = ""
        pullStatus = ""
        pullProgress = 0
    }

    // MARK: - Helpers

    func isModelRunning(_ model: ModelInfo) -> Bool {
        runningModels.contains { $0.name == model.id }
    }

    var totalDiskUsage: Int64 {
        models.compactMap { $0.sizeBytes }.reduce(0, +)
    }

    var ollamaModelCount: Int {
        models.filter { $0.backend == .ollama }.count
    }

    var openAIModelCount: Int {
        models.filter { $0.backend == .openai }.count
    }

    /// Get the backend URL for a given model
    func backendURL(for model: ModelInfo) -> String {
        switch model.backend {
        case .ollama:
            return inferenceService.configManager.ollamaConfig?.baseURL ?? "http://localhost:11434"
        case .openai:
            if let configId = model.openAIConfigId,
               let config = inferenceService.configManager.configurations.first(where: { $0.id == configId }) {
                return config.baseURL
            }
            return "—"
        case .appleIntelligence:
            return "on-device"
        }
    }
}
