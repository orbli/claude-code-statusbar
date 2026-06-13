#!/usr/bin/env bash
# Install claude-code-statusbar: copy statusline.sh into ~/.claude and wire it into
# settings.json without clobbering existing settings.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline.sh"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dest="$claude_dir/statusline.sh"
settings="$claude_dir/settings.json"

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
mkdir -p "$claude_dir"
install -m 0755 "$src" "$dest"
echo "installed: $dest"

[ -f "$settings" ] || echo '{}' > "$settings"
tmp="$(mktemp)"
jq --arg cmd "$dest" '.statusLine = {type:"command", command:$cmd}' "$settings" > "$tmp" && mv "$tmp" "$settings"
echo "configured: $settings -> statusLine.command = $dest"
echo "Done. Open Claude Code (or wait for a repaint) to see it."
