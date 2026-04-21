#!/bin/bash
# flash-iso.sh — Flash a Proxmox auto-install ISO to a USB drive.
#
# Usage:
#   sudo ./flash-iso.sh <iso-file> <device>
#
# Examples:
#   sudo ./flash-iso.sh proxmox-pve1-autoinstall.iso /dev/disk4    # macOS
#   sudo ./flash-iso.sh proxmox-pve1-autoinstall.iso /dev/sdb      # Linux

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ $# -ne 2 ]]; then
    echo "Usage: sudo $0 <iso-file> <device>"
    echo ""
    echo "Available ISOs:"
    ls -1 "$(dirname "$0")"/proxmox-*-autoinstall.iso 2>/dev/null | sed 's/^/  /' || echo "  (none found)"
    exit 1
fi

ISO_FILE="$1"
DEVICE="$2"

[[ -f "${ISO_FILE}" ]] || die "ISO file not found: ${ISO_FILE}"
[[ "$(id -u)" -eq 0 ]] || die "Must run as root (use sudo)"

command -v pv >/dev/null 2>&1 || die "pv (pipe viewer) is required. Install with: brew install pv (macOS) or apt install pv (Linux)"

OS="$(uname -s)"

if [[ "${OS}" == "Darwin" ]]; then
    [[ -e "${DEVICE}" ]] || die "${DEVICE} does not exist"
    RAW_DEVICE="${DEVICE/disk/rdisk}"
else
    [[ -b "${DEVICE}" ]] || die "${DEVICE} is not a block device"
    RAW_DEVICE="${DEVICE}"
fi

ISO_SIZE=$(stat -f%z "${ISO_FILE}" 2>/dev/null || stat -c%s "${ISO_FILE}" 2>/dev/null)
echo ""
echo "=== Flash Proxmox ISO to USB ==="
echo "  ISO:    $(basename "${ISO_FILE}") ($(numfmt --to=iec "${ISO_SIZE}" 2>/dev/null || echo "${ISO_SIZE} bytes"))"
echo "  Device: ${DEVICE}"
echo ""

read -rp "This will ERASE ${DEVICE}. Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || die "Aborted."

echo ""
echo "Unmounting ${DEVICE}..."
if [[ "${OS}" == "Darwin" ]]; then
    diskutil unmountDisk "${DEVICE}" 2>/dev/null || true
else
    umount "${DEVICE}"* 2>/dev/null || true
fi

echo "Flashing to ${RAW_DEVICE}..."
echo ""
pv -petrab "${ISO_FILE}" | dd of="${RAW_DEVICE}" bs=4M oflag=sync 2>/dev/null
sync

if [[ "${OS}" == "Darwin" ]]; then
    diskutil eject "${DEVICE}" 2>/dev/null || true
fi

echo ""
echo "=== Done! ==="
echo "USB drive is ready. Insert into the target machine and boot from USB."
