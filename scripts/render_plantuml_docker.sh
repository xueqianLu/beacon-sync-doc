#!/usr/bin/env bash
set -euo pipefail

# Render all PlantUML diagrams under img/ to PNG using Docker image plantuml/plantuml.
# Usage:
#   bash scripts/render_plantuml_docker.sh

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker command not found. Please install and start Docker Desktop first." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR%/scripts}"
cd "$REPO_ROOT"

if ! compgen -G "img/*.puml" > /dev/null; then
  echo "[INFO] No .puml files found in img/, nothing to render."
  exit 0
fi

echo "[INFO] Pulling plantuml/plantuml Docker image (if not present)..."
docker pull plantuml/plantuml >/dev/null

echo "[INFO] Rendering PlantUML diagrams in img/ to PNG via Docker..."
docker run --rm -v "$PWD":/data plantuml/plantuml -tpng img/*.puml

echo "[INFO] Done. PNG files are generated alongside each .puml in img/."