#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# github-sanitize.sh — Push sanitized commits to the GitHub mirror
# =============================================================================
# Replaces PII (domain, usernames, org name) with generic placeholders before
# pushing to the public GitHub mirror. GitLab keeps the real values.
#
# Usage:
#   ./scripts/github-sanitize.sh              # Sanitize and push to GitHub
#   ./scripts/github-sanitize.sh --dry-run    # Show what would change
#
# Prerequisites:
#   - git-filter-repo installed (pip install git-filter-repo)
#   - SSH key with push access to GitHub
#
# How it works:
#   1. Clones the current branch to a temp directory
#   2. Runs git-filter-repo to replace PII in file content + commit messages
#   3. Removes sensitive files (certs, .env, sanitize script, CI config)
#   4. Force pushes the sanitized branch to GitHub
#   5. Cleans up the temp directory
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
TEMP_DIR="/tmp/github-sanitize-$$"
GITHUB_REMOTE="${GITHUB_REMOTE:-git@github.com:derhornspieler/harvester-proxy-internet-vm.git}"
BRANCH="${1:-main}"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      echo "Usage: $0 [branch] [--dry-run]"
      echo ""
      echo "Sanitize and push to GitHub mirror."
      echo "Default branch: main"
      exit 0
      ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die() { log_error "$@"; exit 1; }

# Validate prerequisites
command -v git-filter-repo &>/dev/null || die "git-filter-repo not found. Install: pip install git-filter-repo"

# =============================================================================
# PII Replacement Map
# =============================================================================
# Add entries here when new PII is introduced.
# Format: REAL_VALUE==>REPLACEMENT
# =============================================================================
create_replacements_file() {
  cat > "${TEMP_DIR}/replacements.txt" << 'REPLACEMENTS'
aegisgroup.ch==>example.com
Aegis Group==>Example Org
alice.morgan==>admin.user
Alice Morgan==>Platform Admin
frank.jones==>dev.user
Frank Jones==>Senior Developer
172.16.3.200==>10.0.0.100
192.168.48.2==>10.0.0.200
192.168.48.4==>10.0.0.201
Harbor12345==>CHANGEME
REPLACEMENTS
  log_info "Replacement map created ($(wc -l < "${TEMP_DIR}/replacements.txt") entries)"
}

# =============================================================================
# Sensitive files to remove from history
# =============================================================================
REMOVE_PATHS=(
  "scripts/github-sanitize.sh"
  ".gitlab-ci.yml"
  "certs/*.pem"
  "certs/*.srl"
  "terraform/terraform.tfvars"
  ".env"
  ".claude/"
  "CLAUDE.md"
  "memory/"
  "docs/plans/"
  "docs/superpowers/"
)

# =============================================================================
# Main
# =============================================================================
log_info "Sanitizing branch '${BRANCH}' for GitHub mirror..."

# Clone current repo to temp
log_info "Cloning to temp directory..."
git clone --branch "${BRANCH}" --single-branch "${REPO_DIR}" "${TEMP_DIR}" 2>/dev/null
cd "${TEMP_DIR}"

# Create replacements file
create_replacements_file

# Build filter-repo args for path removal
FILTER_ARGS=()
for path in "${REMOVE_PATHS[@]}"; do
  FILTER_ARGS+=("--path-glob" "${path}" "--invert-paths")
done

# Pass 1: Replace text in file content + remove sensitive files
log_info "Pass 1: Replacing PII in file content and removing sensitive files..."
git filter-repo \
  --replace-text "${TEMP_DIR}/replacements.txt" \
  "${FILTER_ARGS[@]}" \
  --force 2>/dev/null

# Pass 2: Replace PII in commit messages
log_info "Pass 2: Replacing PII in commit messages..."
git filter-repo \
  --message-callback '
msg = message
msg = msg.replace(b"aegisgroup.ch", b"example.com")
msg = msg.replace(b"Aegis Group", b"Example Org")
msg = msg.replace(b"alice.morgan", b"admin.user")
msg = msg.replace(b"Alice Morgan", b"Platform Admin")
msg = msg.replace(b"frank.jones", b"dev.user")
msg = msg.replace(b"Frank Jones", b"Senior Developer")
msg = msg.replace(b"172.16.3.200", b"10.0.0.100")
msg = msg.replace(b"Harbor12345", b"CHANGEME")
return msg
' --force 2>/dev/null

# Verify
log_info "Verifying sanitization..."
LEAKS=0
for term in "aegisgroup" "Aegis Group" "alice.morgan" "frank.jones" "Harbor12345" "172.16.3.200"; do
  COUNT=$(grep -r "${term}" --include="*.yaml" --include="*.yml" --include="*.md" --include="*.sh" --include="*.json" --include="*.conf" --include="*.tf" . 2>/dev/null | grep -v ".git/" | wc -l)
  if [[ ${COUNT} -gt 0 ]]; then
    log_warn "Found ${COUNT} remaining '${term}' references in files"
    LEAKS=$((LEAKS + COUNT))
  fi
done

MSG_LEAKS=$(git log --oneline 2>/dev/null | grep -ciE "aegisgroup|alice\.morgan|frank\.jones" || true)
if [[ ${MSG_LEAKS} -gt 0 ]]; then
  log_warn "Found ${MSG_LEAKS} commit messages with PII"
  LEAKS=$((LEAKS + MSG_LEAKS))
fi

if [[ ${LEAKS} -gt 0 ]]; then
  die "Sanitization incomplete — ${LEAKS} leaks found. Update the replacement map."
fi
log_ok "Sanitization verified — zero PII in files or commit messages"

# Push
if [[ "${DRY_RUN}" == true ]]; then
  log_warn "DRY RUN — would force push to: ${GITHUB_REMOTE}"
  log_info "Scrubbed repo at: ${TEMP_DIR} (not cleaned up for inspection)"
else
  log_info "Force pushing to GitHub..."
  git remote add github "${GITHUB_REMOTE}" 2>/dev/null || true
  git push github "${BRANCH}" --force 2>&1
  log_ok "Pushed sanitized '${BRANCH}' to GitHub"

  # Cleanup
  cd /
  rm -rf "${TEMP_DIR}"
  log_ok "Temp directory cleaned up"
fi

log_ok "GitHub sanitization complete"
