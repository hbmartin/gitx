# Deterministic runtime scenarios

Choose the smallest scenario that exercises the behavior under review. The launch harness sets the corresponding test environment and creates its local fixture data.

## Milestone 2

- `push-create`: create a remote-backed push flow.
- `existing-pull-request`: surface an already-existing pull request.
- `exact-checkout`: checkout the exact requested revision.
- `deep-link`: open a supported repository deep link.
- `deep-link-no-checkout`: open a deep link without changing checkout.
- `staging-create`: stage changes and create the associated operation.
- `sync-fork`: exercise fork synchronization.

Launch with `scripts/run_app.sh --m2 <scenario>`.

## Milestone 3

- `review`: exercise review presentation and decisions.
- `suggested-change`: apply a suggested change.
- `lifecycle`: exercise termination and pending-operation lifecycle behavior.
- `merge`: complete the merge journey.
- `queue-delete`: delete a queued operation.
- `post-merge`: exercise state after merging.

Launch with `scripts/run_app.sh --m3 <scenario>`.

For every scenario, identify the recorded repository window with `scripts/observe_app.sh id`, assert the expected state through `tree` or `see`, capture a current diagnostic image, and inspect logs for the decision being verified.
