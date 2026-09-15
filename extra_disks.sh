#!/bin/bash

# Script to generate `unlock-disks.service`

# TODO: handle multiple

target_uuid=$(blkid -s UUID -o value $1)

echo "I: Adding $target_uuid to unlocks..."

cat << EOT > /target/etc/systemd/system/unlock-disks.service
[Unit]
Description=Unlock extra encrypted disks
DefaultDependencies=no
After=systemd-udevd.service
After=cryptsetup.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=cryptsetup luksOpen /dev/disk/by-uuid/$target_uuid dm_crypt-1

[Install]
WantedBy=sysinit.target
EOT

systemctl --root /target enable unlock-disks.service
