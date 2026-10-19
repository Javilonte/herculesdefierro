#!/usr/bin/env bash
# patch-banner.sh -- replace the default Hercules 4.00.0 status banner with a
# custom HERCULES v4.00 by JAVI FIERRO box-ASCII-art banner.
#
# Supported platforms:
#   Windows (Git Bash or WSL): works against hdt3270.dll that ships with TK4- v1.00 update 5
#   macOS  (any POSIX shell):  works against hdt3270.dylib (same offsets are assumed)
#   Linux                    : works against hdt3270.so   (same offsets are assumed)
#
# Modes:
#   --check      Verify SHA and report whether the binary is a known build
#   --discover   Compute SHA, search for the "Hercules Version" string,
#                show file offsets (useful when SHA does not match a known build)
#   --apply      Apply the 8-label + 8-value patch (requires the SHA to match a
#                known build; refuses otherwise for safety)
#   --revert     Restore the original binary from <bin>.bak-original
#   --help       Show this message
#
# Without arguments, the script auto-detects hdt3270 in the standard TK4- layout
# (./hercules_run/hercules/{windows,darwin,macos,linux}/64/hdt3270.*).
# Otherwise pass the path to the hdt3270 binary as the only positional argument.
#
# KNOWN SHAS (pre-computed; add new ones as you discover them):
KNOWN_SHAS_WINDOWS_TK4_v100_5="0B85525C5246FF7D616FBCCFD19B7800B1C612CDC21E856E752B64F2CE2D82C3"

set -euo pipefail

print_help() {
  sed -n '2,/^$/p' "$0" | sed -e 's/^# \{0,1\}//' | head -n -1
}

# ----- arg parsing -----------------------------------------------------------

MODE="check"
BIN_PATH=""
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check)     MODE="check";    shift ;;
    --discover)  MODE="discover"; shift ;;
    --apply)     MODE="apply";    shift ;;
    --revert)    MODE="revert";   shift ;;
    --help|-h)   print_help; exit 0 ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  BIN_PATH="$1"; shift ;;
  esac
done

# ----- helpers ---------------------------------------------------------------

sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -b "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -b "$f" 2>/dev/null | awk '{print $1}'
  else
    echo "no SHA-256 tool found (need sha256sum or shasum)" >&2
    return 1
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }
log()  { [ "$VERBOSE" -eq 1 ] && echo "[verbose] $*" >&2 || true; }

# ----- auto-detect ----------------------------------------------------------

if [ -z "$BIN_PATH" ]; then
  candidates=(
    "./hercules_run/hercules/windows/64/hdt3270.dll"
    "./hercules_run/hercules/darwin/64/hdt3270.dylib"
    "./hercules_run/hercules/macos/64/hdt3270.dylib"
    "./hercules_run/hercules/linux/64/hdt3270.so"
  )
  for c in "${candidates[@]}"; do
    [ -f "$c" ] && BIN_PATH="$c" && break
  done
  [ -z "$BIN_PATH" ] && die "could not auto-detect hdt3270 file -- pass the path as the only positional argument"
fi

[ -f "$BIN_PATH" ] || die "file not found: $BIN_PATH"

# ----- common actions --------------------------------------------------------

do_check() {
  echo "=== check mode ==="
  echo "file:    $BIN_PATH"
  echo "size:    $(wc -c < "$BIN_PATH") bytes"
  echo "sha256:  $(sha256_of "$BIN_PATH")"
  case "$(sha256_of "$BIN_PATH")" in
    "$KNOWN_SHAS_WINDOWS_TK4_v100_5")
      echo "status:  KNOWN (TK4- v1.00 update 5 Windows build)"
      echo "action:  safe to apply with --apply"
      ;;
    *)
      echo "status:  UNKNOWN build (not in the known-SHA whitelist)"
      echo "action:  use --discover to see offsets; patching will be refused"
      ;;
  esac
}

do_revert() {
  local bak="${BIN_PATH}.bak-original"
  if [ ! -f "$bak" ]; then
    die "no backup found at $bak -- cannot revert"
  fi
  echo "Killing any running daemon first..."
  pkill -f 'hercules(\.exe)?[[:space:]]+-d' 2>/dev/null || pkill -f hercules 2>/dev/null || true
  sleep 2
  cp "$bak" "$BIN_PATH"
  echo "reverted $BIN_PATH from $bak"
}

