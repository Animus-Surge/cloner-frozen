#!/bin/bash

# TODO: allow for 

udevadm settle --timeout=30

uuid=$(blkid -s uuid -o value /dev/md126p1)
device=/dev/disk/by-uuid/$uuid

if [[ ! -e "$device" ]]; then
  echo "E: Failed to find $device."
  exit 1
fi

cryptsetup luksOpen $device dm_crypt-1

if [[ $? -ne 0 ]]; then
  echo "E: Failed to unlock $device."
  exit 1
fi

# <mounts>

