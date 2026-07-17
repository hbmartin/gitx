import AppKit

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBHistoryBranchFilterPresentation)
final class HistoryBranchFilterPresentation: NSObject {
    @objc let allEnabled: Bool
    @objc let localEnabled: Bool
    @objc let allState: NSControl.StateValue
    @objc let localState: NSControl.StateValue
    @objc let selectedState: NSControl.StateValue
    @objc let selectedTitle: String
    @objc let localTitle: String

    init(simpleBranch: Bool, filter: Int, selectedTitle: String, remote: Bool) {
        allEnabled = simpleBranch
        localEnabled = simpleBranch
        allState = simpleBranch && filter == kGitXAllBranchesFilter.rawValue ? .on : .off
        localState = simpleBranch && filter == kGitXLocalRemoteBranchesFilter.rawValue ? .on : .off
        selectedState = !simpleBranch || filter == kGitXSelectedBranchFilter.rawValue ? .on : .off
        self.selectedTitle = selectedTitle
        localTitle = remote
            ? NSLocalizedString("Remote", comment: "Filter button for all remote commits in history view")
            : NSLocalizedString("Local", comment: "Filter button for all local commits in history view")
    }
}

@objc(PBHistoryStateCoordinator)
final class HistoryStateCoordinator: NSObject {
    private var savedTreePath: [String] = []

    @objc(normalizedSelection:)
    func normalizedSelection(_ selection: [PBGitCommit]) -> [PBGitCommit] {
        guard selection.count > 1,
              let workingState = selection.first(where: { $0 is PBUncommittedChanges })
        else { return selection }
        return [workingState]
    }

    @objc(preservedSelection:inContent:)
    func preservedSelection(_ selection: [PBGitCommit], in content: [PBGitCommit]) -> [PBGitCommit]? {
        guard !selection.isEmpty else { return nil }
        let preserved = selection.compactMap { selected in
            content.first { $0.oid == selected.oid }
        }
        guard preserved.count == selection.count else { return nil }
        NSLog("[GitX] History selection preservation result: %lu commits", preserved.count)
        return preserved
    }

    @objc(detailIndexForCurrentIndex:selectionCount:)
    func detailIndex(currentIndex: Int, selectionCount: Int) -> Int {
        selectionCount > 1 && currentIndex == 1 ? 0 : currentIndex
    }

    @objc(statusForArrangedCount:hasWorkingState:)
    func status(arrangedCount: Int, hasWorkingState: Bool) -> String {
        "\(max(0, arrangedCount - (hasWorkingState ? 1 : 0))) commits loaded"
    }

    @objc(selectionIndexesForProposedSelection:hasWorkingState:)
    func selectionIndexes(proposed: IndexSet, hasWorkingState: Bool) -> IndexSet {
        proposed.contains(0) && hasWorkingState && proposed.count > 1 ? IndexSet(integer: 0) : proposed
    }

    @objc(branchFilterPresentationForSimpleBranch:filter:selectedTitle:remote:)
    func branchFilterPresentation(
        simpleBranch: Bool,
        filter: Int,
        selectedTitle: String,
        remote: Bool
    ) -> HistoryBranchFilterPresentation {
        HistoryBranchFilterPresentation(
            simpleBranch: simpleBranch,
            filter: filter,
            selectedTitle: selectedTitle,
            remote: remote
        )
    }

    @objc(saveFileBrowserSelectionFromSelectedObjects:hasContent:)
    func saveFileBrowserSelection(selectedObjects: [NSObject], hasContent: Bool) {
        guard hasContent,
              let fullPath = selectedObjects.first?.value(forKey: "fullPath") as? String
        else {
            NSLog("[GitX] File-browser selection was not saved: content=%@ selected=%lu", hasContent ? "yes" : "no", selectedObjects.count)
            return
        }
        savedTreePath = fullPath.components(separatedBy: "/")
        NSLog("[GitX] Saved file-browser selection: %@", fullPath)
    }

    @objc(treeSelectionIndexPathForChildren:treeMode:)
    func treeSelectionIndexPath(children initialChildren: [NSObject], treeMode: Bool) -> IndexPath? {
        guard treeMode, !initialChildren.isEmpty else { return nil }
        guard !savedTreePath.isEmpty else { return IndexPath(index: 0) }

        let savedFullPath = savedTreePath.joined(separator: "/")
        if let index = initialChildren.firstIndex(where: {
            ($0.value(forKey: "fullPath") as? String) == savedFullPath
        }) {
            return IndexPath(index: index)
        }

        var children = initialChildren
        var result = IndexPath()
        for component in savedTreePath {
            guard let index = children.firstIndex(where: {
                ($0.value(forKey: "path") as? String) == component
            }) else {
                NSLog("[GitX] Could not restore file-browser selection component: %@", component)
                return nil
            }
            result = result.appending(index)
            children = children[index].value(forKey: "children") as? [NSObject] ?? []
        }
        NSLog("[GitX] Restored file-browser selection: %@", savedTreePath.joined(separator: "/"))
        return result
    }

    @objc(selectedObjectsForOID:content:fallback:)
    func selectedObjects(
        for oid: GTOID?,
        content: [PBGitCommit],
        fallback: PBGitCommit?
    ) -> [PBGitCommit] {
        let matches = content.filter { $0.oid == oid }
        if matches.isEmpty, let fallback {
            return [fallback]
        }
        return matches
    }

    @objc(adjustedScrollRowForSelectionRow:oldRow:visibleRows:contentCount:)
    func adjustedScrollRow(selectionRow: Int, oldRow: Int, visibleRows: Int, contentCount: Int) -> Int {
        guard contentCount > 0, selectionRow > oldRow else { return selectionRow }
        let offset = max(0, visibleRows - 1)
        guard selectionRow <= Int.max - offset else { return contentCount - 1 }
        return min(selectionRow + offset, contentCount - 1)
    }
}

// swiftlint:enable unused_declaration
