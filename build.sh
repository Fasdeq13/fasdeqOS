#!/bin/bash
set -euo pipefail

if [ "${FASDEQ_INNER:-0}" != 1 ]; then
    [ "$(id -u)" = 0 ] || exec sudo -E bash "$(readlink -f "$0")" "$@"
    command -v podman >/dev/null || { echo "podman не найден"; exit 1; }
    SELF=$(readlink -f "$0")
    OUTDIR=${OUTDIR:-$PWD}
    WORK=$(mktemp -d /var/tmp/fasdeqos.XXXXXX)
    IMG=docker.io/library/ubuntu:24.04
    HAD=0
    podman image exists "$IMG" && HAD=1
    cleanup() {
        podman rm -f fasdeqos-build >/dev/null 2>&1 || true
        [ "$HAD" = 1 ] || podman rmi -f "$IMG" >/dev/null 2>&1 || true
        rm -rf "$WORK"
    }
    trap cleanup EXIT
    echo "Сборка идёт во временном контейнере, зависимости на хосте не ставятся"
    echo "Нужно около 15 ГБ свободного места в /var/tmp и 1-2 часа"
    podman run --name fasdeqos-build --privileged --security-opt label=disable \
        -v /dev:/dev -v "$WORK":/work -v "$OUTDIR":/out -v "$SELF":/fasdeqos.sh:ro \
        -e FASDEQ_INNER=1 -e SELFTEST="${SELFTEST:-}" -e COMP="${COMP:-}" \
        "$IMG" bash /fasdeqos.sh
    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$OUTDIR"/FasdeqOS-*.iso* 2>/dev/null || true
    echo
    echo "Готово: $(ls "$OUTDIR"/FasdeqOS-*.iso | head -1)"
    echo "Контейнер, образ и рабочая папка удалены, на хосте ничего не осталось"
    echo
    echo "Запись на флешку: sudo dd if=FasdeqOS-0.2-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync"
    echo "Проверка в виртуалке: загрузка с ISO, BIOS или UEFI, вход выполняется сам"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
W=${FASDEQ_WORK:-/work}
O=${FASDEQ_OUT:-/out}
S=$W/src
B=$W/build
R=$B/root
J=$(nproc)
LOADER=/System/lib/ld-linux-x86-64.so.2
KVER_TAG=v6.12
NV_VER=580.178.04
say() { echo "==> $*"; }

mkdir -p "$S" "$B" "$O" "$W/logs"
L=$W/logs

say "зависимости сборки (удаляются вместе с контейнером)"
apt-get update >"$L/apt.log" 2>&1
apt-get install -y --no-install-recommends \
    build-essential gcc g++ make cmake ninja-build meson pkg-config git curl ca-certificates \
    xorriso btrfs-progs grub-pc-bin grub-efi-amd64-bin grub-common mtools dosfstools cpio \
    flex bison bc libelf-dev libssl-dev libncurses-dev gawk texinfo gettext python3 \
    bsdextrautils libbsd-dev libmd-dev zlib1g-dev libacl1-dev libattr1-dev libedit-dev \
    bzip2 xz-utils zstd libzstd-dev liblzma-dev libbz2-dev autoconf automake libtool byacc \
    patchelf libpcre2-dev rsync file \
    libarchive-tools inotify-tools flatpak bubblewrap xdg-dbus-proxy bash busybox-static \
    $( [ -n "${SELFTEST:-}" ] && echo qemu-system-x86 ) >>"$L/apt.log" 2>&1

if ! command -v cargo >/dev/null; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal >>"$L/apt.log" 2>&1
fi
export PATH="$HOME/.cargo/bin:$PATH"

clone() {
    local url=$1 dir=$2 tag=${3:-}
    [ -d "$S/$dir/.git" ] && return 0
    if [ -n "$tag" ]; then
        git clone --depth 1 --branch "$tag" "$url" "$S/$dir" >>"$L/clone.log" 2>&1
    else
        git clone --depth 1 "$url" "$S/$dir" >>"$L/clone.log" 2>&1
    fi
}

say "исходники"
clone https://github.com/torvalds/linux.git linux "$KVER_TAG" &
clone https://github.com/bminor/glibc.git glibc glibc-2.40 &
clone https://github.com/chimera-linux/chimerautils.git chimerautils &
clone https://github.com/davmac314/dinit.git dinit v0.19.0 &
clone https://github.com/fish-shell/fish-shell.git fish 4.0.2 &
clone https://github.com/NVIDIA/open-gpu-kernel-modules.git nvidia "$NV_VER" &
clone https://github.com/Juniper/libxo.git libxo &
clone https://github.com/kmod-project/kmod.git kmod &
clone https://github.com/Homebrew/brew.git brew &
wait
FF_TAG=$(git ls-remote --tags --refs https://github.com/fastfetch-cli/fastfetch | awk -F/ '{print $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
clone https://github.com/fastfetch-cli/fastfetch.git fastfetch "$FF_TAG"

OV=$B/overlay
rm -rf "$OV"
mkdir -p "$OV/System/etc/dinit.d" "$OV/System/etc/fish" "$OV/System/etc/modprobe.d" \
    "$OV/System/etc/xdg/fastfetch" "$OV/System/libexec/fasdeqos" "$OV/System/bin"

cat >"$B/init.c" <<'EOF_INIT'
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/loop.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define CONTAINER "/FasdeqOS/container.btrfs"
#define ISO_MNT "/mnt/iso"
#define NEWROOT "/newroot"

static void say(const char *m) { dprintf(2, "[fasdeq-init] %s\n", m); }

static void fail(const char *m)
{
	dprintf(2, "[fasdeq-init] FATAL: %s (errno %d: %s)\n", m, errno, strerror(errno));
	sync();
	for (;;)
		sleep(3600);
}

static void mk(const char *p)
{
	if (mkdir(p, 0755) && errno != EEXIST)
		dprintf(2, "[fasdeq-init] mkdir %s: %s\n", p, strerror(errno));
}

static int find_medium(void)
{
	for (int round = 0; round < 40; round++) {
		DIR *d = opendir("/dev");
		struct dirent *e;
		if (!d)
			fail("opendir /dev");
		while ((e = readdir(d))) {
			const char *n = e->d_name;
			if (strncmp(n, "sr", 2) && strncmp(n, "sd", 2) && strncmp(n, "vd", 2) &&
			    strncmp(n, "hd", 2) && strncmp(n, "nvme", 4) && strncmp(n, "mmcblk", 6))
				continue;
			char path[300];
			snprintf(path, sizeof path, "/dev/%s", n);
			if (mount(path, ISO_MNT, "iso9660", MS_RDONLY, NULL) == 0) {
				if (access(ISO_MNT CONTAINER, R_OK) == 0) {
					dprintf(2, "[fasdeq-init] boot medium: %s\n", path);
					closedir(d);
					return 0;
				}
				umount(ISO_MNT);
			}
		}
		closedir(d);
		if (round == 0)
			say("waiting for boot medium...");
		usleep(500 * 1000);
	}
	return -1;
}

static int attach_loop(const char *file, char *devout, size_t n)
{
	int ctl = open("/dev/loop-control", O_RDWR);
	if (ctl < 0)
		return -1;
	int num = ioctl(ctl, LOOP_CTL_GET_FREE);
	close(ctl);
	if (num < 0)
		return -1;
	snprintf(devout, n, "/dev/loop%d", num);
	int dev = -1;
	for (int i = 0; i < 20 && dev < 0; i++) {
		dev = open(devout, O_RDWR);
		if (dev < 0)
			usleep(100 * 1000);
	}
	if (dev < 0)
		return -1;
	int f = open(file, O_RDONLY);
	if (f < 0) {
		close(dev);
		return -1;
	}
	struct loop_config cfg;
	memset(&cfg, 0, sizeof cfg);
	cfg.fd = f;
	cfg.info.lo_flags = LO_FLAGS_READ_ONLY;
	if (ioctl(dev, LOOP_CONFIGURE, &cfg) < 0) {
		close(f);
		close(dev);
		return -1;
	}
	close(f);
	close(dev);
	return 0;
}

static void mount_vol(const char *loopdev, const char *subvol, const char *target)
{
	char opts[128];
	snprintf(opts, sizeof opts, "subvol=%s", subvol);
	if (mount(loopdev, target, "btrfs", MS_RDONLY | MS_NOATIME, opts))
		fail(subvol);
}

static void tmpfs_on(const char *target, const char *opts)
{
	if (mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV, opts))
		dprintf(2, "[fasdeq-init] tmpfs on %s failed: %s\n", target, strerror(errno));
}

