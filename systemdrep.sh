sudo bash -c '
set -euo pipefail

# 1) Find EFI partition (by GPT type GUID) and mount it at /boot
efi=$(lsblk -rpno NAME,PARTTYPE | awk "/c12a7328-f81f-11d2-ba4b-00a0c93ec93b/{print \$1; exit}")
[ -z "$efi" ] && { echo "EFI System Partition not found."; exit 1; }
mountpoint -q /boot || mount "$efi" /boot

# 2) Reinstall systemd-boot
bootctl install

# 3) Detect root device/UUID (the one mounted at /)
rootdev=$(findmnt -no SOURCE /)
rootuuid=$(blkid -s UUID -o value "$rootdev")

# 4) Detect kernel & initramfs filenames
kernel=$(ls /boot/vmlinuz-* 2>/dev/null | head -n1 | xargs -n1 basename)
initrd=$(ls /boot/initramfs-*.img 2>/dev/null | head -n1 | xargs -n1 basename)
[ -z "$kernel" ] && { echo "No kernel found in /boot."; exit 1; }
[ -z "$initrd" ] && { echo "No initramfs found in /boot."; exit 1; }

# 5) Recreate entries
mkdir -p /boot/loader/entries

cat >/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /$kernel
initrd  /$initrd
options root=UUID=$rootuuid rw
EOF

if [ -f /boot/EFI/Microsoft/Boot/bootmgfw.efi ]; then
cat >/boot/loader/entries/windows.conf <<EOF
title   Windows 11
efi     /EFI/Microsoft/Boot/bootmgfw.efi
EOF
fi

# 6) Loader config: Arch default, show menu 5s, disable auto-entries
cat >/boot/loader/loader.conf <<EOF
default arch.conf
timeout 5
auto-entries 0
EOF

echo
bootctl list
echo
echo "✅ Done. Reboot and you should see Arch + Windows. Arch is default."
'