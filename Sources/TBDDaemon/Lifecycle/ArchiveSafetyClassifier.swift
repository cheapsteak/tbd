import CryptoKit
import Foundation

/// Stable categories surfaced when a worktree cannot be archived safely.
public enum ArchiveArtifactCategory: String, Sendable, Equatable {
  case generatedRuntimeResidue
  case reviewableGeneratedOutput
  case uniqueUnpublishedWork
}

public struct ArchiveArtifactFinding: Sendable, Equatable {
  public let path: String
  public let category: ArchiveArtifactCategory
  public let reason: String

  public init(path: String, category: ArchiveArtifactCategory, reason: String) {
    self.path = path
    self.category = category
    self.reason = reason
  }
}

/// An attestation supplied by a trusted, out-of-worktree registry. The
/// in-worktree manifest is only an advisory copy and can never construct this
/// value by itself during archive classification.
struct TrustedBootstrapAttestation: Sendable, Equatable {
  let worktreeID: UUID
  let headSHA: String
  let producerVersion: String
  let manifestData: Data
}

/// Read-only archive preflight. `isEligible` is intentionally strict: only an
/// exact runtime overlay on a remotely published HEAD passes.
public struct ArchiveSafetyReport: Sendable, Equatable {
  public let findings: [ArchiveArtifactFinding]
  public let headIsPublished: Bool

  public init(findings: [ArchiveArtifactFinding], headIsPublished: Bool) {
    self.findings = findings
    self.headIsPublished = headIsPublished
  }

  public var runtimeResidue: [ArchiveArtifactFinding] {
    findings.filter { $0.category == .generatedRuntimeResidue }
  }

  public var reviewableGeneratedOutput: [ArchiveArtifactFinding] {
    findings.filter { $0.category == .reviewableGeneratedOutput }
  }

  public var uniqueUnpublishedWork: [ArchiveArtifactFinding] {
    findings.filter { $0.category == .uniqueUnpublishedWork }
  }

  public var isEligible: Bool {
    headIsPublished && reviewableGeneratedOutput.isEmpty && uniqueUnpublishedWork.isEmpty
  }

  /// Whether cleanup must preserve the dirty bytes before removing a worktree.
  /// Exact runtime residue is reproducible and may be discarded with the
  /// worktree; every other category remains snapshot-worthy.
  public var requiresPreservation: Bool {
    !reviewableGeneratedOutput.isEmpty || !uniqueUnpublishedWork.isEmpty
  }

  /// One alert-sized summary. Runtime residue collapses to a count; paths
  /// that require judgment remain visible.
  public var blockingSummary: String {
    var parts: [String] = []
    if !runtimeResidue.isEmpty {
      parts.append("generated runtime residue: \(runtimeResidue.count) verified path(s)")
    }
    if !reviewableGeneratedOutput.isEmpty {
      parts.append(
        "reviewable generated output: "
          + reviewableGeneratedOutput.map(\.path).sorted().joined(separator: ", ")
      )
    }
    if !uniqueUnpublishedWork.isEmpty {
      parts.append(
        "unique unpublished work: "
          + uniqueUnpublishedWork.map(\.path).sorted().joined(separator: ", ")
      )
    }
    if !headIsPublished {
      parts.append("unique unpublished work: HEAD is not reachable from a remote-tracking branch")
    }
    return parts.joined(separator: "; ")
  }
}

/// Classifies dirty worktree content from exact, versioned provenance. No path
/// family is intrinsically safe; `.agents`, `.codex`, `.Codex`, hooks, and
/// `AGENTS.md` pass only when a valid manifest names their current bytes.
public struct ArchiveSafetyClassifier: Sendable {
  public static let manifestRelativePath = ".codex/bootstrap-provenance.json"

  private let git: GitManager
  public init(git: GitManager) {
    self.git = git
  }

  func classify(
    worktreeID: UUID? = nil,
    worktreePath: String,
    trustedAttestation: TrustedBootstrapAttestation? = nil,
    knownPublished: Bool = false
  ) async -> ArchiveSafetyReport {
    let headIsPublished: Bool
    if knownPublished {
      headIsPublished = true
    } else {
      headIsPublished = await git.isHeadReachableFromAnyRemote(worktreePath: worktreePath)
    }
    let entries: [GitWorktreeStatusEntry]
    do {
      entries = try await git.worktreeStatusEntries(worktreePath: worktreePath)
    } catch {
      return ArchiveSafetyReport(
        findings: [
          ArchiveArtifactFinding(
            path: worktreePath,
            category: .uniqueUnpublishedWork,
            reason: "git status could not be verified"
          )
        ],
        headIsPublished: headIsPublished
      )
    }

    guard !entries.isEmpty else {
      return ArchiveSafetyReport(findings: [], headIsPublished: headIsPublished)
    }

    let manifestEntry = entries.first { $0.path == Self.manifestRelativePath }
    guard let worktreeID, let trustedAttestation,
      trustedAttestation.worktreeID == worktreeID,
      let currentHead = try? await git.headSHA(worktreePath: worktreePath),
      currentHead == trustedAttestation.headSHA,
      manifestEntry?.status == "??" || manifestEntry?.status == "!!",
      let advisoryData = regularFileData(
        rootPath: worktreePath, relativePath: Self.manifestRelativePath
      ),
      advisoryData == trustedAttestation.manifestData,
      let manifest = loadManifest(data: trustedAttestation.manifestData),
      manifest.producerVersion == trustedAttestation.producerVersion
    else {
      return ArchiveSafetyReport(
        findings: entries.map {
          ArchiveArtifactFinding(
            path: $0.path,
            category: .uniqueUnpublishedWork,
            reason: "no matching trusted out-of-worktree bootstrap attestation"
          )
        },
        headIsPublished: headIsPublished
      )
    }

    let artifactsByPath = Dictionary(
      uniqueKeysWithValues: manifest.artifacts.map { ($0.path, $0) }
    )
    var findings: [ArchiveArtifactFinding] = [
      ArchiveArtifactFinding(
        path: Self.manifestRelativePath,
        category: .generatedRuntimeResidue,
        reason: "valid bootstrap provenance manifest"
      )
    ]

    for entry in entries where entry.path != Self.manifestRelativePath {
      guard let artifact = artifactsByPath[entry.path] else {
        findings.append(
          ArchiveArtifactFinding(
            path: entry.path,
            category: .uniqueUnpublishedWork,
            reason: "path is outside the provenance manifest"
          ))
        continue
      }
      findings.append(
        await classify(
          entry: entry, artifact: artifact, worktreePath: worktreePath
        ))
    }

    return ArchiveSafetyReport(findings: findings, headIsPublished: headIsPublished)
  }

