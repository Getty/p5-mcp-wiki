#!/bin/bash
set -e

WIKI_DIR="${MCP_WIKI_ROOT:-/wiki}"

# Started as a plain user (docker run --user): nothing to drop, just run
if [ "$(id -u)" != "0" ]; then
    exec mcp-wiki "$@"
fi

# Run as the owner of the mounted wiki, so files written there stay the
# owner's. A root-owned (fresh) volume is handed to the default user instead.
RUN_UID=$(stat -c '%u' "$WIKI_DIR" 2>/dev/null || echo 0)
RUN_GID=$(stat -c '%g' "$WIKI_DIR" 2>/dev/null || echo 0)
if [ "$RUN_UID" = "0" ]; then
    RUN_UID=1000
    RUN_GID=1000
    chown "$RUN_UID:$RUN_GID" "$WIKI_DIR"
fi

# No shell in between: "$@" reaches mcp-wiki as it was given, spaces included
export HOME=/home/appuser
exec setpriv --reuid "$RUN_UID" --regid "$RUN_GID" --clear-groups mcp-wiki "$@"
