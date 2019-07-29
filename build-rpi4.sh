#!/bin/bash -e

# This script is executed within the container as root. The resulting image &
# logs are written to /output after a succesful build.  These directories are 
# mounted as docker volumes to allow files to be exchanged between the host and 
# the container.

branch=rpi-4.19.y
kernelgitrepo="https://github.com/raspberrypi/linux.git"
#branch=bcm2711-initial-v5.2
#kernelgitrepo="https://github.com/lategoodbye/rpi-zero.git"
# This should be the image we want to modify.
ubuntu_image="eoan-preinstalled-server-arm64+raspi3.img.xz"
ubuntu_image_url="http://cdimage.ubuntu.com/ubuntu-server/daily-preinstalled/current/${ubuntu_image}"
# This is the base name of the image we are creating.
new_image="eoan-preinstalled-server-arm64+raspi4"


# Set Time Stamp
now=`date +"%m_%d_%Y_%H%M"`

# Logging Setup
TMPLOG=/tmp/build.log
touch $TMPLOG
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>$TMPLOG 2>&1

# Use ccache
PATH=/usr/lib/ccache:$PATH
CCACHE_DIR=/ccache
# Change these settings if you need them to be different.
ccache -M 0
ccache -F 0
# Show ccache stats
#echo "Build ccache stats:"
#ccache -s
# Create work directory
mkdir -p /build/source
#cp -a /source-ro/ /build/source






checkfor_and_download_ubuntu_image () {
    echo "Checking for downloaded ${ubuntu_image}"
    cd /build/source
    if [ ! -f /${ubuntu_image} ]; then
        echo "Downloading ${ubuntu_image}"
        wget $ubuntu_image_url -O $ubuntu_image
    else
        ln -s /$ubuntu_image /build/source/
    fi
}

extract_and_mount_image () {
    echo "* Extracting: ${ubuntu_image} to ${new_image}.img"
    xzcat /build/source/$ubuntu_image > /build/source/$new_image.img
    #echo "* Increasing image size by 200M"
    #dd if=/dev/zero bs=1M count=200 >> /build/source/$new_image.img
    echo "* Clearing existing loopback mounts."
    losetup -d /dev/loop0
    dmsetup remove_all
    losetup -a
    cd /build/source
    echo "Mounting: ${new_image}.img"

    kpartx -av ${new_image}.img
    #e2fsck -f /dev/loop0p2
    #resize2fs /dev/loop0p2
    mount /dev/mapper/loop0p2 /mnt
    mount /dev/mapper/loop0p1 /mnt/boot/firmware
    echo "* Extraction of ${ubuntu_image} to ${new_image}.img done."
    # Guestmount is at least an order of magnitude slower than using loopback device.
    #guestmount -a ${new_image}.img -m /dev/sda2 -m /dev/sda1:/boot/firmware --rw /mnt -o dev

}

