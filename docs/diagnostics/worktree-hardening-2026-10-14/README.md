These unmodified XCTest attachments document the worktree ownership, recovery and sidebar fixes on top of merged PR #91. They are diagnostics; no pixel comparison test was added. The provenance file records source hashes and exact run receipts. These precommit checks do not substitute for the final full postcommit profile.

- [Reclaim consent](reclaim-consent.png): the original missing Gitfile requires separate consent; Cancel is the default and an actual Return key cancels without reconstructing the link.
- [Manual guidance](manual-guidance.png): a moved checkout with a symlink Gitfile receives reachable repair guidance and remains protected from prune.
- [Duplicate-row menu](duplicate-row-menu.png): the unlocked clicked checkout offers Lock and Remove while the other checkout stays locked; branch reference actions remain available.
- [Renewed prune confirmation](renewed-prune-consent.png): changed candidates require another Prune action.
- [Explicit History](explicit-history.png): Cmd-1 adopts the newest captured detached HEAD, including a commit reachable only from that checkout.

The green characterization commit is `27f05a8e3215e71caf6d32d6160478d47f64e363`. Baseline production remained unchanged while the first regressions failed locally. Additional direct report cancellation was also proved red before its phase-aware fix. Later passing focused runs contain 112 native tests, 111 complete Core tests, five worktree UI journeys and all 33 existing Release performance tests. Complete correctness/package coverage, coverage ratchets and the final 14-check run remain required.

Release capture measurements use five samples at each inventory size. The historical column came from unchanged production; the two paired columns alternate repeated/indexed capture order on the same healthy fixture in the current implementation. Fixture setup and independent complete filesystem proof remain outside the measured workload. They measure the capture algorithm, not end-to-end Git latency, and introduce no timing floor.

| Registrations | Historical repeated capture p95 | Paired repeated capture p95 | Paired indexed capture p95 |
| --- | ---: | ---: | ---: |
| 8 | 15.97 ms | 15.24 ms | 4.14 ms |
| 32 | 217.69 ms | 195.64 ms | 15.53 ms |
| 128 | 3453.01 ms | 2927.67 ms | 61.91 ms |

Core probe-count tests require one administrative inventory per phase and bounded per-entry reads at multiple sizes. An actual service preparation worker is held while the main actor makes observable progress and the next writer waits for FIFO admission. Admitted writes and operation-owned reconciliation retain their original canonical Git context after preferences change.

The obsolete suspended `worktree-review-final-v3` coordinator was preserved and retired before source changed. Its receipts remain referenced by provenance; it was never resumed against these changes. Resource locks were not altered manually.

Consent is revalidated while holding the shared FIFO. Git runs as a separate process, so these checks cannot make multi-file operations atomic against arbitrary external filesystem or Git activity.
