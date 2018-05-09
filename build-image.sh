#!/bin/bash
### Build a filesystem image for Nintendo Switch

if [ "$1" == "--help" ]; then
    echo "Usage $0 [--all]"
    exit 1
fi

# Sources:
# https://wiki.debian.org/Debootstrap
# https://wiki.debian.org/EmDebian/CrossDebootstrap
# https://wiki.debian.org/Arm64Qemu

set -e

### settings
os=ubuntu
arch=arm64
suite=bionic
apt_mirror='http://ports.ubuntu.com'
repositories='main restricted universe multiverse'
chroot_dir="${1:-/var/chroot/${os}_${arch}_$suite}"
tarball="${2:-${os}_${arch}_${suite}.tar.gz}"

### make sure that the required tools are installed
echo "Installing dependencies..."
apt-get install -qy --reinstall debootstrap qemu-user-static

### Clear chroot_dir to make sure the rebuild is clean
# This is tp prevent a corrupted chroot dir to break repeated failed
# rebuilds that have been observed at the deboostrap minbase stage
echo "Removing existing chroot..."
rm -rf "$chroot_dir"
rm -f "${tarball}"

### install a minbase system with debootstrap
echo "Creating base image chroot, first stage..."
export DEBIAN_FRONTEND=noninteractive
foreign_arg=''
if [ $arch == 'arm64' ]; then
  foreign_arg='--foreign'
fi
debootstrap --verbose $foreign_arg --variant=minbase --arch=$arch $suite "$chroot_dir" $apt_mirror

echo "Creating base image chroot, second stage..."
cp /usr/bin/qemu-aarch64-static "$chroot_dir/usr/bin/"
LC_ALL=C LANGUAGE=C LANG=C chroot "$chroot_dir" /debootstrap/debootstrap --second-stage
LC_ALL=C LANGUAGE=C LANG=C chroot "$chroot_dir" dpkg --configure -a

### set the hostname
echo "switch" > "$chroot_dir/etc/hostname"

### update the list of package sources
cat <<EOF > "$chroot_dir/etc/apt/sources.list"
deb $apt_mirror $suite $repositories
deb $apt_mirror $suite-updates $repositories
deb $apt_mirror $suite-backports $repositories
EOF

# prevent init scripts from running during install/update
echo '#!/bin/sh' > "$chroot_dir/usr/sbin/policy-rc.d"
echo 'exit 101' >> "$chroot_dir/usr/sbin/policy-rc.d"
chmod +x "$chroot_dir/usr/sbin/policy-rc.d"

# force dpkg not to call sync() after package extraction (speeding up installs)
echo 'force-unsafe-io' > "$chroot_dir/etc/dpkg/dpkg.cfg.d/swibuntu-apt-speedup"

# _keep_ us lean by effectively running "apt-get clean" after every install
echo 'DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' > "$chroot_dir/etc/apt/apt.conf.d/swibuntu-clean"
echo 'APT::Update::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' >> "$chroot_dir/etc/apt/apt.conf.d/swibuntu-clean"
echo 'Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache "";' >> "$chroot_dir/etc/apt/apt.conf.d/swibuntu-clean"

# remove apt-cache translations for fast "apt-get update"
echo 'Acquire::Languages "none";' > "$chroot_dir/etc/apt/apt.conf.d/swibuntu-no-languages"

# store Apt lists files gzipped on-disk for smaller size
echo 'Acquire::GzipIndexes "true"; Acquire::CompressionTypes::Order:: "gz";' > "$chroot_dir/etc/apt/apt.conf.d/swibuntu-gzip-indexes"

# man-db does not work via qemu-user
chroot "$chroot_dir" dpkg-divert --local --rename --add /usr/bin/mandb
chroot "$chroot_dir" ln -sf /bin/true /usr/bin/mandb

