#!/usr/bin/env bash
# Update only the originating pane; ai-status.py aggregates window indicators.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/ai-status.py" tool "$@"
