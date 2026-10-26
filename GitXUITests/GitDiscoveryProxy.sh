#!/bin/sh
# Bundle before signing: the sandboxed UI runner cannot create executable scripts.
set -eu
if [ "${1-}" = --version ] && [ ! -e "${GITX_DISCOVERY_PROXY_RELEASE:?}" ]; then
    : > "${GITX_DISCOVERY_PROXY_STARTED:?}"
    read -r token < "${GITX_DISCOVERY_PROXY_GATE:?}"
fi
exec /usr/bin/git "$@"