do_discover() {
  echo "=== discover mode ==="
  echo "file:   $BIN_PATH"
  echo "size:   $(wc -c < "$BIN_PATH") bytes"
  echo "sha256: $(sha256_of "$BIN_PATH")"
  echo ""
  echo "Searching for the 'Hercules Version' ASCII marker..."
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$BIN_PATH" <<'PYEOF'
import sys
fp = sys.argv[1]
data = open(fp, 'rb').read()
needle = b'Hercules Version'
i = 0
hits = []
while True:
    j = data.find(needle, i)
    if j < 0:
        break
    hits.append(j)
    i = j + 1
print(f"  '{needle.decode('ascii')}' found {len(hits)} time(s):")
for h in hits:
    ctx = data[max(0, h - 16): min(len(data), h + 48)]
    safe = bytes(c if 0x20 <= c < 0x7F else 0x2E for c in ctx).decode('ascii')
    print(f"    file offset 0x{h:x}: ...{safe}...")
PYEOF
  else
    # fallback: simple grep on octal/hex dump using od or hexdump
    if command -v od >/dev/null 2>&1; then
      echo "(python3 unavailable; using od for coarse search -- results may be noisy)"
      od -c "$BIN_PATH" | grep -i 'H   e   r   c   u   l   e   s   sp  V   e   r   s   i   o   n' || true
    else
      echo "(no python3 or od available; install python3 for best results)"
    fi
  fi
  echo ""
  echo "Note: the Windows build (hdt3270.dll @ SHA 0B85525C...) has 'Hercules Version'"
  echo "      at file offset 0x77B0 with the 8 lines spanning 0x766B to 0x77EB."
  echo "      Other builds will have different offsets; use the data above to find them."
}

do_apply() {
  local actual
  actual=$(sha256_of "$BIN_PATH")
  if [ "$actual" != "$KNOWN_SHAS_WINDOWS_TK4_v100_5" ]; then
    die "refusing to patch: SHA is not in the known whitelist. Use --discover, compute the new offsets, and add them to the script."
  fi

  local bak="${BIN_PATH}.bak-original"
  if [ ! -f "$bak" ]; then
    echo "Creating backup at $bak"
    cp "$BIN_PATH" "$bak"
  fi

  echo "Killing any running daemon..."
  pkill -f 'hercules(\.exe)?[[:space:]]+-d' 2>/dev/null || pkill -f hercules 2>/dev/null || true
  sleep 2

  echo "Applying banner patch with python3..."
  python3 - "$BIN_PATH" <<'PYEOF'
import sys, os

binfile = sys.argv[1]

# 8 label slots, each 24 bytes, written by overwriting 19 chars content + null + 4 null padding
labels = [
    (0x77B0, "+-----------------+"),            # Row 1 (Hercules Version position)
    (0x7780, "| HERCULES v4.0   |"),            # Row 2 (Host name position)
    (0x7758, "|  by JAVI FIERRO |"),            # Row 3 (Host OS position)  -- your signature
    (0x7718, "|-----------------|"),            # Row 4 (Host Architecture position)
    (0x76F0, "| reverse engineered"),           # Row 5 (Processors position)
    (0x76C8, "| with REA+Ghidra |"),            # Row 6 (LPAR Name position)
    (0x76A0, "| 2026 (TK4 v1.0) |"),            # Row 7 (Device number position)
    (0x7678, "+-----------------+"),            # Row 8 (Subchannel position)
]

# 8 value slots: set to zeros (the value field on the right side of each row)
values = [
    (0x766B, 16),   # Row 1 value (Hercules Version)
    (0x7690, 16),   # Row 2 value
    (0x76B8, 16),   # Row 3 value
    (0x76E0, 16),   # Row 4 value
    (0x7708, 16),   # Row 5 value
    (0x7730, 40),   # Row 6 value (wider)
    (0x7770, 16),   # Row 7 value
    (0x7798, 16),   # Row 8 value
]

# Write values first (in offset order), then labels. This way Row 8's label
# overwrites the zeros in the 3-byte overlap with Row 8's value.
with open(binfile, 'r+b') as f:
    for off, size in sorted(values):
        f.seek(off)
        f.write(b'\x00' * size)
    for off, s in sorted(labels):
        chunk = s.encode('ascii') + b'\x00' * (24 - len(s))
        f.seek(off)
        f.write(chunk[:24])

print(f"Patched {binfile}")
print(f"  8 label slots (each 24 B) -- new box ASCII art")
print(f"  8 value slots (16 or 40 B each) -- cleared to empty")
PYEOF

  echo ""
  echo "Patch applied. Verify with: sha256sum \"$BIN_PATH\""
  echo "The new SHA should differ from the original but the file size should be unchanged."
}

# ----- dispatch --------------------------------------------------------------

case "$MODE" in
  check)    do_check ;;
  discover) do_discover ;;
  apply)    do_apply ;;
  revert)   do_revert ;;
esac
