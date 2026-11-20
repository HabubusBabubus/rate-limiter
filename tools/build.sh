#!/usr/bin/env sh
# Packs the mod into dist/<name>_<version>.zip, ready for the mods folder or the mod portal.
# Usage (from the repository root):  sh tools/build.sh
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/rate-limiter"
name=$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' "$src/info.json")
version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$src/info.json")
folder="${name}_${version}"
mkdir -p "$root/dist"
rm -rf "$root/dist/$folder" "$root/dist/$folder.zip"
cp -r "$src" "$root/dist/$folder"
(cd "$root/dist" && zip -qr "$folder.zip" "$folder")
rm -rf "$root/dist/$folder"
echo "Built dist/$folder.zip"
