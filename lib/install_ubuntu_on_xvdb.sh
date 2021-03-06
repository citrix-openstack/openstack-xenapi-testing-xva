#!/bin/bash
set -eux

HOSTNAME="$1"
ROOT_PARTITION_SIZE_GB="$2"
USERNAME="domzero"

function main() {
    update_debootstrap
    set_mirror
    prepare_disk
    install_base_system
    enable_chroot
    customize_system
    disable_chroot
}

function update_debootstrap() {
    local tmpdir
    local debootstrap_deb

    tmpdir=$(mktemp -d)

    debootstrap_deb="$tmpdir/debootstrap.deb"

    wget -qO "$debootstrap_deb" "http://archive.ubuntu.com/ubuntu/pool/main/d/debootstrap/debootstrap_1.0.67_all.deb"

    sudo dpkg -i "$debootstrap_deb"

    rm -rf "$tmpdir"
}

function set_mirror() {
    sudo sed -ie "s,mirror.anl.gov/pub/ubuntu,us.archive.ubuntu.com/ubuntu,g" /etc/apt/sources.list
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

    sudo mkdir -p /var/jeos
    DEBOOTSTRAP_ARGS="--arch=amd64"
    DEBOOTSTRAP_ARGS+=" --components=main,universe"
    DEBOOTSTRAP_ARGS+=" --include=openssh-server,language-pack-en"
    DEBOOTSTRAP_ARGS+=",linux-image-virtual,grub,sshpass,wget,ethtool"
    DEBOOTSTRAP_ARGS+=",bsdmainutils,ca-certificates,python2.7"
    DEBOOTSTRAP_ARGS+=",strace,gdb"
    DEBOOTSTRAP_ARGS+=" trusty"
    DEBOOTSTRAP_ARGS+=" /ubuntu_chroot"
    DEBOOTSTRAP_ARGS+=" http://us.archive.ubuntu.com/ubuntu/"

    CACHE_MD5=`echo $DEBOOTSTRAP_ARGS | md5sum | cut -f 1 -d ' '`

    JEOS_CACHE="/var/jeos/cache_$CACHE_MD5.tgz"

    if ! [ -e "$JEOS_CACHE" ]; then
        # MD5 of args has changed - delete all old caches
        sudo rm -rf /var/jeos/cache_*.tgz

        sudo mkdir -p /ubuntu_chroot
        sudo http_proxy=http://gold.eng.hq.xensource.com:8000 debootstrap \
             $DEBOOTSTRAP_ARGS < /dev/null
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

    sudo LANG=C chroot /mnt/ubuntu cp /proc/mounts /etc/mtab

    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "grub-install /dev/xvdb"

    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "update-grub -y"


    sudo mkdir -p /mnt/ubuntu/root/.ssh
    sudo chmod 0700 /mnt/ubuntu/root/.ssh
    sudo tee /mnt/ubuntu/root/.ssh/authorized_keys << EOF
# Empty now, should be populated by $USERNAME
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


    # Set hostname
    echo "$HOSTNAME" | sudo tee /mnt/ubuntu/etc/hostname

    # Configure hosts file, so that hostname could be resolved
    sudo sed -i "1 s/\$/ $HOSTNAME/" /mnt/ubuntu/etc/hosts

    # Disable DNS with ssh
    echo "UseDNS no" | sudo tee -a /mnt/ubuntu/etc/ssh/sshd_config

    sudo tee /mnt/ubuntu/etc/network/interfaces << EOF
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF

    sudo tee /mnt/ubuntu/etc/apt/sources.list << EOF
deb http://mirror.rackspace.com/ubuntu/ trusty main restricted
deb-src http://mirror.rackspace.com/ubuntu/ trusty main restricted

deb http://mirror.rackspace.com/ubuntu/ trusty-updates main restricted
deb-src http://mirror.rackspace.com/ubuntu/ trusty-updates main restricted

deb http://mirror.rackspace.com/ubuntu/ trusty universe
deb-src http://mirror.rackspace.com/ubuntu/ trusty universe

deb http://mirror.rackspace.com/ubuntu/ trusty-updates universe
deb-src http://mirror.rackspace.com/ubuntu/ trusty-updates universe

deb http://mirror.rackspace.com/ubuntu/ trusty multiverse
deb-src http://mirror.rackspace.com/ubuntu/ trusty multiverse

deb http://mirror.rackspace.com/ubuntu/ trusty-updates multiverse
deb-src http://mirror.rackspace.com/ubuntu/ trusty-updates multiverse

deb http://mirror.rackspace.com/ubuntu/ trusty-backports main restricted universe multiverse
deb-src http://mirror.rackspace.com/ubuntu/ trusty-backports main restricted universe multiverse

deb http://security.ubuntu.com/ubuntu trusty-security main restricted
deb-src http://security.ubuntu.com/ubuntu trusty-security main restricted

deb http://security.ubuntu.com/ubuntu trusty-security universe
deb-src http://security.ubuntu.com/ubuntu trusty-security universe

deb http://security.ubuntu.com/ubuntu trusty-security multiverse
deb-src http://security.ubuntu.com/ubuntu trusty-security multiverse
EOF


    # Update the apt lists
    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "DEBIAN_FRONTEND=noninteractive \
        apt-get update"

    # Upgrade kernel etc
    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "DEBIAN_FRONTEND=noninteractive \
        apt-get -qy dist-upgrade"

    # Add a user
    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "DEBIAN_FRONTEND=noninteractive \
        adduser --disabled-password --quiet $USERNAME --gecos $USERNAME"

    # Add a script to update authorized keys
    sudo tee /mnt/ubuntu/home/$USERNAME/update_authorized_keys.sh << EOF
#!/bin/bash
set -eux

DOMID=\$(sudo xenstore-read domid)
sudo xenstore-exists /local/domain/\$DOMID/authorized_keys/$USERNAME
sudo xenstore-read /local/domain/\$DOMID/authorized_keys/$USERNAME > /home/$USERNAME/xenstore_value
cat /home/$USERNAME/xenstore_value > /home/$USERNAME/.ssh/authorized_keys
EOF

    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "chown $USERNAME:$USERNAME /home/$USERNAME/update_authorized_keys.sh \
        && chmod 0700 /home/$USERNAME/update_authorized_keys.sh \
        && mkdir -p /home/$USERNAME/.ssh \
        && chown $USERNAME:$USERNAME /home/$USERNAME/.ssh \
        && chmod 0700 /home/$USERNAME/.ssh \
        && touch /home/$USERNAME/.ssh/authorized_keys \
        && chown $USERNAME:$USERNAME /home/$USERNAME/.ssh/authorized_keys \
        && chmod 0600 /home/$USERNAME/.ssh/authorized_keys \
        && true"

    sudo tee /mnt/ubuntu/etc/sudoers.d/allow_$USERNAME << EOF
$USERNAME ALL = NOPASSWD: ALL
EOF

    sudo chmod 0440 /mnt/ubuntu/etc/sudoers.d/allow_$USERNAME

    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c "crontab -u $USERNAME -" << EOF
* * * * * /home/$USERNAME/update_authorized_keys.sh
EOF

    # Ensure "python" exists and links to python2.7
    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c "update-alternatives --install /usr/bin/python python /usr/bin/python2.7 10"

    sudo LANG=C chroot /mnt/ubuntu /bin/bash -c \
        "apt-get clean"
}

function enable_chroot() {
    sudo mount /dev/xvdb1 /mnt/ubuntu
    sudo mount /dev/ /mnt/ubuntu/dev -o bind
    sudo mount none /mnt/ubuntu/dev/pts -t devpts
    sudo mount none /mnt/ubuntu/proc -t proc
    sudo mount none /mnt/ubuntu/sys -t sysfs

    sudo tee /mnt/ubuntu/usr/sbin/policy-rc.d << EOF
exit 101
EOF
    sudo chmod +x /mnt/ubuntu/usr/sbin/policy-rc.d

    sudo cp /etc/mtab /mnt/ubuntu/etc/mtab
}

function disable_chroot() {
    sudo rm /mnt/ubuntu/etc/mtab
    sudo rm /mnt/ubuntu/usr/sbin/policy-rc.d

    sudo umount /mnt/ubuntu/sys
    sudo umount /mnt/ubuntu/proc/xen || true
    sudo umount /mnt/ubuntu/proc
    sudo umount /mnt/ubuntu/dev/pts
    sudo umount /mnt/ubuntu/dev

    unmount_ubuntu
}

main
