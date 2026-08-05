import Foundation
@testable import TBDDaemonLib

/// An `ActuationLog` writing to a unique temp path, for the many tests that
/// construct a daemon type requiring one but assert nothing about the record.
///
/// The writer creates its directory and file lazily, at the first append, so a
/// test that never actuates touches no disk at all.
///
/// This exists because the production types must NOT default the parameter to
/// `ActuationLog(path: TBDConstants.actuationLogPath)`. That default is the
/// "helper ignores its caller's injected seam" shape: ~45 construction sites
/// would silently share one real file under `$TBD_HOME`, appending to each
/// other's record and to the live daemon's whenever the fence was not in force.
public func makeTestActuationLog(tag: String = "test") -> ActuationLog {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-actuation-\(tag)-\(UUID().uuidString)", isDirectory: true)
    return ActuationLog(path: directory.appendingPathComponent("actuations.jsonl").path)
}
