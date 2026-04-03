#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version> [output_dmg_path]" >&2
  echo "Example: $0 0.1.1 dist/release/audia-tap-0.1.1.dmg" >&2
  exit 1
fi

VERSION="$1"
OUTPUT_DMG="${2:-dist/release/audia-tap-${VERSION}.dmg}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${PROJECT_ROOT}/dist/Release/audia-tap.app"
STAGE_DIR="$(mktemp -d /tmp/audia-tap-dmg-stage.XXXXXX)"
README_TEMPLATE="${PROJECT_ROOT}/packaging/README.template.txt"
README_OUT="${STAGE_DIR}/README.txt"

cleanup() {
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

mkdir -p "$(dirname "${OUTPUT_DMG}")"

echo "[audia-release] Building Release app..."
xcodebuild \
  -project "${PROJECT_ROOT}/audia-tap.xcodeproj" \
  -scheme audia-tap \
  -configuration Release \
  -derivedDataPath "${PROJECT_ROOT}/build" \
  build >/dev/null

if [[ ! -d "${APP_PATH}" ]]; then
  echo "[audia-release] ERROR: expected app bundle not found: ${APP_PATH}" >&2
  exit 1
fi

echo "[audia-release] Staging DMG payload..."
cp -R "${APP_PATH}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

if [[ -f "${README_TEMPLATE}" ]]; then
  sed "s/{{VERSION}}/${VERSION}/g" "${README_TEMPLATE}" > "${README_OUT}"
fi

echo "[audia-release] Creating DMG at ${OUTPUT_DMG}..."
rm -f "${OUTPUT_DMG}"
hdiutil create \
  -volname "audia-tap ${VERSION}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${OUTPUT_DMG}" >/dev/null

echo "[audia-release] Done: ${OUTPUT_DMG}"
shasum -a 256 "${OUTPUT_DMG}"
