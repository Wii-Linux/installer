#!/bin/busybox sh

# Define common tasks and variables
version="0.0.1a"
codename="Insert Cool Codename Here"
on_server_version="0_0_1a"
title="Wii Linux Installer - $version \"$codename\""

box_width=$(((COLUMNS * 10) / 12))
box_height=$(((LINES * 10) / 14)) 


# Displays a message box with a single button.
# Argument 1: Text for the button that will close the prompt with success.
# Argument 2: Message box content.
msgbox() {
	dialog --backtitle "$title" --ok-label "$1" --msgbox "$2" "$box_height" "$box_width"
	return $?
}

# Displays a message box with a yes and a no button
# Argument 1: Text for the button that will close the prompt with success.
# Argument 2: Text for the button that will close the prompt with failure.
# Argument 3: Message box content.
# XXX: Swaps yes and no so yes can be on the left
yesno() {
	dialog --backtitle "$title" --yes-label "$2" --no-label "$1" --defaultno --yesno "$3" "$box_height" "$box_width"
	ret=$?
	if [ "$ret" = "255" ]; then return 255
	elif [ "$ret" = "1" ]; then return 0
	elif [ "$ret" = "0" ]; then return 1
	else return 69
	fi
}

yesno "Next" "Cancel" "Welcome to the Wii Linux Installer!\nThis program will install [REDACTED] Linux to your SD Card or USB device.\n\nIf you don't wish to proceed, press the Cancel button to restart.\nIf you want to proceed to partition your storage media, press Next."

