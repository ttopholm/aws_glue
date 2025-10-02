#!/bin/bash
set -e

# Run chown every second for 60 seconds in background
(
  echo "Starting ownership fix loop for /vscode..."
  for i in {1..60}; do
    sudo chown -R glue_user /vscode 2>/dev/null || true
    sleep 1
  done
  echo "Ownership fix loop completed."
) &

# Execute the main command
exec "$@"