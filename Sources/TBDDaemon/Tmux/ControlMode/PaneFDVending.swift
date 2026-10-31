import Foundation

/// The fd sidecar as the control-mode bridge holds it: what the attach
/// handlers vend pane descriptors through. `FDVendingServer` conforms.
protocol PaneFDVending: Sendable {
    func send(fd: Int32, header: Data) async throws
    func sendReportingRecipient(fd: Int32, header: Data) async throws -> ProcessIdentity?
}
