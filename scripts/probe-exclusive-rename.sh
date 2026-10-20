#!/usr/bin/env bash
# Record how an exclusive rename behaves on the file systems an export destination can use.
#
# For each file system it creates a small disk image in a fresh temporary folder, attaches it
# without showing it in Finder, and records:
#   - whether the volume advertises VOL_CAP_INT_RENAME_EXCL (getattrlist ATTR_VOL_CAPABILITIES);
#   - the result of renamex_np(RENAME_EXCL) onto a fresh name and onto an existing file;
#   - whether the existing file's bytes survived.
# The final export commit uses the exclusive rename only where the bit is advertised, and
# check-then-move elsewhere; docs/reference/architecture-conventions.md § Final file commit
# boundary records the results.
#
# Exits 1 if any volume replaced an existing file, or a volume could not be created, attached
# or probed. Without arguments it never touches a volume it did not create: every image lives
# under its own temporary folder and is detached and removed on exit.
#
# SMB and other network shares cannot be imaged. `--folder <dir>` probes the volume holding an
# existing folder instead (the manual SMB checklist in the same section): it works in a new
# hidden subfolder of <dir> and removes only that subfolder.
#
# Usage: probe-exclusive-rename.sh [--folder <dir>]
set -euo pipefail

folder=""
if [[ $# -eq 2 && "$1" == "--folder" && -d "$2" ]]; then
  folder="$2"
elif [[ $# -gt 0 ]]; then
  echo "::error::usage: probe-exclusive-rename.sh [--folder <existing dir>]" >&2
  exit 64
fi

# Resolved, so the mount table (which lists /private/var/...) matches the mount points.
work="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/probe-exclusive-rename.XXXXXX")" && pwd -P)"
mounts=()
folder_probe=""

cleanup() {
  local mount
  for mount in "${mounts[@]+"${mounts[@]}"}"; do
    hdiutil detach "${mount}" -quiet 2>/dev/null || hdiutil detach "${mount}" -force -quiet || true
  done
  rm -rf "${work}"
  if [[ -n "${folder_probe}" ]]; then
    rm -rf "${folder_probe}"
  fi
}
trap cleanup EXIT

echo "::group::Environment"
sw_vers
uname -a
echo "python3: $(python3 --version 2>&1)"
echo "Work folder: ${work}"
echo "::endgroup::"

# Probe one mounted volume. Prints key=value lines; exits 2 when the existing file's bytes
# changed, 1 on an unexpected error.
probe() {
  python3 -I - "$1" <<'PY'
import ctypes
import errno
import os
import sys

ATTR_BIT_MAP_COUNT = 5
ATTR_VOL_INFO = 0x80000000
ATTR_VOL_CAPABILITIES = 0x00020000
VOL_CAPABILITIES_INTERFACES = 1
VOL_CAP_INT_RENAME_EXCL = 0x00080000
RENAME_EXCL = 0x00000004


class AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16),
                ("commonattr", ctypes.c_uint32), ("volattr", ctypes.c_uint32),
                ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                ("forkattr", ctypes.c_uint32)]


class Capabilities(ctypes.Structure):
    _fields_ = [("length", ctypes.c_uint32), ("capabilities", ctypes.c_uint32 * 4),
                ("valid", ctypes.c_uint32 * 4)]


libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
libc.getattrlist.argtypes = [ctypes.c_char_p, ctypes.POINTER(AttrList), ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32]
libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]

volume = sys.argv[1]


def capability():
    request = AttrList(bitmapcount=ATTR_BIT_MAP_COUNT, volattr=ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES)
    reply = Capabilities()
    if libc.getattrlist(os.fsencode(volume), ctypes.byref(request), ctypes.byref(reply),
                        ctypes.sizeof(reply), 0) != 0:
        return f"getattrlist-{errno.errorcode.get(ctypes.get_errno(), ctypes.get_errno())}"
    valid = reply.valid[VOL_CAPABILITIES_INTERFACES] & VOL_CAP_INT_RENAME_EXCL
    supported = reply.capabilities[VOL_CAPABILITIES_INTERFACES] & VOL_CAP_INT_RENAME_EXCL
    if not valid:
        return "not-reported"
    return "yes" if supported else "no"


def exclusive_rename(source, destination):
    if libc.renamex_np(os.fsencode(source), os.fsencode(destination), RENAME_EXCL) == 0:
        return "ok"
    code = ctypes.get_errno()
    return errno.errorcode.get(code, str(code))


def write(path, data):
    with open(path, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def read(path):
    with open(path, "rb") as handle:
        return handle.read()


print(f"capability={capability()}")
fresh_source = os.path.join(volume, "fresh-source.bin")
write(fresh_source, b"fresh")
print(f"fresh_rename={exclusive_rename(fresh_source, os.path.join(volume, 'fresh-target.bin'))}")

source = os.path.join(volume, "stage.bin")
destination = os.path.join(volume, "existing.bin")
write(destination, b"existing bytes")
write(source, b"new bytes")
print(f"existing_rename={exclusive_rename(source, destination)}")
after = read(destination)
print(f"stage_kept={'yes' if os.path.exists(source) else 'no'}")
if after == b"existing bytes":
    print("destination=intact")
    sys.exit(0)
print(f"destination=REPLACED ({after!r})")
sys.exit(2)
PY
}

if [[ -n "${folder}" ]]; then
  folder_probe="$(mktemp -d "${folder%/}/.photo-export-probe.XXXXXX")"
  echo "::group::${folder}"
  echo "Probe folder: ${folder_probe}"
  echo "Volume: $(df -P "${folder_probe}" | tail -1)"
  set +e
  probe "${folder_probe}"
  status=$?
  set -e
  echo "::endgroup::"
  if [[ ${status} -eq 2 ]]; then
    echo "::error::An exclusive rename replaced an existing file on ${folder}"
  elif [[ ${status} -ne 0 ]]; then
    echo "::error::The probe failed on ${folder} (status ${status})"
  fi
  exit $(( status == 0 ? 0 : 1 ))
fi

# "<label>|<hdiutil -fs name>"
filesystems=(
  "APFS|APFS"
  "HFS+|HFS+"
  "ExFAT|ExFAT"
  "MS-DOS (FAT32)|MS-DOS FAT32"
)

summary=()
failed=0
index=0
for entry in "${filesystems[@]}"; do
  label="${entry%%|*}"
  fs="${entry#*|}"
  index=$((index + 1))
  image="${work}/volume-${index}.dmg"
  mount="${work}/mount-${index}"
  echo "::group::${label}"
  if ! hdiutil create -size 64m -fs "${fs}" -volname "PROBE${index}" "${image}"; then
    echo "::error::${label}: hdiutil create failed"
    summary+=("${label}: image could not be created")
    failed=1
    echo "::endgroup::"
    continue
  fi
  mkdir -p "${mount}"
  if ! hdiutil attach -nobrowse -noautoopen -mountpoint "${mount}" "${image}"; then
    echo "::error::${label}: hdiutil attach failed"
    summary+=("${label}: image could not be attached")
    failed=1
    echo "::endgroup::"
    continue
  fi
  mounts+=("${mount}")
  echo "Mounted: $(mount | grep -F " on ${mount} " || echo "(not in the mount table)")"
  set +e
  output="$(probe "${mount}" 2>&1)"
  status=$?
  set -e
  echo "${output}"
  line="$(tr '\n' ' ' <<< "${output}")"
  case "${status}" in
    0) summary+=("${label}: ${line}") ;;
    2)
      echo "::error::${label}: an exclusive rename replaced an existing file"
      summary+=("${label}: OVERWROTE: ${line}")
      failed=1
      ;;
    *)
      echo "::error::${label}: the probe failed (status ${status})"
      summary+=("${label}: PROBE FAILED: ${line}")
      failed=1
      ;;
  esac
  hdiutil detach "${mount}" -quiet || hdiutil detach "${mount}" -force -quiet
  mounts=("${mounts[@]:0:${#mounts[@]}-1}")
  echo "::endgroup::"
done

echo "Exclusive rename results:"
for line in "${summary[@]}"; do
  echo "  ${line}"
done
if [[ ${failed} -ne 0 ]]; then
  echo "::error::At least one volume replaced an existing file or could not be probed."
  exit 1
fi
echo "No volume replaced an existing file."
