# Cloner Bash

A linux-based operating system deployment tool

**THIS PROJECT IS NO LONGER UNDER DEVELOPMENT.**
See https://github.com/Animus-Surge/clonix for an active version.

## Features
- First party encryption support with LUKS, capable of detecting and using any TPM device
- Built in image creation tool with `freeze.sh`
- Support for btrfs
- Automatic handling of Nvidia graphics card drivers (requires CUDA repos)

## Dependencies
- `pv` - Pipe Viewer, for progress bars

## Setup
- Install any linux operating system to an external USB drive (512GB+ recommended)
    - For simplicity, I recommend having three partitions:
        - 512M - EFI System Partition (`/boot/efi`)
        - 32G - Root partition (`/`)
        - 100% - Image store partition (`/mnt`) (Ensure this partition auto mounts via `fstab`)
- Clone this repository and install dependencies

## Usage

### Help

```
Usage: ./deploy.sh -f <archive> -t <target> [OPTIONS]

This script prepares and deploys a compressed system image
(filesystem or disk image) onto a target drive, with
optional encryption, btrfs, and extra packages support.

Required Arguments:
  -f, --file <path>     : Input compressed file, prefers zstd
  -t, --target <path>   : Target device (e.g. /dev/sda, /dev/nvme0n1)

Optional Flags and Options:
  -b, --btrfs           : Use btrfs instead of ext4
  -d, --dual-boot       : Configure grub to scan for other operating systems
  -D, --dry-run         : Give a complete summary of what would happen, without doing anything
  -l, --luks            : Enable LUKS encryption
  -m, --tpm             : Use the system TPM for encryption (enables luks)
  -n, --hostname <name> : Target's hostname (default egr-u-invalid)
  -r, --property <k/v>  : A key-value option. Appended to props.conf.
  -R, --conf-file <file>: The file to use instead of props.conf. Must be a bash script.
  -h, --help            : Display this help message.
```

### Deploying

```
# ./deploy.sh -f <source file> -t /dev/<device> -n <hostname>
```

This command deploys a simple, unencrypted operating system, with ext4 as the root filesystem type.
It sets the hostname by directly writing to `/etc/hostname` on the target system after the clone
operation has been completed.

```
# ./deploy.sh -f <source file> -t /dev/<device> -bmn <hostname>
```

This command deploys a TPM encrypted operating system, with btrfs as the root filesystem type.
This is the same as:

```
# ./deploy.sh --file <source file> --target /dev/<device> --btrfs --tpm --hostname <hostname>
```
