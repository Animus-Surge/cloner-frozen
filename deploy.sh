#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "FATAL: Must be run as root!"
  exit 1
fi

# Timer functions
declare -A TIMER_STARTS
declare -A TIMER_LABELS
TIMER_ORDER=()

start_timer() {
  local name=$1
  local label=${2:-$name}

  TIMER_STARTS["$name"]=$(date +%s.%N)
  TIMER_LABELS["$name"]=$label

  if [[ ! " ${TIMER_ORDER[*]} " =~ " ${name} " ]]; then
    TIMER_ORDER+=("$name")
  fi
}

end_timer() {
  local name=$1
  local end_time=$(date +%s.%N)
  local start_time=${TIMER_STARTS["$name"]}

  if [[ -z "$start_time" ]]; then
    return 0 # Ignore it
  fi

  local elapsed
  if command -v bc >/dev/null 2>&1; then
    elapsed=$(echo "$end_time - $start_time" | bc)
  else
    elapsed=$(awk -v start="$start_time" -v end="$end_time" 'BEGIN {print end - start}')
  fi

  TIMER_STARTS["$name"]=$elapsed
}

print_timer() {
  local name=$1
  local elapsed=${TIMER_STARTS["$name"]}
  local label=${TIMER_LABELS["$name"]}

  if [ -z "$elapsed" ]; then
    return 0
  fi

  local int_part=${elapsed%.*}
  if [ "$int_part" -gt 1000000000 ]; then
    return 0
  fi

  printf "T: %-30s : %.fs\n" "$label" "$elapsed"
}

print_timers() {
  echo -e "\n============================="

  for name in "${TIMER_ORDER[@]}"; do
    print_timer "$name"
  done

  echo -e "============================="
}

# Improvements:
# - todo

# Post install flags
PUPPET_START_ENV=
START_PUPPET=
PUPPET_DISABLE_ON_COMPLETE=
PUPPET_CHANGE_ENV_ON_COMPLETE=
NVIDIA_DRIVER_INSTALL=
INSTALL_LABVIEW_DRIVERS=

skip_bootmgr=false

# Variables
output_log=/dev/stdout
hostname=egr-u-invalid
source_file=
target=
extra_pkgs=()
extra_disk=
crypt_opts=

# Flags
dry_run=false
use_luks=false
use_tpm=false
use_btrfs=false
btrfs_default_subvols=true
use_swap=false
is_dualboot=false
include_raid_volumes=false

usage() {
echo "Usage: $0 -f <archive> -t <target> [OPTIONS]"
echo ""
echo "This script prepares and deploys a compressed system image"
echo "(filesystem or disk image) onto a target drive, with"
echo "optional encryption, btrfs, and extra packages support."
echo ""
echo "Required Arguments:"
echo "  -f, --file <path>     : Input compressed file, prefers zstd"
echo "  -t, --target <path>   : Target device (e.g. /dev/sda, /dev/nvme0n1)"
echo ""
echo "Optional Flags and Options:"
echo "  -b, --btrfs           : Use btrfs instead of ext4"
echo "  -d, --dual-boot       : Configure grub to scan for other operating systems"
echo "  -D, --dry-run         : Give a complete summary of what would happen, without doing anything"
echo "  -l, --luks            : Enable LUKS encryption"
echo "  -L, --log-file        : Specifies output for most log information (Defaults /dev/stdout)"
echo "  -m, --tpm             : Use the system TPM for encryption (enables luks)"
echo "  -n, --hostname <name> : Target's hostname (default egr-u-invalid)"
echo "  -p, --package <pkg>   : An extra package to add to the cloned image (can be used multiple times)"
echo "  -r, --property <k/v>  : A key-value option. Appended to props.conf."
echo "  -R, --conf-file <file>: The file to use instead of props.conf. Must be a bash script."
echo "  -s, --subvolume <vol> : Subvolume <name>:<path> (can be used multiple times)"
echo "  -S, --btrfs-default-subvols: Use default btrfs subvolumes"
echo ""
echo "  -h, --help            : Display this help message."
echo ""
exit 1
}

nmcli -o g | grep -E "^connected" > /dev/null
if [ $? -ne 0 ]; then
	echo "You are not online, please ensure your network connection is functional before continuing"
	exit 1
fi

# Argument parsing
# Organized opts
opts=$(getopt -o f:t:ldDbmsn:p:r:R:L:s:ShE: --long file:,target:luks,dual-boot,dry-run,btrfs,tpm,hostname:,package:,property:,conf-file:,log-file:,subvolume:,btrfs-default-subvols,help,extra-encrypted-disk -n "$0" -- "$@")

