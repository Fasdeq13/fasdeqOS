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
