import TBDShared

/// One row in the branch picker's combined branches + open-PRs list.
///
/// - `branch != nil, pr == nil`  → plain branch row.
/// - `branch != nil, pr != nil`  → same-repo PR decorating an existing branch
///   (selecting it checks out the branch; the PR number is stamped for status).
/// - `branch == nil, pr != nil`  → PR-only row (fork PR, or a same-repo PR whose
///   head branch has not been fetched locally). Selecting it fetches the PR head.
struct PickerItem: Equatable, Identifiable {
    let branch: BranchInfo?
    let pr: OpenPRInfo?
    var id: String { branch?.name ?? "pr-\(pr!.number)" }
}

/// Merge open PRs into the branch list. A non-fork PR whose `headRefName` matches
/// a branch row's `localName` decorates that (first-matching) row; every other PR
/// — fork PRs, and non-fork PRs with no local branch — becomes its own row,
/// inserted after local branches and before the first remote branch. Existing
/// branch order is preserved.
func mergePickerItems(branches: [BranchInfo], prs: [OpenPRInfo]) -> [PickerItem] {
    let branchLocalNames = Set(branches.map(\.localName))

    // A PR decorates a branch only when it is same-repo AND some branch carries
    // its head name. Fork PRs never decorate (a fork head like "main" can collide
    // with an unrelated local branch — see forkDoesNotDecorateCoincidentalLocal).
    // Only ONE PR per head branch can claim the decoration slot; any same-repo PR
    // that loses the race (two PRs sharing a head, e.g. same head → different
    // base) must still surface as its own PR-only row rather than vanish.
    var decoration: [String: OpenPRInfo] = [:]
    var claimed = Set<Int>()   // PR numbers that took a decoration slot
    for pr in prs where !pr.isCrossRepository && branchLocalNames.contains(pr.headRefName) {
        if decoration[pr.headRefName] == nil {
            decoration[pr.headRefName] = pr
            claimed.insert(pr.number)
        }
    }
    let prOnly = prs.filter { !claimed.contains($0.number) }
    let prOnlyRows = prOnly.map { PickerItem(branch: nil, pr: $0) }

    var result: [PickerItem] = []
    var insertedPROnly = false
    for branch in branches {
        if branch.isRemote && !insertedPROnly {
            result.append(contentsOf: prOnlyRows)
            insertedPROnly = true
        }
        // Only the first branch row for a given localName gets the pill.
        let pr = decoration.removeValue(forKey: branch.localName)
        result.append(PickerItem(branch: branch, pr: pr))
    }
    if !insertedPROnly { result.append(contentsOf: prOnlyRows) }
    return result
}

/// Case-insensitive typeahead: branch name/localName, PR number, PR title, owner
/// login, and (for PR-only rows) the head branch name shown as the row title.
func matchesFilter(_ item: PickerItem, query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if q.isEmpty { return true }
    if let b = item.branch,
       b.name.lowercased().contains(q) || b.localName.lowercased().contains(q) {
        return true
    }
    if let pr = item.pr {
        if String(pr.number).contains(q) { return true }
        if pr.title.lowercased().contains(q) { return true }
        if pr.headOwner.lowercased().contains(q) { return true }
        if pr.headRefName.lowercased().contains(q) { return true }
    }
    return false
}