if [ $? != 0 ]; then
echo "E: deploy: failed to parse options." >&2 ; usage
fi

eval set -- "$opts"

# remove old props.conf
rm -f props.conf

while true; do
  case "$1" in
  -D|--dry-run)
    dry_run=true
    shift
    ;;
  -d|--dual-boot)
    is_dualboot=true
    shift
    ;;
  -f|--file)
    source_file="$2"
    shift 2
    ;;
  -t|--target)
    target="$2"
    shift 2
    ;;
  -l|--luks)
    use_luks=true
    shift
    ;;
  -L|--log-file)
    $output_log="$2"
    shift 2
    ;;
  -m|--tpm)
    use_luks=true
    use_tpm=true
    shift
    ;;
  -b|--btrfs)
    use_btrfs=true
    shift
    ;;
  -n|--hostname)
    hostname="$2"
    shift 2
    ;;
  -p|--package)
    # Convert comma-separated string into a bash array
    echo "W: deploy: Extra packages functionality is currently unimplemented."
    # extra_pkgs="$2 $extra_pkgs"
    shift 2
    ;;
  -r|--property)
    key=${2%%=*}
    value=${2#*=}

    if [[ "key" == "value" ]]; then
      echo "E: deploy: property must be in key=value format. Skipping $2"
    else
      echo "export $key=\"$value\"" >> props.conf
    fi
    shift 2
    ;;
  -R|--conf-file)
    source $2
    shift 2
    ;;
  -S|--swap-file)
    use_swap=true
    shift
    ;;
  -h|--help)
    usage
    ;;
  -E|--extra-encrypted-disk)
    extra_disk=$2
    shift 2
    ;;
  --)
    # End of options marker
    shift
    break
    ;;
  *)
    echo "E: deploy: Internal error in argument parsing: $1" >&2
    usage
    ;;
  esac
done

if [[ -f props.conf ]]; then
  . ./props.conf
fi

# Validations

# Determine required options specified
if [ -z "$source_file" ] || [ -z "$target" ]; then
  echo "E: deploy: Both source file (-f) and target (-t) options must be specified." >&2
  usage
fi

# Check if the archive exists
if [ ! -f "$source_file" ]; then
  echo "E: deploy: Source $source_file does not exist. Unable to continue." >&2
  exit 1
fi

# TODO: other checks; assume everything else is fine (for now)

# Gather system information

i_tpmver=N/A

## TPM
dmesg | grep -i tpm > /dev/null
if [ $? -eq 0 ] && $use_tpm; then
  if [[ -e /dev/tpm0 ]]; then
    if [[ -e /dev/tpmrm0 ]]; then
      i_tpmver="2.0"
    else
      i_tpmver="1.2"
    fi
  else
    echo "E: deploy: No TPM device was found, and you had specified to use the TPM. Disabling TPM."
    echo "N:"
    echo "If this is incorrect, you can fix this post-install by performing TPM steps manually."
    echo "See https://wiki-vcu.atlassian.net/wiki/spaces/~712020cfcf61261297472abb6d62d34d4c8490/pages/572752306/systemd-cryptenroll"
    echo "or https://wiki-vcu.atlassian.net/wiki/spaces/~712020cfcf61261297472abb6d62d34d4c8490/pages/573898777/tpm-tools"
    echo "for more information."
    echo ""
    use_tpm=false
  fi
fi

# Output summary

echo "Summary:"
echo "Source: $source_file"
echo "Target: $target"
echo "Use LUKS: $use_luks"
if $use_luks; then
  echo "Use TPM: $use_tpm"
  echo "TPM version: $i_tpmver"
fi
echo "Use BTRFS: $use_btrfs"
echo "Dualboot system: $is_dualboot"
echo "Target Hostname: $hostname"
if [[ ! -z $extra_disk ]]; then
  echo "Using extra volume: $extra_disk"
fi
echo ""

# Check if target is nvme
partition_prefix=
if [[ "$target" == *nvme* ]]; then
  partition_prefix=p
fi
# TODO: allow the user to change something on the fly

# Removed: dry run block
if $dry_run; then
  echo "E: Dry run block removed. Exit 0"
  exit 0
fi

