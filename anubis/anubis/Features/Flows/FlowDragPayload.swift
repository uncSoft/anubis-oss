//
//  FlowDragPayload.swift
//  anubis
//
//  Single payload type the editor's drag-and-drop machinery moves
//  around. Carries either a brand-new step to materialise (dragged
//  from the palette) or the id of an existing step the user is
//  reordering. Drop targets switch on the case and route to the
//  appropriate viewmodel mutation.
//
//  Using one Transferable for both flavours keeps drop destinations
//  simple — they accept FlowDragPayload, not two separate types.
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct FlowDragPayload: Codable, Transferable {
    enum Source: Codable {
        /// A palette item — drop creates a fresh FlowStep wrapping
        /// the kind.
        case newStep(kind: FlowStepKind)
        /// An existing row being reordered — drop relocates the step
        /// with this id to the drop target's path.
        case existingStep(id: UUID)
    }

    var source: Source

    static var transferRepresentation: some TransferRepresentation {
        // The init/visit/exporting/importing of the representation
        // ought to fire when the system serialises us to the
        // pasteboard. If we never see this print, the Transferable
        // protocol-wiring itself is the problem.
        CodableRepresentation(contentType: .anubisFlowDrag)
            .visibility(.all)
    }

    /// Custom encoder so we can see exactly when (and what) the
    /// system asks us to serialise to the pasteboard. Without this
    /// hook, a failed encode would just produce an empty pasteboard
    /// item silently.
    func encode(to encoder: Encoder) throws {
        print("[DragDrop] FlowDragPayload.encode called — source=\(source)")
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
    }

    init(source: Source) {
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = try c.decode(Source.self, forKey: .source)
        print("[DragDrop] FlowDragPayload.init(from:) called — source=\(s)")
        self.source = s
    }

    enum CodingKeys: String, CodingKey { case source }
}

extension UTType {
    /// Scoped to in-process drags so payloads from other apps don't
    /// accidentally satisfy our drop destinations.
    static let anubisFlowDrag = UTType(exportedAs: "com.uncsoft.anubis.flowdrag")
}
