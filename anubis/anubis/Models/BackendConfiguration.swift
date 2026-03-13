//
//  BackendConfiguration.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation
import Combine

/// Configuration for a backend endpoint
struct BackendConfiguration: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var type: BackendType
    var baseURL: String
    var isEnabled: Bool
    var apiKey: String?  // Optional API key for some servers

    enum BackendType: String, Codable, CaseIterable {
        case ollama = "ollama"
        case openaiCompatible = "openai"

        var displayName: String {
            switch self {
            case .ollama: return "Ollama"
            case .openaiCompatible: return "OpenAI Compatible"
            }
        }

        var icon: String {
            switch self {
            case .ollama: return "server.rack"
            case .openaiCompatible: return "globe"
            }
        }

        /// Decode with migration: old "mlx" type becomes openaiCompatible
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if rawValue == "mlx" {
                self = .openaiCompatible
            } else if let value = BackendType(rawValue: rawValue) {
                self = value
            } else {
                self = .openaiCompatible
            }
        }
    }

    /// Default Ollama configuration
    static let defaultOllama = BackendConfiguration(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Ollama (Local)",
        type: .ollama,
        baseURL: "http://localhost:11434",
        isEnabled: true
    )

    /// Default MLX configuration (mlx-lm serve)
    static let defaultMLX = BackendConfiguration(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "MLX",
        type: .openaiCompatible,
        baseURL: "http://localhost:8080",
        isEnabled: true
    )

    /// Default LM Studio configuration
    static let defaultLMStudio = BackendConfiguration(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "LM Studio",
        type: .openaiCompatible,
        baseURL: "http://localhost:1234",
        isEnabled: true
    )

    /// Default vLLM configuration
    static let defaultVLLM = BackendConfiguration(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "vLLM",
        type: .openaiCompatible,
        baseURL: "http://localhost:8000",
        isEnabled: true
    )

    /// IDs of built-in default configurations that cannot be deleted
    static let defaultIDs: Set<UUID> = [
        defaultOllama.id,
        defaultMLX.id,
        defaultLMStudio.id,
        defaultVLLM.id
    ]
}

/// Manages backend configurations
class BackendConfigurationManager: ObservableObject {
    @Published var configurations: [BackendConfiguration] {
        didSet {
            save()
        }
    }

    private let userDefaultsKey = "backend_configurations"

    private static let allDefaults: [BackendConfiguration] = [
        .defaultOllama,
        .defaultMLX,
        .defaultLMStudio,
        .defaultVLLM
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let configs = try? JSONDecoder().decode([BackendConfiguration].self, from: data) {
            // Ensure all built-in defaults exist (migration for existing users)
            var merged = configs
            for defaultConfig in Self.allDefaults {
                if !merged.contains(where: { $0.id == defaultConfig.id }) {
                    merged.append(defaultConfig)
                }
            }
            self.configurations = merged
        } else {
            self.configurations = Self.allDefaults
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    func addConfiguration(_ config: BackendConfiguration) {
        configurations.append(config)
    }

    func removeConfiguration(_ config: BackendConfiguration) {
        // Don't allow removing built-in default backends
        guard !BackendConfiguration.defaultIDs.contains(config.id) else { return }
        configurations.removeAll { $0.id == config.id }
    }

    func updateConfiguration(_ config: BackendConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
        }
    }

    /// Get enabled configurations
    var enabledConfigurations: [BackendConfiguration] {
        configurations.filter { $0.isEnabled }
    }

    /// Get Ollama configuration (there should be exactly one)
    var ollamaConfig: BackendConfiguration? {
        configurations.first { $0.type == .ollama }
    }

    /// Get all OpenAI-compatible configurations
    var openAIConfigs: [BackendConfiguration] {
        configurations.filter { $0.type == .openaiCompatible && $0.isEnabled }
    }
}