echo "W: These next steps will destroy ANY AND ALL DATA on $target. Please confirm you would like to continue."
read -r -p "Continue (y/N) > " start_conf
if [[ ! $start_conf =~ ^[Yy]$ ]]; then
  echo "W: Aborting..."
  exit 0
fi

# LUKS passphrase; if not used for luks, then used for mokutil
while true; do
  luks_pk=
  if $use_luks; then
    echo "Please enter a passphrase for the LUKS volume. This password is also used to enroll the new Machine Owner Key for secure boot."
  else
    echo "Please enter a passphrase for enrolling the Machine Owner Key for secure boot."
  fi
  read -r -s -p "> " luks_pk1
  echo ""
  echo "Please enter it again."
  read -r -s -p "> " luks_pk2
  echo ""
  if [[ -z "$luks_pk1" ]]; then
    echo "E: Passphrase cannot be empty. Try again."
  elif [[ $luks_pk1 == $luks_pk2 ]]; then
    luks_pk=$luks_pk1
    unset luks_pk1 luks_pk2
    break
  else
    echo "E: Passphrases did not match. Try again."
  fi
done

start_timer "main" "Deployment"

# Ensure no mounts active
. ./deactivate_target.sh 2>/dev/null
. ./deactivate_source.sh 2>/dev/null

# Literally doesn't work
#inst_uuid=$(blkid -s UUID -o value $(findmnt -n -o SOURCE /boot/efi))
#echo "I: Installed UUID: $inst_uuid"

echo $(date) >> $output_log
echo "I: Starting deployment." >> $output_log

start_timer "partition" "Partition"
echo "T: partition drive." >> $output_log

mkdir -p /target

efi_uuid=
boot_uuid=
root_uuid=

if $use_luks; then
  # Create table, partitions, set ESP for esp partition
  parted $target --script mklabel gpt \
    mkpart primary fat32 8M 1G \
    mkpart primary ext4 1G 3G \
    mkpart primary ext4 3G 100% \
    set 1 esp on >> $output_log

  udevadm settle

  # Format partitions
  yes | mkfs.vfat -F 32 ${target}${partition_prefix}1 >> $output_log
  yes | mkfs.ext4 ${target}${partition_prefix}2 >> $output_log
  echo -n "$luks_pk" | cryptsetup luksFormat -q "${target}${partition_prefix}3" - >> $output_log
  echo -n "$luks_pk" | cryptsetup luksOpen "${target}${partition_prefix}3" "dm_crypt-0" - >> $output_log

  if $use_btrfs; then
    yes | mkfs.btrfs -f "/dev/mapper/dm_crypt-0" >> $output_log
  else
    yes | mkfs.ext4 "/dev/mapper/dm_crypt-0" >> $output_log
  fi

  # UUID setups
  efi_uuid=$(blkid -s UUID -o value $target${partition_prefix}1)
  boot_uuid=$(blkid -s UUID -o value $target${partition_prefix}2)
  root_uuid=$(cryptsetup luksUUID $target${partition_prefix}3)

  echo "S: Created EFI partition at $target${partition_prefix}1 UUID $efi_uuid" >> $output_log
  echo "S: Created boot partition at $target${partition_prefix}2 UUID $boot_uuid" >> $output_log
  echo "S: Created encrypted root partition at $target${partition_prefix}3 UUID $root_uuid" >> $output_log

else
  parted $target --script mklabel gpt \
    mkpart primary fat32 8M 1G \
    mkpart primary ext4 1G 100% \
    set 1 esp on >> $output_log

  udevadm settle

  yes | mkfs.vfat -F 32 ${target}${partition_prefix}1 >> $output_log

  if $use_btrfs; then
    yes | mkfs.btrfs -f ${target}${partition_prefix}2 >> $output_log
  else
    yes | mkfs.ext4 ${target}${partition_prefix}2 >> $output_log
  fi

  # UUID setups
  efi_uuid=$(blkid -s UUID -o value $target${partition_prefix}1)
  root_uuid=$(blkid -s UUID -o value $target${partition_prefix}2)

  echo "S: Created boot partition at $target${partition_prefix}1 UUID $efi_uuid" >> $output_log
  echo "S: Created root partition at $target${partition_prefix}2 UUID $root_uuid" >> $output_log
fi

echo "I: Partitioning complete." >> $output_log
end_timer "partition"

start_timer "copy" "Copy system image"
echo "T: Copy base system image" >> $output_log

chroot="/target"

# Mount root
if $use_luks; then
  mount "/dev/mapper/dm_crypt-0" "$chroot"
