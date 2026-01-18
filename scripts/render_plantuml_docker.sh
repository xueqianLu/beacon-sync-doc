#!/usr/bin/env bash
set -euo pipefail

# Render all PlantUML diagrams under img/ to PNG using Docker image plantuml/plantuml.
# Usage:
#   bash scripts/render_plantuml_docker.sh

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker command not found. Please install and start Docker Desktop first." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
REPO_ROOT="${SCRIPT_DIR%/scripts}"
cd "$REPO_ROOT"

PUML_FILES=()
while IFS= read -r -d '' file; do
  PUML_FILES+=("$file")
done < <(find img -type f -name '*.puml' -print0)

if ((${#PUML_FILES[@]} == 0)); then
  echo "[INFO] No .puml files found under img/ (including subdirectories), nothing to render."
  exit 0
fi

echo "[INFO] Pulling plantuml/plantuml Docker image (if not present)..."
docker pull plantuml/plantuml >/dev/null

echo "[INFO] Rendering PlantUML diagrams under img/ (including subdirectories) to PNG via Docker..."

failed_count=0
for puml in "${PUML_FILES[@]}"; do
  echo "[INFO] Rendering: $puml"
  if ! docker run --rm -v "$PWD":/data plantuml/plantuml -tpng "$puml"; then
    echo "[ERROR] Failed to render: $puml" >&2
    failed_count=$((failed_count + 1))
  fi
done

if ((failed_count > 0)); then
  echo "[ERROR] Done with failures: $failed_count diagram(s) failed to render." >&2
  exit 1
fi

echo "[INFO] Done. PNG files are generated alongside each .puml under img/."