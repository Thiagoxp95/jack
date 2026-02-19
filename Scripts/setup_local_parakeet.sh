#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODEL="${PARAKEET_MODEL:-mlx-community/parakeet-tdt-0.6b-v2}"
VENV_DIR="${PARAKEET_VENV_DIR:-$ROOT_DIR/.context/parakeet-venv}"
CACHE_DIR="${PARAKEET_CACHE_DIR:-$ROOT_DIR/.context/parakeet-cache}"
PYTHON_VERSION="${PARAKEET_PYTHON_VERSION:-3.11}"
SKIP_DOWNLOAD=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --model=<hf-repo>         Model repo (default: $MODEL)
  --venv-dir=<path>         Virtualenv location (default: $VENV_DIR)
  --cache-dir=<path>        Model cache directory (default: $CACHE_DIR)
  --python=<version>        Python version for uv venv (default: $PYTHON_VERSION)
  --skip-download           Install runtime only, skip model download warmup
  --help                    Show this help

This script installs local Parakeet MLX runtime and can pre-download model weights.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --model=*) MODEL="${arg#*=}" ;;
    --venv-dir=*) VENV_DIR="${arg#*=}" ;;
    --cache-dir=*) CACHE_DIR="${arg#*=}" ;;
    --python=*) PYTHON_VERSION="${arg#*=}" ;;
    --skip-download) SKIP_DOWNLOAD=1 ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: uv is required. Install with: brew install uv" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/.context" "$CACHE_DIR"

echo "==> Creating venv at $VENV_DIR (Python $PYTHON_VERSION)"
uv venv "$VENV_DIR" --python "$PYTHON_VERSION"

echo "==> Installing parakeet-mlx"
uv pip install --python "$VENV_DIR/bin/python" --upgrade pip
uv pip install --python "$VENV_DIR/bin/python" --upgrade parakeet-mlx

CLI_PATH="$VENV_DIR/bin/parakeet-mlx"
if [[ ! -x "$CLI_PATH" ]]; then
  echo "ERROR: parakeet-mlx executable not found at $CLI_PATH" >&2
  exit 1
fi

if [[ "$SKIP_DOWNLOAD" -eq 0 ]]; then
  echo "==> Pre-downloading model weights (this can take a while)"
  TMP_DIR="$(mktemp -d /tmp/parakeet-warmup-XXXXXX)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  WARMUP_WAV="$TMP_DIR/silence.wav"
  "$VENV_DIR/bin/python" - "$WARMUP_WAV" <<'PY'
import pathlib
import wave
import sys

path = pathlib.Path(sys.argv[1])
with wave.open(str(path), "wb") as wf:
    wf.setnchannels(1)
    wf.setsampwidth(2)
    wf.setframerate(16000)
    wf.writeframes(b"\x00\x00" * 16000)
PY

  "$CLI_PATH" \
    --model "$MODEL" \
    --cache-dir "$CACHE_DIR" \
    --output-format txt \
    --output-dir "$TMP_DIR" \
    --output-template "{filename}" \
    "$WARMUP_WAV" >/dev/null

  echo "Model download warmup complete."
fi

echo
echo "Local Parakeet setup complete."
echo "CLI path: $CLI_PATH"
echo "Model: $MODEL"
echo "Cache dir: $CACHE_DIR"
echo
echo "Use these values in the app config UI:"
echo "  CLI Path: $CLI_PATH"
echo "  Model: $MODEL"
echo "  Cache Directory: $CACHE_DIR"
