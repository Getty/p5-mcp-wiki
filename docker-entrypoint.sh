#!/bin/bash
set -e

# The wiki root mcp-wiki will serve: the last --wiki-root in the arguments,
# else /wiki, the image's WORKDIR and so mcp-wiki's default "."
WIKI_DIR=/wiki
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
    case "${ARGS[i]}" in
        --wiki-root)   [ $((i + 1)) -lt ${#ARGS[@]} ] && WIKI_DIR="${ARGS[i + 1]}" ;;
        --wiki-root=*) WIKI_DIR="${ARGS[i]#--wiki-root=}" ;;
    esac
done

# The container runs as the user it was started as (appuser, uid 1000, unless
# --user says otherwise) and never changes the ownership of what is mounted.
if [ ! -d "$WIKI_DIR" ]; then
    echo "mcp-wiki: the wiki root $WIKI_DIR does not exist; mount the wiki there (-v DIR:$WIKI_DIR) or pass --wiki-root." >&2
    exit 1
fi
if [ ! -w "$WIKI_DIR" ]; then
    echo "mcp-wiki: the wiki root $WIKI_DIR is not writable for uid $(id -u)." >&2
    echo "mcp-wiki: run the container as the owner of the mounted directory (docker run --user UID:GID ...) or give uid $(id -u) write access to it." >&2
    exit 1
fi

# No shell in between: "$@" reaches mcp-wiki as it was given, spaces included
exec mcp-wiki "$@"
