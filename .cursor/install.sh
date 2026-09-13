#!/usr/bin/env bash
#
# Cloud Agent install script for GigaAgent.
#
# Idempotent bootstrap that prepares both the frontend bundle and the backend
# Python environment. Safe to run repeatedly (e.g. against cached/snapshotted
# state). Must terminate — it starts no long-running processes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- uv (Python package manager used by the backend) -----------------------
# Install it only when it is not already available.
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
  echo "==> Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
uv --version

# --- Frontend --------------------------------------------------------------
# The backend build hook (backend/hatch_build.py) requires the built frontend
# bundle to exist at front/dist, so the frontend must be built before the
# backend is synced.
echo "==> Building frontend bundle..."
cd "$REPO_ROOT/front"
npm ci
npm run build

# --- Backend ---------------------------------------------------------------
# Sync backend Python deps. The `jupyter` extra provides the local Jupyter
# sandbox / repl tooling used by the agent in dev mode.
echo "==> Syncing backend Python environment..."
cd "$REPO_ROOT/backend"
uv sync --extra jupyter

echo "==> GigaAgent install complete."
