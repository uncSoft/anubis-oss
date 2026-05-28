//
//  FlowDocument.swift
//  anubis
//
//  Portable `.anubisflow` file format — JSON with a small wrapper
//  around the FlowStep tree. Shareable between machines and across
//  app versions; we version the format so future schema changes can
//  reject older files cleanly rather than silently misinterpreting
//  them.
//
//  Intentional non-payload omissions:
//  - Database id, createdAt, updatedAt: local-only. Imported flows
//    get a fresh row.
//  - FlowRun history: a `.anubisflow` is the recipe, not the
//    cookbook. Past runs stay on the source machine.
//

import Foundation
import UniformTypeIdentifiers

/// Top-level wrapper persisted to a `.anubisflow` file. The shape is
/// deliberately small so adding new optional fields stays
/// backward-compatible — older clients just ignore them while still
/// honoring the (name, notes, steps) core.
struct AnubisFlowDocument: Codable {
    /// Bump only when an incompatible change lands (e.g. a step kind
    /// is renamed or removed). Additive changes keep the same version.
    static let currentFormatVersion: Int = 1

    var formatVersion: Int
    var generator: String
    var exportedAt: Date

    var name: String
    var notes: String?
    var steps: [FlowStep]

    init(from flow: Flow) {
        self.formatVersion = Self.currentFormatVersion
        self.generator = Self.generatorString
        self.exportedAt = Date()
        self.name = flow.name
        self.notes = flow.notes
        self.steps = flow.steps
    }

    /// Build a fresh Flow row from this document (no id, current
    /// timestamps). Caller is responsible for inserting it into the DB.
    func makeFlow() -> Flow {
        var flow = Flow(name: name, steps: steps)
        flow.notes = notes
        return flow
    }

    // MARK: Codec

    /// Encode as pretty-printed JSON with sorted keys — exported files
    /// should diff cleanly in version control and stay human-readable.
    func encodeJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Decode a `.anubisflow` payload, rejecting unsupported format
    /// versions with a clear error rather than risking corrupted state.
    static func decode(from data: Data) throws -> AnubisFlowDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(AnubisFlowDocument.self, from: data)
        guard doc.formatVersion >= 1, doc.formatVersion <= currentFormatVersion else {
            throw FlowImportError.unsupportedFormatVersion(found: doc.formatVersion, supported: currentFormatVersion)
        }
        return doc
    }

    // MARK: Generator string

    private static var generatorString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "anubis-oss \(v)"
    }
}

/// Errors thrown during `.anubisflow` import. Surfaced verbatim to the
/// user via FlowsViewModel.lastError.
enum FlowImportError: LocalizedError {
    case unsupportedFormatVersion(found: Int, supported: Int)
    case decodeFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let found, let supported):
            return "This .anubisflow file uses format version \(found), but this build of Anubis only understands up to version \(supported). Update Anubis or re-export from a matching version."
        case .decodeFailed(let reason):
            return "Couldn't read this .anubisflow file: \(reason)"
        }
    }
}

// MARK: - UTType

/// Custom uniform type identifier for `.anubisflow` files. Conforming
/// to `.json` lets the system treat them as JSON for Quick Look,
/// drag-and-drop, etc., while the dedicated identifier scopes our open
/// and save panels so the user isn't shown every JSON file on disk.
extension UTType {
    static let anubisFlow = UTType(
        exportedAs: "com.uncsoft.anubis.flow",
        conformingTo: .json
    )
}