# Prepare for later rootfs resize script
touch "$chroot_dir/.rootfs-repartition"
touch "$chroot_dir/.rootfs-resize"
cat <<'EOF' > "$chroot_dir/usr/sbin/rootfs-resize"
#!/usr/bin/python2
#
#   rootfs-resize :: Resize the root parition and filesytem
#
#   Version 3.0       2018-05-09
#
#   Authors:
#   Chris Tyler, Seneca College         2013-01-11
#   Chris Jones                         2018-05-09
#
#   This script will increase the size of the root partition by
#   moving the end of the partition, and then resize the filesystem
#   to fill the available space.
#
#   Prerequisites for successful operation:
#   1. The root filesystem must be on a partition (not an LV or other
#   abstraction) on a /dev/sdX or /dev/mmcblkX device.
#
#   2. The root filesystem type must be ext2, ext3, or ext4.
#
#   3. There must be room available to increase the size of the
#   root partition by moving the end. The start of the root partition
#   will not be moved.
#
#   4. The file /.nofsresize must not exist.
#
#   5. The kernel must not have been booted with the 'nofsresize'
#   command-line option.
#
#   6. The file /.rootfs-repartition must exist to start phase 1
#   (partition adjustment).
#
#   7. The file /.rootfs-resize, which is created when the partitions
#   are adjusted in phase 1, must exist to start phase 2.
#
#   8. If the file /.swapsize exists when phase 2 is processed,
#   and it contains a text representation of a non-zero whole number,
#   and the file /swap0 does not exist, then a swapfile named /swap0
#   will be created. The size of the swapfile will be the number in
#   /.swapsize interpreted as megabytes. This swapfile will be added to
#   /etc/fstab and activated.
#
#   Requirements (Fedora package name as of F17):
#   - python 2.7+ (python)
#   - pyparted (pyparted)
#   - psutil (python-psutil)
#   - /sbin/resize2fs (e2fsprogs)
#   - /sbin/mkswap (util-linux)
#
#   Optional requirements (recommended):
#   - /usr/bin/ionice (util-linux)
#   - /sbin/swapon (util-linux)

#   Copyright (C)2013 Chris Tyler, Seneca College, and others
#   (see Authors, above).
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#   MA  02110-1301  USA
#

import parted
import re
import sys
import psutil
import ast
import os
import glob

abort_blocked = False;

# Check that the kernel command line parameter 'nofsresize' was NOT specified
for line in open('/proc/cmdline'):
    if 'nofsresize' in line:
        abort_blocked = True

# Check that /.nofsresize is NOT present
if os.path.isfile('/.nofsresize'):
    abort_blocked = True

# Abort due to either of the above
if abort_blocked:
    sys.exit(1)

# Find the root device
for line in open('/proc/self/mountinfo'):
    if '/ / ' in line:
        root_major_minor = line.split(' ')[2]
        break

major=int(root_major_minor.split(":")[0])
minor=int(root_major_minor.split(":")[1])

# We now have the major/minor of the root device.
# Scan devices to find the corresponding block device.
# This is necessary because the device name reported in
# /proc/self/mountinfo may be /dev/root
root_device = ''
for blockdev in glob.glob("/dev/sd??*")+glob.glob("/dev/mmcblk*p*"):
    rdev=os.stat(blockdev).st_rdev
    if os.major(rdev) == major and os.minor(rdev) == minor:
        root_device = blockdev
        break

# If the root device is a partion, find the disk containing it
disk_device = ''
for pattern in [ '/dev/sd.', '/dev/mmcblk.' ]:
    match = re.match(pattern, root_device)
    if match:
        disk_device = root_device[:match.span()[1]]
        break

# Exit if we didn't find a disk_device
if not disk_device:
    sys.exit(2)

# PHASE 1
# If /.rootfs-repartition exists, repartition the disk, then reboot
if os.path.isfile('/.rootfs-repartition'):

    print("Attempting to resize / partition...")
    print("  / partition    : %s" % root_device)
    print("  / disk         : %s" % disk_device)

    # Create block device and disk label objects
    device = parted.Device(disk_device)
    disk = parted.Disk(device)

    # Find root partition and do sanity checks
    root = disk.getPartitionByPath(root_device)

    constraint = device.getConstraint()

    # Find the proposed end of the root partition.
    # This try/except is a workaround for pyparted ticket #50 -
    # see https://fedorahosted.org/pyparted/ticket/50
    try:
        new_end = root.getMaxGeometry(constraint).end
    except TypeError:
        new_end = root.getMaxGeometry(constraint.getPedConstraint()).end

    # If it's a ext[234] filesystem and the partition end can grow,
    # change the partition ending and then reboot
    if (root.fileSystem.type == 'ext2'
        or root.fileSystem.type == 'ext3'
        or root.fileSystem.type == 'ext4' ) \
        and root.geometry.end < new_end:

        newGeom = parted.Geometry(disk.device, start=root.geometry.start, end=new_end)
        constraint = parted.Constraint(exactGeom=newGeom)
        maxGeom = disk.calculateMaxPartitionGeometry(partition = root, constraint=constraint)

        disk.setPartitionGeometry(partition = root, constraint = constraint,
            start = maxGeom.start, end = maxGeom.end)

        print("  Partition type : %s" % root.fileSystem.type)
        print("  Old start block: %s" % root.geometry.start)
        print("  Old end block  : %s" % root.geometry.end)
        print("  New end block  : %s" % new_end)
        print("")
        print("Committing partition change...")
        # disk.commit() will usually throw an exception because the kernel
        # is using the rootfs and refuses to accept the new partition table
        # ... so we call partprobe
        try:
            disk.commit()
        except:
            pass

    else:
        print('Unable to resize root partition (max size, or unresizable fs type).')

    # Change flagfiles and reboot
    open('/.rootfs-resize','w').close()
    os.unlink('/.rootfs-repartition')
    print("Reloading kernel partition table...")
    os.system('/sbin/partprobe')

