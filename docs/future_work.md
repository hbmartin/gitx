# Future Work: Grow GitXCore Deliberately

## Current Boundary

`GitXCore` is a local Swift package containing Foundation-only domain and presentation decisions. `GitX.app` links the package and owns AppKit, ObjectiveGit, persistence adapters, process execution, and Objective-C compatibility facades.

The package currently owns:

- application-preference validation and repository view-state identity;
- commit remote presentation and submission eligibility;
- history-search normalization and Git argument construction;
- repository-configuration validation and commit-message rules;
- sidebar remote synchronization and revision placement.

`swift test --package-path GitXCore --enable-code-coverage` is the canonical hostless test command. CI runs it as a job separate from app-hosted XCTest and enforces `GitXCore/coverage-baseline.json`. `scripts/check_gitxcore_boundary.py` rejects application and global-runtime dependencies.

## Next Candidates

Move behavior in narrow, behavior-preserving slices:

1. Relative-date calculation. Inject `now` and `Calendar`; retain the Objective-C-visible formatter as the app adapter.
2. Revision-specifier parsing and reference-name classification. Keep conversion to ObjectiveGit values in the app.
3. Source-language lookup from `PBHighlighting`. Keep attributed-string construction and HighlightKit in the app.
4. History menu eligibility, staging eligibility, split limits, and retry delays when those decisions are next changed.
5. URL-provider and remote-selection decisions currently coupled to `RepositoryRemoteURLCoordinator`.

Do not move repository access, `NSDocument`, mutable ObjectiveGit models, AppKit values, defaults storage, notifications, file watchers, or task execution into the package.

## Migration Rule

For each slice:

1. Characterize the current app behavior.
2. Define explicit Foundation inputs and outputs.
3. Add equivalent XCTest coverage in `GitXCoreTests`.
4. Implement the policy and retain a thin app adapter where Objective-C compatibility requires it.
5. Run core and app-hosted suites and ratchet both coverage policies.
6. Remove app characterization only when the same observable contract remains covered at the lower layer.

## Success Criteria

- Core tests remain hostless, deterministic, and fast.
- Every package source is represented in the nondecreasing coverage baseline.
- The app depends on `GitXCore`; the package never depends on the app.
- New controller decision logic normally enters through a tested core value.
- New packages or targets require a distinct ownership boundary, not just directory size.

## Deferred Build Work

Dependency and script-phase tuning is intentionally separate from core extraction. See `docs/build-performance-followups.md`.
