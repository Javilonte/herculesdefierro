#!/usr/bin/env bash
# setup.sh -- extract the TK4- v1.00 update 5 zip into a sibling ../hercules_run/
# directory and prepare it for either Linux or macOS binaries.
#
# Usage:
#   bash scripts/setup.sh                       # auto-detect zip in ../ or ~/Downloads/
#   bash scripts/setup.sh /path/to/tk4-_v1.00_current-v05.zip [../hercules_run]
#
# After this script:
#   ../hercules_run/
#     conf/             # tk4-.cnf, cbt_dasd.cnf, source_dasd.cnf, etc.
#     dasd/             # 28 MVS 3.8j disk images (.180, .190, .270, etc.)
#     jcl/, tapes/, pch/, unattended/, rdr/
#     scripts/          # ipl.rc and friends
#     log/              # created if missing
#     local_conf/       # 01..10 override files
#     hercules/windows/64/   # Windows binaries (hercules.exe, hengine.dll, hdt*.dll, ...)
#     hercules/linux/64/     # Linux x64 binaries (hercules, hengine.so, ...)
#     hercules/darwin/64/    # macOS Mach-O binaries -- POPULATE THIS MANUALLY
#
# On macOS, the TK4- zip does not include macOS binaries; you must copy them from
# the Hercules DMG installer you installed separately. See the README.

set -euo pipefail

ZIP_PATH="${1:-}"
DEST_DIR=""

# --- 1. Find the zip ---------------------------------------------------------

if [ -z "$ZIP_PATH" ]; then
  candidates=(
    "../tk4-_v1.00_current-v05.zip"
    "${HOME}/Downloads/tk4-_v1.00_current-v05.zip"
    "./tk4-_v1.00_current-v05.zip"
  )
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
      ZIP_PATH="$c"
      break
    fi
  done
  if [ -z "$ZIP_PATH" ]; then
    echo "Could not auto-discover the TK4- v1.00 update 5 zip." >&2
    echo "  Looked in: $(printf '%s, ' "${candidates[@]}")" >&2
    echo "" >&2
    echo "Download the zip from https://wotho.ethz.ch/tk4-/ (look for the" >&2
    echo "TK4- v1.00 update 5 entry) and pass its path as the only argument:" >&2
    echo "" >&2
    echo "  bash scripts/setup.sh /path/to/tk4-_v1.00_current-v05.zip" >&2
    exit 1
  fi
fi

if [ ! -f "$ZIP_PATH" ]; then
  echo "ERROR: zip not found: $ZIP_PATH" >&2
  exit 1
fi

ZIP_SIZE=$(wc -c < "$ZIP_PATH" | tr -d ' ')
echo "Using zip: $ZIP_PATH  (${ZIP_SIZE} bytes)"

# --- 2. Determine dest dir ---------------------------------------------------

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PARENT_DIR=$(dirname "$SCRIPT_DIR")
DEST_DIR="${2:-$PARENT_DIR/hercules_run}"

if [ -d "$DEST_DIR" ] && [ "$(ls -A "$DEST_DIR" 2>/dev/null)" ]; then
  echo "" >&2
  echo "Re-extracting into the existing (non-empty) $DEST_DIR." >&2
  echo "Matching files will be overwritten. Delete the directory first" >&2
  echo "if you want a clean run." >&2
fi
mkdir -p "$DEST_DIR"
echo "Dest dir: $DEST_DIR"

# --- 3. Extract --------------------------------------------------------------
# Use Python's zipfile so the script works identically on macOS, Linux, and
# (via the WSL bash that ships with Git for Windows) Windows. We can't rely
# on `unzip` being available everywhere.

python3 - "$ZIP_PATH" "$DEST_DIR" <<'PYEOF'
import sys, os, zipfile

zp, dst = sys.argv[1], sys.argv[2]

needed_prefixes = (
    'hercules/windows/64/',
    'hercules/linux/64/',
    'conf/',
    'dasd/',
    'local_conf/',
    'scripts/',
    'log/',
    'jcl/',
    'tapes/',
    'pch/',
    'unattended/',
    'rdr/',
)

