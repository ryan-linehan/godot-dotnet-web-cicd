#!/usr/bin/env bash
set -euo pipefail

GODOT_VERSION="$(cat /opt/godot_version.txt)"
TEMPLATES_DIR="${HOME}/.local/share/godot/export_templates/${GODOT_VERSION}"

mkdir -p "${TEMPLATES_DIR}"

# Map our compiled templates to the standard names Godot looks for in
# ~/.local/share/godot/export_templates/<version>/. Scons emits:
#   godot.web.template_release.wasm32.mono.zip            (multithreaded release)
#   godot.web.template_release.wasm32.nothreads.mono.zip  (single-threaded release)
#   godot.web.template_debug.wasm32.mono.zip              (multithreaded debug)
#   godot.web.template_debug.wasm32.nothreads.mono.zip    (single-threaded debug)
# -n leaves any user-supplied template untouched.
shopt -s nullglob
for src in /opt/godot-templates/*.zip; do
    case "$(basename "$src")" in
        *template_release*nothreads*)
            cp -n "$src" "${TEMPLATES_DIR}/web_nothreads_release.zip"
            ;;
        *template_release*)
            cp -n "$src" "${TEMPLATES_DIR}/web_release.zip"
            ;;
        *template_debug*nothreads*)
            cp -n "$src" "${TEMPLATES_DIR}/web_nothreads_debug.zip"
            ;;
        *template_debug*)
            cp -n "$src" "${TEMPLATES_DIR}/web_debug.zip"
            ;;
    esac
done
shopt -u nullglob

# Make the local NuGet feed (Godot.NET.Sdk built from the fork) discoverable.
# Add it as a user-level source for projects with no nuget.config of their own,
# AND expose it at /.nuget_local so projects using the upstream demo's
# nuget.config (which references `./../.nuget_local` as a sibling of the
# project dir) resolve it correctly when only the project dir is mounted.
if [ -d /opt/godot-nuget ] && [ -n "$(ls -A /opt/godot-nuget 2>/dev/null)" ]; then
    dotnet nuget add source /opt/godot-nuget --name godot-local >/dev/null 2>&1 || true
    ln -sfn /opt/godot-nuget /.nuget_local
fi

cd /project

# Demo presets reference custom_template paths from the upstream author's
# machine (/mnt/Data/...). Godot validates those paths even when valid
# standard templates exist, so blank them out and let the standard
# templates dir take over.
if [ -f export_presets.cfg ]; then
    sed -i 's|^custom_template/debug=".*"$|custom_template/debug=""|' export_presets.cfg
    sed -i 's|^custom_template/release=".*"$|custom_template/release=""|' export_presets.cfg
fi

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

# Godot's GodotTools publishes the .NET project internally and routes its
# stdout/stderr to per-build log files in ~/.local/share/godot/mono/build_logs/.
# Capture the log dir mtime baseline so we can dump only logs from this run.
BUILD_LOGS_DIR="${HOME}/.local/share/godot/mono/build_logs"
mkdir -p "${BUILD_LOGS_DIR}"
LOG_BASELINE="$(mktemp)"
touch -d "1 second ago" "${LOG_BASELINE}"

echo "==> Exporting (debug) preset='${PRESET}' to '${OUTPUT}' (templates: ${GODOT_VERSION})"
if godot --headless --verbose --export-debug "${PRESET}" "${OUTPUT}"; then
    # Container runs as root; output ends up root-owned with directories
    # like _framework/ created by dotnet publish at mode 700. The host
    # runner user (UID 1001) needs read access so actions/upload-artifact
    # can zip the tree without EACCES. Make the build dir world-readable.
    chmod -R a+rX "$(dirname "${OUTPUT}")"
    echo "==> Done. Artifacts in: $(dirname "${OUTPUT}")"
    ls -la "$(dirname "${OUTPUT}")"
else
    rc=$?
    echo "==> Export failed (exit ${rc}). Dumping MSBuild logs from this run:"
    find "${BUILD_LOGS_DIR}" -type f -name '*.txt' -newer "${LOG_BASELINE}" -print0 \
        | while IFS= read -r -d '' log; do
            echo "----- ${log} -----"
            cat "${log}"
            echo
        done
    exit "${rc}"
fi
