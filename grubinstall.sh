#!/usr/bin/env bash
set -euo pipefail

# Interactive GRUB reinstaller for Arch Linux (UEFI + Legacy BIOS)
# Use from an Arch ISO (or rescue) shell.
# Features:
#  - Auto-detects likely ROOT, /boot, and EFI System Partition (ESP)
#  - Reads /etc/fstab from your root to mount /boot and /boot/efi when possible
#  - Works for UEFI (with optional removable fallback) and Legacy BIOS
#  - Clear numbered menus + confirmations
#
# NOTE: If your root is LUKS-encrypted, unlock it first (e.g., cryptsetup open ...).
#       This script assumes unlocked devices are visible under /dev/mapper/*.

MNT="/mnt"
CHROOT_SCRIPT=""
BOOTID_DEFAULT="ArchLinux"
EFI_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"  # EFI System Partition GUID

cleanup() {
  set +e
  [[ -n "${CHROOT_SCRIPT}" && -f "${CHROOT_SCRIPT}" ]] && rm -f "${CHROOT_SCRIPT}"
  for d in run sys proc dev; do
    mountpoint -q "${MNT}/${d}" && umount -R "${MNT}/${d}" || true
  done
  mountpoint -q "${MNT}/boot/efi" && umount -R "${MNT}/boot/efi" || true
  mountpoint -q "${MNT}/boot" && umount -R "${MNT}/boot" || true
  mountpoint -q "${MNT}" && umount -R "${MNT}" || true
}
trap cleanup EXIT

pause() { read -r -p "Press Enter to continue..."; }

println() { printf "%b\n" "$*"; }
hr() { printf -- "-----------------------------------------------------------------\n"; }

confirm() {
  local msg="${1:-Proceed?}"
  while true; do
    read -r -p "${msg} [y/N]: " ans
    case "${ans:-}" in
      y|Y) return 0;;
      n|N|"") return 1;;
      *) println "Please answer y or n.";;
    esac
  done
}