else
  mount "$target${partition_prefix}2" "$chroot"
fi

# Copy compressed system
if pzstd -dcq "$source_file" | pv -pbert | tar --xattrs --xattrs-include='*' -xpf - -C "/target" 2>/dev/null; then
  echo "S: Successfully copied base image to /target." >> $output_log
else
  echo "E: Failed to copy base image to /target. See above for details."
  echo "F: Unable to continue."
  exit 1
fi

end_timer "copy"

echo "T: Post-install steps" >> $output_log

# Mount other partitions

if $use_luks; then
  echo "N: Mount $chroot/boot"
  mkdir -p $chroot/boot
  mount "$target${partition_prefix}2" "$chroot/boot"
fi

echo "N: Mount $chroot/boot/efi"
mkdir -p $chroot/boot/efi
mount "$target${partition_prefix}1" "$chroot/boot/efi"

# Bind mounts
echo "N: Running bind mounts..."
for dir in dev proc run sys; do
  mount --bind "/$dir" "$chroot/$dir"
done

echo "I: Updating target fstab..." >> $output_log

# Generate new fstab
echo "/dev/disk/by-uuid/$efi_uuid /boot/efi vfat defaults,nodev,noexec 0 0" > $chroot/etc/fstab

if $use_luks; then
  root_id=$(ls /dev/disk/by-id/dm-uuid-CRYPT-LUKS2*)
  root_uuid_crypttab="UUID=$(cryptsetup luksUUID "$target${partition_prefix}3")"

  echo "/dev/disk/by-uuid/$boot_uuid /boot ext4 defaults,nodev,nosuid 0 1" >> $chroot/etc/fstab

  if $use_btrfs; then
    start_timer "mksubvol" "BTRFS Subvolume creation"
    echo "I: Creating btrfs subvolumes..."
    echo "N: Using target: $target"
    ./mksubvol-new.sh -d -e $target -E

    echo "I: Adding final fstab entries"

    # Temp and whatnot
    echo "tmpfs /dev/shm tmpfs defaults,nodev,noexec,nosuid 0 0" >> /target/etc/fstab
    echo "tmpfs /tmp tmpfs defaults,nodev,nosuid 0 0" >> /target/etc/fstab
    echo "/swap/swapfile none swap defaults 0 0" >> /target/etc/fstab
    end_timer "mksubvol"
  else
    echo "$root_id / ext4 defaults 0 1" >> $chroot/etc/fstab
  fi
 
else
  root_uuid=$(blkid -s UUID -o value $target${partition_prefix}2)

  if $use_btrfs; then
    start_timer "mksubvol" "BTRFS Subvolume creation"
    echo "N: Using target: $target"
    ./mksubvol-new.sh -d -e $target

    echo "I: Adding final fstab entries"
    # Temp and whatnot
    echo "tmpfs /dev/shm tmpfs defaults,nodev,noexec,nosuid 0 0" >> /target/etc/fstab
    echo "tmpfs /tmp tmpfs defaults,nodev,nosuid 0 0" >> /target/etc/fstab
    echo "/swap/swapfile none swap defaults 0 0" >> /target/etc/fstab
    end_timer "mksubvol"
  else
    echo "/dev/disk/by-uuid/$root_uuid / ext4 defaults 0 1" >> $chroot/etc/fstab
  fi
fi

echo "I: Updated /target/fstab. New contents:"
cat /target/etc/fstab

# Update etc/default/grub with skip list and os prober checks
grub_default_target=$chroot/etc/default/grub

# BROKEN
#if [[ $is_dualboot == true ]]; then
#  echo "N: Adding installer UUID ($inst_uuid) to target GRUB_OS_PROBER_SKIP_LIST"
#  sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$grub_default_target"
#  if grep -q "GRUB_OS_PROBER_SKIP_LIST" "$grub_default_target"; then
#    sed -i "s/GRUB_OS_PROBER_SKIP_LIST=\"/GRUB_OS_PROBER_SKIP_LIST=\"$inst_uuid@\/EFI\/ubuntu\/shimx64.efi /" "$grub_default_target"
#  else
#    echo "GRUB_OS_PROBER_SKIP_LIST=\"$inst_uuid@\/EFI\/ubuntu\/shimx64.efi\"" >> "$grub_default_target"
#  fi
#fi

# Chroot

start_timer "initrd" "Regenerate initrd"

kver=$(ls $chroot/lib/modules | head -n 1)
chroot $chroot /bin/bash <<EOT

