#!/usr/bin/env bash
set -euo pipefail
DEV="${1:-}"
if [[ -z "$DEV" || ! -b "$DEV" ]]; then
    echo "Usage: sudo bash $0 /dev/sdX   (block device, not a partition like /dev/sdX1)"
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo bash $0 $DEV"
    exit 1
fi
echo "== Current layout of $DEV =="
lsblk "$DEV"
echo
echo "This will create ONE new partition using ALL free space after the"
echo "existing partition(s) on $DEV — it will NOT touch existing partitions."
read -rp "Continue? [y/N] " OK
[[ "$OK" == "y" || "$OK" == "Y" ]] || { echo "Aborted."; exit 1; }
BEFORE_PARTS=$(lsblk -lnpo NAME "$DEV" | tail -n +2 | sort)
LAST_END=$(parted -s "$DEV" unit MiB print 2>/dev/null | awk '/^ *[0-9]+/{end=$3} END{print (end=="" ? "1MiB" : end)}')
echo "Creating new partition from ${LAST_END} to end of disk..."
parted -s "$DEV" mkpart primary ext4 "${LAST_END}" 100%
partprobe "$DEV" 2>/dev/null || true
sleep 1
AFTER_PARTS=$(lsblk -lnpo NAME "$DEV" | tail -n +2 | sort)
NEWPART=$(comm -13 <(echo "$BEFORE_PARTS") <(echo "$AFTER_PARTS"))
if [[ -z "$NEWPART" ]]; then
    echo "ERROR: No new partition detected on $DEV after running parted." >&2
    echo "       Refusing to format anything — nothing was touched." >&2
    echo "       Try: sudo partprobe $DEV   then re-run this script," >&2
    echo "       or inspect manually with: lsblk $DEV" >&2
    exit 1
fi
if [[ "$(wc -l <<< "$NEWPART")" -ne 1 ]]; then
    echo "ERROR: Expected exactly one new partition, but found multiple:" >&2
    echo "$NEWPART" >&2
    echo "       Refusing to format — resolve this manually and re-run." >&2
    exit 1
fi
if [[ ! -b "$NEWPART" ]]; then
    echo "ERROR: Detected '$NEWPART' but it is not a valid block device." >&2
    echo "       Refusing to format." >&2
    exit 1
fi
echo "New partition: $NEWPART"
mkfs.ext4 -F -L persistence "$NEWPART"
MNT="$(mktemp -d)"
mount "$NEWPART" "$MNT"
echo "/ union" > "$MNT/persistence.conf"
umount "$MNT"
rmdir "$MNT"
echo
echo "Done. $NEWPART is labeled 'persistence' and ready."
echo "Boot the USB and pick 'NetCoreOS — Persistent Mode (saves changes)' from the GRUB menu."
