#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# INSTALLAZIONE AUTOMATICA ARCH LINUX
# Target fisso: /dev/nvme0n1
# DISTRUTTIVO

DEVICE="/dev/nvme0n1"

msg() { echo -e "\n==> $*"; }

if [[ $(id -u) -ne 0 ]]; then
  echo "Esegui come root."
  exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "Device $DEVICE non trovato."
  exit 1
fi

echo "ATTENZIONE: questo cancellerà COMPLETAMENTE $DEVICE"
read -rp "Digita YES per continuare: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Annullato."; exit 1; }

msg "Pulizia completa disco (wipe GPT + firme)"
wipefs -a "$DEVICE"
sgdisk --zap-all "$DEVICE"

msg "Creazione nuova GPT"
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary fat32 1MiB 513MiB
parted -s "$DEVICE" set 1 esp on
parted -s "$DEVICE" mkpart primary 513MiB 100%

EFI_PART="${DEVICE}p1"
ROOT_PART="${DEVICE}p2"

sleep 2

msg "Formattazione EFI"
mkfs.fat -F32 "$EFI_PART"

msg "Cifratura LUKS2"
cryptsetup luksFormat --type luks2 "$ROOT_PART"
cryptsetup open "$ROOT_PART" cryptroot

ROOT_PART_UUID="$(blkid -s UUID -o value "$ROOT_PART")"

msg "Creazione Btrfs"
mkfs.btrfs -f /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

msg "Montaggio definitivo"
mount -o compress=zstd,noatime,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,boot}
mount -o compress=zstd,noatime,subvol=@home /dev/mapper/cryptroot /mnt/home
mount "$EFI_PART" /mnt/boot

msg "Rilevamento microcode CPU"
CPU_VENDOR="$(awk -F: '/vendor_id/{print $2; exit}' /proc/cpuinfo)"
PKGS="base linux linux-firmware btrfs-progs networkmanager vim efibootmgr dosfstools"

if [[ "$CPU_VENDOR" == *Intel* ]]; then
  PKGS="$PKGS intel-ucode"
elif [[ "$CPU_VENDOR" == *AMD* ]]; then
  PKGS="$PKGS amd-ucode"
fi

msg "Installazione sistema base"
pacstrap /mnt $PKGS

genfstab -U /mnt >> /mnt/etc/fstab

cat > /mnt/root/post.sh <<EOF
#!/usr/bin/env bash
set -e

ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
hwclock --systohc

echo "it_IT.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=it_IT.UTF-8" > /etc/locale.conf

echo "archlaptop" > /etc/hostname

echo "Imposta password root:"
passwd

sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

systemctl enable NetworkManager
systemctl enable fstrim.timer

bootctl install

cat > /boot/loader/loader.conf <<LOADER
default arch
timeout 3
editor no
LOADER

MIC=""
[[ -f /boot/intel-ucode.img ]] && MIC="initrd  /intel-ucode.img"
[[ -f /boot/amd-ucode.img ]] && MIC="initrd  /amd-ucode.img"

cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
\$MIC
initrd  /initramfs-linux.img
options cryptdevice=UUID=${ROOT_PART_UUID}:cryptroot root=/dev/mapper/cryptroot rw
ENTRY
EOF

chmod +x /mnt/root/post.sh

msg "Entrata in chroot"
arch-chroot /mnt /root/post.sh

msg "Smontaggio"
umount -R /mnt
cryptsetup close cryptroot

msg "Installazione completata. Riavvio..."
reboot
