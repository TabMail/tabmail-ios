#!/bin/sh
# Copy the primary checkout's private iOS build configuration into one
# registered tabmail-ios worktree without inspecting or printing its contents.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PRIMARY_REPO=$(dirname -- "$SCRIPT_DIR")
WORKSPACE_ROOT=$(dirname -- "$PRIMARY_REPO")
WORKTREE_ROOT="$WORKSPACE_ROOT/.worktrees"
SOURCE_FILE="$PRIMARY_REPO/Secrets.xcconfig"

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /absolute/path/to/tabmail-ios-worktree" >&2
    exit 64
fi

destination=${1%/}
case "$destination" in
    "$WORKTREE_ROOT"/*) ;;
    *)
        echo "refusing destination outside $WORKTREE_ROOT" >&2
        exit 65
        ;;
esac

if [ ! -f "$SOURCE_FILE" ] || [ -L "$SOURCE_FILE" ]; then
    echo "primary private configuration is missing or is a symlink" >&2
    exit 66
fi

if [ ! -d "$destination" ] || [ -L "$destination" ]; then
    echo "destination is missing or is a symlink" >&2
    exit 67
fi

resolved_top=$(git -C "$destination" rev-parse --show-toplevel 2>/dev/null || true)
resolved_common=$(git -C "$destination" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ "$resolved_top" != "$destination" ] || [ "$resolved_common" != "$PRIMARY_REPO/.git" ]; then
    echo "destination is not a registered worktree of $PRIMARY_REPO" >&2
    exit 68
fi

target="$destination/Secrets.xcconfig"
if [ -L "$target" ]; then
    echo "refusing symlink destination" >&2
    exit 69
fi

/usr/bin/install -m 600 "$SOURCE_FILE" "$target"
echo "private build configuration installed in registered worktree"
