"""
Python implementation of create_first_run

Generates the first run script
"""

import json, os, re, shutil, sys

# Flags
TEST_MODE=False

# Directories
CLONER_DIR="/home/tech/cloner" if not TEST_MODE else "/home/floydes/projects/cloner"
SNIPPET_DIR=os.path.join(CLONER_DIR, "snippets")
TARGET_SBIN="/target/usr/local/sbin"
TARGET_SERVICES="/target/etc/systemd/system"
TEST_DIR=os.path.join(CLONER_DIR, "test")

INIT_FILE=os.path.join(TEST_DIR if TEST_MODE else TARGET_SBIN, "init.sh")
INIT_SERVICE=os.path.join(TEST_DIR if TEST_MODE else TARGET_SERVICES, "init.service")

# Default configuration
DEFAULT_CONFIG={
    "NVIDIA_DRIVER_DEFAULT_VERSION": "580",
    "NVIDIA_DRIVER_DO_INSTALL": True,
    "LABVIEW_DRIVERS_DO_INSTALL": False
}

# Markers
DRIVER_MARKER="# <DRIVER: insert>"
PACKAGE_MARKER="# <PACKAGE: insert>"

config=DEFAULT_CONFIG

def insert_text(marker, text, target):
    print("I: first-run: insert_snippet: Adding to {}".format(target))

    with open (target, 'r') as f:
        target_lines = f.readlines()

    output_lines = []
    for line in target_lines:
        output_lines.append(line)
        if line.rstrip('\r\n') == marker:
            if not text.endswith('\n'):
                output_lines.append(text + '\n')
            else:
                output_lines.append(text)

    with open(target, 'w') as f:
        f.writelines(output_lines)


def insert_snippet(marker, replacement_file):
    print("I: first-run: insert_snippet: Copying {} to {}".format(replacement_file, INIT_FILE))
    
    with open(replacement_file, 'r') as f:
        snippet_content = f.read()

    with open(INIT_FILE, 'r') as f:
        target_lines = f.readlines()

    output_lines=[]

    for line in target_lines:
        output_lines.append(line)
        if line.rstrip('\r\n') == marker:
            if not snippet_content.endswith('\n'):
                output_lines.append(snippet_content + '\n')
            else:
                output_lines.append(snippet_content)

    with open(INIT_FILE, 'w') as f:
        f.writelines(output_lines)

def insert_snippet_placeholder(marker, replacement_file, placeholder, placeholder_replacement, redact_placeholder=False):
    print("I: first-run: insert_snippet: Copying {} to {}; replacing {} with {}".format(replacement_file, INIT_FILE, placeholder, placeholder_replacement if not redact_placeholder else "[HIDDEN]"))
    with open(replacement_file, 'r') as f:
        snippet_content = f.read()

    updated_snippet=re.sub(re.escape(placeholder), str(placeholder_replacement), snippet_content)

    with open(INIT_FILE, 'r') as f:
        target_lines = f.readlines()

    output_lines=[]

    for line in target_lines:
        output_lines.append(line)
        if line.rstrip('\r\n') == marker:
            if not updated_snippet.endswith('\n'):
                output_lines.append(updated_snippet + '\n')
            else:
                output_lines.append(updated_snippet)

    with open(INIT_FILE, 'w') as f:
        f.writelines(output_lines)

def copy_file(source, target):
    # WARNING: this function overwrites the target completely!
    if os.path.exists(target):
        os.remove(target)

    with open(source, "r") as f:
        source_content = f.read()

    with open(target, "w") as f:
        f.write(source_content)

    print("I: first-run: copy_file: Copied {} to {}".format(source, target))

def copy_file_placeholder(source, target, placeholder, replacement):
    # WARNING: this function overwrites the target completely!
    if os.path.exists(target):
        os.remove(target)

    with open(source, "r") as f:
        source_content = f.read()

    replaced_source_content = re.sub(re.escape(placeholder), replacement, source_content)

    with open(target, "w") as f:
        f.write(replaced_source_content)

    print("I: first-run: copy_file: Copied {} to {}; replaced {} with {}".format(source, target, placeholder, replacement))

if __name__=="__main__":
    # Test dir
    if TEST_MODE:
        if os.path.exists(TEST_DIR):
            shutil.rmtree(TEST_DIR)
        os.mkdir(TEST_DIR)
    
    if len(sys.argv) >= 2 and sys.argv[1] and os.path.exists(sys.argv[1]):
        with open(os.path.abspath(sys.argv[1]), 'r') as f:
            print("I: first-run: Using config file {}".format(sys.argv[1]))
            config = json.loads(f.read())

    print("I: first-run: Creating first run script and service...")

    # Arguments
    luks_mok_pw=os.getenv("CLONER_PW")
    if not luks_mok_pw:
        print("E: first-run: No cloner password set; will not be able to handle MOK.")

    # Other dirs should exist already

    # Create init.service
    copy_file(os.path.join(SNIPPET_DIR, "init.service.snip"), INIT_SERVICE)
    
    # Create init.sh
    copy_file_placeholder(os.path.join(SNIPPET_DIR, "init.sh.snip"), INIT_FILE, "<replaceme>", luks_mok_pw)

    if config.get("include_raid", False):
        uuid = config.get("raid_uuid", None)
        label = config.get("raid_label", None)
        fstype = config.get("raid_fs", None)

        if uuid and label and fstype:
            print("I: first-run: Creating raid scripts...")

            mounts = []
            for mount in config.get("raid_mounts", []):
                subvolume = mount.get("subvolume", None)
                mountpoint = mount.get("mountpoint", None)
                if not mountpoint or not subvolume: continue
                mounts.append(f'mount {mountpoint}')

                with open('/target/etc/fstab', 'a') as f:
                    line = f"LABEL={label} {mountpoint} subvol={subvolume},defaults,noauto,nofail,nodatacow,nodev,nosuid 0 0\n"

                    f.write(line)

            copy_file_placeholder(os.path.join(SNIPPET_DIR, "unlock-raid.sh.snip"), "/target/sbin/unlock-raid.sh", "<uuid>", uuid)
            copy_file(os.path.join(SNIPPET_DIR, "unlock-raid.service.snip"), "/target/etc/systemd/system/unlock-raid.service")
            copy_text("# <mounts>", mounts, "/target/sbin/unlock-raid.sh")

            print("S: Created raid scripts.")

        else:
            print("E: Failed to create raid configuration. Label and UUID are required.")



    # Drivers
    if config.get("NVIDIA_DRIVER_DO_INSTALL"):
        # TODO: check arch wiki table for version. Also check vendor:device IDs
        version = config.get("NVIDIA_DRIVER_DEFAULT_VERSION", 580)
        insert_snippet_placeholder(DRIVER_MARKER, os.path.join(SNIPPET_DIR, "NVIDIA_DRIVER_INSTALL.sh.snip"), "<NVIDIA_DRIVER_DEFAULT_VERSION>", version)

    if config.get("LABVIEW_DRIVERS_DO_INSTALL"):
        insert_snippet(DRIVER_MARKER, os.path.join(SNIPPET_DIR, "INSTALL_LABVIEW_DRIVERS.sh.snip"))

    # Packages
    # Nothing here yet.

    # Moved enable to deploy.sh

    print("S: first-run: Created first run files.")

