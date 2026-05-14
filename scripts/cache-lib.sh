# Caching helpers for tmux-ai-session-name. Source this file.
#
# Cache file path comes from AI_SESSION_NAME_CACHE_FILE in env. If
# unset, functions act as no-ops.
#
# Format (TSV per line):
#   key<TAB>scanned_at_unix_s<TAB>value
# Empty value means "negative entry" — verified miss with a TTL.

cache_now_s() {
  if [ -n "${EPOCHSECONDS:-}" ]; then
    printf '%s\n' "$EPOCHSECONDS"
  else
    date +%s 2>/dev/null || printf '0\n'
  fi
}

# cache_lookup KEY [NEG_TTL_S] [POS_TTL_S]
# Prints positive value on stdout. Sets exit code:
#   0 = positive hit (value printed)
#   2 = negative hit within TTL (no value)
#   1 = miss or expired
cache_lookup() {
  local key="$1"
  local neg_ttl="${2:-30}"
  local pos_ttl="${3:-30}"
  local cache_file="${AI_SESSION_NAME_CACHE_FILE:-}"
  [ -n "$cache_file" ] && [ -r "$cache_file" ] || return 1

  local now line_key scanned_at value age
  now="$(cache_now_s)"

  while IFS=$'\t' read -r line_key scanned_at value || [ -n "${line_key:-}" ]; do
    [ "$line_key" = "$key" ] || continue
    [ -n "${scanned_at:-}" ] || return 1
    age=$(( now - scanned_at ))
    [ "$age" -ge 0 ] || return 1
    if [ -n "${value:-}" ]; then
      if [ "$age" -lt "$pos_ttl" ]; then
        printf '%s\n' "$value"
        return 0
      fi
      return 1
    fi
    if [ "$age" -lt "$neg_ttl" ]; then
      return 2
    fi
    return 1
  done < "$cache_file"

  return 1
}

# cache_lookup_permanent KEY
# Compatibility helper for callers that intentionally want non-expiring
# positive cache entries.
cache_lookup_permanent() {
  local key="$1"
  local neg_ttl="${2:-30}"
  local cache_file="${AI_SESSION_NAME_CACHE_FILE:-}"
  [ -n "$cache_file" ] && [ -r "$cache_file" ] || return 1

  local now line_key scanned_at value age
  now="$(cache_now_s)"

  while IFS=$'\t' read -r line_key scanned_at value || [ -n "${line_key:-}" ]; do
    [ "$line_key" = "$key" ] || continue
    if [ -n "${value:-}" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    [ -n "${scanned_at:-}" ] || return 1
    age=$(( now - scanned_at ))
    [ "$age" -ge 0 ] || return 1
    if [ "$age" -lt "$neg_ttl" ]; then
      return 2
    fi
    return 1
  done < "$cache_file"

  return 1
}

# cache_store KEY VALUE
# Persists an entry. Empty VALUE means negative.
cache_store() {
  local key="$1"
  local value="${2:-}"
  local cache_file="${AI_SESSION_NAME_CACHE_FILE:-}"
  [ -n "$cache_file" ] || return 0

  value="${value//$'\t'/ }"
  value="${value//$'\n'/ }"

  local now tmp
  now="$(cache_now_s)"
  tmp="$(mktemp "${cache_file}.XXXXXX" 2>/dev/null)" || return 0

  {
    if [ -r "$cache_file" ]; then
      awk -F'\t' -v k="$key" '$1 != k' "$cache_file" 2>/dev/null || true
    fi
    printf '%s\t%s\t%s\n' "$key" "$now" "$value"
  } | tail -n 500 > "$tmp" 2>/dev/null

  mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}
