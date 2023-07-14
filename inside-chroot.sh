#!/bin/sh

# This should be run by debian-install.sh when it executes the chroot
# Variables will be stored in the  debian install script and passed in when the script is executed

# Set hostname
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 ${HOSTNAME}.localdomain $HOSTNAME" >> /etc/hosts

# Edit apt sources
echo "deb http://deb.debian.org/debian/ $SUITE main contrib non-free non-free-firmware" > /etc/apt/sources.list

# Just in case we don't have locale stuff
apt update && apt install -yy locales efivar

# timezone and locale stuff
# If related vars are non-empty at the top, handle this automatically
# Otherwise, ask for help using the curses interface.
# Timezone
if [ -z "$TZ" ]; then
	dpkg-reconfigure tzdata;
else
	ln -sf /usr/share/zoneinfo/US/Eastern /etc/localtime;
fi

# Locale
if [ -z "$LOCALE" ]; then
	dpkg-reconfigure locales;
else
	echo "$LOCALE" > /etc/locale.gen && locale-gen;
fi

# Add luks container to crypttab
echo "Modifying /etc/crypttab..."
ENCRYPTED_UUID=$(blkid -s UUID | grep "$LUKS2_PARTITION" | awk '{print $2}')
echo -e "${CRYPT_NAME} \t ${ENCRYPTED_UUID} \t none \t discard,luks" >> /etc/crypttab

# Install necessary stuff
while ! apt install -yy linux-image-amd64 \
	linux-headers-amd64 \
	firmware-iwlwifi \
	firmware-misc-nonfree \
	firmware-linux-nonfree \
	sudo \
	vim \
	bash-completion \
	command-not-found \
	plocate \
	systemd-timesyncd \
	usbutils \
	hwinfo \
	v4l-utils \
	task-laptop \
	powertop \
	linux-cpupower \
	efibootmgr \
	btrfs-progs \
	cryptsetup-initramfs \
	cryptsetup \
	systemd-boot \
	systemd-boot-efi \
	gnome-core
do
	echo "Trying download again in 60 seconds..."
done

# Set plymouth theme
# plymouth-set-default-theme -R moonlight

echo "Set root password..."
passwd

echo "Create new user..."
useradd graham -m -c "Graham Trogdon" -s /bin/bash
echo "Set a password for the new user."
passwd graham
echo "Adding users to groups..."
usermod -aG sudo,adm,dialout,cdrom,floppy,audio,dip,video,plugdev,users,netdev,bluetooth,wireshark graham

echo "Installing bootloader (systemd-boot)..."
bootctl install
mkdir -p /boot/efi/`cat /etc/machine-id`
kernel-install add `uname -r` /boot/vmlinuz-`uname -r` /boot/initrd.img-`uname -r`

echo "Modify bootloader entry..."
ENTRY_ARGS="root=UUID=`blkid -s UUID -o value /dev/mapper/${CRYPT_NAME}` rootflags=subvol=@ rootfstype=btrfs"
ENTRY_FILE="/boot/efi/loader/entries/`cat /etc/machine-id`-`uname -r`.conf"
sed -i "s/options\([ \t]*\).*/options\1${ENTRY_ARGS}/g" "$ENTRY_FILE"

# Enable auto-updating for bootloader
touch /etc/kernel/postinst.d/zz-update-systemd-boot
chmod +x /etc/kernel/postinst.d/zz-update-systemd-boot
echo '''#!/bin/sh
set -e
/usr/bin/kernel-install add "$1" "$2"
exit 0''' > /etc/kernel/postinst.d/zz-update-systemd-boot

touch /etc/kernel/postrm.d/zz-update-systemd-boot
chmod +x /etc/kernel/postrm.d/zz-update-systemd-boot
echo '''#!/bin/sh
set -e
/usr/bin/kernel-install remove "$1"
exit 0''' > /etc/kernel/postrm.d/zz-update-systemd-boot
