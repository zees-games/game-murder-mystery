#!/bin/bash
# Publishes this game's pack. Linked addons (symlinks in addons/) are left out: the host ships them; any game-owned addon
# committed there still ships. maps/ and maps_extra/ link to map repos (maps is its own pack, murder-mystery-maps).
# tools/, ci/ and game.sh hold scripts the site refuses; art-src, reports and screenshots are not runtime content.
#   tools/publish.sh VERSION [extra publish_pack.sh flags, e.g. --site URL --token-file F --lock F --dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V=${1:?usage: tools/publish.sh VERSION [flags]}; shift
EX=(); for l in "$HERE"/addons/*; do [ -L "$l" ] && EX+=(--exclude-dir "$(basename "$l")"); done
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id game-murder-mystery --version "$V" \
    "${EX[@]}" --exclude-dir maps --exclude-dir maps_extra --exclude-dir tools --exclude-dir ci --exclude-dir art-src \
    --exclude-dir reports --exclude-dir screenshots \
    --lock "$HERE/content.lock.json" "$@"
