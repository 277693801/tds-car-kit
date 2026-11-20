#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

# Regenerate the Xcode project from the (iOS 14.5) generator configuration.
python3 Tools/generate_project.py

# Restore the local accessory identity from CI secrets (base64), if present.
identity_dir="$project_root/.local/Identity"
if [[ -n "${IDENTITY_P7B_B64:-}" && -n "${IDENTITY_LEAF_B64:-}" && -n "${IDENTITY_X963_B64:-}" ]]; then
  mkdir -p "$identity_dir"
  printf '%s' "$IDENTITY_P7B_B64"  | base64 --decode > "$identity_dir/certificate.p7b"
  printf '%s' "$IDENTITY_LEAF_B64" | base64 --decode > "$identity_dir/leaf.cer"
  printf '%s' "$IDENTITY_X963_B64" | base64 --decode > "$identity_dir/private.x963"
fi

xcodebuild \
  -project TDSCarKit.xcodeproj \
  -scheme TDSCarKit \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=14.5 \
  build

app_path="build/Build/Products/Release-iphoneos/TDSCarKit.app"
[[ -d "$app_path" ]] || { echo "Expected app bundle not found at $app_path"; exit 1; }

rm -rf Payload
mkdir -p Payload
cp -R "$app_path" Payload/
zip -qry TDSCarKit-TrollStore.ipa Payload

echo "Built: $project_root/TDSCarKit-TrollStore.ipa"
