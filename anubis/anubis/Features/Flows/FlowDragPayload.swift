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
        CodableRepresentation(contentType: .anubisFlowDrag)
    }
}

extension UTType {
    /// Scoped to in-process drags so payloads from other apps don't
    /// accidentally satisfy our drop destinations.
    static let anubisFlowDrag = UTType(exportedAs: "com.uncsoft.anubis.flowdrag")
}
