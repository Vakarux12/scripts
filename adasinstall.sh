#!/usr/bin/env bash
# Arch Linux automated install for /dev/nvme0n1 (UEFI, systemd-boot)
# DANGER: This wipes the target disk!

set -euo pipefail

# ---- Config (edit if needed) ----
DEVICE="/dev/nvme0n1"
HOSTNAME="arch"
USERNAME="adasjusk"
TIMEZONE="Europe/Vilnius"
LOCALE="en_US.UTF-8"

# Optional: set these to avoid interactive password prompts
# export ROOTPASSWORD="changeme"
# export USERPASSWORD="changeme"
ROOTPASSWORD="${ROOTPASSWORD:-}"
USERPASSWORD="${USERPASSWORD:-}"
# ---------------------------------

echo ">>> WARNING: This will WIPE ${DEVICE}. Press Enter to continue or Ctrl+C to abort."
read -r

# Must be UEFI-booted
if [ ! -d /sys/firmware/efi/efivars ]; then
  echo "ERROR: System is not booted in UEFI mode. Aborting."
  exit 1
fi

echo ">>> Syncing time..."
timedatectl set-ntp true || true

echo ">>> Partitioning ${DEVICE} (GPT: ESP + swap + ext4 root)..."
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart ESP fat32 1MiB 513MiB
parted -s "$DEVICE" set 1 esp on
parted -s "$DEVICE" mkpart primary linux-swap 513MiB 10793MiB
parted -s "$DEVICE" mkpart primary ext4 10793MiB 100%

# Wait for /dev nodes to appear
sleep 2

ESP="${DEVICE}p1"
SWAP="${DEVICE}p2"
ROOT="${DEVICE}p3"

echo ">>> Creating filesystems..."
mkfs.fat -F32 "$ESP"
mkswap "$SWAP"
swapon "$SWAP"
mkfs.ext4 -F "$ROOT"

echo ">>> Mounting target..."
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$ESP" /mnt/boot

echo ">>> Installing base system..."
pacstrap -K /mnt base linux linux-firmware nano sudo networkmanager

echo ">>> Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

PARTUUID_ROOT="$(blkid -s PARTUUID -o value "$ROOT")"

echo ">>> Chroot configuration..."
arch-chroot /mnt /bin/bash -euxo pipefail <<CHROOT
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
if ! grep -q "^$LOCALE " /etc/locale.gen; then
  echo "$LOCALE UTF-8" >> /etc/locale.gen
fi
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Hostname & hosts
echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain $HOSTNAME
EOF

# User
useradd -m -G wheel -s /bin/bash $USERNAME

# Passwords (root)
if [ -n "$ROOTPASSWORD" ]; then
  echo "root:$ROOTPASSWORD" | chpasswd
else
  echo "Set a root password now:"
  passwd
fi

# Passwords (user)
if [ -n "$USERPASSWORD" ]; then
  echo "$USERNAME:$USERPASSWORD" | chpasswd
else
  echo "Set a password for $USERNAME:"
  passwd $USERNAME
fi

# Sudo for wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# systemd-boot
bootctl --path=/boot install
cat >/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$PARTUUID_ROOT rw
EOF

cat >/boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
EOF

# Enable network
systemctl enable NetworkManager

# Update & dev tools
pacman -Syyu --noconfirm
pacman -S --needed --noconfirm git base-devel

# Optional: HyDE (as regular user). Ignore errors if script expects extras.
runuser -l $USERNAME -c 'git clone --depth 1 https://github.com/HyDE-Project/HyDE ~/HyDE && bash ~/HyDE/Scripts/install.sh || true'
CHROOT

echo ">>> All set. You can now 'reboot'."