# PHASE 2
# If /.rootfs-resize exists, resize the filesystem
elif os.path.isfile('/.rootfs-resize'):

    print("Resizing / to fill partition...")
    # Use ionice if available
    if os.path.isfile('/usr/bin/ionice'):
        os.system('/usr/bin/ionice -c2 -n7 /sbin/resize2fs %s' % root_device )
    else:
        os.system('/sbin/resize2fs %s' % root_device )

    # Create swap if requested
    if os.path.isfile('/.swapsize'):

        swapsizefile = open('/.swapsize')
        try:
            swapsize = ast.literal_eval(swapsizefile.readline())
        except:
            swapsize = 0

        swapsizefile.close()

        # Create /swap0 as a swapfile if it doesn't exist and
        # the requested size in MB is greater than 0
        if ( not os.path.isfile('/swap0') ) and swapsize > 0:

            # Lower the I/O priority to minimum best-effort
            psutil.Process(os.getpid()).set_ionice(psutil.IOPRIO_CLASS_BE, 7)

            # Create swap file as swap0.part (so we recreate if aborted)
            MB = ' ' * (1024*1024)
            swapfile = open('/swap0.part','w')
            for X in range(swapsize):
                swapfile.write(MB)

            # Make it a swapfile
            os.system('/sbin/mkswap /swap0.part')

            # Rename the swapfile to /swap0
            os.rename('/swap0.part','/swap0')

        # Add /swap0 to the fstab if not already present
        abort_fstab = False
        for line in open('/etc/fstab'):
            if re.match('/swap0', line):
                abort_fstab = True
                break

        if not abort_fstab:
            fstab = open('/etc/fstab','a')
            fstab.write('/swap0\t\t\tswap\tswap\n')
            fstab.close()

        # Activate all swap spaces if possible
        if os.path.isfile('/sbin/swapon'):
            os.system('/sbin/swapon -a')

        # Delete swap flagfile
        os.unlink('/.swapsize')

    # Delete resize flagfile
    os.unlink('/.rootfs-resize')
EOF
chmod +x "$chroot_dir/usr/sbin/rootfs-resize"

cat <<EOF > "$chroot_dir/etc/systemd/system/rootfs-resize.service"
[Unit]
Description=Root Filesystem Auto-Resizer
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=base.target

[Service]
Environment=TERM=linux
Type=oneshot
ExecStart=/usr/sbin/rootfs-resize
StandardError=journal+console
StandardOutput=journal+console
RemainAfterExit=no

[Install]
WantedBy=base.target
EOF
mkdir -p "$chroot_dir/etc/systemd/system/multi-user.target.wants/"
chroot "$chroot_dir" ln -s /etc/systemd/system/rootfs-resize.service /etc/systemd/system/multi-user.target.wants/

mount -o bind /proc "$chroot_dir/proc"

### install ubuntu-desktop
chroot "$chroot_dir" apt-get update
chroot "$chroot_dir" apt-get -qy install \
        ubuntu-minimal \
        ubuntu-desktop \
        openssh-server \
        xinput \
        net-tools \
        usbutils \
        pciutils \
        iw \
        accountsservice \
        xserver-xorg-core \
        xserver-xorg \
        xserver-xorg-input-libinput \
        xserver-xorg-video-nouveau \
        linux-firmware \
        libgl1-mesa-dri \
        bluez \
        driconf \
        quicksynergy \
        gnome-tweak-tool \
        materia-gtk-theme \
        python-parted \
        python-psutil \
        sudo

### generate at least a basic locale
chroot "$chroot_dir" locale-gen en_US.UTF-8

### install some newer packages from my PPA
chroot "$chroot_dir" add-apt-repository -y ppa:cmsj/nintendoswitch
chroot "$chroot_dir" apt-get -qy install libdrm-common libdrm-nouveau2 libdrm2
chroot "$chroot_dir" apt-get -qy upgrade