count = 0
skipped = 0
with zipfile.ZipFile(zp) as zf:
    for info in zf.infolist():
        if not any(info.filename.startswith(p) for p in needed_prefixes):
            skipped += 1
            continue
        if info.filename.endswith('/'):
            continue
        outpath = os.path.join(dst, info.filename.replace('/', os.sep))
        outdir = os.path.dirname(outpath)
        if outdir:
            os.makedirs(outdir, exist_ok=True)
        with zf.open(info) as src, open(outpath, 'wb') as outf:
            outf.write(src.read())
        count += 1

print(f"Extracted {count} files (skipped {skipped} unnecessary entries).")
PYEOF

# --- 4. Pre-create the log dir (the zip only contains a 'log/' entry) --------

mkdir -p "$DEST_DIR/log"

# --- 5. Sanity checks ---------------------------------------------------------

required=(
  "hercules/windows/64/hercules.exe"
  "hercules/linux/64/hercules"
  "conf/tk4-.cnf"
  "scripts/ipl.rc"
)
missing=()
for r in "${required[@]}"; do
  if [ ! -f "$DEST_DIR/$r" ]; then
    missing+=("$r")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "" >&2
  echo "ERROR: required files missing after extraction:" >&2
  for m in "${missing[@]}"; do
    echo "  - $m" >&2
  done
  echo "" >&2
  echo "The zip you provided may not be TK4- v1.00 update 5." >&2
  exit 1
fi

# --- 6. Platform-specific next steps ----------------------------------------

echo ""
echo "Setup complete."
echo ""
DASDC=$(ls "$DEST_DIR/dasd" 2>/dev/null | wc -l | tr -d ' ')
echo "  hercules_run/ ready (DASD images in dasd/: $DASDC files)"
echo ""

case "$(uname -s 2>/dev/null)" in
  Darwin)
    echo "  Detected platform: macOS"
    echo ""
    echo "  NEXT STEPS on macOS:"
    echo "  1. Install the official Hercules DMG from https://www.hercules-390.org/."
    echo "     This gives you the Mach-O binaries in /Applications/Hercules.app/Contents/MacOS/."
    echo "  2. Copy the macOS binaries into a darwin/ subdirectory of hercules_run/:"
    echo "       HERSRC=/Applications/Hercules.app/Contents/MacOS"
    echo "       HERDEST=\"$DEST_DIR/hercules/darwin/64\""
    echo "       mkdir -p \"\$HERDEST\""
    echo "       cp \"\$HERSRC\"/{hercules,hengine.dylib,hutil.dylib,hsys.dylib,hdt*.dylib,dasd*} \"\$HERDEST/\""
    echo "  3. Apply the welcome-banner patch:"
    echo "       bash ../herculesdefierro/scripts/patch-banner.sh --discover"
    echo "  4. Start the daemon:"
    echo "       cd \"$DEST_DIR\""
    echo "       ./hercules/darwin/64/hercules -d -f conf/tk4-.cnf"
    echo "  5. Connect with wx3270 (see README)."
    ;;
  Linux)
    echo "  Detected platform: Linux"
    echo ""
    echo "  NEXT STEPS on Linux:"
    echo "  1. Verify the Linux binaries are runnable (they're already in hercules_run/hercules/linux/64/)."
    echo "       ls -l \"$DEST_DIR/hercules/linux/64/hercules\""
    echo "       \"$DEST_DIR/hercules/linux/64/hercules\" -v"
    echo "  2. Apply the welcome-banner patch:"
    echo "       bash ../herculesdefierro/scripts/patch-banner.sh --discover"
    echo "  3. Start the daemon:"
    echo "       cd \"$DEST_DIR\""
    echo "       ./hercules/linux/64/hercules -d -f conf/tk4-.cnf"
    echo "  4. Connect with x3270 or wx3270."
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "  Detected platform: Windows (Git Bash / MSYS)"
    echo ""
    echo "  NEXT STEPS on Windows:"
    echo "  1. Use scripts/setup.ps1 instead (PowerShell), or continue here and use"
    echo "     the Bash scripts afterwards -- both work."
    echo "  2. Apply the welcome-banner patch:"
    echo "       bash scripts/patch-banner.sh --discover"
    echo "  3. Start the daemon:"
    echo "       \"\$DEST_DIR/hercules/windows/64/hercules.exe\" -d -f conf\\\\tk4-.cnf"
    ;;
  *)
    echo "  Detected platform: $(uname -s 2>/dev/null) (unknown)"
    echo ""
    echo "  Set up binaries manually for your platform; the configs and DASD are ready."
    ;;
esac
