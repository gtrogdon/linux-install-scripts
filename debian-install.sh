#!/bin/sh

# Install script for Debian with BTRFS in LUKS2 container

# Run as root
# Requires apt, so best to run from Debian/Ubuntu LiveISO

# PARAMETERS
ARCH="amd64"			# architecture of target system
SUITE="stable"			# debian suite to target (can be release codename e.g. bookworm, sid, jessie, etc) or symbolic name (stable, unstable, etc).
DISK="/dev/nvme0n1"		# target disk
EFI_PARTITION="${DISK}p1"	# partition for EFI system partition
LUKS2_PARTITION="${DISK}p2"	# partition for LUKS2 container

TZ="US/Eastern"			# Timezone -- set to blank if unsure
LOCALE="en_US.UTF-8 UTF-8"	# Locale -- set to blank if unsure
HOSTNAME="thinkpad"		# Hostname for new install

CRYPT_NAME="cryptroot"		# name of mounted LUKS container (not really that important...)
MOUNT_LOCATION="/mnt"		# location where we will doing most mounting

# SCRIPT

# Install crypt utils, debian bootstrapper, and arch installation scripts to ease process
echo "Installing utilities..."
apt install -yy debootstrap cryptsetup arch-install-scripts btrfs-progs efivar
modprobe efivarfs
# TODO: Automatic partitioning with variables and prompts and stuff.

# ESP Filesystem stuff
echo "Creating ESP..."
mkfs.vfat -F 32 -n EFI "$EFI_PARTITION"	# format as FAT32
parted "$DISK" set 1 esp on	# enable EFI system partition flag
parted "$DISK" set 1 boot on	# enable bootable flag

# Format encrypted partition
clear; echo "Create a password for LUKS2 container."
cryptsetup -y -v --type=luks2 luksFormat --label=Debian "$LUKS2_PARTITION" || exit 1

clear; echo "Type in the password you created to open and mount LUKS2 container"
cryptsetup open "$LUKS2_PARTITION" "$CRYPT_NAME" || exit 1

# Create filesystem and mount it
"Creating btrfs filesystem..."
mkfs.btrfs "/dev/mapper/$CRYPT_NAME"			# create btrfs in LUKS2
mount "/dev/mapper/$CRYPT_NAME" "$MOUNT_LOCATION"	# mount rootfs to /mnt so we can create subvolumes
# Subvolume creation time!
btrfs subvolume create "${MOUNT_LOCATION}/@"			# root subvolume
btrfs subvolume create "${MOUNT_LOCATION}/@home"		# home subvolume
btrfs subvolume create "${MOUNT_LOCATION}/@snapshots"		# snapshots subvolume
btrfs subvolume create "${MOUNT_LOCATION}/@swap"		# swap subvolume

# Unmount the container root
umount "$MOUNT_LOCATION"

# Now we need to re-mount the subvolumes with the structure that we
# want for the resultant system
echo "Re-mounting subvolumes with proper mounting options..."
mount -o noatime,nodiscard,compress=zstd:3,space_cache=v2,subvol=@		"/dev/mapper/$CRYPT_NAME"	"$MOUNT_LOCATION"
mkdir -p "$MOUNT_LOCATION/boot"			# create directories for other mounting targets
mkdir -p "$MOUNT_LOCATION/home"
mkdir -p "$MOUNT_LOCATION/.snapshots"
mkdir -p "$MOUNT_LOCATION/swap"
mkdir "$MOUNT_LOCATION/boot/efi"				# create directory to mount EFI partition in
mount "$EFI_PARTITION" "$MOUNT_LOCATION/boot/efi"		# mount the EFI partition where it would be on an actual system
mount -o noatime,nodiscard,compress=zstd:3,space_cache=v2,subvol=@home		"/dev/mapper/$CRYPT_NAME"	"$MOUNT_LOCATION/home"
mount -o noatime,nodiscard,compress=zstd:3,space_cache=v2,subvol=@snapshots	"/dev/mapper/$CRYPT_NAME"	"$MOUNT_LOCATION/.snapshots"
# Mount the subvolume that will hold our swapfile. We don't want any options on this one aside from the subvol :)
mount -o subvol=@swap								"/dev/mapper/$CRYPT_NAME"	"$MOUNT_LOCATION/swap"

# Set up swapfile
echo "Setting up and formatting the swapfile..."
touch "$MOUNT_LOCATION/swap/swapfile"					# create empty file inside the swap subvolume
chmod 600 "$MOUNT_LOCATION/swap/swapfile"				# set permissions--only owner can read and write to the file
chattr +C "$MOUNT_LOCATION/swap/swapfile"				# disable CoW (copy on write) for swapfile
									# Note that disabling CoW implicitly disables compression,
									# which is good.
dd if=/dev/zero of="$MOUNT_LOCATION/swap/swapfile" bs=1M count=16384	# set swapfile to RAM amount (e.g. 32GB, so 1024 * 32 = 32768)
mkswap "$MOUNT_LOCATION/swap/swapfile"					# finally, format the file as a swapfile
swapon "$MOUNT_LOCATION/swap/swapfile"					# enable the swap file

mkdir -p "${MOUNT_LOCATION}/var/log"
btrfs subvolume create "${MOUNT_LOCATION}/var/log"	# create subvolume in /var/log. Creating a subvolume at this level excludes it from snapshots
							# which is what we want to happen.

# Install the base system
echo "Installing base system..."

while ! debootstrap --arch $ARCH $SUITE $MOUNT_LOCATION
do
	echo "Waiting to retry bootstrap..."
	sleep 60
done

# Perform bind mounts in preparation for chroot
for i in dev proc sys; do
  mount --rbind "/$i" "${MOUNT_LOCATION}/$i"; mount --make-rslave "${MOUNT_LOCATION}/$i"
done

# Generate fstab for our filesystem
echo "Generating new fstab..."
genfstab -U "$MOUNT_LOCATION" >> "${MOUNT_LOCATION}/etc/fstab"

# Copy DNS info over
cp /etc/resolv.conf "${MOUNT_LOCATION}/etc/resolv.conf"

# Copy inside-chroot.sh to root of new system so that we can run next commands there
# inside-chroot.sh should be in the same directory as this script.
cp "`dirname ${BASH_SOURCE[0]}`/inside-chroot.sh" "${MOUNT_LOCATION}/inside-chroot.sh"

# chroot into install and execute next script
SUITE="$SUITE" \
LUKS2_PARTITION="$LUKS2_PARTITION" \
HOSTNAME="$HOSTNAME" \
TZ="$TZ" \
LOCALE="$LOCALE" \
CRYPT_NAME="$CRYPT_NAME" \
chroot $MOUNT_LOCATION /bin/bash /inside-chroot.sh