setup_arm64_chroot () {
    echo "* Setup ARM64 chroot"
    cp /usr/bin/qemu-aarch64-static /mnt/usr/bin
    

    mount -t proc proc     /mnt/proc/
#    mount -t sysfs sys     /mnt/sys/
#    mount -o bind /dev     /mnt/dev/
#    mount -o bind /dev/pts /mnt/dev/pts
#    mknod -m 0666 /mnt/dev/null c 1 3
    mount --bind /apt_cache /mnt/var/cache/apt
 #   chmod -R 777 /mnt/var/lib/apt/
 #   setfacl -R -m u:_apt:rwx /mnt/var/lib/apt/ 
    mkdir /mnt/ccache || ls -aFl /mnt
    mount --bind /ccache /mnt/ccache
    mount --bind /run /mnt/run
    mkdir -p /run/systemd/resolve
    cp /etc/resolv.conf /run/systemd/resolve/stub-resolv.conf
    rsync -avh --devices --specials /run/systemd/resolve /mnt/run/systemd
    
    mkdir -p /mnt/build
    mount -o bind /build /mnt/build
   
    
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    update -qq > /dev/null
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=/apt_cache \
    upgrade -d -y -qq > /dev/null
    #-o Acquire::GzipIndexes=false \
    #-o Dir::State=/mnt/var/lib/apt \
    
    chroot /mnt /bin/bash -c "/usr/bin/apt-get upgrade -y -qq > /dev/null"
    #-o dir::cache::archives=/build/src/apt/archives \
    #upgrade -y"
    
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=/apt_cache \
    install -d -y --no-install-recommends \
               build-essential \
               bc \
               bison \
               ccache \
               cdbs \
               cmake \
               cpio \
               devscripts \
               dkms \
               dpkg-dev \
               equivs \
               fakeroot \
               flex \
               gawk \
               gcc \
               cpp \
               g++  \
               git \
               kpartx \
               lz4 \
               libelf-dev \
               libncurses-dev \
               libssl-dev \
               qemu-user-static \
               patch \
               rsync \
               sudo \
               wget \
               xz-utils -qq > /dev/null
    #sed -i -- 's/# deb-src/deb-src/g' /mnt/etc/apt/sources.list
    chroot /mnt /bin/bash -c "apt update && /usr/bin/apt-get \
    install -y --no-install-recommends \
               build-essential \
               bc \
               bison \
               ccache \
               cdbs \
               cmake \
               cpio \
               devscripts \
               dkms \
               dpkg-dev \
               equivs \
               fakeroot \
               flex \
               gawk \
               gcc \
               cpp \
               g++  \
               git \
               kpartx \
               lz4 \
               libelf-dev \
               libncurses-dev \
               libssl-dev \
               qemu-user-static \
               patch \
               rsync \
               sudo \
               wget \
               xz-utils -qq > /dev/null"
    #chroot /mnt /bin/bash -c "apt build-dep -y linux-image-raspi2"
    #sed -i -- 's/deb-src/# deb-src/g' /mnt/etc/apt/sources.list
    #install gcc make flex bison libssl-dev -y"
    #-o dir::cache::archives=/build/src/apt/archives \
    #install gcc make flex bison libssl-dev -y"
    echo "* ARM64 chroot is setup" 
}

get_rpi_firmware () {
    cd /build/source
    echo "* Downloading current RPI firmware."
    git clone --quiet --depth=1 https://github.com/Hexxeh/rpi-firmware
}

