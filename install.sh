#!/usr/bin/env bash
#
# install.sh — universal installer for Ablation.
# Works on macOS (Apple Silicon + Intel) and Linux (x86_64 + aarch64).
#
# One-liner (after hosting in a repo/gist you control):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | bash
#
# Strategy: create a conda env, then install every dependency INTO that env so
# the env's own Python can import them:
#   * numpy / capstone / pyelftools  -> conda-forge (precompiled, all platforms)
#   * lief                           -> pip, into the env (PyPI ships prebuilt
#                                       arm64/x86_64 wheels; this is the piece a
#                                       plain install gets wrong — Homebrew's lief
#                                       lands in Homebrew's Python, NOT the env)
#   * fastembed                      -> pip (prebuilt ONNX wheels; the lightweight
#                                       replacement Ablation uses instead of
#                                       sentence-transformers/torch)
#   * ablation                       -> pip --no-deps (deps satisfied above)
#
# Env overrides:  ABLATION_ENV=<name>  ABLATION_PY=<version>
set -euo pipefail

ENV_NAME="${ABLATION_ENV:-ablation}"
PY_VERSION="${ABLATION_PY:-3.11}"
REPO="git+https://github.com/Ablation-Tool/ablation"

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 0. Detect platform ------------------------------------------------------
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

# --- 2. Compiled native deps from conda-forge --------------------------------
say "Installing numpy / capstone / pyelftools from conda-forge..."
conda install -c conda-forge -y "numpy>=1.26" "capstone>=5" "pyelftools>=0.29"

# --- 3. lief — INTO the env, BEFORE Ablation ---------------------------------
# pip pulls the prebuilt arm64/x86_64 wheel from PyPI straight into this env, so
# `import lief` resolves here. (Homebrew's lief would install outside the env and
# not be importable — that's the usual "cannot find lief" cause on Apple Silicon.)
say "Installing lief into the env (prebuilt wheel)..."
if ! pip install "lief>=0.16"; then
  say "No lief wheel for this interpreter; trying conda-forge..."
  if ! conda install -c conda-forge -y "lief>=0.16"; then
    if [ "$os" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
      # Last resort: Homebrew bottle, then expose its bindings to THIS env.
      say "Falling back to Homebrew lief and linking it into the env..."
      brew list lief >/dev/null 2>&1 || brew install lief
      brew_site="$(brew --prefix lief)/lib/python${PY_VERSION}/site-packages"
      if [ -d "$brew_site" ]; then
        printf '%s\n' "$brew_site" > \
          "$(python -c 'import site; print(site.getsitepackages()[0])')/homebrew-lief.pth"
      fi
    fi
  fi
fi
python -c "import lief" 2>/dev/null || \
  die "lief still not importable in env '$ENV_NAME'. Run 'conda activate $ENV_NAME' then 'pip install lief' and retry."

# --- 4. fastembed from pip ---------------------------------------------------
say "Installing fastembed..."
pip install "fastembed>=0.3.0"

# --- 5. Ablation itself (no dep re-resolution; deps satisfied above) ---------
say "Installing Ablation..."
pip install --no-deps "$REPO"

# --- 6. Verify ---------------------------------------------------------------
say "Verifying imports..."
python - <<'PY'
import importlib, sys
bad = []
for m in ["lief", "numpy", "capstone", "elftools", "fastembed", "ablation"]:
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
