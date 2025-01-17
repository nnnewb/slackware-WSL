#!/bin/bash
# Generate a very minimal filesystem from slackware

if [ -z "$ARCH" ]; then
  case "$( uname -m )" in
    i?86) ARCH="" ;;
    arm*) ARCH=arm ;;
       *) ARCH=64 ;;
  esac
fi

VERBOSE=${VERBOSE:-""} # unused yet
BUILD_NAME=${BUILD_NAME:-"slackware"}
VERSION=${VERSION:="current"}
RELEASENAME=${RELEASENAME:-"slackware${ARCH}"}
RELEASE=${RELEASE:-"${RELEASENAME}-${VERSION}"}
MIRROR=${MIRROR:-"http://mirrors.ustc.edu.cn/slackware"}
CACHEFS=${CACHEFS:-"/tmp/${BUILD_NAME}/${RELEASE}"}
ROOTFS=${ROOTFS:-"/tmp/rootfs-${RELEASE}"}
CWD=$(pwd)

base_pkgs="a/aaa_base \
	a/aaa_elflibs \
	a/coreutils \
	a/glibc-solibs \
	a/aaa_terminfo \
	a/pkgtools \
	a/shadow \
	a/tar \
	a/xz \
	a/bash \
	a/etc \
	a/gzip \
	l/pcre2 \
	l/libpsl \
	n/wget \
	n/gnupg \
	a/elvis \
	ap/slackpkg \
	l/ncurses \
	a/bin \
	a/bzip2 \
	a/grep \
	a/sed \
	a/dialog \
	a/file \
	a/gawk \
	a/time \
	a/gettext \
	a/libcgroup \
	a/patch \
	a/sysfsutils \
	a/time \
	a/tree \
	a/utempter \
	a/which \
	a/util-linux \
	l/mpfr \
	l/libunistring \
	ap/diffutils \
	a/procps \
	n/net-tools \
	a/findutils \
	n/iproute2 \
	n/openssl"

function cacheit() {
	file=$1
	if [ ! -f "${CACHEFS}/${file}"  ] ; then
		mkdir -vp $(dirname ${CACHEFS}/${file})
		echo "Fetching ${MIRROR}/${RELEASE}/${file}" >&2
		curl -s -o "${CACHEFS}/${file}" "${MIRROR}/${RELEASE}/${file}"
	fi
	echo "/cdrom/${file}"
}

mkdir -vp $ROOTFS $CACHEFS

cacheit "isolinux/initrd.img"

cd $ROOTFS
# extract the initrd to the current rootfs
## ./slackware64-14.2/isolinux/initrd.img:    gzip compressed data, last modified: Fri Jun 24 21:14:48 2016, max compression, from Unix, original size 68600832
## ./slackware64-current/isolinux/initrd.img: XZ compressed data
if $(file ${CACHEFS}/isolinux/initrd.img | grep -wq XZ) ; then
	xzcat "${CACHEFS}/isolinux/initrd.img" | cpio -idm --null --no-absolute-filenames
else
	zcat "${CACHEFS}/isolinux/initrd.img" | cpio -idm --null --no-absolute-filenames
fi

if stat -c %F $ROOTFS/cdrom | grep -q "symbolic link" ; then
	rm -v $ROOTFS/cdrom
fi
mkdir -vp $ROOTFS/{mnt,cdrom,dev,proc,sys}

for dir in cdrom dev sys proc ; do
	if mount | grep -q $ROOTFS/$dir  ; then
		umount -vf $ROOTFS/$dir
	fi
done

mount -v --bind $CACHEFS ${ROOTFS}/cdrom
mount -v -t devtmpfs none ${ROOTFS}/dev
mount -v --bind -o ro /sys ${ROOTFS}/sys
mount -v --bind /proc ${ROOTFS}/proc

mkdir -vp mnt/etc
cp -v etc/ld.so.conf mnt/etc

# older versions than 13.37 did not have certain flags
install_args=""
if [ -f ./sbin/upgradepkg ] &&  grep -qw terse ./sbin/upgradepkg ; then
	install_args="--install-new --reinstall --terse"
elif [ -f ./sbin/installpkg ] && grep -qw terse ./sbin/installpkg ; then
	install_args="--terse"
elif [ -f ./usr/lib/setup/installpkg ] &&  grep -qw terse ./usr/lib/setup/installpkg ; then
	install_args="--terse"
fi

relbase=$(echo ${RELEASE} | cut -d- -f1)
if [ ! -f ${CACHEFS}/paths ] ; then
	echo 'run get_paths.sh -r ${RELEASE} > ${CACHEFS}/paths...'
	MIRROR=${MIRROR} bash ${CWD}/get_paths.sh -r ${RELEASE} > ${CACHEFS}/paths
fi

for pkg in ${base_pkgs}
do
	path=$(grep ^${pkg} ${CACHEFS}/paths | cut -d : -f 1)
	if [ ${#path} -eq 0 ] ; then
		echo "$pkg not found"
		continue
	fi

	l_pkg=$(cacheit $relbase/$path)
	if [ -e ./sbin/upgradepkg ] ; then
		echo "upgradepkg ${l_pkg}..."
		PATH=/bin:/sbin:/usr/bin:/usr/sbin chroot . /sbin/upgradepkg --root /mnt ${install_args} ${l_pkg}
	elif [ -e ./sbin/installpkg ]; then
		echo "installpkg ${l_pkg}..."
		PATH=/bin:/sbin:/usr/bin:/usr/sbin chroot . /sbin/installpkg --root /mnt ${install_args} ${l_pkg}
	else
		echo "installpkg ${l_pkg}..."
		PATH=/bin:/sbin:/usr/bin:/usr/sbin chroot . /usr/lib/setup/installpkg --root /mnt ${install_args} ${l_pkg}
	fi
done

cd mnt
set -x
touch etc/resolv.conf
echo "export TERM=linux" >> etc/profile.d/term.sh
chmod +x etc/profile.d/term.sh
echo ". /etc/profile" > .bashrc
echo "${MIRROR}/${RELEASE}/" >> etc/slackpkg/mirrors
sed -i 's/DIALOG=on/DIALOG=off/' etc/slackpkg/slackpkg.conf
sed -i 's/POSTINST=on/POSTINST=off/' etc/slackpkg/slackpkg.conf
sed -i 's/SPINNING=on/SPINNING=off/' etc/slackpkg/slackpkg.conf

mount --bind /etc/resolv.conf etc/resolv.conf
echo 'slackpkg update ...'
chroot . sh -c 'yes y | /usr/sbin/slackpkg -batch=on -default_answer=y update'
echo 'slackpkg upgrade-all ...'
chroot . sh -c '/usr/sbin/slackpkg -batch=on -default_answer=y upgrade-all'

# now some cleanup of the minimal image
set +x
rm -rf var/lib/slackpkg/*
rm -rf usr/share/locale/*
rm -rf usr/man/*
find usr/share/terminfo/ -type f ! -name 'linux' -a ! -name 'xterm' -a ! -name 'screen.linux' -exec rm -f "{}" \;
umount $ROOTFS/dev
rm -f dev/* # containers should expect the kernel API (`mount -t devtmpfs none /dev`)
umount etc/resolv.conf

tar --numeric-owner -czf ${CWD}/${RELEASE}.tar.gz .
ls -sh ${CWD}/${RELEASE}.tar.gz

for dir in cdrom dev sys proc ; do
	if mount | grep -q $ROOTFS/$dir  ; then
		umount $ROOTFS/$dir
	fi
done
