#!/bin/bash

# mksubvol.sh [-n|--subvol-name <name>] [-v|--volume-path <path>] [-d|--default-subvols] [-D|--dry-run] [-e|--device <device>]

opts=$(getopt -o dDn:v:e:E --long default-subvols,dry-run,subvol-name:,volume-path:,device:,encrypted -n "$0" -- "$@")
if [[ $? != 0 ]]; then
  echo "E: mksubvol: Failed to parse options." >&2
  exit 1
fi

vol_name=
vol_path=
device=
default_volumes=false
dry_run=false
encrypted=false

original_wd=$(pwd)

eval set -- "$opts"

shopt -s extglob

while true; do
  case "$1" in
    -d|--default-subvols)
      default_volumes=true
      shift
      ;;
    -D|--dry-run)
      dry_run=true
      shift
      ;;
    -n|--subvol-name)
      vol_name=$2
      shift 2
      ;;
    -v|--volume-path)
      vol_path=$2
      shift 2
      ;;
    -e|--device)
      device=$2
      shift 2
      ;;
    -E|--encrypted)
      encrypted=true
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "W: mksubvol: Unknown option $1"
      ;;
  esac
done

echo "I: mksubvol: Gathering partition information..."

echo "N: mksubvol: Using default subvolumes: $default_volumes"
echo "N: mksubvol: Dry run: $dry_run"
echo "N: mksubvol: Volume name: $vol_name"
echo "N: mksubvol: Volume path: $vol_path"
echo "N: mksubvol: Device: $device"

partition_prefix=
if [[ "$device" == *nvme* ]]; then
  partition_prefix=p
fi

# Gather number of partitions; 2 if unencrypted, 3 if encrypted
if $encrypted; then
  num_parts=3
else
  num_parts=2
fi

# EFI system partition will ALWAYS be present
efi_uuid=$(blkid -s UUID -o value $device${partition_prefix}1)

echo "N: mksubvol: Number of partitions on target: $num_parts"

if [ $num_parts == 2 ]; then
  root_part_id=$(blkid -s UUID -o value $device${partition_prefix}2)
elif [ $num_parts == 3 ]; then
  boot_part_uuid=$(blkid -s UUID -o value $device${partition_prefix}2)
  root_part_id=$(ls /dev/disk/by-id/dm-uuid-CRYPT-LUKS2*)
fi

# TODO: support additional volume options; like specify root and boot partitions

echo "I: mksubvol: Gathered information:"
echo "N: mksubvol: EFI system partition UUID: $efi_uuid"
echo "N: mksubvol: Boot partition UUID: $boot_part_uuid"
echo "N: mksubvol: Root partition ID/UUID: $root_part_id"

cd /target

echo "I: mksubvol: In /target."

if $default_volumes; then
  echo "I: mksubvol: Using default btrfs subvolumes. btrfs filesystem label: root"

  btrfs filesystem label . root

  btrfs subvolume create @
  btrfs subvolume create @home
  btrfs subvolume create @swap
  btrfs subvolume create @var
  btrfs subvolume create @var_log
  btrfs subvolume create @var_log_audit
  btrfs subvolume create @var_tmp

  echo "I: mksubvol: Created subvolumes."
  echo "I: mksubvol: Unmounting non-root partitions..."

  umount ./boot/efi
  sleep 2
  if [ $num_parts == 3 ]; then
    umount ./boot
  fi
  umount ./dev
  umount ./proc
  umount ./run
  umount ./sys

  sleep 2

  echo "I: mksubvol: Copying files to subvolumes..."

  mv ./var/log/* ./@var_log
  mv ./var/*     ./@var
  mv !(@*)       ./@

  cd /

  umount --recursive /target

  echo "I: mksubvol: Re-mounting target..."

  mount LABEL=root -o subvol=@ /target
  mount LABEL=root -o subvol=@var /target/var
  mount LABEL=root -o subvol=@var_log /target/var/log
  sleep 1
  mkdir /target/var/tmp
  mount LABEL=root -o subvol=@var_tmp /target/var/tmp

  cd /target

  mkdir ./var/log/audit
  chown root:adm ./var/log/audit
  chmod 750 ./var/log/audit

  mount LABEL=root -o subvol=@var_log_audit /target/var/log/audit

  # Mount boot / efi
  if [[ ! -z $boot_part_uuid ]]; then
    mount /dev/disk/by-uuid/$boot_part_uuid /target/boot
  fi
  mount /dev/disk/by-uuid/$efi_uuid /target/boot/efi

  for dir in dev proc run sys; do
    mount --bind "/$dir" "/target/$dir"
  done

  echo "I: mksubvol: Creating swapfile..."
  
  mkdir swap
  mount LABEL=root -o subvol=@swap /target/swap
  mem_av=$(free -m | awk '/^Mem:/ {print $2}')
  echo "N: mksubvol: Swapfile with size ${mem_av}MiB"
  btrfs filesystem mkswapfile --size "${mem_av}m" --uuid clear /target/swap/swapfile

  echo "I: mksubvol: Updating fstab..."

  echo "LABEL=root / btrfs subvol=@,defaults,compress=zstd 0 0" >> /target/etc/fstab
  echo "LABEL=root /home btrfs subvol=@home,defaults,compress=zstd,nodev,nosuid 0 0" >> /target/etc/fstab
  echo "LABEL=root /swap btrfs subvol=@swap,defaults,compress=zstd,nodev,noexec,nosuid 0 0" >> /target/etc/fstab
  echo "LABEL=root /var btrfs subvol=@var,defaults,compress=zstd,nodev,nosuid 0 0" >> /target/etc/fstab
  echo "LABEL=root /var/log btrfs subvol=@var_log,defaults,compress=zstd,nodev,noexec,nosuid 0 0" >> /target/etc/fstab
  echo "LABEL=root /var/log/audit btrfs subvol=@var_log_audit,defaults,compress=zstd,nodev,noexec,nosuid 0 0" >> /target/etc/fstab
  echo "LABEL=root /var/tmp btrfs subvol=@var_tmp,defaults,compress=zstd,nodev,nosuid 0 0" >> /target/etc/fstab

  cd $original_wd

  echo "S: mksubvol: Done."
else
  echo "E: mksubvol: Unimplemented."
  exit 1
fi
