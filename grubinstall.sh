#!/usr/bin/env bash
set -Eeuo pipefail

# GRUB reinstall helper for Arch Linux (UEFI + Legacy BIOS)
# - Auto-detects ROOT (/), /boot, and ESP
# - Reads /etc/fstab from your root when possible
# - Clear menus + confirmations
# - Good error handling and cleanup
#
# Use from an Arch ISO / live environment.
# If LUKS: unlock first so the root FS is visible under /dev/mapper/*

LOG="/tmp/grubinstall.log"
MNT="/mnt"
BOOTID_DEFAULT="ArchLinux"
EFI_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

msg()   { printf "%b\n" "$*" | tee -a "$LOG"; }
die()   { printf "ERROR: %b\n" "$*" | tee -a "$LOG" >&2; exit 1; }
hr()    { printf -- "------------------------------------------------------------\n" | tee -a "$LOG"; }
pause() { read -r -p "Press Enter to continue..."; }
yesno() { read -r -p "${1:-Proceed?} [y/N]: " _a; [[ "${_a:-}" =~ ^[Yy]$ ]]; }

cleanup() {
  set +e
  for d in run sys proc dev; do
    mountpoint -q "${MNT}/${d}" && umount -R "${MNT}/${d}" || true
  done
  mountpoint -q "${MNT}/boot/efi" && umount -R "${MNT}/boot/efi" || true
  mountpoint -q "${MNT}/boot" && umount -R "${MNT}/boot" || true
  mountpoint -q "${MNT}" && umount -R "${MNT}" || true
}
trap cleanup EXIT

require_root() {
  [[ $EUID -eq 0 ]] || die "Please run as root."
}

lsblk_table() {
  lsblk -o NAME,PATH,SIZE,FSTYPE,TYPE,MOUNTPOINTS,PARTTYPE,PARTFLAGS,LABEL
}

