#!/usr/bin/env bash
# validate-k8s.sh — Run all local Kubernetes manifest validations.
# Usage: ./scripts/validate-k8s.sh [--strict]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$(cd "$SCRIPT_DIR/../kubernetes" && pwd)"
STRICT="${1:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

errors=0

# ── kubeval ───────────────────────────────────────────────────────────────────
if command -v kubeval &>/dev/null; then
  echo "── kubeval ─────────────────────────────────────────────────────"
  find "$MANIFEST_DIR" -name "*.yaml" -not -name "*.example*" | sort | while read -r f; do
    if kubeval --strict --ignore-missing-schemas --kubernetes-version 1.29.0 "$f" 2>&1; then
      pass "$f"
    else
      fail "$f"
      (( errors++ )) || true
    fi
  done
else
  warn "kubeval not found. Install: https://github.com/instrumenta/kubeval"
fi

# ── kube-score ────────────────────────────────────────────────────────────────
if command -v kube-score &>/dev/null; then
  echo ""
  echo "── kube-score ──────────────────────────────────────────────────"
  find "$MANIFEST_DIR" -name "*.yaml" -not -name "*.example*" | sort | while read -r f; do
    kube-score score \
      --ignore-test pod-probes \
      --output-format ci \
      "$f" 2>&1 || warn "kube-score issues in $f (non-blocking)"
  done
else
  warn "kube-score not found. Install: https://github.com/zegl/kube-score"
fi

# ── yamllint ─────────────────────────────────────────────────────────────────
if command -v yamllint &>/dev/null; then
  echo ""
  echo "── yamllint ────────────────────────────────────────────────────"
  find "$MANIFEST_DIR" -name "*.yaml" -not -name "*.example*" | sort | while read -r f; do
    if yamllint -d relaxed "$f" 2>&1; then
      pass "$f"
    else
      fail "$f"
      (( errors++ )) || true
    fi
  done
else
  warn "yamllint not found. Install: pip install yamllint"
fi

echo ""
if [[ $errors -eq 0 ]]; then
  echo -e "${GREEN}All validations passed.${NC}"
else
  echo -e "${RED}$errors validation error(s) found.${NC}"
  [[ "$STRICT" == "--strict" ]] && exit 1
fi
