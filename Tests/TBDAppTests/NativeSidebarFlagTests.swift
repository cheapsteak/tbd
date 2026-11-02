import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: the storage contract only.

/// The `useAppKitSidebar` flag's three-state storage contract.
@MainActor
@Suite("Native sidebar flag")
struct NativeSidebarFlagTests {
    // MARK: Storage

    @Test func flagUnsetReadsDefault() {
        let suite = TestDefaultsSuite("NativeSidebarFlagTests.unset")
        defer { suite.tearDown() }
        #expect(AppState.appKitSidebarDefault == false)
        #expect(suite.defaults.object(forKey: AppState.appKitSidebarKey) == nil)
        #expect(AppState.appKitSidebarEnabled(suite.defaults) == AppState.appKitSidebarDefault)
        #expect(AppState.appKitSidebarEnabled(suite.defaults) == false)
    }

    /// The graduation rehearsal: flip the shipped default to `true` and check
    /// that only the untouched state follows it.
    @Test func explicitFalseSurvivesDefaultChange() {
        #expect(!AppState.appKitSidebarEnabled(stored: false, shippedDefault: true))
        #expect(!AppState.appKitSidebarEnabled(stored: false, shippedDefault: false))
        #expect(AppState.appKitSidebarEnabled(stored: true, shippedDefault: false))
        #expect(AppState.appKitSidebarEnabled(stored: nil, shippedDefault: true))
        #expect(!AppState.appKitSidebarEnabled(stored: nil, shippedDefault: false))

        let suite = TestDefaultsSuite("NativeSidebarFlagTests.explicit")
        defer { suite.tearDown() }
        suite.defaults.set(false, forKey: AppState.appKitSidebarKey)
        #expect(suite.defaults.object(forKey: AppState.appKitSidebarKey) as? Bool == false)
        #expect(!AppState.appKitSidebarEnabled(suite.defaults))
        suite.defaults.set(true, forKey: AppState.appKitSidebarKey)
        #expect(AppState.appKitSidebarEnabled(suite.defaults))
    }
}
