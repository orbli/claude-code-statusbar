#!/usr/bin/env bash
# Claude Code status line: two right-aligned rows.
#
#   user@host:cwd                          in <1+2> | tool <3> | out <4>
#   owner/repo <branch> #<pr> (or "no github repo")   $<cost> | ctx <used>/<size> <pct>%
#
# Cumulative token usage by area, all derived from the usage counters (no tokenizer). Per
# assistant request t: I_t = input + cache_creation + cache_read (full prompt size);
# U_t = (I_t - I_{t-1}) - out_{t-1} (new external input that turn). Then:
# - "in"   (1+2): injected context (system/tools/skills) + your input. These two cannot be
#                 split from the usage numbers alone (a turn's delta can lump both), so they
#                 are shown combined and honest, not split by a guess.
# - "tool" (3)  : tool-result tokens (Read/Bash/WebFetch...), labeled by tool name.
# - "out"  (4)  : model output (thinking + text + tool calls) = sum of out_t.
#   in + tool + out = the cumulative total; cached by transcript byte-size.
# - "#<pr>": latest PR whose head is the current branch, as an OSC-8 link. Looked up via `gh`,
#           cached per (repo,branch) and refreshed in the BACKGROUND on a TTL — the repaint
#           always serves the cached value and never blocks on the network.
# - "ctx" : current context-window occupancy; "$": native cumulative cost.total_cost_usd.
# - Counts >= 1000 are abbreviated k/M, else shown exact.
# - Pure ASCII + interior padding only, so measured width == painted width. Right edge is
#   padded to COLUMNS-4 (the TUI's usable area); tune that constant if your terminal differs.
#
# Requires: bash, jq, coreutils (wc/stat/md5sum), awk, sed. Optional: git (repo line),
#           gh + timeout (PR link).

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