choose_from_list() {
  # args: title, array items...
  local title="$1"; shift
  local items=("$@")
  local i
  println "$title"
  for ((i=0;i<${#items[@]};i++)); do
    printf "  %d) %s\n" "$((i+1))" "${items[$i]}"
  done
  local choice
  while true; do
    read -r -p "Select 1-${#items[@]} (or 0 to cancel): " choice
    [[ -z "${choice}" ]] && continue
    if [[ "${choice}" =~ ^[0-9]+$ ]]; then
      if (( choice == 0 )); then
        return 1
      elif (( choice >= 1 && choice <= ${#items[@]} )); then
        printf "%s" "${items[$((choice-1))]}"
        return 0
      fi
    fi
    println "Invalid choice."
  done
}

lsblk_table() {
  lsblk -o NAME,PATH,FSTYPE,SIZE,TYPE,MOUNTPOINTS,PARTTYPE,PARTFLAGS,LABEL
}

device_exists() {
  local dev="$1"
  [[ -b "$dev" ]]
}

detect_root_candidates() {
  # Likely Linux roots: ext4, btrfs, xfs
  lsblk -rno PATH,FSTYPE,TYPE | awk '
    $2 ~ /^(ext4|btrfs|xfs|ext3|ext2)$/ && $3 == "part" {print $1}
  '
  # Also include mapped devices (e.g., LUKS/LVM) that are formatted as Linux FS
  lsblk -rno PATH,FSTYPE,TYPE | awk '
    $2 ~ /^(ext4|btrfs|xfs|ext3|ext2)$/ && $3 == "lvm" {print $1}
  '
}

detect_esp_candidates() {
  # Prefer partitions with PARTTYPE == EFI GUID and vfat
  while IFS= read -r line; do
    echo "$line"
  done < <(lsblk -rno PATH,FSTYPE,PARTTYPE,PARTFLAGS | awk -v guid="$EFI_GUID" '
    $2 ~ /^vfat$/ && ($3 == guid || index(tolower($4),"esp")>0) {print $1}
  ')

  # Fallback: any vfat partition ~50MB-1GB often is ESP (heuristic)
  while IFS= read -r line; do
    echo "$line"
  done < <(lsblk -rno PATH,FSTYPE,SIZE,TYPE | awk '
    $2 ~ /^vfat$/ && $4=="part" {
      # crude size filter removed for compatibility; still include
      print $1
    }
  ')
}

uuid_to_dev() {
  # Resolve UUID=... or PARTUUID=... from fstab to /dev node
  local token="$1"
  local dev=""
  if [[ "$token" == UUID=* ]]; then
    local u="${token#UUID=}"
    dev=$(blkid -U "$u" 2>/dev/null || true)
  elif [[ "$token" == PARTUUID=* ]]; then
    local pu="${token#PARTUUID=}"
    dev=$(blkid -t PARTUUID="$pu" -o device 2>/dev/null || true)
  elif [[ "$token" == LABEL=* ]]; then
    local l="${token#LABEL=}"
    dev=$(blkid -L "$l" 2>/dev/null || true)
  fi
  [[ -n "$dev" ]] && printf "%s" "$dev"
}

mount_root_and_parse_fstab() {
  local root_dev="$1"
  println "==> Mounting root ${root_dev} at ${MNT}"
  mkdir -p "$MNT"
  mount "$root_dev" "$MNT"

  if [[ -f "${MNT}/etc/fstab" ]]; then
    println "==> Found fstab; attempting to mount /boot and /boot/efi per fstab"
    # Grep entries ignoring comments
    local boot_src efi_src
    boot_src=$(awk '!/^#/ && $2=="/boot"{print $1}' "${MNT}/etc/fstab" | head -n1 || true)
    efi_src=$(awk '!/^#/ && ($2=="/efi" || $2=="/boot/efi"){print $1}' "${MNT}/etc/fstab" | head -n1 || true)

    if [[ -n "$boot_src" ]]; then
      local boot_dev; boot_dev=$(uuid_to_dev "$boot_src" || true)
      if [[ -z "$boot_dev" && "$boot_src" == /dev/* ]]; then boot_dev="$boot_src"; fi
      if [[ -n "$boot_dev" ]]; then
        println "  -> Mounting /boot from ${boot_dev}"
        mkdir -p "${MNT}/boot"
        mount "$boot_dev" "${MNT}/boot"
      fi
    fi

    if [[ -n "$efi_src" ]]; then
      local efi_dev; efi_dev=$(uuid_to_dev "$efi_src" || true)
      if [[ -z "$efi_dev" && "$efi_src" == /dev/* ]]; then efi_dev="$efi_src"; fi
      if [[ -n "$efi_dev" ]]; then
        println "  -> Mounting ESP at /boot/efi from ${efi_dev}"
        mkdir -p "${MNT}/boot/efi"
        mount "$efi_dev" "${MNT}/boot/efi"
      fi
    fi
  else
    println "==> No fstab found on root. Will ask you to pick /boot and ESP manually if needed."
  fi
}

bind_mounts() {
  println "==> Binding system directories"
  for d in dev proc sys run; do
    mount --rbind "/${d}" "${MNT}/${d}"
    mount --make-rslave "${MNT}/${d}"
  done
}

ensure_pkg_in_chroot() {
  local pkg="$1"
  cat <<EOF
if ! pacman -Q ${pkg} >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed ${pkg}
fi
EOF
}

grub_install_uefi() {
  local bootid="$1"; local removable_flag="$2"
  cat <<EOF
${REM:=}
$(ensure_pkg_in_chroot grub)
$(ensure_pkg_in_chroot efibootmgr)

mkdir -p /boot/efi
echo "==> Installing GRUB (UEFI) to /boot/efi with Bootloader ID: ${bootid}"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="${bootid}" --recheck

if [[ "${removable_flag}" = "yes" ]]; then
  echo "==> Also installing removable fallback at EFI/BOOT/BOOTX64.EFI"
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck
fi

echo "==> Generating grub.cfg"
mkdir -p /boot/grub
grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

grub_install_bios() {
  local disk="$1"
  cat <<EOF
$(ensure_pkg_in_chroot grub)
echo "==> Installing GRUB (BIOS) to ${disk}"
grub-install --target=i386-pc ${disk} --recheck

echo "==> Generating grub.cfg"
mkdir -p /boot/grub
grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

ensure_mounted_esp() {
  if ! mountpoint -q "${MNT}/boot/efi"; then
    println "==> ESP not mounted. Attempting auto-detection..."
    mapfile -t esp_list < <(detect_esp_candidates | sort -u)
    if ((${#esp_list[@]}==0)); then
      println "Could not auto-detect an ESP. You will need to select it."
      lsblk_table
      read -r -p "Enter ESP device path (e.g., /dev/nvme0n1p1): " esp_dev
    else
      local choice; choice=$(choose_from_list "Choose your EFI System Partition (ESP):" "${esp_list[@]}") || { println "Cancelled."; exit 1; }
      local esp_dev="$choice"
    fi
    if ! device_exists "${esp_dev}"; then println "ESP device not found: ${esp_dev}"; exit 1; fi
    mkdir -p "${MNT}/boot/efi"
    println "==> Mounting ESP ${esp_dev} at ${MNT}/boot/efi"
    mount "${esp_dev}" "${MNT}/boot/efi"
  fi
}

ensure_boot_mounted() {
  # If /boot exists and is not a mountpoint, ask user whether they have a separate /boot
  if [[ -d "${MNT}/boot" && ! $(mountpoint -q "${MNT}/boot"; echo $?) -eq 0 ]]; then
    if confirm "Do you have a separate /boot partition to mount?"; then
      lsblk_table
      read -r -p "Enter /boot partition device (or leave blank to skip): " boot_dev
      if [[ -n "${boot_dev:-}" ]]; then
        if ! device_exists "${boot_dev}"; then println "Device not found: ${boot_dev}"; exit 1; fi
        mkdir -p "${MNT}/boot"
        println "==> Mounting /boot from ${boot_dev}"
        mount "${boot_dev}" "${MNT}/boot"
      fi
    fi
  fi
}

menu_main() {
  clear
  hr
  println "GRUB Rescue for Arch Linux"
  hr
  println "Detected environment:"
  if [[ -d /sys/firmware/efi/efivars ]]; then
    println "  • Booted in UEFI mode"
  else
    println "  • Booted in Legacy BIOS (or UEFI not exposed)"
  fi
  hr
  println "1) Reinstall GRUB (UEFI)"
  println "2) Reinstall GRUB (UEFI) + install removable fallback (EFI/BOOT/BOOTX64.EFI)"
  println "3) Reinstall GRUB (Legacy BIOS)"
  println "4) Show disks/partitions"
  println "0) Quit"
  hr
  read -r -p "Choose an option: " opt
  case "${opt:-}" in
    1) flow_uefi "no";;
    2) flow_uefi "yes";;
    3) flow_bios;;
    4) lsblk_table; pause; menu_main;;
    0) println "Bye!"; exit 0;;
    *) println "Invalid option."; pause; menu_main;;
  esac
}

pick_root() {
  println "==> Detecting candidate Linux root partitions..."
  mapfile -t roots < <(detect_root_candidates | sort -u)
  if ((${#roots[@]}==0)); then
    println "No obvious Linux filesystems found."
    lsblk_table
    read -r -p "Enter your ROOT device (e.g., /dev/nvme0n1p3 or /dev/mapper/vol-root): " root_dev
  else
    local root_dev
    root_dev=$(choose_from_list "Choose your ROOT partition:" "${roots[@]}") || { println "Cancelled."; exit 1; }
    printf "%s" "$root_dev"
    return 0
  fi
  printf "%s" "${root_dev}"
}

flow_uefi() {
  local do_removable="${1:-no}"

  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    println "ERROR: You are not booted in UEFI mode (no /sys/firmware/efi/efivars)."
    println "Reboot the live ISO in UEFI mode and run again."
    exit 1
  fi

  local root_dev; root_dev="$(pick_root)"
  [[ -z "$root_dev" ]] && { println "No root selected."; exit 1; }

  clear
  hr
  println "About to proceed with:"
  println "  • Mode: UEFI (removable fallback: ${do_removable})"
  println "  • Root: ${root_dev}"
  hr
  lsblk_table
  confirm "Proceed with these settings?" || { println "Cancelled."; exit 1; }

  mount_root_and_parse_fstab "$root_dev"
  ensure_boot_mounted
  ensure_mounted_esp

  bind_mounts

  local bootid
  read -r -p "Bootloader ID (what firmware menu shows) [${BOOTID_DEFAULT}]: " bootid
  bootid="${bootid:-$BOOTID_DEFAULT}"

  CHROOT_SCRIPT="$(mktemp)"
  {
    echo "set -euo pipefail"
    grub_install_uefi "$bootid" "$do_removable"
  } > "${CHROOT_SCRIPT}"

  println "==> Entering chroot to install GRUB (UEFI)"
  arch-chroot "${MNT}" /bin/bash "${CHROOT_SCRIPT}"
  println "==> UEFI GRUB reinstall complete."
  println "If firmware entry is missing, try option 2 (removable fallback) or add an entry in firmware setup."
}

flow_bios() {
  local root_dev; root_dev="$(pick_root)"
  [[ -z "$root_dev" ]] && { println "No root selected."; exit 1; }

  clear
  hr
  println "About to proceed with:"
  println "  • Mode: Legacy BIOS"
  println "  • Root: ${root_dev}"
  hr
  lsblk_table
  confirm "Proceed with these settings?" || { println "Cancelled."; exit 1; }

  mount_root_and_parse_fstab "$root_dev"
  ensure_boot_mounted
  bind_mounts

  println "==> Select the DISK (not a partition) to install the BIOS bootloader to."
  println "Hint: choose the whole device like /dev/sda or /dev/nvme0n1 (NOT ...p1)."
  lsblk -dn -o NAME,PATH,SIZE,TYPE | awk '$4=="disk"{printf "   %s  %s  (%s)\n",$2,$1,$3}'
  local disk
  read -r -p "Disk (e.g., /dev/sda or /dev/nvme0n1): " disk
  if [[ -z "${disk:-}" || ! -b "$disk" ]]; then
    println "Invalid disk."
    exit 1
  fi

  CHROOT_SCRIPT="$(mktemp)"
  {
    echo "set -euo pipefail"
    grub_install_bios "$disk"
  } > "${CHROOT_SCRIPT}"

  println "==> Entering chroot to install GRUB (BIOS)"
  arch-chroot "${MNT}" /bin/bash "${CHROOT_SCRIPT}"
  println "==> BIOS GRUB reinstall complete."
  println "If it still won’t boot, check partition flags and that your BIOS is set to boot this disk."
}

main() {
  while true; do
    menu_main
  done
}

main