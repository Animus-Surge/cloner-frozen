#!/bin/bash

if [[ -z $1 ]]; then
	echo "E: Requires device."
	exit 1
fi

if [[ ! -e $1 ]]; then
	echo "E: Device $1 does not exist."
	exit 1
fi

echo "I: Updating boot entries..."

entries=$(efibootmgr | grep '^Boot[0-9A-F]' | sed -E 's/Boot([0-9A-F]{4}).*/\1/')

for entry in $entries; do
	label=$(efibootmgr | grep "^Boot$entry" | cut -d' ' -f2-)

	if [[ "$label" == "BootCurrent" ]] || [[ "$label" == "Timeout" ]] || [[ "$label" == "BootOrder" ]] || [[ "$label" == "BootNext" ]]; then
		continue
	fi

	if $is_dualboot && [[ "$label" == *"Windows Boot Manager"* ]] || [[ "$label" == "UEFI"* ]] || [[ "$label" == "ONBOARD"* ]]; then
		echo "N: Keeping $entry $label"
	else
		echo "N: Removing $entry $label"
		efibootmgr -b "$entry" -B > /dev/null 2>&1

# TODO: add check logic
	fi
done

efibootmgr -c -d "$1" -p 1 -L "Ubuntu" -l '\EFI\ubuntu\shimx64.efi' > /dev/null

echo ""
echo "I: Created new boot entry, wiped preexisting linux entries. New boot order:"
efibootmgr

echo "I: Done."
