#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version> [tap_repo_path]" >&2
  echo "Example: $0 0.1.1 /Users/<you>/Projects/homebrew-tap" >&2
  exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${ROOT}/dist/release/audia-tap-${VERSION}.dmg"
TAP_REPO="${2:-}"

chmod +x "${ROOT}/Scripts/build_release_dmg.sh"
"${ROOT}/Scripts/build_release_dmg.sh" "${VERSION}" "${DMG_PATH}"

echo "[audia-release] Uploading ${DMG_PATH} to GitHub release ${TAG}..."
gh release upload "${TAG}" "${DMG_PATH}" --clobber

if [[ -n "${TAP_REPO}" ]]; then
  SHA="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
  CASK="${TAP_REPO}/Casks/audia-tap.rb"
  if [[ ! -f "${CASK}" ]]; then
    echo "[audia-release] ERROR: cask file missing at ${CASK}" >&2
    exit 1
  fi

  perl -0777 -i -pe "s/version\\s+\\\"[^\\\"]+\\\"/version \\\"${VERSION}\\\"/g; s/sha256\\s+\\\"[0-9a-f]+\\\"/sha256 \\\"${SHA}\\\"/g" "${CASK}"

  (
    cd "${TAP_REPO}"
    git add Casks/audia-tap.rb
    if ! git diff --cached --quiet; then
      git commit -m "[skip ci] bump audia-tap cask to ${VERSION}"
      git push origin main
    else
      echo "[audia-release] No tap changes to commit."
    fi
  )
fi

echo "[audia-release] Release flow complete."