echo "I: chroot: IN /target."
echo "I: chroot: Kernel version $kver"

# initrd handling

echo "I: chroot: Rebuilding initrd..."
apt-get update
apt-get reinstall linux-image-$kver linux-modules-$kver linux-modules-extra-$kver

# NEW: upgrades (Moved to init.sh)
# apt-get upgrade

# GRUB

echo "I: chroot: Configuring grub..."

# WIP
#if $is_dualboot; then # OS Prober disabled by default in base system image
#  echo "I: Enabling OS Prober"
#  sed '/GRUB_DISABLE_OS_PROBER/s/true/false/' /etc/default/grub > /etc/default/grub
#fi

echo "I: chroot: Installing grub..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="ubuntu" --recheck
grub-mkconfig -o /boot/efi/EFI/ubuntu/grub.cfg

echo "S: chroot: Successfully installed and configured grub."
EOT

end_timer "initrd"

echo "I: Updating encryption settings..."

if $is_dualboot; then
  crypt_opts=--"tpm2-pcrs="
fi

chroot $chroot /bin/bash <<EOT
# Update crypttab and handle encryption

echo "I: chroot: IN /target."

echo "# <target name> <source device>     <key file>  <options>" > /etc/crypttab
if $use_luks; then
  if $use_tpm; then
    echo "I: chroot: Enabling TPM..."
    if [ "$i_tpmver" == "1.2" ]; then
      apt install -y trousers tpm-tools
      echo "I: chroot: Running TPM 1.2 tasks..."
      tpm_takeownership -y -z
      dd if=/dev/urandom of=/run/user/1000/tpm.key bs=1 count=256
      tpm_nvdefine -i 1 -s 256 -y -z -p 'READ_STCLEAR|OWNERWRITE' -r 7
      tpm_nvwrite -i 1 -s 256 -f /run/user/1000/tpm.key -z
      shred -u /run/user/1000/tpm.key

      echo "I: chroot: Updating /etc/crypttab..."
      echo "dm_crypt-0 $root_uuid_crypttab /mnt/tpm/key luks" > /etc/crypttab
      echo 'omit_dracutmodules+=" tpm2-tss "' > /etc/dracut.conf.d/10-encrypt.conf

      apt-get autopurge -y tpm2-tools
    fi
  
    if [ "$i_tpmver" == "2.0" ]; then
      apt install -y tpm2-tools
      echo "I: chroot: Running TPM 2.0 tasks..."
      PASSWORD="$luks_pk" systemd-cryptenroll "$target${partition_prefix}3" --tpm2-device=auto $crypt_opts
    
      echo "I: chroot: Updating /etc/crypttab..."
      echo "dm_crypt-0 $root_uuid_crypttab none luks,tpm2-device=auto" > /etc/crypttab
      echo 'omit_dracutmodules+=" tpm12 "' > /etc/dracut.conf.d/10-encrypt.conf

      apt-get autopurge -y trousers
    fi
  else
    echo "dm_crypt-0 $root_uuid_crypttab none luks" > /etc/crypttab
    echo 'omit_dracutmodules+=" tpm2-tss tpm12 "' > /etc/dracut.conf.d/10-encrypt.conf
    apt-get autopurge -y tpm2-tools trousers
  fi
  echo 'install_items+=" /etc/crypttab "' >> /etc/dracut.conf.d/10-encrypt.conf
else
  apt-get autopurge tpm2-tools trousers
fi

echo "S: chroot: Encryption settings updated."

EOT

echo "I: Final configuration: hostname, vmd driver, one more dracut run..."

chroot $chroot /bin/bash <<EOT
# Update hostname
echo "$hostname" > /etc/hostname
echo 'force_drivers+=" vmd ahci "' > /etc/dracut.conf.d/05-raid.conf

# One last reconfigure
dracut -f --kver "$kver"
EOT

echo "I: Running post-install steps..." >> $output_log

# Reset machine-id
truncate -s 0 $chroot/etc/machine-id

# Packages
if [ ! -z $extra_pkgs]; then
  #TODO: implement;  possibly handle in create_first_run?
  echo "W: Extra packages functionality is currently unimplemented."
fi

# btrfs compression
if $use_btrfs; then
  start_timer "compress" "Defragment $chroot"
  echo "I: Gathering file count..." >> $output_log
  total_files=$(find $chroot -type f | wc -l)

  echo "N: Total files: $total_files" >> $output_log

  echo "I: Compressing filesystem..." >> $output_log
  btrfs filesystem defragment -rfvc$btrfs_compress_alg $chroot 2>&1 | pv -l -s "$total_files" -F "%p %e %a [%b]" > /dev/null
  end_timer "compress"