  private func classify(
    entry: GitWorktreeStatusEntry,
    artifact: BootstrapArtifact,
    worktreePath: String
  ) async -> ArchiveArtifactFinding {
    guard
      let currentDigest = digestForRegularFile(
        rootPath: worktreePath, relativePath: entry.path
      )
    else {
      return ArchiveArtifactFinding(
        path: entry.path,
        category: .uniqueUnpublishedWork,
        reason: "artifact is missing, unreadable, non-regular, or traverses a symlink"
      )
    }
    guard currentDigest == artifact.sha256 else {
      return ArchiveArtifactFinding(
        path: entry.path,
        category: .uniqueUnpublishedWork,
        reason: "artifact bytes differ from the provenance digest"
      )
    }

    switch artifact.kind {
    case .runtime:
      guard entry.status == "??" || entry.status == "!!" else {
        return ArchiveArtifactFinding(
          path: entry.path,
          category: .uniqueUnpublishedWork,
          reason: "runtime artifact is not untracked"
        )
      }
      return ArchiveArtifactFinding(
        path: entry.path,
        category: .generatedRuntimeResidue,
        reason: "exact untracked runtime artifact"
      )

    case .trackedMutation:
      guard entry.status != "??", let expectedBaseDigest = artifact.baseSha256 else {
        return ArchiveArtifactFinding(
          path: entry.path,
          category: .uniqueUnpublishedWork,
          reason: "tracked mutation lacks an exact committed base digest"
        )
      }
      guard
        let baseData = try? await git.headFileContents(
          worktreePath: worktreePath, path: entry.path
        ), Self.sha256(baseData) == expectedBaseDigest,
        let indexData = try? await git.indexFileContents(
          worktreePath: worktreePath, path: entry.path
        ), Self.sha256(indexData) == expectedBaseDigest
      else {
        return ArchiveArtifactFinding(
          path: entry.path,
          category: .uniqueUnpublishedWork,
          reason: "tracked mutation's committed base or index does not match provenance"
        )
      }
      return ArchiveArtifactFinding(
        path: entry.path,
        category: .generatedRuntimeResidue,
        reason: "exact tracked bootstrap mutation"
      )

    case .generatedOutput:
      return ArchiveArtifactFinding(
        path: entry.path,
        category: .reviewableGeneratedOutput,
        reason: "digest is known, but regeneration from committed inputs is unproven"
      )
    }
  }

  private func loadManifest(data: Data) -> BootstrapProvenanceManifest? {
    guard
      let manifest = try? JSONDecoder().decode(BootstrapProvenanceManifest.self, from: data),
      manifest.schemaVersion == 1,
      manifest.producer == "agent-bootstrap",
      !manifest.producerVersion.isEmpty,
      !manifest.artifacts.isEmpty
    else {
      return nil
    }

    var paths = Set<String>()
    for artifact in manifest.artifacts {
      guard isSafeRelativePath(artifact.path),
        artifact.path != Self.manifestRelativePath,
        paths.insert(artifact.path).inserted,
        Self.isSHA256(artifact.sha256)
      else {
        return nil
      }
      if artifact.kind == .trackedMutation {
        guard let base = artifact.baseSha256, Self.isSHA256(base) else { return nil }
      } else if artifact.baseSha256 != nil {
        return nil
      }
    }
    return manifest
  }

  private func digestForRegularFile(rootPath: String, relativePath: String) -> String? {
    regularFileData(rootPath: rootPath, relativePath: relativePath).map(Self.sha256)
  }

  private func regularFileData(rootPath: String, relativePath: String) -> Data? {
    guard isSafeRelativePath(relativePath) else { return nil }
    var current = URL(fileURLWithPath: rootPath, isDirectory: true)
    for component in relativePath.split(separator: "/").map(String.init) {
      current.appendPathComponent(component)
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
        let type = attributes[.type] as? FileAttributeType,
        type != .typeSymbolicLink
      else {
        return nil
      }
    }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else {
      return nil
    }
    return try? Data(contentsOf: current, options: [.mappedIfSafe])
  }

  private func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }
}

private struct BootstrapProvenanceManifest: Decodable {
  let schemaVersion: Int
  let producer: String
  let producerVersion: String
  let artifacts: [BootstrapArtifact]
}

private struct BootstrapArtifact: Decodable {
  enum Kind: String, Decodable {
    case runtime
    case trackedMutation
    case generatedOutput
  }

  let path: String
  let kind: Kind
  let sha256: String
  let baseSha256: String?
}
