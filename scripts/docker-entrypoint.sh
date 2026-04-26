#!/usr/bin/env bash
set -euo pipefail

GODOT_VERSION="$(cat /opt/godot_version.txt)"
TEMPLATES_DIR="${HOME}/.local/share/godot/export_templates/${GODOT_VERSION}"

mkdir -p "${TEMPLATES_DIR}"

# Install baked templates into the standard Godot location.
# -n leaves any user-supplied template untouched.
for tpl in /opt/godot-templates/*.zip; do
    [ -e "$tpl" ] || continue
    cp -n "$tpl" "${TEMPLATES_DIR}/$(basename "$tpl")"
done

# Make the local NuGet feed (Godot.NET.Sdk built from the fork) discoverable.
if [ -d /opt/godot-nuget ] && [ -n "$(ls -A /opt/godot-nuget 2>/dev/null)" ]; then
    dotnet nuget add source /opt/godot-nuget --name godot-local >/dev/null 2>&1 || true
fi

cd /project

# Restore C# deps if a project file exists at the root.
if compgen -G "*.csproj" > /dev/null || compgen -G "*.sln" > /dev/null; then
    dotnet restore || true
fi

# Godot import: first run can fail on missing .import metadata; second always succeeds.
godot --headless --import || true
godot --headless --import

PRESET="${1:-${GODOT_PRESET}}"
OUTPUT="${2:-${OUTPUT_PATH}}"

mkdir -p "$(dirname "${OUTPUT}")"

echo "==> Exporting preset='${PRESET}' to '${OUTPUT}' (templates: ${GODOT_VERSION})"
godot --headless --export-release "${PRESET}" "${OUTPUT}"

echo "==> Done. Artifacts in: $(dirname "${OUTPUT}")"
ls -la "$(dirname "${OUTPUT}")"
