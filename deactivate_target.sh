#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "FATAL: Must be run as root!"
  exit 1
fi

umount -R /target
vgchange -an ubuntu-vg
cryptsetup close dm_crypt-0

