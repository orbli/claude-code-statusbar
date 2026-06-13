# claude-code-statusbar

A two-row, right-aligned [Claude Code](https://claude.com/claude-code) status line that shows token usage, session cost, context-window occupancy, and the current GitHub repo.

```
o@host:~/work/project                         last in 780 out 401 | sess in 4.7M out 117k
owner/repo                                                  $3.8677 | ctx 96.4k/1M 10%
```

## What it shows

| Field | Meaning |
|-------|---------|
| `user@host:cwd` | identity + working directory (`~` for `$HOME`) |
| `last in / out`  | the most recent turn's newly-processed input (`input + cache_creation`) and output tokens |
| `sess in / out`  | cumulative tokens this session, summed from the transcript (deduped by `message.id`) |
| `$<cost>`        | native cumulative session cost (`cost.total_cost_usd`) |
| `ctx <used>/<size> <pct>%` | current context-window occupancy |
| `owner/repo`     | the cwd's GitHub repo as a clickable link, or `no github repo` |

Token counts ≥ 1000 are abbreviated `k`/`M`; smaller values are shown exact.

## Requirements

- `bash`, `jq`, coreutils (`wc`, `stat`, `md5sum`), `awk`, `sed`
- `git` is optional — only used (locally, no network) to detect the repo line

## Install

```sh
git clone https://github.com/orbli/claude-code-statusbar.git
cd claude-code-statusbar
./install.sh
```

`install.sh` copies `statusline.sh` to `~/.claude/statusline.sh` and points your
`~/.claude/settings.json` `statusLine` at it (merging, not overwriting, your other settings).

### Manual install

Copy the script and add this to `~/.claude/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "/absolute/path/to/statusline.sh" }
}
```

## Customization

- **Right-edge alignment** — the script pads to `COLUMNS - 4`. Claude Code's TUI reserves a
  few columns at the right edge (for its own truncation `…`), and the exact reserve varies by
  terminal. If the right side clips, increase the `4` in this line; if there's too big a gap,
  decrease it:
  ```sh
  COLS=$(( COLS - 4 ))
  ```
- **Colors** — defined near the top of the presentation section (`R/D/G/B/C/Y` ANSI codes).

## Design notes

Status lines are deceptively fiddly. This script deliberately:

- uses **only ASCII** in the rendered text, so `wc -L` (used to measure column width) agrees
  with what the terminal actually paints — ambiguous-width glyphs like `↑ ↓ ·` can render as
  2 columns and break alignment;
- right-aligns using **interior padding** (between two visible tokens), never leading spaces,
  which some renderers strip;
- pads to `COLUMNS - 4` rather than `COLUMNS`, because the reported terminal width is not the
  writable status-line width;
- caches the cumulative-token transcript scan by file **byte-size** (transcripts only grow),
  so frequent repaints don't re-parse a large unchanged file.
