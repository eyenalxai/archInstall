#! /bin/bash

# Silence shellcheck warnings:
# Ignore word splitting of unquoted variables
# shellcheck disable=SC2086
# Ignore read mangling backwards slashes
# shellcheck disable=SC2162

# Strict mode - http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
RedColor='\033[0;31m'
YellowColor='\033[0;33m'
BlueColor='\033[0;94m'
NoColor='\033[0m'

# Beautify pacman
function pacmanConf {
	sed -i s/#Color/Color/g /etc/pacman.conf
	sed -i s/#TotalDownload/TotalDownload/g /etc/pacman.conf
	sed -i s/#VerbosePkgLists/VerbosePkgLists/g /etc/pacman.conf
}

# Selfexplainatory
if [[ $(id -u) != "0" ]]; then
	echo -e "${RedColor}Script needs to be run under the root user${NoColor}"
	exit 1
fi

# Selfexplainatory
if [[ -e /var/lib/pacman/db.lck ]]; then
	echo -e "${RedColor}Pacman lockfile detected, make sure nothing is using pacman, exiting.${NoColor}"
	exit 1
fi
if [[ -z ${1-} ]]; then
	# Start NTP so we get correct time and script doesn't fuck up on TLS errors
	timedatectl set-ntp true

	# If previous install failed to unmount the partitions, unmount them
	if mountpoint -q "/mnt/boot"; then
		umount -l /mnt/boot
	fi
	if mountpoint -q "/mnt"; then
		umount -l /mnt
	fi
	
	# More verbose lsblk in the live install
	alias lsblk='lsblk -o +fstype,label,uuid'
	clear; lsblk
	echo -e "${YellowColor}Select the drive you want to install Arch Linux on e.g. \"sda\" or \"sdb\" without the quotes.${NoColor}"
	read drive; clear
	
	echo -e "${YellowColor}Login for private stuff${NoColor}"
	read loginPrivate; clear

	echo -e "${YellowColor}Password for private stuff${NoColor}"
	read passwordPrivate; clear
	
	echo -e "${YellowColor}URL for private stuff${NoColor}"
	read urlPrivate; clear
	
	username='dmitry'
	hostname='archbox'
	
    # If the drive is NVMe the naming scheme differs from the usual naming
    #if echo ${drive} | grep "nvme"; then
    #    Part1Name="p1"
    #    Part2Name="p2"
    #else
    #    Part1Name="1"
    #    Part2Name="2"
    #fi
	Part1Name="5"
    Part2Name="6"
    
    # Create partitions 
    #wipefs -a /dev/${drive}
    #parted -s /dev/${drive} mklabel gpt
    #parted -s /dev/${drive} mkpart ESP fat32 1MiB 129MiB
    #parted -s /dev/${drive} set 1 boot on
    #parted -s /dev/${drive} mkpart primary btrfs 129MiB 100%
    
    # BTRFS subvolumes 
    mkfs.btrfs -L ARCH /dev/${drive}${Part2Name} -f
    mount -o compress=zstd /dev/${drive}${Part2Name} /mnt
    cd /mnt
    btrfs su cr ROOT
    btrfs su cr DOWNLOADS
    btrfs su cr NEXTCLOUD
    btrfs su cr .snapshots
    cd
    umount /mnt
    mount -o compress=zstd,subvol=ROOT /dev/${drive}${Part2Name} /mnt
    cd /mnt
    mkdir -p {.snapshots,boot,home/${username}/{Downloads,Nextcloud,Stuff}}
    mount -o compress=zstd,subvol=.snapshots /dev/${drive}${Part2Name} /mnt/.snapshots
    mount -o compress=zstd,subvol=DOWNLOADS /dev/${drive}${Part2Name} /mnt/home/${username}/Downloads
    mount -o compress=zstd,subvol=NEXTCLOUD /dev/${drive}${Part2Name} /mnt/home/${username}/Nextcloud
    mkfs.fat -F32 /dev/${drive}${Part1Name}
    mkdir -p /mnt/boot
    
    # EFI partition
    mount /dev/${drive}${Part1Name} /mnt/boot
	
	# If this is the live ISO env, set max live space to 2GB instead of 256MB to be able to do a -Syu in the live env
	if mount | grep /run/archiso/cowspace >/dev/null; then
		mount -o remount,size=2G /run/archiso/cowspace
	fi

	# MAIN BLOCK
	
	# Make pacman output prettier in the live env
	pacmanConf
	
	# Install reflector in the live env to download and sort mirrorlist so the install doesn't hang on downloading packages
	# If it fails due to different dependencies on ISO vs current packages or running, just update the entire live boot env
	echo -e "${YellowColor}Ranking mirrors for faster download speeds...${NoColor}"
	pacman -Sy reflector git --noconfirm --needed
	
	# Ranks lastest 50 mirrors only
	reflector --latest 50 --sort rate --save /etc/pacman.d/mirrorlist
	
	# Install base and necessary packages
	pacstrap /mnt ansible base base-devel linux linux-firmware git btrfs-progs sudo
	
	# Copy mirrorlist
	cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
	genfstab -U /mnt > /mnt/etc/fstab
	
    # Return to the location of this script
	cd

	# Copy script so it would be able to run in chroot 
	# cp ${BASH_SOURCE} /mnt/root
    # Clone repo that includes this script and ansible playbooks
    git clone https://git.auteiy.me/dmitry/archInstall.git /mnt/home/${username}/Stuff/archInstall

	# Prepare answers for ansible
	declare -p hostname username drive loginPrivate passwordPrivate urlPrivate > /mnt/root/answerfile
	
    # CHROOT
    # Script will continue from here because we defined ${1}

	arch-chroot /mnt /bin/bash -c "/home/${username}/Stuff/archInstall/$(basename ${BASH_SOURCE}) letsgo" 

else # We're in chroot. ${1} is only set after chrooting
	# Source answers
	source /root/answerfile

    # Clone repo that includes this script and ansible playbooks
    # git clone https://git.auteiy.me/dmitry/archInstall.git /home/${username}/Stuff/archInstall
	
	# Ansible
	ansible-playbook /home/${username}/Stuff/archInstall/ansible/playbooks/site.yaml
	
fi
echo -e "${YellowColor}Looks like the first part of the installation was a success! Now you should reboot with 'reboot'.${NoColor}"
