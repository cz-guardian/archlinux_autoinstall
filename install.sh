#!/bin/bash

#
# GLOBALS
#
MAIN_HDD=""
CRYPTO_PWD=""
COMPUTER_NAME=""
TOTAL_MEMORY=$[ $(free -g -tt | tail -n 1 | awk '{print $2}') + 1 ]
TIMEZONE="Europe/Prague"
ROOT_PASSWORD=""
MODULES="etx4 atkbd i8042 psmouse"
HOOKS="base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck"
GRUB_PARAMS="earlymodules=atkbd,i8042,psmouse modules-load=atkbd,i8042,psmouse quiet"
GRUB_PARAMS_CRYPTO=""

#
# Functions
#
human_print()
{
  while read B dummy; do
    [ $B -lt 1024 ] && echo ${B} bytes && break
      KB=$(((B+512)/1024))
    [ $KB -lt 1024 ] && echo ${KB} kilobytes && break
      MB=$(((KB+512)/1024))
    [ $MB -lt 1024 ] && echo ${MB} megabytes && break
      GB=$(((MB+512)/1024))
    [ $GB -lt 1024 ] && echo ${GB} gigabytes && break
      echo $(((GB+512)/1024)) terabytes
  done
}

function get_dev_size()
{
  device="${1}"

  blockdev --getsize64 /dev/${device} | human_print
}

function get_dev_by_size()
{
  device="${1}"

  device_size=( $(get_dev_size "${device}") )
  
  if [ "${device_size[1]}" == "gigabytes" ] && [ ${device_size[0]} -gt 8 ]; then
    echo $device
  elif [ "${device_size[1]}" == "terabytes" ]; then
    echo $device
  fi
}

function interact()
{
  echo "Please insert your computer details"
  read -r -p "Crypto password: "
  CRYPTO_PWD=$REPLY

  read -r -p "Computer name: "
  COMPUTER_NAME=$REPLY

  read -r -p "Root password: "
  ROOT_PASSWORD=$REPLY
}

#
# Interact with user
#
interact

#
# Detect storage devices
#
all_devices=( $(ls -1 /sys/block | grep -ve '^loop*' -ve 'sr[0-9]') )
devices=( )
for dev in ${all_devices[@]}; do
  devices+=( $(get_dev_by_size $dev) )
done

if [ ${#devices[@]} -eq 1 ]; then
  echo "Storage /dev/${devices[0]} with capacity of $(get_dev_size ${devices[0]}) was found."
  MAIN_HDD="/dev/${devices[0]}"
else
  echo "Multiple devices found"
  echo "Not implemented yet!"
  exit 1
fi

GRUB_PARAMS_CRYPTO="cryptdevice=/dev/sda3:${COMPUTER_NAME}:allow-discards"

#
# Format and partition
#

echo "(I) Zeroing HDD"
dd if=/dev/zero of=${MAIN_HDD} bs=1M count=300
sync; sleep 1

echo "(I) Creating partitions"
echo -e "n\np\n1\n\n+100M\nt\nef\n
n\np\n2\n\n+250M\n
n\np\n3\n\n\n
w
" | fdisk ${MAIN_HDD}
sleep 1

mkfs.vfat -F32 ${MAIN_HDD}1
mkfs.ext2 ${MAIN_HDD}2

echo -n "${CRYPTO_PWD}" | cryptsetup -q -c aes-xts-plain64 -y --use-random luksFormat ${MAIN_HDD}3
echo -n "${CRYPTO_PWD}" | cryptsetup luksOpen ${MAIN_HDD}3 ${COMPUTER_NAME}

pvcreate /dev/mapper/${COMPUTER_NAME}
vgcreate ${COMPUTER_NAME} /dev/mapper/${COMPUTER_NAME}
lvcreate --size ${TOTAL_MEMORY}G ${COMPUTER_NAME} --name swap
lvcreate -l +100%FREE ${COMPUTER_NAME} --name root

mkfs.ext4 /dev/mapper/${COMPUTER_NAME}-root
mkswap /dev/mapper/${COMPUTER_NAME}-swap

#
# Mount HDD
#
echo "(I) Mounting created partitions"
mount /dev/mapper/${COMPUTER_NAME}-root /mnt
swapon /dev/mapper/${COMPUTER_NAME}-swap
mkdir /mnt/boot
mount ${MAIN_HDD}2 /mnt/boot
mkdir /mnt/boot/efi
mount ${MAIN_HDD}1 /mnt/boot/efi

#
# Install and configure
#
echo "(I) Installing Archlinux base system"
pacstrap /mnt base base-devel grub-efi-x86_64 zsh vim git efibootmgr dialog wpa_supplicant

echo "(I) Generating fstab"
genfstab -pU /mnt >> /mnt/etc/fstab
echo "tmpfs /tmp  tmpfs defaults,noatime,mode=1777  0 0" >> /mnt/etc/fstab

echo "(I) In chroot configuration"
cat <<EOF | arch-chroot /mnt /bin/bash
ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc --utc
echo ${COMPUTER_NAME} > /etc/hostname
echo LANG=en_US.UTF-8 >> /etc/locale.conf
echo LANGUAGE=en_US >> /etc/locale.conf
echo LC_ALL=C >> /etc/locale.conf
echo -e -n "${ROOT_PASSWORD}\n${ROOT_PASSWORD}" | passwd
sed -i -e 's/^MODULES.*/MODULES="${MODULES}"/' /etc/mkinitcpio.conf
sed -i -e 's/^HOOKS.*/HOOKS="${HOOKS}"/' /etc/mkinitcpio.conf
mkinitcpio -p linux
grub-install
sed -i -e 's/^GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="${GRUB_PARAMS_CRYPTO}"/' -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_PARAMS}"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
EOF

umount -R /mnt
swapoff -a

reboot