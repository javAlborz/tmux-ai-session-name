#!/usr/bin/env bash
# Install or run the status worker for the invoking tmux socket.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  --restart) shift; exec python3 "$script_dir/ai-status.py" restart "$@" ;;
  --install-hooks) shift; exec python3 "$script_dir/ai-status.py" install "$@" ;;
  --view) shift; exec python3 "$script_dir/ai-status.py" view "$@" ;;
  --refresh) shift; exec python3 "$script_dir/ai-status.py" refresh "$@" ;;
  *) exec python3 "$script_dir/ai-status.py" tick "$@" ;;
esac
