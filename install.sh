#!/usr/bin/env bash
#
# install.sh — universal installer for Ablation.
# Works on macOS (Apple Silicon + Intel) and Linux (x86_64 + aarch64).
#
# One-liner (after hosting in a repo/gist you control):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | bash
#
# Strategy: install every native dependency from conda-forge, which ships
# precompiled binaries for all four platforms above (so nothing builds from
# source and there are no pip "wheel" failures), then install Ablation itself
# with pip --no-deps. On macOS, if the conda-forge lief build is unavailable,
# fall back to Homebrew's prebuilt bottle.
#
# Env overrides:  ABLATION_ENV=<name>  ABLATION_PY=<version>
set -euo pipefail

ENV_NAME="${ABLATION_ENV:-ablation}"
PY_VERSION="${ABLATION_PY:-3.11}"
REPO="git+https://github.com/Ablation-Tool/ablation"

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 0. Detect platform (for messaging + fallback decisions) -----------------
os="$(uname -s)"; arch="$(uname -m)"
say "Platform: $os / $arch"

command -v conda >/dev/null 2>&1 || \
  die "conda not found. Install Miniforge/Miniconda first: https://github.com/conda-forge/miniforge"

# --- 1. Conda environment ----------------------------------------------------
# shellcheck disable=SC1091
source "$(conda info --base)/etc/profile.d/conda.sh"

if conda env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
  say "Conda env '$ENV_NAME' already exists — reusing it."
else
  say "Creating conda env '$ENV_NAME' (python=$PY_VERSION)..."
  conda create -n "$ENV_NAME" "python=$PY_VERSION" -y
fi
conda activate "$ENV_NAME"

# --- 2. Native deps from conda-forge (precompiled for every platform) --------
say "Installing native dependencies from conda-forge..."
if ! conda install -c conda-forge -y \
      "numpy>=1.26" \
      "capstone>=5" \
      "lief>=0.14" \
      "pyelftools>=0.29" \
      "sentence-transformers>=2.3"; then

  # Fallback: retry without lief, then get lief from Homebrew (macOS only).
  say "conda-forge install failed; retrying without lief..."
  conda install -c conda-forge -y \
      "numpy>=1.26" "capstone>=5" "pyelftools>=0.29" "sentence-transformers>=2.3"

  if [ "$os" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    say "Installing lief via Homebrew (prebuilt arm64/x86_64 bottle)..."
    brew list lief >/dev/null 2>&1 || brew install lief
  else
    die "Could not install lief from conda-forge and no Homebrew fallback is available on this platform.
Install lief manually, then re-run this script."
  fi
fi

# --- 3. Ablation itself (pure Python; no dep re-resolution) ------------------
say "Installing Ablation..."
pip install --no-deps "$REPO"

# --- 4. Verify ---------------------------------------------------------------
say "Verifying imports..."
python - <<'PY'
import importlib, sys
bad = []
for m in ["lief", "numpy", "capstone", "elftools", "ablation"]:
    try:
        importlib.import_module(m)
    except Exception as e:
        bad.append(f"{m}: {e}")
if bad:
    print("Some imports failed:\n  " + "\n  ".join(bad)); sys.exit(1)
print("All core modules import OK.")
PY

say "Done. Activate with:  conda activate $ENV_NAME"
say "Optional LLM features: pip install 'anthropic>=0.39'"