# --- cumulative token usage by area (cached by transcript byte size; files only grow) ---
# Buckets:  CIN = injected + your input (1+2)   CTOOL = tool results (3)   COUT = model output (4)
# A tool-result turn's U_t -> CTOOL (unless the tool is "Skill", which is injected -> CIN);
# every other positive U_t and the baseline I_1 -> CIN; sum of out_t -> COUT. Evictions ignored.
CIN=0; CTOOL=0; COUT=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  sz=$(stat -c %s "$TRANSCRIPT" 2>/dev/null || echo 0)
  cf="$CACHE/cat-$(hashk "$TRANSCRIPT")"
  csz=""; [ -f "$cf" ] && { mapfile -t CC < "$cf"; csz=${CC[0]}; CIN=${CC[1]:-0}; CTOOL=${CC[2]:-0}; COUT=${CC[3]:-0}; }
  if [ "${csz:-x}" != "$sz" ]; then
    out=$(jq -rs '
      (reduce .[] as $e ({}; if $e.type=="assistant" then
         reduce ($e.message.content[]?|select(.type=="tool_use")) as $t (.; .[$t.id]=$t.name) else . end)) as $names
      | .[]
      | if .type=="user" then
          (.message.content) as $c
          | if ($c|type)=="string" then "H\t-\t0\t0"
            elif ($c|type)=="array" then
              ([ $c[]|select(.type=="tool_result")|.tool_use_id ]) as $ids
              | if ($ids|length)>0 then "R\t\($names[$ids[0]] // "?")\t0\t0"
                elif any($c[]; .type=="text" or .type=="image") then "H\t-\t0\t0" else "X\t-\t0\t0" end
            else "X\t-\t0\t0" end
        elif .type=="assistant" then
          "A\t\(.message.id)\t\((.message.usage.input_tokens//0)+(.message.usage.cache_creation_input_tokens//0)+(.message.usage.cache_read_input_tokens//0))\t\(.message.usage.output_tokens//0)"
        else empty end' "$TRANSCRIPT" 2>/dev/null | awk -F'\t' '
      $1=="H"{ pend=(pend==""?"H":(pend=="R"?"MIX":pend)); next }
      $1=="R"{ if(pend==""){pend="R";pname=$2} else if(pend=="H")pend="MIX"; next }
      $1=="A"{ id=$2;I=$3+0;O=$4+0; if(seen[id])next; seen[id]=1; n++;
        if(n==1)comb+=I;
        else{ U=(I-prevI)-prevO; if(U>=0){ if(pend=="R"&&pname!="Skill")tool+=U; else comb+=U } }
        model+=O; prevI=I; prevO=O; pend=""; pname="" }
      END{ printf "%d %d %d", comb, tool, model }')
    read -r CIN CTOOL COUT <<<"$out"
    CIN=${CIN:-0}; CTOOL=${CTOOL:-0}; COUT=${COUT:-0}
    printf '%s\n%s\n%s\n%s\n' "$sz" "$CIN" "$CTOOL" "$COUT" > "$cf"
  fi
fi

# --- github repo + current branch (local git only, no network): slug + url + branch, else empty ---
SLUG=""; REPOURL=""; BRANCH=""
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)   # empty on detached HEAD
  rurl=$(git -C "$CWD" remote get-url origin 2>/dev/null)
  case "$rurl" in
    *github.com*)
      SLUG=$(printf '%s' "$rurl" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#^ssh://[^/]+/##; s#\.git$##')
      [ -n "$SLUG" ] && REPOURL="https://github.com/$SLUG" ;;
  esac
fi

# --- latest PR for the current branch (gh; cached per (repo,branch), refreshed async) ---
# The repaint serves whatever is cached and NEVER waits on gh. When the cache is older than
# PR_TTL, one background refresher (guarded by a mkdir lock) re-queries and rewrites the cache
# for the next repaint. An empty result is cached too, so branches with no PR don't re-query.
PRNUM=""; PRURL=""; PR_TTL=120
if [ -n "$SLUG" ] && [ -n "$BRANCH" ] && command -v gh >/dev/null 2>&1; then
  {
    pf="$CACHE/pr-$(hashk "$SLUG|$BRANCH")"
    [ -f "$pf" ] && { mapfile -t PR < "$pf"; PRNUM=${PR[0]:-}; PRURL=${PR[1]:-}; }
    now=$(date +%s); ts=0; [ -f "$pf" ] && ts=$(stat -c %Y "$pf" 2>/dev/null || echo 0)
    if [ $(( now - ts )) -ge "$PR_TTL" ]; then
      lock="$pf.lock"
      # clear a lock left behind by a refresher that died mid-flight
      [ -d "$lock" ] && [ $(( now - $(stat -c %Y "$lock" 2>/dev/null || echo "$now") )) -ge 60 ] && rmdir "$lock" 2>/dev/null
      if mkdir "$lock" 2>/dev/null; then
        ( j=$(timeout 10 gh pr list --repo "$SLUG" --head "$BRANCH" --state all \
                --json number,url --limit 1 2>/dev/null \
              | jq -r '.[0] | "\(.number // "")\n\(.url // "")"' 2>/dev/null)
          n=$(printf '%s\n' "$j" | sed -n '1p'); u=$(printf '%s\n' "$j" | sed -n '2p')
          printf '%s\n%s\n' "$n" "$u" > "$pf.tmp" && mv -f "$pf.tmp" "$pf"  # atomic; no torn read
          rmdir "$lock" 2>/dev/null ) >/dev/null 2>&1 &
        disown 2>/dev/null
      fi
    fi
  }
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

emit_row(){ # leftplain leftdec rightplain rightdec  -> one right-aligned row
  local pad=$(( COLS - $(pw "$1") - $(pw "$3") )); [ "$pad" -lt 1 ] && pad=1
  printf '%s%s%s\n' "$2" "$(sp "$pad")" "$4"
}

# ROW 1 — left: user@host:cwd   right: token usage by area  (1+2)=in | 3=tool | 4=out
L1p="${USER_}@${HOST_}:${CWDD}"; L1d="${G}${USER_}@${HOST_}${R}:${B}${CWDD}${R}"
R1p="in $(abbr "$CIN") | tool $(abbr "$CTOOL") | out $(abbr "$COUT")"
R1d="${D}in${R} ${C}$(abbr "$CIN")${R} ${D}|${R} ${D}tool${R} ${C}$(abbr "$CTOOL")${R} ${D}|${R} ${D}out${R} ${C}$(abbr "$COUT")${R}"
# trim cwd from the left if it would collide with the right block (ASCII '..' marker)
avail=$(( COLS - $(pw "$R1p") - 2 ))
if [ "$(pw "$L1p")" -gt "$avail" ] && [ "$avail" -gt 12 ]; then
  prefix="${USER_}@${HOST_}:"; keep=$(( avail - ${#prefix} - 1 ))
  if [ "$keep" -gt 3 ]; then CWDD2="..${CWDD: -keep}"; L1p="${prefix}${CWDD2}"; L1d="${G}${USER_}@${HOST_}${R}:${B}${CWDD2}${R}"; fi
fi

# ROW 2 — left: github repo link (+ branch + latest PR) or "no github repo"   right: cost + ctx
if [ -n "$SLUG" ]; then
  L2p="$SLUG"; L2d="${D}$(link "$REPOURL" "$SLUG")${R}"
  if [ -n "$BRANCH" ]; then L2p="$L2p $BRANCH"; L2d="$L2d ${G}${BRANCH}${R}"; fi
  if [ -n "$PRNUM" ] && [ -n "$PRURL" ]; then
    L2p="$L2p #$PRNUM"; L2d="$L2d ${C}$(link "$PRURL" "#$PRNUM")${R}"
  fi
else L2p="no github repo"; L2d="${D}no github repo${R}"; fi
R2p="\$${COSTF} | ctx $(abbr "$CTX_USED")/$(abbr "$CTX_SIZE") ${CTX_PCT}%"
R2d="${Y}\$${COSTF}${R} ${D}|${R} ${D}ctx${R} ${C}$(abbr "$CTX_USED")${R}${D}/$(abbr "$CTX_SIZE") ${CTX_PCT}%${R}"

emit_row "$L1p" "$L1d" "$R1p" "$R1d"
emit_row "$L2p" "$L2d" "$R2p" "$R2d"
