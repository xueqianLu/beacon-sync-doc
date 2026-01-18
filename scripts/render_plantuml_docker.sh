#!/usr/bin/env bash
set -euo pipefail

# Render all PlantUML diagrams under img/ to PNG using Docker.
#
# Why a custom image?
# - The upstream `plantuml/plantuml` image ships with very few fonts (often no CJK fonts),
#   resulting in Chinese text rendered as squares/garbled characters.
# - We build a small wrapper image that installs CJK fonts and then force-load `plantuml.config`.
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

PLANTUML_IMAGE_DEFAULT="beacon-sync-doc/plantuml:cjk"
PLANTUML_IMAGE="${PLANTUML_IMAGE:-$PLANTUML_IMAGE_DEFAULT}"

PLANTUML_DOCKERFILE="$SCRIPT_DIR/plantuml/Dockerfile"
if [[ -f "$PLANTUML_DOCKERFILE" ]]; then
  if ! docker image inspect "$PLANTUML_IMAGE" >/dev/null 2>&1; then
    echo "[INFO] Building PlantUML image with CJK fonts: $PLANTUML_IMAGE"
    docker build -t "$PLANTUML_IMAGE" -f "$PLANTUML_DOCKERFILE" "$SCRIPT_DIR/plantuml" >/dev/null
  fi
fi

PLANTUML_CONFIG_HOST="$REPO_ROOT/plantuml.config"
PLANTUML_CONFIG_CONTAINER="/data/plantuml.config"
PLANTUML_CONFIG_ARGS=()
if [[ -f "$PLANTUML_CONFIG_HOST" ]]; then
  PLANTUML_CONFIG_ARGS=("-config" "$PLANTUML_CONFIG_CONTAINER")
else
  echo "[WARN] plantuml.config not found at repo root; rendering without explicit config." >&2
fi

echo "[INFO] Rendering PlantUML diagrams under img/ (including subdirectories) to PNG via Docker..."

failed_count=0
for puml in "${PUML_FILES[@]}"; do
  echo "[INFO] Rendering: $puml"
  if ! docker run --rm \
      -e LANG=C.UTF-8 \
      -e LC_ALL=C.UTF-8 \
      -v "$PWD":/data \
      "$PLANTUML_IMAGE" \
      -charset UTF-8 \
      "${PLANTUML_CONFIG_ARGS[@]}" \
      -tpng "$puml"; then
    echo "[ERROR] Failed to render: $puml" >&2
    failed_count=$((failed_count + 1))
  fi
done

if ((failed_count > 0)); then
  echo "[ERROR] Done with failures: $failed_count diagram(s) failed to render." >&2
  exit 1
fi

echo "[INFO] Done. PNG files are generated alongside each .puml under img/."