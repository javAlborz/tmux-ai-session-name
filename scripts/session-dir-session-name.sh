#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
_pane_title="${3:-}"
rows="${4:-}"
report_tool_only="${AI_SESSION_NAME_REPORT_TOOL_ONLY:-}"
report_id="${AI_SESSION_NAME_REPORT_ID:-}"
proc_root="${AI_SESSION_NAME_PROC_ROOT:-/proc}"

[ -n "$pane_pid" ] || exit 1
command -v jq >/dev/null 2>&1 || exit 1

process_pids="$(
  {
    printf '%s\n' "$pane_pid"
    printf '%s\n' "$rows" | awk '{ print $1 }'
  } | awk 'NF && !seen[$0]++'
)"

# This provider is intentionally product-neutral. Any descendant process may
# advertise a directory through an environment variable ending in SESSION_DIR.
# Session files use the JSONL session/session_info schema documented by the
# client: a header UUID plus optional user-defined display-name records.
session_sources="$(
  while read -r pid; do
    [ -r "$proc_root/$pid/environ" ] || continue
    tr '\0' '\n' <"$proc_root/$pid/environ" 2>/dev/null |
      sed -nE 's/^[A-Z0-9_]*SESSION_DIR=(.+)$/\1/p' |
      while IFS= read -r session_dir; do
        [ -d "$session_dir" ] || continue
        printf '%s\t%s\n' "$pid" "$session_dir"
      done
  done <<EOF_PIDS
$process_pids
EOF_PIDS
)"
session_sources="$(printf '%s\n' "$session_sources" | awk -F'\t' 'NF >= 2 && !seen[$0]++')"
[ -n "$session_sources" ] || exit 1

clean_field() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

session_metadata() {
  local file="$1"
  local header
  local identity
  local cwd
  local name

  [ -r "$file" ] || return 1
  header="$(head -n 1 "$file" 2>/dev/null || true)"
  identity="$(printf '%s\n' "$header" | jq -r 'select(.type == "session") | .id // empty' 2>/dev/null)"
  cwd="$(printf '%s\n' "$header" | jq -r 'select(.type == "session") | .cwd // empty' 2>/dev/null)"
  [ -n "$identity" ] || return 1
  [ -n "$cwd" ] || return 1

  name="$(jq -r 'select(.type == "session_info" and (.name // "") != "") | .name' "$file" 2>/dev/null | tail -n 1)"
  identity="$(clean_field "$identity")"
  cwd="$(clean_field "$cwd")"
  name="$(clean_field "$name")"
  printf '%s\t%s\t%s\n' "$identity" "$cwd" "$name"
}

cwd_matches() {
  local session_cwd="$1"
  [ -n "$session_cwd" ] || return 1
  [ "$pane_cwd" = "$session_cwd" ] && return 0
  case "$pane_cwd/" in
    "$session_cwd"/*) return 0 ;;
  esac
  return 1
}

emit_result() {
  local identity="$1"
  local name="$2"
  local confidence="$3"

  if [ "$report_tool_only" = "1" ]; then
    printf '1\n'
    return 0
  fi
  [ -n "$name" ] || return 1
  if [ "$report_id" = "1" ]; then
    printf '%s\t%s\t%s\n' "$identity" "$name" "$confidence"
  else
    printf '%s\n' "$name"
  fi
}

# Prefer a session file held open by the process. This gives an authoritative
# identity even when several sessions share the same working directory.
while IFS=$'\t' read -r pid session_dir; do
  [ -d "$proc_root/$pid/fd" ] || continue
  for fd in "$proc_root/$pid/fd"/*; do
    [ -L "$fd" ] || continue
    file="$(readlink -f "$fd" 2>/dev/null || true)"
    case "$file" in
      "$session_dir"/*.jsonl)
        metadata="$(session_metadata "$file" || true)"
        [ -n "$metadata" ] || continue
        identity="${metadata%%	*}"
        rest="${metadata#*	}"
        session_cwd="${rest%%	*}"
        name="${rest#*	}"
        cwd_matches "$session_cwd" || continue
        emit_result "$identity" "$name" "strong" && exit 0
        # This is the authoritative live session. An unnamed session must not
        # fall through to an older named file from the same directory.
        exit 1
        ;;
    esac
  done
done <<EOF_SOURCES
$session_sources
EOF_SOURCES

# Most clients open JSONL only while appending. Fall back to the newest matching
# session. Treat it as weak so the core debounce and duplicate-identity checks
# can reject transient or cross-window ambiguity.
candidates="$(
  while IFS=$'\t' read -r _pid session_dir; do
    find "$session_dir" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@\t%p\n' 2>/dev/null
  done <<EOF_SOURCES
$session_sources
EOF_SOURCES
)"
candidates="$(printf '%s\n' "$candidates" | sort -t $'\t' -k1,1nr | awk -F'\t' '!seen[$2]++')"

while IFS=$'\t' read -r _mtime file; do
  [ -n "$file" ] || continue
  metadata="$(session_metadata "$file" || true)"
  [ -n "$metadata" ] || continue
  identity="${metadata%%	*}"
  rest="${metadata#*	}"
  session_cwd="${rest%%	*}"
  name="${rest#*	}"
  cwd_matches "$session_cwd" || continue

  confidence="weak"
  if printf '%s\n' "$rows" | grep -Fq "$file" || printf '%s\n' "$rows" | grep -Fq "$identity"; then
    confidence="strong"
  fi
  emit_result "$identity" "$name" "$confidence" && exit 0
  # The newest cwd match is the active-session candidate. If it has no
  # explicit name, report no name instead of borrowing one from history.
  exit 1
done <<EOF_CANDIDATES
$candidates
EOF_CANDIDATES

if [ "$report_tool_only" = "1" ]; then
  printf '1\n'
  exit 0
fi
exit 1
