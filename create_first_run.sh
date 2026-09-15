#!/bin/bash

# Create first run files; Creates init.service, first-run.service, and first-run.sh; copies handle_mok.sh and sys_init.sh

#CLONER_DIR=/home/tech/cloner
CLONER_DIR=/home/floydes/projects/cloner
TEST_DIR=/home/floydes/projects/cloner/test
SNIPPETS_DIR=$CLONER_DIR/first_run_snippets
#TARGET_SBIN=/target/usr/local/sbin
#TARGET_ETC=/target/etc/
#TARGET_SERVICES=$TARGET_ETC/systemd/system
TARGET_SBIN=$TEST_DIR
TARGET_ETC=$TEST_DIR
TARGET_SERVICES=$TEST_DIR

INIT_FILE=$TARGET_SBIN/init.sh
INIT_SERVICE=$TARGET_SERVICES/init.service
DRIVER_MARK="# <DRIVER: insert>"
PACKAGE_MARK="# <PACKAGE: insert>"

copy_to_init_driver() {
  echo "I: first-run: copy_to_init: Copying $1 to $INIT_FILE..."
  escaped=$(sed -e 's/[\/&]/\\&/g' -e '$!s/$/\\/' $SNIPPETS_DIR/$1)

  sed -i "/$DRIVER_MARK/a\\
  $escaped" "$INIT_FILE"
}

copy_to_init_replace_driver() {
  echo "I: first_run: copy_to_init_replace: Copying $1 to $INIT_FILE..."
  echo "N: first_run: copy_to_init_replace: $2 replaced with $3"
  place_esc=$(printf '%s\n' "$2" | sed 's/[^^$*.[\]{}()?"|+=\\]/\\&/g')
  escaped=$(sed -e "s/$place_esc/$3/g" -e 's/[\/&]/\\&/g' -e '$s/$/\\/' $SNIPPETS_DIR/$1)

  sed -i "/$DRIVER_MARK/a\\
  $escaped" "$INIT_FILE"
}

echo "I: first-run: Creating first run files..."

# Source the first run configuration file and its override
. $CLONER_DIR/first_run.conf
if [[ -e $CLONER_DIR/props.conf ]]; then
  # Override file
  . $CLONER_DIR/props.conf
fi

# REQUIRED: init.sh and init.service
# Create directories if they don't exist
mkdir -p $TARGET_SBIN
mkdir -p $TARGET_SERVICES

cp $SNIPPETS_DIR/init.sh.snip $INIT_FILE
cp $SNIPPETS_DIR/init.service.snip $INIT_SERVICE

# BEGIN: drivers

# NVIDIA_DRIVER_DO_INSTALL
if $NVIDIA_DRIVER_DO_INSTALL; then
  echo "I: first-run: Adding NVIDIA driver install setup..."
  copy_to_init_replace_driver NVIDIA_DRIVER_INSTALL.sh.snip "<NVIDIA_DRIVER_DEFAULT_VERSION>" $NVIDIA_DRIVER_DEFAULT_VERSION
fi

if $LABVIEW_INSTALL_DRIVERS; then
  echo "I: first-run: Adding LabView driver install setup..."
  copy_to_init_driver INSTALL_LABVIEW_DRIVERS.sh.snip
fi

# END: drivers

# BEGIN: packages

# todo

# END: packages

echo "S: first-run: Created init.sh and init.service."
systemctl --root /target enable init.service

