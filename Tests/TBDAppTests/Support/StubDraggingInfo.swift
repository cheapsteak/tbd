import AppKit
import Foundation
@testable import TBDApp

/// An `NSDraggingInfo` over a uniquely named pasteboard, for driving
/// `validateDrop` and `acceptDrop` without a drag session. Call `release()`
/// once done with it.
@MainActor
final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    /// Where the pointer is, in window coordinates.
    var draggingLocation: NSPoint = .zero
    let draggingSequenceNumber = Int.random(in: 1...Int.max)
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
        super.init()
    }

    /// A fresh pasteboard holding `writers`, one item each.
    convenience init(writing writers: [any NSPasteboardWriting]) {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        _ = pasteboard.writeObjects(writers)
        self.init(pasteboard: pasteboard)
    }

    /// A fresh pasteboard carrying one sidebar row, as the sidebar's writer
    /// puts it there.
    convenience init(carrying id: UUID) {
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: .tbdSidebarWorktrees)
        self.init(writing: [item])
    }

    func release() {
        draggingPasteboard.releaseGlobally()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    // `namesOfPromisedFilesDropped(atDestination:)` is deliberately absent: the inherited `NSObject` implementation satisfies the requirement.

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

    func resetSpringLoading() {}
}
