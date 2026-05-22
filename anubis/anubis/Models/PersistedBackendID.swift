//
//  PersistedBackendID.swift
//  anubis
//

import Foundation

/// A backend the user last selected. Persisted to UserDefaults so the
/// app reopens on the same backend they were using — no Ollama-default
/// bias for users who run only LM Studio, MLX, vLLM, or Apple Intelligence.
///
/// For `.openai`, the specific OpenAI-compatible configuration is identified
/// by `openAIConfigId`. For `.ollama` and `.appleIntelligence` the type alone
/// is sufficient.
struct PersistedBackendID: Codable, Equatable {
    let type: InferenceBackendType
    let openAIConfigId: UUID?

    init(type: InferenceBackendType, openAIConfigId: UUID? = nil) {
        self.type = type
        self.openAIConfigId = openAIConfigId
    }

    // MARK: - UserDefaults bridge

    /// Load the persisted selection, or nil if none / corrupt.
    static func load() -> PersistedBackendID? {
        guard let data = UserDefaults.standard.data(forKey: Constants.UserDefaultsKeys.lastUsedBackend)
        else { return nil }
        return try? JSONDecoder().decode(PersistedBackendID.self, from: data)
    }

    /// Persist this selection and stamp the last-used time.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Constants.UserDefaultsKeys.lastUsedBackend)
            UserDefaults.standard.set(Date(), forKey: Constants.UserDefaultsKeys.lastUsedAt)
        }
    }

    /// Last-used timestamp, if any. Used for the "last used Xh ago" picker subtitle.
    static var lastUsedAt: Date? {
        UserDefaults.standard.object(forKey: Constants.UserDefaultsKeys.lastUsedAt) as? Date
    }
}

/// Per-backend last-used model name. Scoped to the persisted backend so
/// switching backends doesn't carry over a model name that doesn't exist
/// on the new one.
enum PersistedModelSelection {
    static func load() -> String? {
        UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastUsedModelName)
    }

    static func save(_ name: String?) {
        if let name = name, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: Constants.UserDefaultsKeys.lastUsedModelName)
        } else {
            UserDefaults.standard.removeObject(forKey: Constants.UserDefaultsKeys.lastUsedModelName)
        }
    }
}
