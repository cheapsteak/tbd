import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// **The composer's controls can be found by name.** A GUI driver — cua-driver,
/// an XCUITest-shaped tool, the offscreen harness in this suite — reaches a
/// control through the accessibility tree, and the only stable handle that tree
/// carries is the identifier. Labels are not that handle: the send button is
/// named after whichever terminal it points at, the blocked banner says whatever
/// the daemon carried, and a thumbnail's sentence changes with its number.
///
/// So this suite mounts the real `MessageComposerView` in a real (offscreen)
/// window, walks the accessibility tree of the hosting view, and asserts the
/// identifiers are actually in it. Asserting on the *tree* rather than on the
/// source is the whole point: `.accessibilityIdentifier` on a container SwiftUI
/// declines to make an element at all is a no-op that reads perfectly well in a
/// diff, and every assertion here fails against the composer as it stood before
/// the identifiers were added.
///
/// **Nested under `AccessibilityBridgeSerialized`, and every body inside
/// `withAccessibilityBridge`.** SwiftUI builds no accessibility tree until a
/// client asks for one, the switch that asks is process-wide, and it changes
/// AppKit's own behavior while it is on — so it is scoped to the body that needs
/// it, and this suite is ordered against the others that care.
extension AccessibilityBridgeSerialized {
    @MainActor
    @Suite("composer accessibility identifiers")
    struct ComposerAccessibilityIdentifierTests {

        // MARK: - The core controls

        /// The container, the field, and the button: what any driver needs before
        /// it can do anything at all with the composer.
        @Test func theComposerExposesItsContainerFieldAndSendButton() async throws {
            try await withAccessibilityBridge {
                let harness = try ComposerHarness(name: "ComposerAccessibilityIdentifierTests")
                defer { harness.tearDown() }
                let wanted: Set<String> = [
                    ComposerAccessibility.root,
                    ComposerAccessibility.field,
                    ComposerAccessibility.send,
                ]
                let seen = await harness.settle(untilIdentifiers: wanted)
                #expect(wanted.isSubset(of: seen), Self.report(harness, seen))
            }
        }

        // MARK: - The completion list

        /// The list and its rows, each row addressable on its own. A list that
        /// exposed only itself would let a driver see the menu and pick nothing
        /// out of it.
        @Test func theOpenMenuExposesItselfAndEachRow() async throws {
            try await withAccessibilityBridge {
                let harness = try ComposerHarness(
                    name: "ComposerAccessibilityIdentifierTests",
                    prepare: { $0.draft.text = "/comp" })
                defer { harness.tearDown() }
                let prefix = ComposerAccessibility.menuRow(command: "")
                let seen = await harness.settle(untilAnyIdentifierHasPrefix: prefix)

                #expect(seen.contains(ComposerAccessibility.menu), Self.report(harness, seen))
                let rows = seen.filter { $0.hasPrefix(prefix) }
                #expect(!rows.isEmpty, Self.report(harness, seen))
                // Named by command, so two rows are two identifiers rather than
                // one repeated — the property that makes a specific row
                // selectable.
                #expect(rows.count > 1, Self.report(harness, seen))
                #expect(
                    rows.contains(ComposerAccessibility.menuRow(command: "compact0")),
                    Self.report(harness, seen))
            }
        }

        // MARK: - The attachment strip

        /// A staged image, its thumbnail, and its own remove button. The button
        /// is the one that had to be argued for: an attachment thumbnail was a
        /// `.combine`d element, which folds the x into the picture and leaves
        /// nothing to press.
        @Test func aStagedImageExposesItsThumbnailAndItsRemoveButton() async throws {
            try await withAccessibilityBridge {
                // Staged with no file behind it: the strip's structure is the
                // subject, and a thumbnail that never decodes reaches its final
                // shape a pump sooner.
                let harness = try ComposerHarness(
                    name: "ComposerAccessibilityIdentifierTests",
                    prepare: { try $0.stage(png: nil) })
                defer { harness.tearDown() }
                let wanted: Set<String> = [
                    ComposerAccessibility.attachments,
                    ComposerAccessibility.attachmentItem(number: 1),
                    ComposerAccessibility.attachmentRemove(number: 1),
                ]
                let seen = await harness.settle(untilIdentifiers: wanted)
                #expect(wanted.isSubset(of: seen), Self.report(harness, seen))
            }
        }

        // MARK: - The two banners

        /// Blocked: the sentence, and the button that gets somebody to the
        /// dialog. Built from the terminal's own `awaitingInputReason`, so the
        /// state under test is the one the daemon's record would produce.
        @Test func theBlockedBannerExposesItsMessageAndRevealButton() async throws {
            try await withAccessibilityBridge {
                let harness = try ComposerHarness(
                    name: "ComposerAccessibilityIdentifierTests",
                    terminal: {
                        ComposerHarness.blockedTerminal(
                            worktreeID: $0, message: "Claude is asking something")
                    })
                defer { harness.tearDown() }
                let wanted: Set<String> = [
                    ComposerAccessibility.blockedMessage,
                    ComposerAccessibility.blockedReveal,
                ]
                let seen = await harness.settle(untilIdentifiers: wanted)
                #expect(wanted.isSubset(of: seen), Self.report(harness, seen))
            }
        }

        /// Not running: the note explaining that a send resumes the session.
        @Test func theNotRunningNoteIsExposed() async throws {
            try await withAccessibilityBridge {
                let harness = try ComposerHarness(
                    name: "ComposerAccessibilityIdentifierTests",
                    terminal: { ComposerHarness.parkedTerminal(worktreeID: $0, exited: true) })
                defer { harness.tearDown() }
                let seen = await harness.settle(
                    untilIdentifiers: [ComposerAccessibility.note])
                #expect(seen.contains(ComposerAccessibility.note), Self.report(harness, seen))
            }
        }

        /// And the note is not there when the session is running — so the
        /// assertion above is about the state and not about a string that is
        /// always present.
        @Test func theNotRunningNoteIsAbsentWhileRunning() async throws {
            try await withAccessibilityBridge {
                let harness = try ComposerHarness(name: "ComposerAccessibilityIdentifierTests")
                defer { harness.tearDown() }
                _ = await harness.settle(untilIdentifiers: [ComposerAccessibility.field])
                let seen = harness.host.accessibilityIdentifiers()
                #expect(!seen.contains(ComposerAccessibility.note), Self.report(harness, seen))
                #expect(
                    !seen.contains(ComposerAccessibility.blockedReveal),
                    Self.report(harness, seen))
            }
        }

        /// What the tree held, and the tree itself — so a failure names the state
        /// it gave up in rather than only the identifier it wanted.
        private static func report(_ harness: ComposerHarness, _ seen: Set<String>) -> Comment {
            Comment(rawValue: """
                the tree held: \(seen.sorted().joined(separator: ", "))
                \(harness.host.accessibilityTreeDescription())
                """)
        }
    }
}
