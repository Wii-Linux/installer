#!/bin/bash




# Define common tasks and variables
version="0.0.1a"
codename="Insert Cool Codename Here"
title="Wii Linux Installer - $version \"$codename\""

box_width=$(((COLUMNS * 10) / 12))
box_height=$(((LINES * 10) / 14)) 


. /logging.sh

inst_log "hi"
fifo="/installer_log_fifo"
mkfifo "$fifo"

inst_log "hi2"
inst_log_stdin < "$fifo" &
inst_log "hi2a"
exec 2> "$fifo"
inst_log "hi2b"


# Displays a message box with a single button.
# Argument 1: Text for the button that will close the prompt with success.
# Argument 2: Title for the message box.
# Argument 3: Message box content.
msgbox() {
	dialog --backtitle "$title" --ok-label "$1" --title "$2" --msgbox "$3" "$box_height" "$box_width"
	return $?
}

# Displays a message box with no buttons that immediately exits.  Up to the script to handle timing.
# Argument 1: Title for the message box.
# Argument 2: Message box content.
infobox() {
	dialog --backtitle "$title" --title "$1" --infobox "$2" "$box_height" "$box_width"
	return $?
}

# Displays a message box with a yes and a no button
# Argument 1: Text for the button that will close the prompt with success.
# Argument 2: Text for the button that will close the prompt with failure.
# Argument 3: Title for the message box.
# Argument 4: Message box content.
# XXX: Swaps yes and no so yes can be on the right
yesno() {
	dialog --backtitle "$title" --no-label "$1" --yes-label "$2" --defaultno --title "$3" --yesno "$4" "$box_height" "$box_width"
	ret=$?
	if [ "$ret" = "255" ]; then return 255
	elif [ "$ret" = "1" ]; then return 0
	elif [ "$ret" = "0" ]; then return 1
	else return $ret
	fi
}


# Displays a menu box
# Argument 1: Menu title.
# Argument 2+: Menu options (paired: option tag and description).
menu() {
	local selection
	selection=$(dialog --backtitle "$title" --menu "$1" "$box_height" "$box_width" "0" "${@:2}" 2>&1 >/dev/console)
	ret=$?

	echo "$selection"
	return $ret
}



stateFile=/.installer_state
welcome_seen="false"
disks_partitioned="false"
net_is_up="false"
inst_log "hi3"
if [ -f $stateFile ]; then
	source $stateFile
fi
inst_log "hi4"

updateState() {
	echo "welcome_seen=$welcome_seen" > $stateFile
	echo "disks_partitioned=$disks_partitioned" >> $stateFile
	echo "net_is_up=$net_is_up" >> $stateFile
}



mainScreen() {
	yesno "Next" "Cancel" "Welcome" "Welcome to the Wii Linux Installer!\nThis program will install Wii Linux to your SD Card or USB device.\n\nIf you don't wish to proceed, press the Cancel button to restart.\nIf you want to proceed to partition your storage media, press Next."
	ret=$?

	# cancel
	if [ "$ret" = "1" ] || [ "$ret" = "255" ]; then
		yesno "Continue Installation" "Exit" "Warning" "Are you sure you want to exit the Wii Linux Installer?\nYour Wii will restart."
		ret="$?"
		
		# Chose no, e.g. "exit"
		if [ "$ret" = "1" ] || [ "$ret" = "255" ]; then
			inst_log "Leaving via user selecting exit on welcome screen, dialog just crashing"
			exit 0
		fi

		# user chose "Continue Installation", loop up to the top
		if [ "$ret" = "0" ]; then
			return 69
		fi
	fi

	# ret = 0 falls through and the function loops
	return 0
}

inst_log "about to start mainScreen"
while [ "$welcome_seen" = "false" ]; do
	if mainScreen; then
		welcome_seen="true"
		updateState
		break
	fi
done

swap_location=""

