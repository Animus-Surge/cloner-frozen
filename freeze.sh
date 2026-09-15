#!/bin/bash

# Cloner: Filesystem freeze.

if [ "$EUID" -ne 0 ]; then
  echo "FATAL: Must be run as root!"
  exit 1
fi

source_dir="/source"
output_file=

#Option parsing

while getopts "s:" opt; do
  case ${opt} in
    s )
      source_dir=$OPTARG
      ;;
    \?)
      echo "Usage: $0 [-s <source_dir>] <output_filename.tar.zst>" >&2
      exit 1
      ;;
    : )
      echo "ERROR: Option -$OPTARG requires an argument." >&2
      echo "Usage: $0 [-s <source_dir>] <output_filename.tar.zst>" >&2
      exit 1
  esac
done

shift $((OPTIND - 1))

# Checks

if [ -z "$1" ]; then
  echo "ERROR: Output filename is required." >&2
  echo "Usage: $0 [-s <source_dir>] <output_filename.tar.zst>" >&2
  exit 1
fi

if [ ! -d "$source_dir" ]; then
  echo "ERROR: Source directory $source_dir does not exist."
  exit 1
fi

output_file="$1"

echo "INFO: Starting filesystem freeze on $source_dir..."
echo "NOTE: Outputting to $output_file"

if [ -f "$output_file" ]; then
  echo "WARNING: File $output_file already exists."
  read -r -p "Overwrite? (y/N) " overwrite_resp
  if [[ ! $overwrite_resp =~ ^[yY]$ ]]; then
    echo "WARNING: Aborting."
    exit 1
  else
    echo "WARNING: Overwriting output file."
  fi
fi
  

# Perform operation

if tar \
  --create \
  --file=- \
  --absolute-names \
  --preserve-permissions \
  --sparse \
  --xattrs \
  --xattrs-include='*' \
  --acls \
  --ignore-failed-read \
  --exclude='dev/*' \
  --exclude='proc/*' \
  --exclude='run/*' \
  --exclude='sys/*' \
  --exclude='tmp/*' \
  --exclude='home/*' \
  --exclude='var/cache/apt/*' \
  --exclude='etc/puppetlabs/puppet/ssl' \
  --exclude='etc/ssh/ssh_host_*' \
  --directory="$source_dir" \
  . | pv -pbert | pzstd -c > "$output_file"; then
  echo "SUCCESS: Filesystem freeze completed."
else
  echo "ERROR: Filesystem freeze failed. See above for details."
  exit 1
fi

echo "NOTE: Done."
