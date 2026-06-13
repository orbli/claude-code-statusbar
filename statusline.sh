#!/usr/bin/env bash
# Claude Code status line: two right-aligned rows.
#
#   user@host:cwd                          last in <i> out <o> | sess in <i> out <o>
#   owner/repo (or "no github repo")                  $<cost> | ctx <used>/<size> <pct>%
#
# - "last": the most recent turn's newly-processed input (input + cache_creation) and output.
# - "sess": cumulative tokens this session, summed from the transcript (deduped by message.id),
#           cached by transcript byte-size so repaints don't re-parse an unchanged file.
# - "ctx" : current context-window occupancy; "$": native cumulative cost.total_cost_usd.
# - Counts >= 1000 are abbreviated k/M, else shown exact.
# - Pure ASCII + interior padding only, so measured width == painted width. Right edge is
#   padded to COLUMNS-4 (the TUI's usable area); tune that constant if your terminal differs.
#
# Requires: bash, jq, coreutils (wc/stat/md5sum), awk, sed. git is optional (repo line).

input=$(cat)

# --- scalars: one value per line; mapfile keeps empty fields positional ---
mapfile -t F < <(printf '%s' "$input" | jq -r '[
  (.workspace.current_dir // .cwd // ""),
  (.transcript_path // ""),
  (.context_window.total_input_tokens // 0),
  (.context_window.context_window_size // 0),
  (.context_window.used_percentage // 0),
  (.context_window.current_usage.input_tokens // 0),
  (.context_window.current_usage.cache_creation_input_tokens // 0),
  (.context_window.current_usage.output_tokens // 0),
  (.cost.total_cost_usd // 0)
] | .[]' 2>/dev/null)
CWD=${F[0]}; TRANSCRIPT=${F[1]}
CTX_USED=${F[2]:-0}; CTX_SIZE=${F[3]:-0}; CTX_PCT=${F[4]:-0}
U_IN=${F[5]:-0}; U_CC=${F[6]:-0}; U_OUT=${F[7]:-0}; COST=${F[8]:-0}

CACHE="/tmp/cc-statusline-$(id -u)"; mkdir -p "$CACHE" 2>/dev/null
hashk(){ printf '%s' "$1" | md5sum | cut -c1-16; }

# abbreviate: < 1000 -> exact; else one-decimal k / M with trailing .0 trimmed
abbr(){
  local n=${1:-0}
  if [ "$n" -lt 1000 ] 2>/dev/null; then printf '%s' "$n"; return; fi
  awk -v n="$n" 'BEGIN{
    if (n>=1000000){v=n/1000000;u="M"} else {v=n/1000;u="k"}
    s=sprintf("%.1f",v); sub(/\.0$/,"",s); printf "%s%s",s,u }'
}

# --- identity ---
USER_=$(id -un 2>/dev/null)
HOST_=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
CWDD="$CWD"; case "$CWDD" in "$HOME") CWDD="~";; "$HOME"/*) CWDD="~${CWDD#"$HOME"}";; esac

# --- cumulative session tokens (cached by transcript byte size; files only grow) ---
CIN=0; COUT=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  sz=$(stat -c %s "$TRANSCRIPT" 2>/dev/null || echo 0)
  cf="$CACHE/cum-$(hashk "$TRANSCRIPT")"
  csz=""; [ -f "$cf" ] && { mapfile -t CC < "$cf"; csz=${CC[0]}; CIN=${CC[1]:-0}; COUT=${CC[2]:-0}; }
  if [ "${csz:-x}" != "$sz" ]; then
    mapfile -t S < <(jq -rs '
      [ .[] | select(.type=="assistant") | {id: .message.id, u: .message.usage} ] | unique_by(.id)
      | (reduce .[] as $m (0; . + (($m.u.input_tokens)//0)+(($m.u.cache_creation_input_tokens)//0)+(($m.u.cache_read_input_tokens)//0))) as $i
      | (reduce .[] as $m (0; . + (($m.u.output_tokens)//0))) as $o
      | $i, $o' "$TRANSCRIPT" 2>/dev/null)
    CIN=${S[0]:-0}; COUT=${S[1]:-0}
    printf '%s\n%s\n%s\n' "$sz" "$CIN" "$COUT" > "$cf"
  fi
fi

# --- github repo (local git only, no network): slug + url, else empty ---
SLUG=""; REPOURL=""
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rurl=$(git -C "$CWD" remote get-url origin 2>/dev/null)
  case "$rurl" in
    *github.com*)
      SLUG=$(printf '%s' "$rurl" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#^ssh://[^/]+/##; s#\.git$##')
      [ -n "$SLUG" ] && REPOURL="https://github.com/$SLUG" ;;
  esac
fi

# ---------- presentation ----------
R=$'\033[0m'; D=$'\033[2m'; G=$'\033[32m'; B=$'\033[34m'; C=$'\033[36m'; Y=$'\033[33m'
link(){ printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"; }   # OSC 8 hyperlink: url, text
pw(){ printf '%s' "$1" | wc -L; }                 # visible width in display columns
sp(){ [ "${1:-0}" -gt 0 ] 2>/dev/null && printf '%*s' "$1" ''; }
COLS=${COLUMNS:-}; [ -z "$COLS" ] && COLS=$(tput cols 2>/dev/null); [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=100
# The TUI shows content fully up to COLUMNS-4 (last col + its overflow reserve);
# padding to that right-aligns flush to the real edge and adapts to any width.
COLS=$(( COLS - 4 )); [ "$COLS" -lt 20 ] && COLS=20

COSTF=$(printf '%.4f' "$COST" 2>/dev/null || printf '%s' "$COST")
LIN=$(( ${U_IN:-0} + ${U_CC:-0} ))

emit_row(){ # leftplain leftdec rightplain rightdec  -> one right-aligned row
  local pad=$(( COLS - $(pw "$1") - $(pw "$3") )); [ "$pad" -lt 1 ] && pad=1
  printf '%s%s%s\n' "$2" "$(sp "$pad")" "$4"
}

# ROW 1 — left: user@host:cwd   right: last + session
L1p="${USER_}@${HOST_}:${CWDD}"; L1d="${G}${USER_}@${HOST_}${R}:${B}${CWDD}${R}"
R1p="last in $(abbr "$LIN") out $(abbr "$U_OUT") | sess in $(abbr "$CIN") out $(abbr "$COUT")"
R1d="${D}last in${R} ${C}$(abbr "$LIN")${R} ${D}out${R} ${C}$(abbr "$U_OUT")${R} ${D}|${R} ${D}sess in${R} ${C}$(abbr "$CIN")${R} ${D}out${R} ${C}$(abbr "$COUT")${R}"
# trim cwd from the left if it would collide with the right block (ASCII '..' marker)
avail=$(( COLS - $(pw "$R1p") - 2 ))
if [ "$(pw "$L1p")" -gt "$avail" ] && [ "$avail" -gt 12 ]; then
  prefix="${USER_}@${HOST_}:"; keep=$(( avail - ${#prefix} - 1 ))
  if [ "$keep" -gt 3 ]; then CWDD2="..${CWDD: -keep}"; L1p="${prefix}${CWDD2}"; L1d="${G}${USER_}@${HOST_}${R}:${B}${CWDD2}${R}"; fi
fi

# ROW 2 — left: github repo link or "no github repo"   right: cost + ctx
if [ -n "$SLUG" ]; then L2p="$SLUG"; L2d="${D}$(link "$REPOURL" "$SLUG")${R}"
else L2p="no github repo"; L2d="${D}no github repo${R}"; fi
R2p="\$${COSTF} | ctx $(abbr "$CTX_USED")/$(abbr "$CTX_SIZE") ${CTX_PCT}%"
R2d="${Y}\$${COSTF}${R} ${D}|${R} ${D}ctx${R} ${C}$(abbr "$CTX_USED")${R}${D}/$(abbr "$CTX_SIZE") ${CTX_PCT}%${R}"

emit_row "$L1p" "$L1d" "$R1p" "$R1d"
emit_row "$L2p" "$L2d" "$R2p" "$R2d"