install_rpi_firmware () {
    cd /build/source
    echo "* Installing current RPI firmware."
    cp rpi-firmware/bootcode.bin /mnt/boot/firmware/
    cp rpi-firmware/*.elf /mnt/boot/firmware/
    cp rpi-firmware/*.dat /mnt/boot/firmware/
    cp rpi-firmware/*.dat /mnt/boot/firmware/
    cp rpi-firmware/*.dtb /mnt/boot/firmware/
    cp rpi-firmware/overlays/*.dtbo /mnt/boot/firmware/overlays/
}

get_kernel_src () {
    echo "* Downloading $branch kernel source."
    cd /build/source
    git clone --quiet --depth=1 -b $branch $kernelgitrepo rpi-linux
    kernelrev=`cd /build/source/rpi-linux ; git rev-parse HEAD`
}

build_kernel () {
    echo "* Building $branch kernel."
    cd /build/source/rpi-linux
    #git checkout origin/rpi-4.19.y # change the branch name for newer versions
    mkdir /build/source/kernel-build
    
    [ ! -f arch/arm64/configs/bcm2711_defconfig ] && \
    wget https://raw.githubusercontent.com/raspberrypi/linux/rpi-5.2.y/arch/arm64/configs/bcm2711_defconfig \
    -O arch/arm64/configs/bcm2711_defconfig
    
    make O=/build/source/kernel-build ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- bcm2711_defconfig
    
    cd /build/source/kernel-build
    # Use kernel config modification script from sakaki- found at 
    # https://github.com/sakaki-/bcm2711-kernel-bis
    /source-ro/conform_config.sh
    yes "" | make O=./build/source/kernel-build/ \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    cd ..

    cd /build/source/rpi-linux
    make -j $(($(nproc) + 1)) O=/build/source/kernel-build \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
    
    KERNEL_VERSION=`cat /build/source/kernel-build/include/generated/utsrelease.h | \
    sed -e 's/.*"\(.*\)".*/\1/'`
    echo "* Regenerating broken cross-compile module installation infrastructure."
    # Cross-compilation of kernel wreaks havoc with building out of kernel modules
    # later, so let's fix this with natively compiled module tools.
    files=("scripts/recordmcount" "scripts/mod/modpost" \
        "scripts/basic/fixdep")
        
    for i in "${files[@]}"
    do
     rm /build/source/kernel-build/$i || true
    done
    chroot /mnt /bin/bash -c "cd /build/source/rpi-linux ; \
    CCACHE_DIR=/ccache PATH=/usr/lib/ccache:$PATH make -j $(($(nproc) + 1)) \
    O=/build/source/kernel-build modules_prepare"

    mkdir -p /build/source/kernel-build/tmp/scripts/mod
    mkdir -p /build/source/kernel-build/tmp/scripts/basic
    for i in "${files[@]}"
    do
     cp /build/source/kernel-build/$i /build/source/kernel-build/tmp/$i
     rm /build/source/kernel-build/$i
     sed -i "/.tmp_quiet_recordmcount$/i TABTMP\$(Q)cp /build/source/kernel-build/tmp/${i} ${i}" \
     /build/source/rpi-linux/Makefile
    done
    TAB=$'\t'
    sed -i "s/TABTMP/${TAB}/g" /build/source/rpi-linux/Makefile
    
    # Now we have qemu-static & arm64 binaries installed, so we copy libraries over
    # from image to build container in case they are needed during this install.
    cp /mnt/usr/lib/aarch64-linux-gnu/libc.so.6 /lib64/
    cp /mnt/lib/ld-linux-aarch64.so.1 /lib/
    
    aarch64-linux-gnu-gcc -static /build/source/rpi-linux/scripts/basic/fixdep.c -o \
    /build/source/kernel-build/tmp/scripts/basic/fixdep
    
    aarch64-linux-gnu-gcc -static /build/source/rpi-linux/scripts/recordmcount.c -o \
    /build/source/kernel-build/tmp/scripts/recordmount

    make -j $(($(nproc) + 1)) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    O=/build/source/kernel-build bindeb-pkg
    cp /build/source/*.deb /output/ 
    #make -j $(($(nproc) + 1)) O=/usr/src/linux-headers-${KERNEL_VERSION} modules_prepare ;\
    #make -j $(($(nproc) + 1)) O=/build/source/kernel-build ARCH=arm64 bindeb-pkg"
    
    mkdir /build/source/kernel-install
#    sed '/^a.tmp_quiet_recordmcount/i $(Q)cp ' Makefile
    sudo make -j $(($(nproc) + 1)) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    O=/build/source/kernel-build DEPMOD=echo \
    INSTALL_MOD_PATH=/build/source/kernel-install \
    modules_install
}

install_kernel () {
    echo "* Copying compiled ${KERNEL_VERSION} kernel to image."
    df -h
    cd /build/source
    # Ubuntu defaults to using uBoot, which doesn't work yet for RPI4.
    # Replacee uBoot with kernel.
    cp /build/source/kernel-build/arch/arm64/boot/Image /mnt/boot/firmware/kernel8.img
    # Once uBoot works, it should be able to use the standard raspberry pi boot
    # script to boot the compressed kernel on arm64, so we copy this in anyways.
    cp /build/source/kernel-build/arch/arm64/boot/Image.gz \
    /mnt/boot/vmlinuz-${KERNEL_VERSION}
    
    cp /build/source/kernel-build/arch/arm64/boot/Image.gz \
    /mnt/boot/firmware/vmlinuz
    
    cp /build/source/kernel-build/.config /mnt/boot/config-${KERNEL_VERSION}

    echo "* Copying compiled ${KERNEL_VERSION} modules to image."
    #rm  -rf /build/source/kernel-install/lib/modules/build
    cp -avr /build/source/kernel-install/lib/modules/* \
    /mnt/usr/lib/modules/
    
    rm  -rf /mnt/usr/lib/modules/${KERNEL_VERSION}/build 

    echo "* Copying compiled ${KERNEL_VERSION} dtbs & dtbos to image."
    cp /build/source/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb /mnt/boot/firmware/
    cp /build/source/kernel-build/arch/arm64/boot/dts/overlays/*.dtbo \
    /mnt/boot/firmware/overlays/
    
    cp /build/source/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb \
    /mnt/etc/flash-kernel/dtbs/
    

}

install_kernel_headers () {
     echo "* Copying ${KERNEL_VERSION} kernel headers to image."
#     mkdir -p /mnt/usr/src/linux-headers-${KERNEL_VERSION}
# 
#     cp /build/source/kernel-build/.config /build/source/rpi-linux/
#     chroot /mnt /bin/bash -c "cd /build/source/rpi-linux ; \
#     make -j $(($(nproc) + 1)) O=/usr/src/linux-headers-${KERNEL_VERSION} oldconfig ;\
#     rm .config"
#     
#     
#     rm /mnt/usr/src/linux-headers-${KERNEL_VERSION}/source
#     cp /build/source/kernel-build/Module.symvers /mnt/usr/src/linux-headers-${KERNEL_VERSION}/
}

get_armstub8-gic () {
    echo "* Get RPI4 armstub8-gic source."
    cd /build/source
    git clone --quiet --depth=1 https://github.com/raspberrypi/tools.git rpi-tools
}

install_armstub8-gic () {
    echo "* Installing RPI4 armstub8-gic source."
    cd /build/source/rpi-tools/armstubs
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- armstub8-gic.bin
    cd ../..
    cp rpi-tools/armstubs/armstub8-gic.bin /mnt/boot/firmware/armstub8-gic.bin
}

get_non-free_firmware () {
    echo "* Getting non-free firmware."
    cd /build/source
    git clone --quiet --depth=1 https://github.com/RPi-Distro/firmware-nonfree firmware-nonfree
}

install_non-free_firmware () {
    echo "* Installing non-free firmware."
    cd /build/source
    cp -avf firmware-nonfree/* /mnt/usr/lib/firmware
}


configure_rpi_config_txt () {
    echo "* Making /boot/firmware/config.txt modifications."
    echo "armstub=armstub8-gic.bin" >> /mnt/boot/firmware/config.txt
    echo "enable_gic=1" >> /mnt/boot/firmware/config.txt
    if ! grep -qs 'arm_64bit=1' /mnt/boot/firmware/config.txt
        then echo "arm_64bit=1" >> /mnt/boot/firmware/config.txt
    fi
    if ! grep -qs 'kernel8.bin' /mnt/boot/firmware/config.txt
        then sed -i -r 's/kernel8.bin/kernel8.img/' /mnt/boot/firmware/config.txt
    fi
    
    if ! grep -qs 'initramfs' /mnt/boot/firmware/config.txt
        then echo "initramfs initrd.img followkernel" >> /mnt/boot/firmware/config.txt
    fi
}

get_rpi_userland () {
    echo "* Getting Raspberry Pi userland source."
    cd /build/source
    git clone --quiet --depth=1 https://github.com/raspberrypi/userland
}

install_rpi_userland () {
    echo "* Installing Raspberry Pi userland source."
    cd /build/source
    mkdir -p /mnt/opt/vc
    cd userland/
    CROSS_COMPILE=aarch64-linux-gnu- ./buildme --aarch64 /mnt
    echo '/opt/vc/lib' > /mnt/etc/ld.so.conf.d/vc.conf 
    mkdir -p /mnt/etc/environment.d
    tee /mnt/etc/environment.d/10-vcgencmd.conf <<EOF
# /etc/env.d/00vcgencmd
# Do not edit this file
    
PATH="/opt/vc/bin:/opt/vc/sbin"
ROOTPATH="/opt/vc/bin:/opt/vc/sbin"
LDPATH="/opt/vc/lib"
EOF
    chmod +x /mnt/etc/environment.d/10-vcgencmd.conf
    # cd ..
}

modify_wifi_firmware () {
    echo "* Modifying wireless firmware."
    # as per https://andrei.gherzan.ro/linux/raspbian-rpi4-64/
    if ! grep -qs 'boardflags3=0x44200100' \
    /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
        then sed -i -r 's/0x48200100/0x44200100/' \
        /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
    fi
}

install_first_start_cleanup_script () {
    echo "* Creating first start cleanup script."
    tee /mnt/etc/rc.local <<EOF
#!/bin/sh -e
# 1st Boot Cleanup Script
#
# Print the IP address
_IP=\$(hostname -I) || true
if [ "\$_IP" ]; then
 printf "My IP address is %s\n" "\$_IP"
fi
#
/usr/bin/dpkg -i /var/cache/apt/archive/*.deb
/usr/bin/apt remove linux-image-raspi2 -y
#cd /usr/src
#/usr/bin/git clone --depth=1 -b $branch $kernelgitrepo \
#linux-headers-${KERNEL_VERSION}
#/usr/bin/git checkout $kernelrev
rm /etc/rc.local
exit 0
EOF
    chmod +x /mnt/etc/rc.local
} 

make_kernel_install_scripts () {
    # This script allows flash-kernel to create the uncompressed kernel file
    # on the boot partition.
    echo "* Making kernel install scripts."
    mkdir -p /mnt/etc/kernel/postinst.d
    echo "Creating /mnt/etc/kernel/postinst.d/zzzz_rpi4_kernel ."
    tee /mnt/etc/kernel/postinst.d/zzzz_rpi4_kernel <<EOF
#!/bin/sh -eu
COMMAND="\$1"
KERNEL_VERSION="\$2"
#BOOT_DIR_ABS="\$3"

gunzip -c -f \mis$KERNEL_VERSION > /boot/firmware/kernel8.img
exit 0
EOF
    
    chmod +x /mnt/etc/kernel/postinst.d/zzzz_rpi4_kernel
    
    # This allows flash-kernel to copy ther kernel so that it can 
    # be copied to the boot partition.
    mkdir -p /mnt/etc/flash-kernel/
    echo "Creating /mnt/etc/flash-kernel/db ."
    tee /mnt/etc/flash-kernel/db <<EOF
#
# Raspberry Pi 4 Model B Rev 1.1
DTB-Id: /etc/flash-kernel/dtbs/bcm2711-rpi-4-b.dtb
Boot-DTB-Path: /boot/firmware/bcm2711-rpi-4-b.dtb
Boot-Kernel-Path: /boot/firmware/vmlinuz
Boot-Initrd-Path: /boot/firmware/initrd.img
EOF

}

cleanup_image_remove_chroot () {
    echo "* Finishing image setup."

    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=/apt_cache \
    -d install wireless-tools wireless-regdb crda -y -qq > /dev/null
    
    chroot /mnt /bin/bash -c "/usr/bin/apt-get \
    install wireless-tools wireless-regdb crda -y -qq > /dev/null"
    
    
    echo "* Cleaning up arm64 chroot"
    chroot /mnt /bin/bash -c "/usr/bin/apt-get \
    autoclean -y -qq > /dev/null"
    
    # binfmt-support wreaks havoc with container, so let it get 
    # installed at first boot.
    umount /mnt/var/cache/apt
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=/mnt/var/cache/apt \
    -d install binfmt-support -y -qq > /dev/null
        

    
    # Copy in kernel debs generated earlier to be installed at
    # first boot.
    cp /build/source/*.deb /var/cache/apt/archives/
    sync
    umount /mnt/build
    umount /mnt/run
    umount /mnt/ccache
    rmdir /mnt/ccache
    umount /mnt/proc
    #umount /mnt/sys
    # This is no longer needed.
    rm /mnt/usr/bin/qemu-aarch64-static
}

unmount_image () {
    echo "* Unmounting modified ${new_image}.img"
    sync
    umount /mnt/boot/firmware
    umount /mnt || (mount | grep /mnt)
    #guestunmount /mnt

    
    kpartx -dv /build/source/${new_image}.img
    #losetup -d /dev/loop0
    dmsetup remove_all
}

export_compressed_image () {
    echo "* Compressing ${new_image} with lz4 and exporting"
    echo "  out of container to:"
    echo "${new_image}-${KERNEL_VERSION}_${now}.img.lz4"
    cd /build/source
    chown -R $USER:$GROUP /build
    compresscmd="lz4 ${new_image}.img \
    /output/${new_image}-${KERNEL_VERSION}_${now}.img.lz4"
    echo $compresscmd
    $compresscmd
}

export_log () {
    echo "* Build log at: build-log-${KERNEL_VERSION}_${now}.log"
    cat $TMPLOG > /output/build-log-${KERNEL_VERSION}_${now}.log
    chown $USER:$GROUP /output/build-log-${KERNEL_VERSION}_${now}.log
}

checkfor_and_download_ubuntu_image 
get_kernel_src &
get_rpi_firmware &
get_armstub8-gic &
get_non-free_firmware &
get_rpi_userland &
extract_and_mount_image
setup_arm64_chroot
install_rpi_firmware
# KERNEL_VERSION is set here:
build_kernel
install_armstub8-gic
install_non-free_firmware
configure_rpi_config_txt &
install_rpi_userland
modify_wifi_firmware &
install_first_start_cleanup_script &
make_kernel_install_scripts &
install_kernel
#install_kernel_headers 
cleanup_image_remove_chroot
unmount_image
export_compressed_image
export_log
# This stops the tail process.
rm $TMPLOG