choose() {
  # choose "Title" item1 item2 ...
  local title="$1"; shift
  local items=("$@")
  (( ${#items[@]} )) || return 1
  msg "$title"
  local i
  for ((i=0;i<${#items[@]};i++)); do
    printf "  %d) %s\n" "$((i+1))" "${items[$i]}"
  done
  local sel
  while true; do
    read -r -p "Select 1-${#items[@]} (or 0 to cancel): " sel
    [[ "$sel" =~ ^[0-9]+$ ]] || { echo "Invalid."; continue; }
    (( sel==0 )) && return 1
    (( sel>=1 && sel<=${#items[@]} )) && { printf "%s" "${items[$((sel-1))]}"; return 0; }
    echo "Invalid."
  done
}

detect_roots() {
  # Likely Linux roots: ext4/btrfs/xfs on part or lvm/mapper
  lsblk -rno PATH,FSTYPE,TYPE | awk '
    $2 ~ /^(ext4|btrfs|xfs|ext3)$/ && ($3=="part" || $3=="lvm") {print $1}
  ' | sort -u
}

detect_esps() {
  # Prefer vfat + ESP type GUID or ESP flag
  lsblk -rno PATH,FSTYPE,PARTTYPE,PARTFLAGS | awk -v g="$EFI_GUID" '
    $2 ~ /^vfat$/ && ($3==g || index(tolower($4),"esp")) {print $1}
  ' | sort -u
}

uuid_to_dev() {
  local token="$1" dev=""
  case "$token" in
    UUID=*)      dev=$(blkid -U "${token#UUID=}" 2>/dev/null || true) ;;
    PARTUUID=*)  dev=$(blkid -t PARTUUID="${token#PARTUUID=}" -o device 2>/dev/null || true) ;;
    LABEL=*)     dev=$(blkid -L "${token#LABEL=}" 2>/dev/null || true) ;;
    /dev/*)      dev="$token" ;;
  esac
  [[ -n "$dev" ]] && printf "%s" "$dev"
}

mount_root_and_fstab() {
  local root_dev="$1"
  msg "Mounting root ${root_dev} at ${MNT}"
  mkdir -p "$MNT"
  mount "$root_dev" "$MNT" || die "Failed to mount root ${root_dev}"

  if [[ -f "${MNT}/etc/fstab" ]]; then
    msg "Found fstab; trying to mount /boot and ESP from it"
    local boot_src efi_src boot_dev efi_dev
    boot_src=$(awk '!/^#/ && $2=="/boot"{print $1}' "${MNT}/etc/fstab" | head -n1 || true)
    efi_src=$(awk '!/^#/ && ($2=="/boot/efi" || $2=="/efi"){print $1}' "${MNT}/etc/fstab" | head -n1 || true)

    if [[ -n "$boot_src" ]]; then
      boot_dev=$(uuid_to_dev "$boot_src" || true)
      if [[ -n "$boot_dev" ]]; then
        mkdir -p "${MNT}/boot"
        mount "$boot_dev" "${MNT}/boot" || die "Mount /boot failed (${boot_dev})"
        msg "Mounted /boot from ${boot_dev}"
      fi
    fi
    if [[ -n "$efi_src" ]]; then
      efi_dev=$(uuid_to_dev "$efi_src" || true)
      if [[ -n "$efi_dev" ]]; then
        mkdir -p "${MNT}/boot/efi"
        mount "$efi_dev" "${MNT}/boot/efi" || die "Mount ESP failed (${efi_dev})"
        msg "Mounted ESP at /boot/efi from ${efi_dev}"
      fi
    fi
  else
    msg "No fstab on root — will ask you for /boot and ESP if needed."
  fi
}

ensure_boot_mounted() {
  if [[ -d "${MNT}/boot" && ! $(mountpoint -q "${MNT}/boot"; echo $?) -eq 0 ]]; then
    if yesno "Do you have a separate /boot partition?"; then
      lsblk_table
      read -r -p "Enter /boot partition (e.g., /dev/nvme0n1p2), or blank to skip: " bdev
      if [[ -n "${bdev:-}" ]]; then
        [[ -b "$bdev" ]] || die "Not a block device: $bdev"
        mkdir -p "${MNT}/boot"
        mount "$bdev" "${MNT}/boot" || die "Failed to mount /boot ($bdev)"
      fi
    fi
  fi
}

ensure_esp_mounted() {
  if ! mountpoint -q "${MNT}/boot/efi"; then
    msg "ESP not mounted. Attempting auto-detect…"
    mapfile -t esps < <(detect_esps)
    local esp
    if ((${#esps[@]})); then
      esp=$(choose "Choose your EFI System Partition:" "${esps[@]}") || die "Cancelled."
    else
      msg "No clear ESP found. Show disks below:"
      lsblk_table
      read -r -p "Enter ESP device (e.g., /dev/nvme0n1p1): " esp
    fi
    [[ -b "$esp" ]] || die "ESP device not found: $esp"
    mkdir -p "${MNT}/boot/efi"
    mount "$esp" "${MNT}/boot/efi" || die "Failed to mount ESP ($esp)"
    msg "Mounted ESP at ${MNT}/boot/efi from ${esp}"
  fi
}

bind_mounts() {
  msg "Binding system dirs"
  for d in dev proc sys run; do
    mount --rbind "/${d}" "${MNT}/${d}"
    mount --make-rslave "${MNT}/${d}"
  done
}

ensure_pkg_in_chroot() {
  # echo shell code for chroot: ensure package installed
  local pkg="$1"
  cat <<EOF
if ! pacman -Q ${pkg} >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed ${pkg}
fi
EOF
}

do_grub_install_uefi() {
  local removable="$1"
  local bootid="$2"
  local CH="/tmp/chroot-grub.sh"
  cat > "${MNT}${CH}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
$(ensure_pkg_in_chroot grub)
$(ensure_pkg_in_chroot efibootmgr)

mkdir -p /boot/efi
echo "Installing GRUB (UEFI) with Bootloader ID: ${bootid}"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="${bootid}" --recheck

if [[ "${removable}" == "yes" ]]; then
  echo "Also installing removable fallback at EFI/BOOT/BOOTX64.EFI"
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck
fi

echo "Generating grub.cfg"
mkdir -p /boot/grub
grub-mkconfig -o /boot/grub/grub.cfg
EOF
  chmod +x "${MNT}${CH}"
  arch-chroot "${MNT}" /bin/bash "${CH}" 2>&1 | tee -a "$LOG"
  rm -f "${MNT}${CH}"
}

do_grub_install_bios() {
  local disk="$1"
  local CH="/tmp/chroot-grub.sh"
  cat > "${MNT}${CH}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
$(ensure_pkg_in_chroot grub)
echo "Installing GRUB (BIOS) to ${disk}"
grub-install --target=i386-pc ${disk} --recheck
echo "Generating grub.cfg"
mkdir -p /boot/grub
grub-mkconfig -o /boot/grub/grub.cfg
EOF
  chmod +x "${MNT}${CH}"
  arch-chroot "${MNT}" /bin/bash "${CH}" 2>&1 | tee -a "$LOG"
  rm -f "${MNT}${CH}"
}

menu() {
  clear
  hr
  msg "GRUB Reinstall (Arch) — safer edition"
  hr
  if [[ -d /sys/firmware/efi/efivars ]]; then
    msg "Booted in: UEFI mode"
  else
    msg "Booted in: Legacy BIOS (or UEFI not exposed)"
  fi
  hr
  echo "1) UEFI reinstall"
  echo "2) UEFI reinstall + install removable fallback (EFI/BOOT/BOOTX64.EFI)"
  echo "3) Legacy BIOS reinstall"
  echo "4) Show disks/partitions"
  echo "0) Quit"
  hr
}

pick_root() {
  msg "Detecting Linux root candidates…"
  mapfile -t roots < <(detect_roots)
  local root
  if ((${#roots[@]})); then
    root=$(choose "Choose your ROOT partition:" "${roots[@]}") || die "Cancelled."
  else
    lsblk_table
    read -r -p "Enter ROOT device (e.g., /dev/nvme0n1p3 or /dev/mapper/…): " root
  fi
  [[ -b "$root" ]] || die "Not a block device: $root"
  printf "%s" "$root"
}

flow_uefi() {
  local removable="$1"
  [[ -d /sys/firmware/efi/efivars ]] || die "Not in UEFI mode. Reboot the ISO in UEFI."
  local root_dev; root_dev="$(pick_root)"

  clear; hr
  msg "Planned action:"
  msg "  Mode: UEFI (removable fallback: $removable)"
  msg "  Root: $root_dev"
  hr; lsblk_table; hr
  yesno "Proceed?" || die "Cancelled."

  mount_root_and_fstab "$root_dev"
  ensure_boot_mounted
  ensure_esp_mounted
  bind_mounts

  local bootid
  read -r -p "Bootloader ID [${BOOTID_DEFAULT}]: " bootid
  bootid="${bootid:-$BOOTID_DEFAULT}"

  do_grub_install_uefi "$removable" "$bootid"
  msg "UEFI GRUB reinstall complete. If firmware entry is missing, try the removable fallback or add it in firmware setup."
}

flow_bios() {
  local root_dev; root_dev="$(pick_root)"

  clear; hr
  msg "Planned action:"
  msg "  Mode: Legacy BIOS"
  msg "  Root: $root_dev"
  hr; lsblk_table; hr
  yesno "Proceed?" || die "Cancelled."

  mount_root_and_fstab "$root_dev"
  ensure_boot_mounted
  bind_mounts

  msg "Choose the DISK (whole device) to install the MBR bootloader to:"
  lsblk -dn -o NAME,PATH,SIZE,TYPE | awk '$4=="disk"{printf "   %s  %s  (%s)\n",$2,$1,$3}'
  local disk
  read -r -p "Disk (e.g., /dev/sda or /dev/nvme0n1): " disk
  [[ -b "$disk" ]] || die "Not a block device: $disk"

  do_grub_install_bios "$disk"
  msg "BIOS GRUB reinstall complete. Verify BIOS is set to boot this disk."
}

main() {
  require_root
  : > "$LOG"
  while true; do
    menu
    read -r -p "Choose: " opt
    case "${opt:-}" in
      1) flow_uefi "no" ;;
      2) flow_uefi "yes" ;;
      3) flow_bios ;;
      4) lsblk_table; pause ;;
      0) msg "Bye."; exit 0 ;;
      *) echo "Invalid."; sleep 1 ;;
    esac
  done
}

main