doPartition() {
	inst_log "doPartition"
	# Nuke /mnt/* just in case
	inst_log "umount /mnt/boot"
	umount /mnt/boot
	inst_log "umount /mnt/root"
	umount /mnt/root
	rm -f /swapfile_path

	# Initialize an empty array for dialog options
	options=()

	inst_log "lsblk start"
	# Get list of disks and their types
	while read -r l; do
		inst_log "lsblk about to eval"
		eval "$l"
		inst_log "lsblk eval done"
		if [ "$TYPE" != "disk" ]; then
			continue
		fi

		case "$NAME" in
			sd*) disk_type="USB" ;;
			rvlsda*) disk_type="SD Card" ;;
	mmc*) disk_type="SD Card" ;;
			zram*) continue ;;
			*) disk_type="Unknown" ;;
		esac

		# Format each option as 'disk_name (disk_type)' and size
		options+=("$NAME ($disk_type)" "$SIZE")
		inst_log "lsblk processing end"
	done < <(lsblk --shell --pairs)
	inst_log "lsblk done"

	# If no disks were found, return 1 (failure)
	if [ ${#options[@]} -eq 0 ]; then
		msgbox "OK" "No Disks Found" "No disks found!"
		bash
		return 1
	fi

	inst_log "calling menu in doPartition"

	# Present the user with a menu of disks to choose from
	selected_disk=$(menu "Select a disk to partition:" "${options[@]}")
	ret=$?
	inst_log "menu exit, supposedly selected $selected_disk"
	if [ $ret -ne 0 ] || [ -z "$selected_disk" ]; then
		msgbox "OK" "Cancelled" "Operation cancelled."
		bash
		return 1
	fi

	# Extract the actual disk name
	disk_name=$(echo "$selected_disk" | cut -d " " -f1)

	# Gather all partitions from the selected disk
	partitions=$(lsblk -lno NAME,SIZE,FSTYPE,MOUNTPOINT /dev/$disk_name | grep -v "$disk_name")

	# Save the partition information to a file
	echo "$partitions" > /tmp/${disk_name}_partitions.txt

	# Menu for partitioning actions
	action=$(menu "Partitioning Actions" \
	1 "Auto-Partition (highly recommended)" \
	2 "Manual Partitioning (cfdisk)")
	ret=$?
	if [ $ret -ne 0 ] || [ -z "$action" ]; then
		msgbox "OK" "Cancelled" "Operation cancelled."
		bash
		return 1
	fi

	case $action in
		1)
			# Auto-partition based on the disk size
			size=$(lsblk -lbno SIZE /dev/"$disk_name")
			if [ "$size" -le $((15 * 1024 * 1024 * 1024)) ]; then
				boot_size=512M
				swap_size=1G
			elif [ "$size" -le $((30 * 1024 * 1024 * 1024)) ]; then
				boot_size=1G
				swap_size=2G
			else
				boot_size=2G
				swap_size=4G
			fi

			if ! yesno "OK" "Cancel" "Auto-Partitioning" "OK to Auto-Partition /dev/$disk_name?"; then return 1; fi
			(
				echo o	  # Create a new empty DOS partition table
				echo n	  # Add a new partition (boot)
				echo p
				echo 1
				echo
				echo +$boot_size
				echo t	  # Change the partition type to FAT32
				echo 1
				echo n	  # Add a new partition (swap)
				echo p
				echo 2
				echo
				echo +$swap_size
				echo t	  # Change the partition type to Linux swap
				echo 2
				echo 82
				echo n	  # Add a new partition (rootfs)
				echo p
				echo 3
				echo
				echo
				echo w	  # Write the partition table
			) | fdisk /dev/$disk_name

			# Format the partitions
			mkfs.vfat -F32 /dev/${disk_name}1
			mkswap /dev/${disk_name}2
			mkfs.ext4 /dev/${disk_name}3

			msgbox "OK" "Auto-Partitioning" "Auto-partitioning complete!"
			;;
		2)
			msgbox "OK" "Manual Partitioning" "This section is not yet complete.\nIf you would like a non-standard partitioning setup, do so by hand here, \"cfdisk\", \"fdisk\", \"mkfs.{ext4,vfat}\", and \"mkswap\" are all here.  The script expects /mnt/boot and /mnt/root to be mounted when you exit.  Note that /mnt/boot is __ALREADY MOUNTED__.  If you opt to make a swap partition or swapfile now, write it's path from the perspective of the installed system (e.g. /dev/sda2, or /swapfile) to /swapfile_path in the current (in-RAM) rootfs.\nYou are now getting dumped to a shell (GNU Bash), good luck."
			bash
			# we're back, verify that they weren't an idiot
			if ! mountpoint -q /mnt/root || ! mountpoint -q /mnt/boot; then
				msgbox "OK" "Error" "You've set up partitioning incorrectly.  Wizard is now being restarted, please try again, or use automatic partitioning."
				return 1
			fi

			return 0 ;;
			#msgbox "I understand." "External Program Warning" \
