#!/bin/bash
set -eux

HOSTNAME="$1"
ROOT_PARTITION_SIZE_GB="$2"

function main() {
    set_mirror
    prepare_disk
    install_base_system
    enable_chroot
    customize_system
    disable_chroot
}

function set_mirror() {
    sudo sed -ie "s,mirror.anl.gov/pub/ubuntu,mirror.pnl.gov/ubuntu,g" /etc/apt/sources.list
}

function prepare_disk() {
    # Update system and install dependencies
    export DEBIAN_FRONTEND=noninteractive

    sudo apt-get update
    #sudo apt-get -qy upgrade

    # Partition xvdb
    sudo fdisk /dev/xvdb << EOF
o
n
p


+${ROOT_PARTITION_SIZE_GB}G
t
83
n
p



t
2
82
wq
EOF

    sudo partprobe /dev/xvdb

    sudo mkfs.ext3 /dev/xvdb1
    sudo mkswap /dev/xvdb2
    sudo sync
}

function unmount_ubuntu() {
    sudo sync

    sudo umount "/mnt/ubuntu"

    while grep -q "/mnt/ubuntu" /proc/mounts; do
        sleep 1
    done
}

function install_base_system() {
    sudo mkdir -p /mnt/ubuntu
    sudo mount /dev/xvdb1 /mnt/ubuntu

    sudo apt-get install -qy debootstrap

    sudo mkdir -p /var/jeos
    JEOS_CACHE="/var/jeos/cache.tgz"

    if ! [ -e "$JEOS_CACHE" ]; then
        sudo mkdir -p /ubuntu_chroot
        sudo http_proxy=http://gold.eng.hq.xensource.com:8000 debootstrap \
             --arch=amd64 \
             --components=main,universe \
             --include=openssh-server,language-pack-en,linux-image-virtual,grub-pc,sshpass,wget \
             saucy \
             /ubuntu_chroot \
             http://mirror.pnl.gov/ubuntu/ > /dev/null 2> /dev/null < /dev/null
        echo "Saving cache..."
        sudo tar -czf "$JEOS_CACHE" -C /ubuntu_chroot ./
        sudo rm -rf /ubuntu_chroot
    fi

    sudo tar -xzf "$JEOS_CACHE" -C /mnt/ubuntu

    unmount_ubuntu
}

function customize_system() {
    sudo tee /mnt/ubuntu/etc/fstab << EOF
proc /proc proc nodev,noexec,nosuid 0 0
UUID=$(sudo blkid -s UUID /dev/xvdb1 -o value) /    ext3 errors=remount-ro 0 1
UUID=$(sudo blkid -s UUID /dev/xvdb2 -o value) none swap sw                0 0
EOF

    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "grub-install /dev/xvdb"

    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "update-grub"

    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "apt-get clean"

    sudo mkdir -p /mnt/ubuntu/root/.ssh
    sudo chmod 0700 /mnt/ubuntu/root/.ssh
    sudo tee /mnt/ubuntu/root/.ssh/authorized_keys << EOF
# Empty now, will be populated by /root/update_authorized_keys.sh
EOF
    sudo chmod 0600 /mnt/ubuntu/root/.ssh/authorized_keys

    # Install xenserver tools
    sudo wget -qO /mnt/ubuntu/xstools http://downloads.vmd.citrix.com/OpenStack/xe-guest-utilities/xe-guest-utilities_6.2.0-1120_amd64.deb
    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "RUNLEVEL=1 dpkg -i --no-triggers /xstools"
    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "/etc/init.d/xe-linux-distribution stop" || true

    sudo tee /mnt/ubuntu/etc/init/hvc0.conf << EOF
# hvc0 - getty
#
# This service maintains a getty on hvc0 from the point the system is
# started until it is shut down again.

start on stopped rc RUNLEVEL=[2345] and (
            not-container or
            container CONTAINER=lxc or
            container CONTAINER=lxc-libvirt)

stop on runlevel [!2345]

respawn
exec /sbin/getty -L hvc0 9600 linux
EOF

    sudo tee /mnt/ubuntu/root/update_authorized_keys.sh << EOF
#!/bin/bash
set -eux

DOMID=\$(xenstore-read domid)
xenstore-exists /local/domain/\$DOMID/authorized_keys/root
xenstore-read /local/domain/\$DOMID/authorized_keys/root > /root/xenstore_value
cat /root/xenstore_value > /root/.ssh/authorized_keys
EOF
    sudo chmod +x /mnt/ubuntu/root/update_authorized_keys.sh

    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c "crontab -" << EOF
* * * * * /root/update_authorized_keys.sh
EOF

    # Set hostname
    echo "$HOSTNAME" | sudo tee /mnt/ubuntu/etc/hostname

    # Configure hosts file, so that hostname could be resolved
    sudo sed -i "1 s/\$/ $HOSTNAME/" /mnt/ubuntu/etc/hosts

    # Disable DNS with ssh
    echo "UseDNS no" | sudo tee /mnt/ubuntu/etc/ssh/sshd_config

    sudo tee /mnt/ubuntu/etc/network/interfaces << EOF
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF

    sudo tee /mnt/ubuntu/etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu precise main
deb http://archive.ubuntu.com/ubuntu precise universe
EOF
}

function enable_chroot() {
    sudo mount /dev/xvdb1 /mnt/ubuntu
    sudo mount /dev/ /mnt/ubuntu/dev -o bind
    sudo mount none /mnt/ubuntu/dev/pts -t devpts
    sudo mount none /mnt/ubuntu/proc -t proc
    sudo mount none /mnt/ubuntu/sys -t sysfs

    sudo cp /etc/mtab /mnt/ubuntu/etc/mtab
}

function disable_chroot() {
    sudo rm /mnt/ubuntu/etc/mtab

    sudo umount /mnt/ubuntu/sys
    sudo umount /mnt/ubuntu/proc/xen || true
    sudo umount /mnt/ubuntu/proc
    sudo umount /mnt/ubuntu/dev/pts
    sudo umount /mnt/ubuntu/dev

    unmount_ubuntu
}

main