### install RetroArch PPA
chroot "$chroot_dir" add-apt-repository -y ppa:libretro/stable

### install Dolphin PPA
chroot "$chroot_dir" add-apt-repository -y ppa:dolphin-emu/ppa

### install RetroArch and Dolphin
#chroot "$chroot_dir" apt-get -qy install dolphin-emu-master
#chroot '$chroot_dir" apt-get -qy install retroarch libretro-*

# Configuration: DNS
cat <<EOF > "$chroot_dir/etc/resolv.conf"
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# Configuration: user (username: switch password: switch)
chroot "$chroot_dir" useradd -m -s /bin/bash -d /home/switch -p Q4OiRew2o/3Fk switch
if ! [ -d "$chroot_dir/home/switch" ]; then
  # Really not sure why useradd isn't making this
  mkdir -p "$chroot_dir/home/switch"
  chown 1000:1000 "$chroot_dir/home/switch"
fi
chroot "$chroot_dir" adduser switch sudo

# Configuration: autologin
cat <<EOF > "$chroot_dir/etc/gdm3/custom.conf"
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = switch
WaylandEnable = false
[security]
[xdcmp]
[chooser]
[debug]
EOF

# Configuration: touchscreen config
cat <<EOF > "$chroot_dir/etc/udev/rules.d/01-nintendo-switch-libinput-matrix.rules"
ATTRS{name}=="stmfts", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 1 0 -1 0 1"
EOF

mkdir -p "$chroot_dir/home/switch/.config"
cat <<EOF > "$chroot_dir/home/switch/.config/monitors.xml"
<monitors version="2">
  <configuration>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>1</scale>
      <primary>yes</primary>
      <transform>
        <rotation>left</rotation>
        <flipped>no</flipped>
      </transform>
      <monitor>
        <monitorspec>
          <connector>DSI-1</connector>
          <vendor>unknown</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>720</width>
          <height>1280</height>
          <rate>60</rate>
        </mode>
      </monitor>
    </logicalmonitor>
  </configuration>
</monitors>
EOF
chroot "$chroot_dir" chown -R 1000:1000 /home/switch/.config

mkdir -p "$chroot_dir/var/lib/gdm3/.config"
cp "$chroot_dir/home/switch/.config/monitors.xml" "$chroot_dir/var/lib/gdm3/.config"
chroot "$chroot_dir" chown -R gdm:gdm /var/lib/gdm3/.config

# Configuration: disable crazy ambient backlight
mkdir -p "$chroot_dir/etc/dconf/db/local.d"
cat <<EOF > "$chroot_dir/etc/dconf/db/local.d/01-nintendo-switch-disable-ambient-backlight.conf"
[org/gnome/settings-daemon/plugins/power]
ambient-enabled=false
EOF

