#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "FATAL: Must be run as root!"
  exit 1
fi

if [[ -z $1 ]]; then
  echo "ERROR: needs drive to mount"
  exit 1
fi

# Attempt luks; omit errors
cryptsetup luksOpen $1 dm_crypt-0 2> /dev/null
if [ $? -eq 0 ]; then
  sleep 5s
  mount /dev/dm-1 /source
  exit 0
fi

mount $1 /source
