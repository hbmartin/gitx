#!/bin/sh
# The UI runner executes this signed-bundle resource directly. Only disposable
# per-test state is written beneath the explicitly supplied fixture root.
worktree_proxy_root=${GITX_UITEST_WORKTREE_PROXY_ROOT:?Missing worktree proxy fixture root}
worktree_proxy_detached=${GITX_UITEST_WORKTREE_PROXY_DETACHED:?Missing worktree proxy checkout}
worktree_proxy_reason=${GITX_UITEST_WORKTREE_PROXY_REASON:?Missing worktree proxy lock reason}
worktree_proxy_git=${GITX_UITEST_WORKTREE_PROXY_GIT:?Missing concrete Git executable}

if [ "$1" = --version ] || [ "$2" = --version ]; then
    worktree_version_base="$worktree_proxy_root/proxy-version-diagnostics/$$"
    printf '%s\0' "$@" > "$worktree_version_base.arguments"
    "$worktree_proxy_git" "$@" > "$worktree_version_base.stdout" 2> "$worktree_version_base.stderr"
    worktree_version_status=$?
    printf '%s\n' "$worktree_version_status" > "$worktree_version_base.exit"
    /bin/cat "$worktree_version_base.stdout"
    /bin/cat "$worktree_version_base.stderr" >&2
    exit "$worktree_version_status"
fi

if [ "$2" = worktree ] && [ "$3" = lock ] && [ "$4" = --reason ] && [ "$5" = "$worktree_proxy_reason" ] && [ "$6" = "$worktree_proxy_detached" ]; then
    printf '%s\0' "$@" > "$worktree_proxy_root/lock-arguments"
    : > "$worktree_proxy_root/writer-started"
    worktree_attempts=0
    while [ ! -f "$worktree_proxy_root/writer-release" ]; do
        [ "$worktree_attempts" -lt 600 ] || exit 124
        /bin/sleep 0.1
        worktree_attempts=$((worktree_attempts + 1))
    done
fi

if [ "$2" = worktree ] && [ "$3" = repair ]; then
    printf '%s\0' "$@" > "$worktree_proxy_root/repair-arguments"
    printf x >> "$worktree_proxy_root/repair-invocations"
fi
exec "$worktree_proxy_git" "$@"