# Configuration: Add missing firmware definition file for Broadcom driver
# https://bugzilla.kernel.org/show_bug.cgi?id=185661
cat <<EOF > "$chroot_dir/lib/firmware/brcm/brcmfmac4356-pcie.txt"
# Sample variables file for BCM94356Z NGFF 22x30mm iPA, iLNA board with PCIe for production package
NVRAMRev=\$Rev: 492104 $
#4356 chip = 4354 A2 chip
sromrev=11
boardrev=0x1102
boardtype=0x073e
boardflags=0x02400201
#0x2000 enable 2G spur WAR
boardflags2=0x00802000
boardflags3=0x0000000a
#boardflags3 0x00000100 /* to read swctrlmap from nvram*/
#define BFL3_5G_SPUR_WAR   0x00080000   /* enable spur WAR in 5G band */
#define BFL3_AvVim   0x40000000   /* load AvVim from nvram */
macaddr=00:90:4c:1a:10:01
ccode=0x5854
regrev=205
antswitch=0
pdgain5g=4
pdgain2g=4
tworangetssi2g=0
tworangetssi5g=0
paprdis=0
femctrl=10
vendid=0x14e4
devid=0x43ec
manfid=0x2d0
#prodid=0x052e
nocrc=1
otpimagesize=502
xtalfreq=37400
rxgains2gelnagaina0=0
rxgains2gtrisoa0=7
rxgains2gtrelnabypa0=0
rxgains5gelnagaina0=0
rxgains5gtrisoa0=11
rxgains5gtrelnabypa0=0
rxgains5gmelnagaina0=0
rxgains5gmtrisoa0=13
rxgains5gmtrelnabypa0=0
rxgains5ghelnagaina0=0
rxgains5ghtrisoa0=12
rxgains5ghtrelnabypa0=0
rxgains2gelnagaina1=0
rxgains2gtrisoa1=7
rxgains2gtrelnabypa1=0
rxgains5gelnagaina1=0
rxgains5gtrisoa1=10
rxgains5gtrelnabypa1=0
rxgains5gmelnagaina1=0
rxgains5gmtrisoa1=11
rxgains5gmtrelnabypa1=0
rxgains5ghelnagaina1=0
rxgains5ghtrisoa1=11
rxgains5ghtrelnabypa1=0
rxchain=3
txchain=3
aa2g=3
aa5g=3
agbg0=2
agbg1=2
aga0=2
aga1=2
tssipos2g=1
extpagain2g=2
tssipos5g=1
extpagain5g=2
tempthresh=255
tempoffset=255
rawtempsense=0x1ff
pa2ga0=-147,6192,-705
pa2ga1=-161,6041,-701
pa5ga0=-194,6069,-739,-188,6137,-743,-185,5931,-725,-171,5898,-715
pa5ga1=-190,6248,-757,-190,6275,-759,-190,6225,-757,-184,6131,-746
subband5gver=0x4
pdoffsetcckma0=0x4
pdoffsetcckma1=0x4
pdoffset40ma0=0x0000
pdoffset80ma0=0x0000
pdoffset40ma1=0x0000
pdoffset80ma1=0x0000
maxp2ga0=76
maxp5ga0=74,74,74,74
maxp2ga1=76
maxp5ga1=74,74,74,74
cckbw202gpo=0x0000
cckbw20ul2gpo=0x0000
mcsbw202gpo=0x99644422
mcsbw402gpo=0x99644422
dot11agofdmhrbw202gpo=0x6666
ofdmlrbw202gpo=0x0022
mcsbw205glpo=0x88766663
mcsbw405glpo=0x88666663
mcsbw805glpo=0xbb666665
mcsbw205gmpo=0xd8666663
mcsbw405gmpo=0x88666663
mcsbw805gmpo=0xcc666665
mcsbw205ghpo=0xdc666663
mcsbw405ghpo=0xaa666663
mcsbw805ghpo=0xdd666665
mcslr5glpo=0x0000
mcslr5gmpo=0x0000
mcslr5ghpo=0x0000
sb20in40hrpo=0x0
sb20in80and160hr5glpo=0x0
sb40and80hr5glpo=0x0
sb20in80and160hr5gmpo=0x0
sb40and80hr5gmpo=0x0
sb20in80and160hr5ghpo=0x0
sb40and80hr5ghpo=0x0
sb20in40lrpo=0x0
sb20in80and160lr5glpo=0x0
sb40and80lr5glpo=0x0
sb20in80and160lr5gmpo=0x0
sb40and80lr5gmpo=0x0
sb20in80and160lr5ghpo=0x0
sb40and80lr5ghpo=0x0
dot11agduphrpo=0x0
dot11agduplrpo=0x0
phycal_tempdelta=255
temps_period=15
temps_hysteresis=15
rssicorrnorm_c0=4,4
rssicorrnorm_c1=4,4
rssicorrnorm5g_c0=1,2,3,1,2,3,6,6,8,6,6,8
rssicorrnorm5g_c1=1,2,3,2,2,2,7,7,8,7,7,8
EOF

# Configuration: Capture lots of information onto SD, since I still can't actually execute stuff directly on the Switch
cat <<'EOF' > "$chroot_dir/etc/rc.local"
#!/bin/sh
# FIXME: Setting the GPU clock should really be a systemd startup job
pstate_file=$(find /sys/kernel/debug/dri/ -name pstate | head -1)
echo 0a > $pstate_file
sync
EOF
chmod +x "$chroot_dir/etc/rc.local"

# Cleanup: man-db does not work via qemu-user
chroot "$chroot_dir" rm /usr/bin/mandb
chroot "$chroot_dir" dpkg-divert --local --rename --remove /usr/bin/mandb

### cleanup and unmount /proc
chroot "$chroot_dir" apt-get autoclean
chroot "$chroot_dir" apt-get clean
chroot "$chroot_dir" apt-get autoremove
rm "$chroot_dir/etc/resolv.conf"
umount "$chroot_dir/proc"

### create a tar archive from the chroot directory
TAROPTS="cf"
if [[ "${tarball}" == *z ]]; then
    TAROPTS="${TAROPTS}z"
fi
tar ${TAROPTS} "${tarball}" -C "$chroot_dir" .

# ### cleanup
#rm $os_$arch_$suite.tar.gz
#rm -rf "$chroot_dir"

echo "Finished building ubuntu rootfs."
