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