#"You are about to enter an external program, \"cfdisk\".  This is not code written by Techflash or any other member of the Wii Linux team.
#As such, we can't really add tips to the app itself to help you through it.  However, here are some tips before we dump you straight in:
#- Use the arrow keys to navigate the bottom bar
#- When done partitioning, navigate to the \"Write\" button, press enter, type \"yes\", and press enter again.  Then navigate to the \"Quit\" button and press enter, or just press \"q\".
#- You'll want one partition >256MB (but probably not >2GB) for storing boot files, and it should be set to the type \"W95 FAT32 (LBA)\"
#- You'll want one partition >2GB for storing the Linux distro itself, set to the type \"Linux\"
#- You'll likely want a swap partition of >512MB if you plan to do anything remotely demanding with your Wii."
#			cfdisk ;;
		*)
			msgbox "OK" "Error" "No valid action selected."
			return 1
			;;
	esac

	return 0
}


while [ "$disks_partitioned" = "false" ]; do
	if doPartition; then
		disks_partitioned="true"
		updateState
		break
	fi
done

netSetup() {
	msgbox "I understand." "External Program Warning" "You are about to enter an external program, \"nmtui\".  This is not code written by Techflash or any other member of the Wii Linux team.\nAs such, we can't really add tips to the app itself to help you through it.  However, here are some tips before we dump you straight in:\n- When done, tap ESC, or navigate to the quit button, in order to return to the Wii Linux Installer\n- Got ethernet?  It should've been configured automatically.  Check that the cable is securely connected, and that \"nmtui\" lists your adapter under \"Edit a connection\".\n- Need to use WiFi?  Go to \"Activate a connection\", pick your network, enter the credentials, and if you see a star next to your network name, it means you're connected.  Go ahead and exit."
	
	# alright, hope they got all of that, dumping them into nmtui
	nmtui

	# alright they made it out, but do they have networking?
	if ! ping -c 1 1.1.1.1 > /dev/null 2>&1; then
		infobox "Network Setup" "Network setup failed, cannot reach the internet.  Please try again."
		sleep 5
		return 1
	fi

	# success, but do they have DNS?
	if ! ping -c 1 google.com > /dev/null 2>&1; then
		infobox "Network Setup" "Network setup failed, no DNS.  Please try again."
		sleep 5
		return 1
	fi

	
	infobox "Network Setup" "Network setup succeeed.  Continuing with installation."
	sleep 5
	return 0
}


while [ "$net_is_up" = "false" ]; do
	if netSetup; then
		net_is_up="true"
		updateState
		break
	fi
done



url="https://wii-linux/installer/stage2.sh"
output="stage2.sh"

{
	wget --progress=dot -O "/mnt/boot/$output" "$url" 2>&1 | \
	grep --line-buffered "%" | \
	sed -u -e "s/.* \([0-9]*\)% .*/\1/" 
} | dialog --gauge "Downloading $output..." 10 70 0

msgbox "OK" "Incomplete" "This installer is incomplete, and ends here.  If you are testing this build, please go verify that your disk(s) were partitioned and formatted correctly!"