static void bind_file(const char *src, const char *dst)
{
	int fd = open(src, O_WRONLY | O_CREAT, 0644);
	if (fd >= 0)
		close(fd);
	if (mount(src, dst, NULL, MS_BIND, NULL))
		dprintf(2, "[fasdeq-init] bind %s failed: %s\n", dst, strerror(errno));
}

int main(void)
{
	mk("/proc");
	mk("/sys");
	mk("/dev");
	if (mount("proc", "/proc", "proc", 0, NULL))
		fail("mount /proc");
	if (mount("sysfs", "/sys", "sysfs", 0, NULL))
		fail("mount /sys");
	if (mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755"))
		fail("mount /dev");

	say("FasdeqOS booting");

	mk("/mnt");
	mk(ISO_MNT);
	mk("/mnt/hb");
	mk("/mnt/ov");
	mk(NEWROOT);

	if (find_medium())
		fail("boot medium with " CONTAINER " not found");

	char loopdev[64];
	if (attach_loop(ISO_MNT CONTAINER, loopdev, sizeof loopdev))
		fail("attach loop device");

	tmpfs_on(NEWROOT, "mode=0755,size=4m");
	mk(NEWROOT "/System");
	mk(NEWROOT "/Applications");
	mk(NEWROOT "/Users");
	mk(NEWROOT "/home");
	mk(NEWROOT "/boot");
	mk(NEWROOT "/dev");
	mk(NEWROOT "/proc");
	mk(NEWROOT "/sys");

	mount_vol(loopdev, "@system", NEWROOT "/System");
	mount_vol(loopdev, "@homebrew", "/mnt/hb");

	tmpfs_on("/mnt/ov", "mode=0755,size=40%");
	mk("/mnt/ov/up");
	mk("/mnt/ov/work");
	if (mount("overlay", NEWROOT "/home", "overlay", 0,
		  "lowerdir=/mnt/hb,upperdir=/mnt/ov/up,workdir=/mnt/ov/work"))
		dprintf(2, "[fasdeq-init] overlay /home failed: %s\n", strerror(errno));

	tmpfs_on(NEWROOT "/Applications", "mode=0755,uid=1000,gid=1000,size=40%");
	tmpfs_on(NEWROOT "/Users", "mode=0755,size=40%");
	mk(NEWROOT "/Users/live");
	if (chown(NEWROOT "/Users/live", 1000, 1000))
		dprintf(2, "[fasdeq-init] chown live: %s\n", strerror(errno));

	tmpfs_on(NEWROOT "/System/run", "mode=0755,size=64m");
	tmpfs_on(NEWROOT "/System/tmp", "mode=1777,size=40%");
	tmpfs_on(NEWROOT "/System/var", "mode=0755,size=256m");
	mk(NEWROOT "/System/var/log");
	mk(NEWROOT "/System/var/root");

	bind_file(NEWROOT "/System/run/resolv.conf", NEWROOT "/System/etc/resolv.conf");

	if (mount(ISO_MNT, NEWROOT "/boot", NULL, MS_MOVE, NULL))
		dprintf(2, "[fasdeq-init] could not move boot medium: %s\n", strerror(errno));
	mount("/dev", NEWROOT "/dev", NULL, MS_MOVE, NULL);
	mount("/proc", NEWROOT "/proc", NULL, MS_MOVE, NULL);
	mount("/sys", NEWROOT "/sys", NULL, MS_MOVE, NULL);

	if (chdir(NEWROOT))
		fail("chdir newroot");
	if (mount(".", "/", NULL, MS_MOVE, NULL))
		fail("move newroot to /");
	if (chroot("."))
		fail("chroot");
	if (chdir("/"))
		fail("chdir /");

	char *const argv[] = { "dinit", "--system", "--services-dir", "/System/etc/dinit.d",
			       "--socket-path", "/System/run/dinitctl", "boot", NULL };
	char *const envp[] = {
		"PATH=/System/bin:/System/sbin:/System/Applications/Chimerautils.app/Contents/MacOS",
		"HOME=/System/var/root", "TMPDIR=/System/tmp", "TERM=linux", NULL
	};
	execve("/System/sbin/dinit", argv, envp);
	fail("exec /System/sbin/dinit");
	return 1;
}
EOF_INIT

cat >"$B/kernel.fragment" <<'EOF_KCFG'
CONFIG_LOCALVERSION="-fasdeqos"
CONFIG_DEFAULT_HOSTNAME="fasdeq"
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_ZSTD=y
CONFIG_KERNEL_ZSTD=y
CONFIG_BTRFS_FS=y
CONFIG_BTRFS_FS_POSIX_ACL=y
CONFIG_SQUASHFS=y
CONFIG_ISO9660_FS=y
CONFIG_JOLIET=y
CONFIG_ZISOFS=y
CONFIG_OVERLAY_FS=y
CONFIG_TMPFS=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_INOTIFY_USER=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_CGROUPS=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_SR=y
CONFIG_ATA=y
CONFIG_SATA_AHCI=y
CONFIG_ATA_PIIX=y
CONFIG_BLK_DEV_NVME=y
CONFIG_USB_STORAGE=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_UAS=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_NET=y
CONFIG_E1000=y
CONFIG_E1000E=y
CONFIG_R8169=y
CONFIG_IGB=y
CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_FB=y
CONFIG_FB_EFI=y
CONFIG_FB_SIMPLE=y
CONFIG_DRM=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_DRM_SIMPLEDRM=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_AMDGPU_SI=y
CONFIG_DRM_AMDGPU_CIK=y
CONFIG_DRM_NOUVEAU=n
CONFIG_DRM_I915=n
CONFIG_DRM_RADEON=n
CONFIG_DRM_XE=n
CONFIG_DRM_VMWGFX=n
CONFIG_DRM_QXL=n
CONFIG_DRM_BOCHS=n
CONFIG_DRM_CIRRUS_QEMU=n
CONFIG_FW_LOADER_COMPRESS=y
CONFIG_FW_LOADER_COMPRESS_ZSTD=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_MODVERSIONS=n
CONFIG_MODULE_COMPRESS_NONE=y
CONFIG_PCI=y
CONFIG_MMU_NOTIFIER=y
CONFIG_HMM_MIRROR=y
CONFIG_INPUT_EVDEV=y
CONFIG_HID_GENERIC=y
CONFIG_USB_HID=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_NO_HZ_IDLE=y
CONFIG_PREEMPT=y
CONFIG_DEBUG_INFO=n
CONFIG_DEBUG_INFO_BTF=n
CONFIG_SOUND=n
CONFIG_WIRELESS=n
CONFIG_BT=n
CONFIG_NFS_FS=n
CONFIG_XFS_FS=n
CONFIG_KVM=n
CONFIG_XEN=n
CONFIG_HYPERV=n
CONFIG_NETFILTER=n
CONFIG_MEDIA_SUPPORT=n
CONFIG_INFINIBAND=n
CONFIG_STAGING=n
CONFIG_SND=n
CONFIG_SECURITY_SELINUX=n
CONFIG_SECURITY_APPARMOR=n
CONFIG_AUDIT=n
CONFIG_PCCARD=n
CONFIG_ISDN=n
CONFIG_FPGA=n
CONFIG_EXT4_FS=y
CONFIG_VFAT_FS=y
CONFIG_FAT_FS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_NLS_UTF8=y
EOF_KCFG

say "glibc 2.40 (пути /System/etc и /System/bin/sh вшиваются в libc)"
cd "$S/glibc"
for f in $(grep -rlE '"/etc/|_PATH_BSHELL' nss resolv misc elf sysdeps/generic sysdeps/unix/sysv/linux 2>/dev/null | grep -vE '/(tst|test|bug)[^/]*$'); do
    sed -i -e 's|"/etc/|"/System/etc/|g' -e 's|"/bin/sh"|"/System/bin/sh"|g' "$f"
done
mkdir -p "$B/glibc-build"
cd "$B/glibc-build"
if [ ! -f Makefile ]; then
    "$S/glibc/configure" --prefix=/System --libdir=/System/lib --libexecdir=/System/libexec \
        --sysconfdir=/System/etc --localstatedir=/System/var --disable-werror --disable-nscd \
        --disable-sanity-checks --enable-kernel=5.4 --without-selinux --disable-profile \
        --disable-timezone-tools CFLAGS="-O2 -pipe -U_FORTIFY_SOURCE" >"$L/glibc-configure.log" 2>&1
fi
make -j"$J" >"$L/glibc-make.log" 2>&1

say "корень"
rm -rf "$R"
mkdir -p "$R/System"
rm -f /System
ln -s "$R/System" /System
make -C "$B/glibc-build" install DESTDIR="$R" >"$L/glibc-install.log" 2>&1

mkdir -p "$R/System/lib/locale"
localedef -i "$S/glibc/localedata/locales/C" -f UTF-8 -c --no-archive "$R/System/lib/locale/C.utf8" >"$L/localedef.log" 2>&1 || true

say "libxo"
cd "$S/libxo"
[ -f configure ] || autoreconf -fi >"$L/libxo-autoreconf.log" 2>&1
mkdir -p "$B/libxo-build"
cd "$B/libxo-build"
[ -f Makefile ] || "$S/libxo/configure" --prefix=/System --libdir=/System/lib --disable-gettext \
    --disable-dependency-tracking >"$L/libxo-configure.log" 2>&1
make -j"$J" >"$L/libxo-make.log" 2>&1
make install DESTDIR="$R" >"$L/libxo-install.log" 2>&1

say "kmod"
if [ ! -d "$B/kmod-build" ]; then
    meson setup "$B/kmod-build" "$S/kmod" --prefix=/System --bindir=/System/bin --sbindir=/System/sbin \
        --libdir=/System/lib --sysconfdir=/System/etc -Dmoduledir=/System/Library/Extensions \
        -Dzstd=enabled -Dxz=enabled -Dzlib=enabled -Dopenssl=disabled -Dmbedtls=disabled \
        -Dmanpages=false -Ddocs=false >"$L/kmod-setup.log" 2>&1
fi
ninja -C "$B/kmod-build" >"$L/kmod-ninja.log" 2>&1
DESTDIR="$R" ninja -C "$B/kmod-build" install >"$L/kmod-install.log" 2>&1

say "dinit"
cd "$S/dinit"
[ -f mconfig ] || ./configure --prefix=/System --exec-prefix=/System --sbindir=/System/sbin \
    --mandir=/System/share/man --syscontrolsocket=/System/run/dinitctl --disable-strip \
    LDFLAGS_EXTRA="-static-libstdc++ -static-libgcc" >"$L/dinit-configure.log" 2>&1
make -j"$J" >"$L/dinit-make.log" 2>&1
make install DESTDIR="$R" >"$L/dinit-install.log" 2>&1

say "fish"
cd "$S/fish"
CARGO_TARGET_DIR="$B/fish-target" cargo build --release -j"$J" --no-default-features >"$L/fish-build.log" 2>&1
for t in fish fish_indent fish_key_reader; do
    install -D -m755 "$B/fish-target/release/$t" "$R/System/bin/$t"
done
mkdir -p "$R/System/share/fish"
for d in functions completions tools; do cp -a "$S/fish/share/$d" "$R/System/share/fish/"; done
cp "$S/fish/share/config.fish" "$R/System/share/fish/"

say "fastfetch $FF_TAG"
cmake -S "$S/fastfetch" -B "$B/fastfetch-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/System -DBUILD_FLASHFETCH=OFF >"$L/fastfetch-cmake.log" 2>&1
ninja -C "$B/fastfetch-build" >"$L/fastfetch-ninja.log" 2>&1
DESTDIR="$R" ninja -C "$B/fastfetch-build" install >"$L/fastfetch-install.log" 2>&1

say "chimerautils"
sed -i "/^    subdir('telnet')/d" "$S/chimerautils/src.freebsd/meson.build"
if [ ! -d "$B/chimera-build" ]; then
    PKG_CONFIG_PATH="$R/System/lib/pkgconfig" CFLAGS="-I$R/System/include" LDFLAGS="-L$R/System/lib" \
    meson setup "$B/chimera-build" "$S/chimerautils" --prefix=/System --bindir=/System/bin \
        --sbindir=/System/sbin --libdir=/System/lib --sysconfdir=/System/etc \
        -Dopenssl=disabled -Dlibedit=disabled -Dpam=disabled -Dselinux=disabled -Dtiny=disabled \
        >"$L/chimera-setup.log" 2>&1
fi
ninja -C "$B/chimera-build" >"$L/chimera-ninja.log" 2>&1
rm -rf "$B/stage-chimera"
DESTDIR="$B/stage-chimera" ninja -C "$B/chimera-build" install >"$L/chimera-install.log" 2>&1

say "ядро Linux 6.12"
cd "$S/linux"
[ -f .config ] || make defconfig >"$L/kernel-defconfig.log" 2>&1
scripts/kconfig/merge_config.sh -m .config "$B/kernel.fragment" >"$L/kernel-merge.log" 2>&1
make olddefconfig >"$L/kernel-olddefconfig.log" 2>&1
make -j"$J" bzImage modules >"$L/kernel-build.log" 2>&1
KVER=$(cat include/config/kernel.release)

say "модули NVIDIA open $NV_VER"
cd "$S/nvidia"
make -j"$J" modules SYSSRC="$S/linux" SYSOUT="$S/linux" IGNORE_CC_MISMATCH=1 >"$L/nvidia-modules.log" 2>&1
mkdir -p "$B/nvidia-modules"
cp kernel-open/nvidia.ko kernel-open/nvidia-uvm.ko kernel-open/nvidia-drm.ko kernel-open/nvidia-modeset.ko "$B/nvidia-modules/"
strip --strip-debug "$B"/nvidia-modules/*.ko

say "пакеты NVIDIA userland и прошивки"
mkdir -p "$B/debs"
cd "$B/debs"
NVMAJ=${NV_VER%%.*}
ls ./*.deb >/dev/null 2>&1 || apt-get download \
    libnvidia-gl-$NVMAJ libnvidia-compute-$NVMAJ libnvidia-extra-$NVMAJ libnvidia-decode-$NVMAJ \
    libnvidia-encode-$NVMAJ nvidia-utils-$NVMAJ nvidia-firmware-$NVMAJ-$NV_VER linux-firmware >"$L/debs.log" 2>&1
rm -rf "$B/nv" "$B/fw"
mkdir -p "$B/nv" "$B/fw"
for d in "$B"/debs/*nvidia*.deb; do dpkg-deb -x "$d" "$B/nv"; done
dpkg-deb -x "$B"/debs/linux-firmware*.deb "$B/fw"

say "Homebrew"
rm -rf /home/linuxbrew
mkdir -p /home/linuxbrew/.linuxbrew
cp -a "$S/brew" /home/linuxbrew/.linuxbrew/Homebrew
for d in bin etc include lib opt sbin share var Cellar; do mkdir -p /home/linuxbrew/.linuxbrew/$d; done
(
    cd /home/linuxbrew/.linuxbrew/Homebrew
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew \
        ./bin/brew vendor-install ruby >"$L/brew-vendor.log" 2>&1
) || echo "   (portable ruby для brew не скачан, brew докачает при первом запуске)"
grep -rIl -e '/bin/bash' -e '/usr/bin/env' /home/linuxbrew/.linuxbrew/Homebrew --exclude-dir=.git --exclude-dir=vendor 2>/dev/null |
    xargs -r sed -i -e 's|/usr/bin/env bash|/System/Library/Homebrew/bin/bash|g' -e 's|/bin/bash|/System/Library/Homebrew/bin/bash|g' -e 's|/usr/bin/env|/System/bin/env|g'
cat >/home/linuxbrew/.linuxbrew/bin/brew <<'EOF_BREW'
#!/System/Library/Homebrew/bin/bash
exec /System/Library/Homebrew/bin/bash /home/linuxbrew/.linuxbrew/Homebrew/bin/brew "$@"
EOF_BREW
chmod 755 /home/linuxbrew/.linuxbrew/bin/brew
rm -rf "$B/hb"
mkdir -p "$B/hb"
cp -a /home/linuxbrew "$B/hb/"

glibc_soname() {
    case "$1" in
        linux-vdso.so.1|ld-linux-x86-64.so.2|libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|\
        libutil.so.1|libresolv.so.2|libnsl.so.1|libanl.so.1|libmvec.so.1|libBrokenLocale.so.1|\
        libthread_db.so.1|libnss_*|libSegFault.so) return 0 ;;
    esac
    return 1
}
is_elf() { [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]; }
collect_libs() {
    local elf=$1 dest=$2 line name path
    mkdir -p "$dest"
    while read -r line; do
        case "$line" in *"=>"*) ;; *) continue ;; esac
        name=${line%% *}
        name=${name##*/}
        path=${line#*=> }
        path=${path%% *}
        glibc_soname "$name" && continue
        [ -f "$path" ] || continue
        case "$path" in /System/*|"$R"/*) continue ;; esac
        if [ ! -e "$dest/$name" ]; then
            cp -L "$path" "$dest/$name"
            collect_libs "$dest/$name" "$dest"
        fi
    done < <(ldd "$elf" 2>/dev/null || true)
}
patch_exec() { patchelf --set-interpreter "$LOADER" --set-rpath "$2" "$1" 2>/dev/null || true; }

say "системные инструменты из Ubuntu (бинарники, без сборки)"
IMPORT=$B/import
rm -rf "$IMPORT"
mkdir -p "$IMPORT"
imp() { [ -x "$1" ] && install -D -m755 "$1" "$2" || echo "   нет $1"; }
imp /usr/bin/bsdtar "$R/System/bin/tar"
imp /usr/bin/zstd "$R/System/bin/zstd"
imp /usr/bin/inotifywait "$R/System/bin/inotifywait"
imp /usr/bin/git "$R/System/bin/git"
imp /usr/bin/curl "$R/System/bin/curl"
imp /usr/bin/flatpak "$R/System/bin/flatpak"
imp /usr/bin/bwrap "$R/System/bin/bwrap"
imp /usr/bin/xdg-dbus-proxy "$R/System/bin/xdg-dbus-proxy"
imp /usr/bin/busybox "$R/System/bin/busybox"
imp /usr/bin/bash "$R/System/Library/Homebrew/bin/bash"
for h in git-remote-http git-remote-https git-http-fetch; do imp /usr/lib/git-core/$h "$R/System/libexec/git-core/$h"; done
mkdir -p "$R/System/share/git-core"
cp -a /usr/share/git-core/templates "$R/System/share/git-core/" 2>/dev/null || true
mkdir -p "$R/System/etc/ssl/certs"
cp -L /etc/ssl/certs/ca-certificates.crt "$R/System/etc/ssl/certs/ca-certificates.crt"
mkdir -p "$R/System/share/flatpak" "$R/System/etc/flatpak"
cp -a /usr/share/flatpak/. "$R/System/share/flatpak/" 2>/dev/null || true

say "chimerautils -> /System/Applications/Chimerautils.app"
APP=$R/System/Applications/Chimerautils.app/Contents
mkdir -p "$APP/MacOS" "$APP/Frameworks" "$APP/Resources"
cp -a "$B/stage-chimera/System/bin/." "$APP/MacOS/"
[ -d "$B/stage-chimera/System/sbin" ] && cp -a "$B/stage-chimera/System/sbin/." "$APP/MacOS/"
[ -d "$B/stage-chimera/System/share/man" ] && cp -a "$B/stage-chimera/System/share/man" "$APP/Resources/man"
cp -L "$R/System/lib/libxo.so.0" "$APP/Frameworks/libxo.so.0"
for l in "$B"/stage-chimera/System/lib/lib*.so*; do [ -e "$l" ] && cp -a "$l" "$APP/Frameworks/"; done
cat >"$APP/Info.plist" <<'EOF_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Chimerautils</string>
<key>CFBundleIdentifier</key><string>org.fasdeqos.chimerautils</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
EOF_PLIST
find "$APP/MacOS" -type f | while read -r f; do
    if is_elf "$f"; then
        collect_libs "$f" "$APP/Frameworks"
        patch_exec "$f" '$ORIGIN/../Frameworks'
    fi
done
for f in "$APP"/Frameworks/*.so*; do
    [ -L "$f" ] && continue
    patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
done
install -m755 "$APP/MacOS/sh" "$R/System/bin/sh"
install -m755 "$APP/MacOS/env" "$R/System/bin/env"

say "NVIDIA -> NVIDIA.framework и /System/Applications/NVIDIA.app"
FW=$R/System/Library/Frameworks/NVIDIA.framework
mkdir -p "$FW/lib" "$FW/share" "$FW/etc"
cp -a "$B/nv/usr/lib/x86_64-linux-gnu/." "$FW/lib/"
for d in "$B"/nv/usr/share/*; do
    case "$(basename "$d")" in doc|lintian|man|bash-completion) continue ;; esac
    cp -a "$d" "$FW/share/"
done
[ -d "$B/nv/etc" ] && cp -a "$B/nv/etc/." "$FW/etc/"
mkdir -p "$R/System/Library/Firmware"
cp -a "$B/nv/lib/firmware/nvidia" "$R/System/Library/Firmware/"
if [ -d "$B/fw/usr/lib/firmware/amdgpu" ]; then
    cp -a "$B/fw/usr/lib/firmware/amdgpu" "$R/System/Library/Firmware/"
elif [ -d "$B/fw/lib/firmware/amdgpu" ]; then
    cp -a "$B/fw/lib/firmware/amdgpu" "$R/System/Library/Firmware/"
fi
NV=$R/System/Applications/NVIDIA.app/Contents
mkdir -p "$NV/MacOS" "$NV/Resources"
if [ -d "$B/nv/usr/bin" ]; then
    cp -a "$B/nv/usr/bin/." "$NV/MacOS/"
    find "$NV/MacOS" -type f | while read -r f; do
        is_elf "$f" && patch_exec "$f" '/System/Library/Frameworks/NVIDIA.framework/lib:/System/lib'
    done
fi
cat >"$NV/Info.plist" <<EOF_NVPLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleName</key><string>NVIDIA</string>
<key>CFBundleIdentifier</key><string>org.fasdeqos.nvidia</string>
<key>CFBundleVersion</key><string>$NV_VER</string>
</dict></plist>
EOF_NVPLIST

say "слой настроек"
cat >"$OV/System/etc/dinit.d/boot" <<'EOF'
type = internal
depends-on = network
waits-for = nvidia
waits-for = pkgd
waits-for = session
EOF
cat >"$OV/System/etc/dinit.d/session" <<'EOF'
type = process
command = /System/bin/fish --login
run-as = live
options = runs-on-console
env-file = /System/etc/dinit.d/env.live
restart = true
smooth-recovery = true
EOF
cat >"$OV/System/etc/dinit.d/pkgd" <<'EOF'
type = process
command = /System/bin/fish /System/bin/pkgd
run-as = live
env-file = /System/etc/dinit.d/env.live
logfile = /System/var/log/pkgd.log
logfile-permissions = 644
restart = true
EOF
cat >"$OV/System/etc/dinit.d/nvidia" <<'EOF'
type = scripted
command = /System/bin/fish /System/libexec/fasdeqos/nvidia-load.fish
stop-command = /System/bin/fish /System/libexec/fasdeqos/nvidia-unload.fish
env-file = /System/etc/dinit.d/environment
restart = false
logfile = /System/var/log/nvidia.log
logfile-permissions = 644
EOF
cat >"$OV/System/etc/dinit.d/network" <<'EOF'
type = scripted
command = /System/bin/fish /System/libexec/fasdeqos/network.fish
env-file = /System/etc/dinit.d/environment
restart = false
logfile = /System/var/log/network.log
logfile-permissions = 644
EOF
cat >"$OV/System/etc/dinit.d/environment" <<'EOF'
HOME=/System/var/root
USER=root
LOGNAME=root
SHELL=/System/bin/fish
PATH=/System/bin:/System/sbin:/System/Applications/Chimerautils.app/Contents/MacOS
TMPDIR=/System/tmp
TERM=linux
LANG=C.UTF-8
GIT_EXEC_PATH=/System/libexec/git-core
SSL_CERT_FILE=/System/etc/ssl/certs/ca-certificates.crt
EOF
cat >"$OV/System/etc/dinit.d/env.live" <<'EOF'
HOME=/Users/live
USER=live
LOGNAME=live
SHELL=/System/bin/fish
PATH=/System/bin:/System/sbin:/System/Applications/Chimerautils.app/Contents/MacOS:/System/Applications/NVIDIA.app/Contents/MacOS:/home/linuxbrew/.linuxbrew/bin
TMPDIR=/System/tmp
TERM=linux
LANG=C.UTF-8
XDG_CONFIG_DIRS=/System/etc/xdg
XDG_DATA_DIRS=/System/share:/home/linuxbrew/.linuxbrew/share
GIT_EXEC_PATH=/System/libexec/git-core
GIT_TEMPLATE_DIR=/System/share/git-core/templates
GIT_SSL_CAINFO=/System/etc/ssl/certs/ca-certificates.crt
SSL_CERT_FILE=/System/etc/ssl/certs/ca-certificates.crt
CURL_CA_BUNDLE=/System/etc/ssl/certs/ca-certificates.crt
FLATPAK_BWRAP=/System/bin/bwrap
HOMEBREW_NO_ANALYTICS=1
HOMEBREW_NO_ENV_HINTS=1
EOF
cat >"$OV/System/etc/fish/config.fish" <<'EOF'
set -gx PATH /System/bin /System/sbin /System/Applications/Chimerautils.app/Contents/MacOS /System/Applications/NVIDIA.app/Contents/MacOS /home/linuxbrew/.linuxbrew/bin
set -g fish_greeting ""

if test -f /System/run/gpu-mode; and test (cat /System/run/gpu-mode) = nvidia-primary
    set -gx LD_LIBRARY_PATH /System/Library/Frameworks/NVIDIA.framework/lib
    set -gx __GLX_VENDOR_LIBRARY_NAME nvidia
    set -gx __EGL_VENDOR_LIBRARY_FILENAMES /System/Library/Frameworks/NVIDIA.framework/share/glvnd/egl_vendor.d/10_nvidia.json
    set -gx VK_ICD_FILENAMES /System/Library/Frameworks/NVIDIA.framework/share/vulkan/icd.d/nvidia_icd.json
end

function fish_prompt
    set -l s $status
    set_color brblue
    echo -n (prompt_pwd)
    if test $s -ne 0
        set_color red
    else
        set_color green
    end
    echo -n ' ❯ '
    set_color normal
end

if status is-login; and status is-interactive
    command -q fastfetch; and fastfetch
end
EOF
cat >"$OV/System/etc/xdg/fastfetch/config.jsonc" <<'EOF'
{
  "logo": { "type": "small" },
  "display": { "separator": "  " },
  "modules": [
    "title",
    "separator",
    { "type": "custom", "key": "OS", "format": "FasdeqOS 0.2" },
    "kernel",
    "uptime",
    "shell",
    "cpu",
    "gpu",
    "memory",
    "disk"
  ]
}
EOF
cat >"$OV/System/etc/os-release" <<'EOF'
NAME="FasdeqOS"
ID=fasdeqos
PRETTY_NAME="FasdeqOS"
VERSION_ID="0.2"
HOME_URL="https://github.com/fasdeq13"
EOF
cat >"$OV/System/etc/passwd" <<'EOF'
root:x:0:0:root:/System/var/root:/System/bin/fish
live:x:1000:1000:Live:/Users/live:/System/bin/fish
nobody:x:65534:65534:nobody:/nonexistent:/System/bin/fish
EOF
cat >"$OV/System/etc/group" <<'EOF'
root:x:0:
live:x:1000:
nogroup:x:65534:
EOF
cat >"$OV/System/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
EOF
printf '127.0.0.1 localhost fasdeq\n' >"$OV/System/etc/hosts"
: >"$OV/System/etc/resolv.conf"
printf 'fasdeq\n' >"$OV/System/etc/hostname"
cat >"$OV/System/etc/ld.so.conf" <<'EOF'
/System/lib
EOF
cat >"$OV/System/etc/modprobe.d/gpu.conf" <<'EOF'
blacklist nouveau
EOF

cat >"$OV/System/libexec/fasdeqos/nvidia-load.fish" <<'EOF'
#!/System/bin/fish
set -x PATH /System/bin /System/sbin /System/Applications/Chimerautils.app/Contents/MacOS

set -l nv 0
set -l other 0
for d in /sys/bus/pci/devices/*
    set -l c (cat $d/class 2>/dev/null)
    string match -q '0x03*' -- $c; or continue
    if test (cat $d/vendor) = 0x10de
        set nv (math $nv + 1)
    else
        set other (math $other + 1)
    end
end

if test $nv -eq 0
    echo "nvidia: no NVIDIA GPU, driver not loaded"
    echo none >/System/run/gpu-mode
    exit 0
end

modprobe nvidia
or begin
    echo "nvidia: kernel module did not load"
    exit 1
end
modprobe nvidia-uvm

if test $other -eq 0
    modprobe nvidia-modeset
    modprobe nvidia-drm modeset=1
    echo nvidia-primary >/System/run/gpu-mode
else
    echo nvidia-offload >/System/run/gpu-mode
end

test -e /dev/nvidiactl; or mknod -m 666 /dev/nvidiactl c 195 255
test -e /dev/nvidia-modeset; or mknod -m 666 /dev/nvidia-modeset c 195 254
set -l n 0
for gpu in /proc/driver/nvidia/gpus/*
    test -e /dev/nvidia$n; or mknod -m 666 /dev/nvidia$n c 195 $n
    set n (math $n + 1)
end
set -l uvm (string match -r '^\s*(\d+)\s+nvidia-uvm$' (cat /proc/devices) | tail -n 1)
if test -n "$uvm"
    test -e /dev/nvidia-uvm; or mknod -m 666 /dev/nvidia-uvm c $uvm 0
    test -e /dev/nvidia-uvm-tools; or mknod -m 666 /dev/nvidia-uvm-tools c $uvm 1
end
echo "nvidia: ready, mode "(cat /System/run/gpu-mode)
EOF
cat >"$OV/System/libexec/fasdeqos/nvidia-unload.fish" <<'EOF'
#!/System/bin/fish
set -x PATH /System/bin /System/sbin /System/Applications/Chimerautils.app/Contents/MacOS
for m in nvidia-uvm nvidia-drm nvidia-modeset nvidia
    rmmod $m 2>/dev/null
end
exit 0
EOF
cat >"$OV/System/libexec/fasdeqos/network.fish" <<'EOF'
#!/System/bin/fish
set -x PATH /System/bin /System/sbin /System/Applications/Chimerautils.app/Contents/MacOS
for i in (ls /sys/class/net)
    test $i = lo; and continue
    busybox ifconfig $i up
    busybox udhcpc -q -n -t 3 -T 1 -i $i -s /System/libexec/fasdeqos/udhcpc.script
end
busybox ifconfig lo 127.0.0.1 up
exit 0
EOF
cat >"$OV/System/libexec/fasdeqos/udhcpc.script" <<'EOF'
#!/System/bin/fish
switch "$argv[1]"
    case bound renew
        busybox ifconfig $interface $ip netmask $subnet
        if test -n "$router"
            busybox route add default gw (string split ' ' -- $router)[1] dev $interface
        end
        if test -n "$dns"
            for ns in (string split ' ' -- $dns)
                echo nameserver $ns
            end >/System/etc/resolv.conf
        end
end
exit 0
EOF
cat >"$OV/System/bin/nvrun" <<'EOF'
#!/System/bin/fish
set -gx LD_LIBRARY_PATH /System/Library/Frameworks/NVIDIA.framework/lib
set -gx __NV_PRIME_RENDER_OFFLOAD 1
set -gx __GLX_VENDOR_LIBRARY_NAME nvidia
set -gx __EGL_VENDOR_LIBRARY_FILENAMES /System/Library/Frameworks/NVIDIA.framework/share/glvnd/egl_vendor.d/10_nvidia.json
set -gx VK_ICD_FILENAMES /System/Library/Frameworks/NVIDIA.framework/share/vulkan/icd.d/nvidia_icd.json
exec $argv
EOF

cat >"$OV/System/bin/pkg" <<'EOF'
#!/System/bin/fish
set -g APPS /Applications
set -g DB /Applications/.pkgdb
set -g FLATHUB https://dl.flathub.org/repo/flathub.flatpakrepo
set -g BREWBIN /home/linuxbrew/.linuxbrew/bin
set -g PKGVER 1.0

function die
    echo "pkg: $argv" >&2
    exit 1
end

function mget
    set -l v (string match -rg '^'$argv[2]':\s*(.*)$' < $argv[1])
    echo $v[1]
end

function appdir
    set -l d $APPS/$argv[1].app
    if test -d $d
        set -l cur (cat $d/Contents/Version 2>/dev/null)
        if test "$cur" != "$argv[2]"
            set d "$APPS/$argv[1] $argv[2].app"
        end
    end
    echo $d
end

function register
    mkdir -p $DB
    set -l base (basename $argv[1] .app)
    cp $argv[1]/Contents/+MANIFEST "$DB/$base"
    echo "dir: $argv[1]" >>"$DB/$base"
end

function mkapp
    set -l d $argv[1]
    set -l name $argv[2]
    set -l ver $argv[3]
    set -l type $argv[4]
    set -l ref $argv[5]
    set -l ex $argv[6]
    set -l comment $argv[7]
    set -l icon $argv[8]
    set -l tmp "$APPS/.$name.part"
    rm -rf $tmp
    mkdir -p $tmp/Contents/MacOS $tmp/Contents/Resources
    echo $ver >$tmp/Contents/Version
    printf 'name: %s\nversion: %s\ntype: %s\nref: %s\nexec: %s\ncomment: %s\n' $name $ver $type $ref $ex $comment >$tmp/Contents/+MANIFEST
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n<key>CFBundleName</key><string>%s</string>\n<key>CFBundleVersion</key><string>%s</string>\n<key>CFBundleExecutable</key><string>launcher</string>\n</dict></plist>\n' $name $ver >$tmp/Contents/Info.plist
    set -l l $tmp/Contents/MacOS/launcher
    echo '#!/System/bin/fish' >$l
    switch $type
        case flatpak
            echo 'exec flatpak run '$ref' $argv' >>$l
        case brew
            echo 'exec '$BREWBIN'/'$ex' $argv' >>$l
        case container
            echo 'exec distrobox-enter -n '$name' -- '$ex' $argv' >>$l
    end
    chmod 755 $l
    test -n "$icon"; and test -f "$icon"; and cp $icon $tmp/Contents/Resources/icon.png
    rm -rf $d
    mv $tmp $d
    register $d
end

function add_pkg
    set -l f $argv[1]
    test -f "$f"; or die "$f: no such file"
    set -l t (mktemp -d)
    tar -xf "$f" -C $t 2>/dev/null; or begin
        rm -rf $t
        die "$f: not a valid package"
    end
    set -l m $t/+MANIFEST
    test -f $m; or begin
        rm -rf $t
        die "$f: +MANIFEST missing"
    end
    set -l name (mget $m name)
    set -l ver (mget $m version)
    set -l type (mget $m type)
    set -l ref (mget $m ref)
    set -l ex (mget $m exec)
    set -l comment (mget $m comment)
    set -l setup (mget $m setup)
    test -n "$name"; or begin
        rm -rf $t
        die "manifest has no name"
    end
    test -n "$ver"; or set ver 1
    set -l d (appdir $name $ver)
    switch $type
        case bundle
            set -l a (ls -d $t/payload/*.app 2>/dev/null)[1]
            test -n "$a"; or begin
                rm -rf $t
                die "bundle package has no payload/*.app"
            end
            set -l tmp "$APPS/.$name.part"
            rm -rf $tmp
            cp -R $a $tmp
            mkdir -p $tmp/Contents
            echo $ver >$tmp/Contents/Version
            cp $m $tmp/Contents/+MANIFEST
            rm -rf $d
            mv $tmp $d
            register $d
        case flatpak
            flatpak remote-add --user --if-not-exists flathub $FLATHUB; or begin
                rm -rf $t
                die "cannot add flathub"
            end
            flatpak install --user -y --noninteractive flathub $ref; or begin
                rm -rf $t
                die "flatpak install failed: $ref"
            end
            mkapp $d $name $ver flatpak $ref $ex $comment $t/icon.png
        case brew
            $BREWBIN/brew install $ref; or begin
                rm -rf $t
                die "brew install failed: $ref"
            end
            test -n "$ex"; or set ex $ref
            mkapp $d $name $ver brew $ref $ex $comment $t/icon.png
        case container
            distrobox create --yes --name $name --image $ref; or begin
                rm -rf $t
                die "distrobox create failed: $ref"
            end
            test -n "$setup"; and distrobox-enter -n $name -- sh -c "$setup"
            mkapp $d $name $ver container $ref $ex $comment $t/icon.png
        case '*'
            rm -rf $t
            die "unknown package type: $type"
    end
    rm -rf $t
    echo "installed: $d"
end

function create_pkg
    set -l spec $argv[1]
    set -l outdir .
    set -l name ''
    set -l ver ''
    set -l i 2
    while test $i -le (count $argv)
        switch $argv[$i]
            case -o
                set i (math $i + 1)
                set outdir $argv[$i]
            case -n
                set i (math $i + 1)
                set name $argv[$i]
            case -v
                set i (math $i + 1)
                set ver $argv[$i]
        end
        set i (math $i + 1)
    end
    set -l type (string split -m1 : -- $spec)[1]
    set -l ref (string split -m1 : -- $spec)[2]
    test -n "$ref"; or die "usage: pkg create flathub:APP.ID | brew:FORMULA | container:IMAGE | bundle:/path/Name.app"
    test -n "$ver"; or set ver 1
    set -l t (mktemp -d)
    switch $type
        case flathub flatpak
            set type flatpak
            test -n "$name"; or set name (string split . -- $ref)[-1]
        case brew
            test -n "$name"; or set name $ref
        case container
            test -n "$name"; or set name (string replace -ra '[^A-Za-z0-9]' '-' -- $ref)
        case bundle
            test -n "$name"; or set name (basename $ref .app)
            mkdir -p $t/payload
            cp -R $ref $t/payload/
        case '*'
            rm -rf $t
            die "unknown source: $type"
    end
    printf 'name: %s\nversion: %s\ntype: %s\nref: %s\nexec: %s\ncomment: %s\n' $name $ver $type $ref $ref $name >$t/+MANIFEST
    set -l out "$outdir/$name-$ver.pkg"
    tar --zstd -cf "$out" -C $t +MANIFEST (ls $t | string match -v '+MANIFEST')
    rm -rf $t
    echo "created: $out"
end

function remove_pkg
    for n in $argv
        set -l e "$DB/$n"
        test -f "$e"; or begin
            echo "pkg: $n: not installed" >&2
            continue
        end
        set -l type (mget $e type)
        set -l ref (mget $e ref)
        set -l dir (mget $e dir)
        switch $type
            case flatpak
                flatpak uninstall --user -y $ref
            case brew
                $BREWBIN/brew uninstall $ref
            case container
                distrobox rm --force $n
        end
        rm -rf "$dir"
        rm -f "$e"
        echo "removed: $n"
    end
end

function list_pkg
    for e in $DB/*
        test -f "$e"; or continue
        echo (basename "$e")"-"(mget $e version)" ["(mget $e type)"]"
    end
end

function resolve_install
    set -l a $argv[1]
    if string match -q '*.pkg' -- $a
        add_pkg $a
    else if string match -q '*:*' -- $a
        set -l t (mktemp -d)
        set -l out (create_pkg $a -o $t | string replace 'created: ' '')
        add_pkg $out
        rm -rf $t
    else if string match -q '*.*.*' -- $a
        resolve_install flathub:$a
    else
        resolve_install brew:$a
    end
end

if test (count $argv) -eq 0
    echo "usage: pkg add|install|delete|remove|info|search|update|upgrade|create|autoremove|version"
    exit 1
end

set -l cmd $argv[1]
set -e argv[1]

switch $cmd
    case add
        for a in $argv
            add_pkg $a
        end
    case install
        for a in $argv
            resolve_install $a
        end
    case delete remove
        remove_pkg $argv
    case info
        if test (count $argv) -eq 0
            list_pkg
        else
            for n in $argv
                test -f "$DB/$n"; and cat "$DB/$n"; or echo "pkg: $n: not installed" >&2
            end
        end
    case list
        list_pkg
    case search
        flatpak remote-add --user --if-not-exists flathub $FLATHUB 2>/dev/null
        flatpak search --user $argv 2>/dev/null
        $BREWBIN/brew search $argv 2>/dev/null
    case update
        flatpak update --user -y --appstream 2>/dev/null
        $BREWBIN/brew update 2>/dev/null
    case upgrade
        flatpak update --user -y 2>/dev/null
        $BREWBIN/brew upgrade 2>/dev/null
    case create
        create_pkg $argv
    case autoremove
        flatpak uninstall --user --unused -y 2>/dev/null
        $BREWBIN/brew autoremove 2>/dev/null
    case version -v --version
        echo $PKGVER
    case '*'
        die "unknown command: $cmd"
end
EOF
cat >"$OV/System/bin/pkgd" <<'EOF'
#!/System/bin/fish
set -x PATH /System/bin /System/sbin /System/Applications/Chimerautils.app/Contents/MacOS /home/linuxbrew/.linuxbrew/bin

function handle
    set -l p /Applications/$argv[1]
    sleep 0.2
    if pkg add $p >>$HOME/.pkgd.log 2>&1
        rm -f $p
    end
end

for f in /Applications/*.pkg
    test -f $f; and handle (basename $f)
end

inotifywait -m -q -e close_write -e moved_to --format '%f' /Applications | while read -l f
    string match -q '*.pkg' -- $f; and handle $f
end
EOF
chmod 755 "$OV"/System/bin/pkg "$OV"/System/bin/pkgd "$OV"/System/bin/nvrun "$OV"/System/libexec/fasdeqos/*

cat >"$B/selftest.fish" <<'EOF'
#!/System/bin/fish
echo "=== SELFTEST BEGIN ==="
echo "user: "(id -un)" uid "(id -u)
echo "home: $HOME"; ls -ld /Users/live
echo "--- root"; ls /
echo "--- /System"; ls /System
echo "--- /System/Applications"; ls /System/Applications
echo "--- symlinks"; find /System /Applications /home -xdev -type l | wc -l
echo "--- mounts"; cat /proc/mounts | grep -E "btrfs|tmpfs|overlay|iso9660"
echo "--- tools"
for t in tar zstd git curl flatpak bwrap busybox inotifywait fastfetch pkg brew sh env fish
    command -q $t; and echo "  ok   $t"; or echo "  MISS $t"
end
echo "--- bash only for brew"; ls /System/Library/Homebrew/bin
echo "--- homebrew tree"; ls /home/linuxbrew/.linuxbrew
echo "--- passwd lookup"; id live; getent passwd live
echo "--- network"; busybox ifconfig -a 2>&1 | grep -E "^[a-z]|inet addr"; cat /System/etc/resolv.conf; cat /System/var/log/network.log; busybox route -n
echo "--- binaries run"; git --version; curl --version | head -1; flatpak --version; brew --version; tar --version
echo "--- curl https"; curl -sS -m 8 -o /dev/null -w "%{http_code}\n" https://example.com 2>&1
echo "--- gpu mode"; cat /System/run/gpu-mode
echo "--- nvidia log"; cat /System/var/log/nvidia.log
echo "--- fastfetch"; fastfetch --pipe 2>&1 | head -12
echo "--- pkg drag-and-drop"
mkdir -p /System/tmp/t/Hello.app/Contents/MacOS
printf '#!/System/bin/fish\necho hello\n' >/System/tmp/t/Hello.app/Contents/MacOS/launcher
chmod 755 /System/tmp/t/Hello.app/Contents/MacOS/launcher
pkg create bundle:/System/tmp/t/Hello.app -o /System/tmp/t -v 1.0
pkg create bundle:/System/tmp/t/Hello.app -o /System/tmp/t -v 2.0
cp /System/tmp/t/Hello-1.0.pkg /Applications/
set -l t0 (date +%s)
for i in (seq 1 40)
    test -d /Applications/Hello.app; and break
    sleep 0.25
end
test -d /Applications/Hello.app; and echo "SHORTCUT-OK after "(math (date +%s) - $t0)"s"; or echo "SHORTCUT-FAIL"
cp /System/tmp/t/Hello-2.0.pkg /Applications/
for i in (seq 1 40)
    test -d "/Applications/Hello 2.0.app"; and break
    sleep 0.25
end
test -d "/Applications/Hello 2.0.app"; and echo "VERSIONED-OK"; or echo "VERSIONED-FAIL"
ls -A /Applications
echo "--- pkg info"; pkg info
echo "--- run launcher"; /Applications/Hello.app/Contents/MacOS/launcher
echo "--- pkg delete"; pkg delete Hello "Hello 2.0"; ls -A /Applications
echo "=== SELFTEST END ==="
EOF

say "сборка образа"
rm -rf "$B/iso" "$B/mnt"
mkdir -p "$B/iso/FasdeqOS" "$B/iso/boot/grub" "$B/mnt" "$O"
ISO=$O/FasdeqOS-0.2-x86_64${SELFTEST:+-selftest}.iso
IMG=$B/iso/FasdeqOS/container.btrfs
MNT=$B/mnt
cleanup_mnt() { mountpoint -q "$MNT" && umount "$MNT" || true; }
trap cleanup_mnt EXIT

TOTAL=$(du -sm "$R/System" "$B/hb" "$B/overlay" | awk '{s+=$1} END {print s}')
SIZE_MB=$(( TOTAL * 110 / 100 + 512 ))
truncate -s "${SIZE_MB}M" "$IMG"
mkfs.btrfs -q -f -L FasdeqOS -m single -d single --nodesize 16384 -O no-holes,free-space-tree "$IMG"
mount -o loop,compress-force=${COMP:-zstd:1},noatime "$IMG" "$MNT"
btrfs subvolume create "$MNT/@system" >/dev/null
btrfs subvolume create "$MNT/@homebrew" >/dev/null
cp -a "$R/System/." "$MNT/@system/"
cp -a "$B/hb/." "$MNT/@homebrew/"
cp -a "$OV/System/." "$MNT/@system/"
mkdir -p "$MNT/@system/run" "$MNT/@system/tmp" "$MNT/@system/var"
chown -R 1000:1000 "$MNT/@homebrew/linuxbrew"

say "модули ядра"
make -C "$S/linux" modules_install MODLIB="$MNT/@system/Library/Extensions/$KVER" INSTALL_MOD_STRIP=1 DEPMOD=true >"$L/modules-install.log" 2>&1
rm -f "$MNT/@system/Library/Extensions/$KVER/build" "$MNT/@system/Library/Extensions/$KVER/source"
mkdir -p "$MNT/@system/Library/Extensions/$KVER/extra"
cp "$B"/nvidia-modules/*.ko "$MNT/@system/Library/Extensions/$KVER/extra/"
"$R/System/sbin/depmod" -a -b "$MNT/@system" --moduledir Library/Extensions "$KVER" 2>>"$L/depmod.log" || \
    depmod -a -b "$MNT/@system/Library/Extensions" "$KVER" 2>>"$L/depmod.log" || true

say "библиотеки и пути для всех бинарников"
ELFDIRS=("$MNT/@system/bin" "$MNT/@system/sbin" "$MNT/@system/libexec")
for dir in "${ELFDIRS[@]}"; do
    find "$dir" -type f 2>/dev/null | while read -r f; do
        is_elf "$f" || continue
        case "$(basename "$f")" in ldconfig|sln|iconvconfig|ld.so|busybox) continue ;; esac
        patchelf --print-interpreter "$f" >/dev/null 2>&1 || continue
        collect_libs "$f" "$MNT/@system/lib"
        patch_exec "$f" '/System/lib'
    done
done
for f in "$MNT/@system/Library/Homebrew/bin/bash"; do
    [ -f "$f" ] || continue
    collect_libs "$f" "$MNT/@system/lib"
    patch_exec "$f" '/System/lib'
done
for f in "$MNT"/@system/lib/*.so*; do
    [ -L "$f" ] && continue
    case "$(basename "$f")" in ld-linux*|libc.so.6|libm.so.6) continue ;; esac
    patchelf --set-rpath '/System/lib' "$f" 2>/dev/null || true
done
mount --bind "$MNT/@system" "$R/System"
"$R/System/sbin/ldconfig" -X -r "$R" 2>>"$L/ldconfig.log" || true
umount "$R/System"

say "лицензия"
install -D -m644 "$S/linux/COPYING" "$MNT/@system/share/licenses/FasdeqOS/GPL-2.0.txt"
cat >"$MNT/@system/share/licenses/FasdeqOS/README" <<'EOF_LIC'
FasdeqOS - author: fasdeq13 - licensed under the GNU General Public License v2.0.
Components keep their own licenses.
NVIDIA userland and AMD firmware are proprietary redistributable binaries.
EOF_LIC
cp "$MNT/@system/share/licenses/FasdeqOS/GPL-2.0.txt" "$B/iso/LICENSE"

if [ -n "${SELFTEST:-}" ]; then
    install -m755 "$B/selftest.fish" "$MNT/@system/libexec/fasdeqos/selftest.fish"
    printf 'type = process\ncommand = /System/bin/fish /System/libexec/fasdeqos/selftest.fish\nrun-as = live\noptions = runs-on-console\nenv-file = /System/etc/dinit.d/env.live\nrestart = false\n' >"$MNT/@system/etc/dinit.d/session"
fi

say "ни одного симлинка: заменяю клонами"
flatten() {
    local root=$1 link tgt dir abs
    while IFS= read -r -d '' link; do
        tgt=$(readlink "$link")
        dir=$(dirname "$link")
        case "$tgt" in
            /System/*) abs="$MNT/@system/${tgt#/System/}" ;;
            /home/*)   abs="$MNT/@homebrew/${tgt#/home/}" ;;
            /*)        abs="$tgt" ;;
            *)         abs="$dir/$tgt" ;;
        esac
        abs=$(realpath -m "$abs")
        rm "$link"
        if [ -e "$abs" ]; then
            if [ -d "$abs" ]; then cp -a --reflink=always "$abs" "$link"; else cp --reflink=always "$abs" "$link"; fi
        fi
    done < <(find "$root" -type l -print0)
}
for pass in 1 2 3; do flatten "$MNT/@system"; flatten "$MNT/@homebrew"; done
LEFT=$(find "$MNT/@system" "$MNT/@homebrew" -type l | wc -l)
echo "   симлинков осталось: $LEFT"
[ "$LEFT" -eq 0 ]

mkdir -p "$MNT/.snapshots"
btrfs subvolume snapshot -r "$MNT/@system" "$MNT/.snapshots/system-0.2" >/dev/null

say "сжатие образа"
sync
btrfs balance start -d -m "$MNT" >/dev/null 2>&1 || true
sync
ALLOC=$(btrfs filesystem usage -b "$MNT" | awk '/Device allocated:/ {print $3; exit}')
NEW=$(( ALLOC / 1048576 + 128 ))
SHRUNK=0
if btrfs filesystem resize "1:${NEW}M" "$MNT" >/dev/null 2>&1; then SHRUNK=1; fi
sync
umount "$MNT"
[ "$SHRUNK" = 1 ] && truncate -s "${NEW}M" "$IMG"
ls -la "$IMG" | awk '{printf "контейнер: %.0f МБ\n", $5/1048576}'

say "initramfs, ядро, загрузчик"
gcc -O2 -static -Wall -o "$B/init" "$B/init.c"
rm -rf "$B/initrd"
mkdir -p "$B/initrd/dev" "$B/initrd/proc" "$B/initrd/sys"
install -m755 "$B/init" "$B/initrd/init"
( cd "$B/initrd" && find . | cpio -o -H newc --quiet | zstd -19 -q -o "$B/iso/boot/initramfs.zst" )
install -m644 "$S/linux/arch/x86/boot/bzImage" "$B/iso/boot/vmlinuz"
cat >"$B/iso/boot/grub/grub.cfg" <<'EOF_GRUB'
set timeout=2
set default=0
menuentry "FasdeqOS" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 quiet loglevel=3 firmware_class.path=/System/Library/Firmware modprobe.blacklist=nouveau
    initrd /boot/initramfs.zst
}
menuentry "FasdeqOS (verbose)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 loglevel=7 firmware_class.path=/System/Library/Firmware
    initrd /boot/initramfs.zst
}
EOF_GRUB
rm -f "$ISO"
grub-mkrescue -o "$ISO" "$B/iso" -volid FASDEQOS >"$L/grub-mkrescue.log" 2>&1
ls -la "$ISO" | awk '{printf "ISO: %.0f МБ  %s\n", $5/1048576, $9}'
( cd "$O" && sha256sum "$(basename "$ISO")" | tee "$(basename "$ISO").sha256" )
rm -f /System
rm -rf /home/linuxbrew