fi

# RAID volume stuff
#if $include_raid_volumes; then
#  # Including 
#  echo "I: Handling RAID volume..."
#  . ./raid.conf
#  
#  if RAID_REFORMAT; then
#    parted $RAID_DEVICE --script mklabel gpt \
#        mkpart primary $RAID_FS 8M 100%
#
#    udevadm settle
#
#    raid_uuid=$(blkid -s UUID -o value ${RAID_DEVICE}p1)
#
#    case $RAID_FORMAT
#      crypt)
#        echo "N: Formatting /dev/disk/by-uuid/$raid_uuid as encrypted $RAID_FS"
#
#        echo -n "$luks_pk" | cryptsetup luksFormat -q "/dev/disk/by-uuid/$raid_uuid" -
#        echo -n "$luks_pk" | cryptsetup luksOpen "/dev/disk/by-uuid/$raid_uuid" "dm_crypt-1" -
#
#        if [[ $RAID_FS == btrfs ]]; then
#          raid_opts="-f"
#        fi
#
#        yes | mkfs.$RAID_FS "$raid_opts" "/dev/mapper/dm_crypt-1"
#        ;;
#      *)
#        if [[ $RAID_FS == btrfs ]]; then
#          raid_opts="-f"
#        fi
#
#        echo "N: Formatting /dev/disk/by-uuid/$raid_uuid as $RAID_FS"
#
#        yes | mkfs.$RAID_FS "$raid_opts" "/dev/disk/by_uuid/$raid_uuid"
#        ;;
#    esac
#  fi
#
#  echo "I: Creating unlock-raid.service files..."
#
#  # Create unlock-raid.sh
#  
#
#fi

# UEFI boot order stuff
echo "I: Updating UEFI boot order..." >> $output_log
if [[ "$skip_bootmgr" == "false" ]]; then
  entries=$(efibootmgr | grep '^Boot[0-9A-F]' | sed -E 's/Boot([0-9A-F]{4}).*/\1/')

  for entry in $entries; do
    label=$(efibootmgr | grep "^Boot$entry" | cut -d' ' -f2-)

    if [[ "$label" == "BootCurrent" ]] || [[ "$label" == "Timeout" ]] || [[ "$label" == "BootOrder" ]] || [[ "$label" == "BootNext" ]]; then
      continue
    fi

    if $is_dualboot && [[ "$label" == *"Windows Boot Manager"* ]] || [[ "$label" == "UEFI"* ]] || [[ "$label" == "ONBOARD"* ]]; then
      echo "Keeping $entry $label" >> $output_log
    else
      echo "Removing $entry $label" >> $output_log
      efibootmgr -b "$entry" -B > /dev/null 2>&1
  
      # TODO: add check logic
    fi
  done

  efibootmgr -c -d "$target" -p 1 -L "Ubuntu" -l '\EFI\ubuntu\shimx64.efi' > /dev/null

  echo ""
  echo "I: Created new boot entry, wiped preexisting linux entries. New boot order:" >> $output_log
  efibootmgr >> $output_log

else
  echo "W: Skipping running efiboomgr (skip_bootmgr is true)."
fi


# NEW: Extra encrypted disk handling
#FORMAT_EXTRA_DISK=false
#if FORMAT_EXTRA_DISK; then
#  echo "W: FORMAT_EXTRA_DISK: Not implemented."
#fi

#if [[ ! -z $extra_disk ]]; then
#  echo "I: Including extra encrypted volume..."
#  ./extra_disks.sh $extra_disk

#  # TODO: allow for updating fstab as well (will fix in python version)
#fi

# init.sh creation
CLONER_PW=$luks_pk python3 ./python_scripts/create_first_run.py
chmod +x /target/usr/local/sbin/init.sh
systemctl --root=/target enable init.service

# NEW: mokutil reset

echo "I: Resetting mokutil... password set to luks_pk"

touch /tmp/mokhash
mokutil --generate-hash=$luks_pk > /tmp/mokhash
mokutil --reset --hash-file /tmp/mokhash
mokutil --timeout -1

# Removed: first-run.sh; Moved to `create_first_run.sh`

end_timer "main"
# Done.
echo "S: System deployed."

print_timers
