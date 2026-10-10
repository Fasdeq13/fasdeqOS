#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <time.h>
#include <pwd.h>
#include <grp.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#define PKG_VERSION "2026.10.10-3"
#define CACHY "docker.io/cachyos/cachyos:latest"
#define DAVB "ghcr.io/zelikos/davincibox:latest"
#define PAC(x) "sudo pacman -Sy --noconfirm --needed " x
#define PACAUR(x) "sudo pacman -Sy --noconfirm --needed " x " || (command -v paru >/dev/null 2>&1 && paru -S --noconfirm --needed " x ")"
#define MULTILIB "grep -q '^\\[multilib\\]' /etc/pacman.conf || printf '[multilib]\\nInclude = /etc/pacman.d/mirrorlist\\n' | sudo tee -a /etc/pacman.conf >/dev/null; "
#define UPG "sudo pacman -Syu --noconfirm"

typedef enum { K_CONTAINER, K_FLATPAK, K_NATIVE, K_AUR } kind_t;

typedef struct {
    const char *name;
    const char *aliases;
    const char *app;
    const char *comment;
    kind_t kind;
    const char *image;
    const char *inst;
    const char *exec;
    const char *icon;
    const char *cat;
    int term;
    const char *natpkgs;
    const char *post;
    const char *note;
    const char *aur;
    const char *session;
} def_t;

static const def_t catalog[] = {
    { .name = "steam", .app = "Steam", .comment = "Valve Steam game client",
      .kind = K_CONTAINER, .image = CACHY, .inst = MULTILIB PAC("steam"),
      .exec = "steam", .icon = "steam", .cat = "Game;" },
    { .name = "blender", .app = "Blender", .comment = "3D creation suite",
      .kind = K_CONTAINER, .image = CACHY, .inst = PAC("blender"),
      .exec = "blender", .icon = "blender", .cat = "Graphics;3DGraphics;" },
    { .name = "discord", .app = "Discord", .comment = "Voice and text chat",
      .kind = K_CONTAINER, .image = CACHY, .inst = PAC("discord"),
      .exec = "discord", .icon = "discord", .cat = "Network;InstantMessaging;" },
    { .name = "vesktop", .app = "Vesktop", .comment = "Discord client with Vencord",
      .kind = K_FLATPAK, .image = "dev.vencord.Vesktop",
      .icon = "dev.vencord.Vesktop", .cat = "Network;InstantMessaging;" },
    { .name = "davinci-resolve", .aliases = "resolve,resolve-pro,davinci-resolve-pro",
      .app = "DaVinci Resolve", .comment = "Video editing and colour grading (davincibox)",
      .kind = K_CONTAINER, .image = DAVB, .inst = "command -v setup-davincibox.sh >/dev/null 2>&1 && setup-davincibox.sh || true",
      .exec = "/opt/resolve/bin/resolve", .icon = "davinci-resolve", .cat = "AudioVideo;Video;",
      .note = "Blackmagic does not allow redistribution: download the DaVinci Resolve zip from blackmagicdesign.com and finish the setup with: pkg shell davinci-resolve, then setup-davincibox.sh" },
    { .name = "jetbrains-toolbox", .app = "JetBrains Toolbox", .comment = "JetBrains IDE manager",
      .kind = K_CONTAINER, .image = CACHY,
      .inst = PAC("curl tar fuse2 libxcrypt-compat nss alsa-lib") " && mkdir -p \"$HOME/.local/jetbrains-toolbox\" && curl -fL 'https://data.services.jetbrains.com/products/download?platform=linux&code=TBA' -o /tmp/toolbox.tgz && tar -xzf /tmp/toolbox.tgz -C \"$HOME/.local/jetbrains-toolbox\" --strip-components=1 && rm -f /tmp/toolbox.tgz",
      .exec = "sh -c 'exec \"$HOME/.local/jetbrains-toolbox/bin/jetbrains-toolbox\"'", .icon = "jetbrains-toolbox", .cat = "Development;IDE;" },
    { .name = "openrazer", .app = "OpenRazer", .comment = "Razer lighting and macro daemon",
      .kind = K_CONTAINER, .image = CACHY, .inst = PAC("openrazer-daemon python-openrazer"),
      .exec = "openrazer-daemon -F", .icon = "openrazer", .cat = "System;Settings;", .term = 1,
      .note = "the openrazer kernel module must be provided by the host kernel" },
    { .name = "opentabletdriver", .app = "OpenTabletDriver", .comment = "Graphics tablet driver and UI",
      .kind = K_CONTAINER, .image = CACHY, .inst = PACAUR("opentabletdriver"),
      .exec = "otd-gui", .icon = "opentabletdriver", .cat = "System;Settings;",
      .note = "the package may live only in the AUR; the install uses paru when pacman does not have it" },
    { .name = "openrgb", .app = "OpenRGB", .comment = "RGB lighting control",
      .kind = K_CONTAINER, .image = CACHY, .inst = PAC("openrgb"),
      .exec = "openrgb", .icon = "OpenRGB", .cat = "System;Settings;" },
    { .name = "oversteer", .app = "Oversteer", .comment = "Steering wheel settings",
      .kind = K_CONTAINER, .image = CACHY, .inst = PACAUR("oversteer"),
      .exec = "oversteer", .icon = "oversteer", .cat = "System;Settings;" },
    { .name = "displaylink", .app = "DisplayLink", .comment = "DisplayLink dock userspace driver",
      .kind = K_CONTAINER, .image = CACHY, .inst = PACAUR("displaylink"),
      .exec = "DisplayLinkManager", .icon = "displaylink", .cat = "System;Settings;", .term = 1,
      .note = "the evdi kernel module must be provided by the host kernel" },
    { .name = "niri", .app = "niri", .comment = "Scrollable-tiling Wayland compositor (native)",
      .kind = K_NATIVE, .natpkgs = "niri xwayland-satellite foot fuzzel swaybg", .post = "session:niri",
      .session = "niri", .note = "start it from a tty with: start-niri" },
    { .name = "plasma", .aliases = "kde,kde-plasma", .app = "Plasma", .comment = "KDE Plasma desktop (native, Wayland)",
      .kind = K_NATIVE, .natpkgs = "plasma-desktop plasma-workspace plasma-nm plasma-pa powerdevil kscreen xdg-desktop-portal-kde konsole dolphin", .post = "session:plasma",
      .session = "startplasma-wayland", .note = "start it from a tty with: start-plasma. KWin expects logind, which this system does not have, so it may refuse to start; niri and mango are the safer choices" },
    { .name = "dms", .aliases = "dank-material-shell,dankmaterialshell", .app = "DMS", .comment = "DankMaterialShell, a Quickshell desktop shell (native)",
      .kind = K_NATIVE, .natpkgs = "dms-shell quickshell", .post = "session:none",
      .note = "DMS is a shell, not a compositor: install niri or mango as well, start-niri and start-mango run it automatically" },
    { .name = "mango", .aliases = "mangowc,mangowm", .app = "Mango", .comment = "Mango Wayland compositor (built from the AUR in a container)",
      .kind = K_AUR, .aur = "mangowm-git", .image = CACHY,
      .natpkgs = "wayland libinput libdrm libxkbcommon pixman libdisplay-info libliftoff hwdata seatd pcre2 xorg-xwayland libxcb foot", .post = "session:mango",
      .session = "mango", .note = "mangowm-git comes from the AUR and pulls wlroots and scenefx, the first install builds them and takes a while" },
    { .name = "noctalia", .aliases = "noctalia-shell", .app = "Noctalia", .comment = "Noctalia Quickshell desktop shell (built from the AUR in a container)",
      .kind = K_AUR, .aur = "noctalia-qs noctalia-shell", .image = CACHY,
      .natpkgs = "brightnessctl imagemagick python git", .post = "session:none",
      .note = "Noctalia is a shell, not a compositor: install niri or mango as well. The launch command is not verified, start-niri tries noctalia-shell when DMS is not installed" },
    { .name = "docker", .app = "Docker", .comment = "Container engine (native, dinit service)",
      .kind = K_NATIVE, .natpkgs = "docker containerd runc iptables-nft docker-compose", .post = "docker" },
    { .name = "fish", .app = "fish", .comment = "Friendly interactive shell (native)",
      .kind = K_NATIVE, .natpkgs = "fish", .post = "shell:fish" },
    { .name = "zsh", .app = "zsh", .comment = "Z shell (native)",
      .kind = K_NATIVE, .natpkgs = "zsh", .post = "shell:zsh" },
};

#define NCAT ((int)(sizeof catalog / sizeof catalog[0]))

static const char *P_ROOT = "";
static const char *DISTROBOX = "distrobox";
static const char *FLATPAK = "flatpak";
static const char *ARCHFETCH = "arch-fetch";
static const char *PODMAN = "podman";
static int opt_y, opt_n, opt_q, opt_f;
static uid_t tuid;
static gid_t tgid;
static char thome[512];
static char tname[64];

static void die(const char *fmt, ...)
{
    va_list ap;
    fprintf(stderr, "pkg: ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

static void say(const char *fmt, ...)
{
    va_list ap;
    if (opt_q)
        return;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}

static char *pth(const char *fmt, ...)
{
    static char buf[8][4096];
    static int i;
    char tmp[4000];
    va_list ap;
    char *o = buf[i++ & 7];
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    snprintf(o, 4096, "%s%s", P_ROOT, tmp);
    return o;
}

static const char *apps_dir(void) { return pth("/Applications"); }
static const char *share_dir(void) { return pth("/System/share/applications"); }
static const char *db_dir(void) { return pth("/Library/pkg/db"); }

static int mkdir_p(const char *path, mode_t mode)
{
    char tmp[4096];
    char *p;
    snprintf(tmp, sizeof tmp, "%s", path);
    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(tmp, mode) && errno != EEXIST)
                return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, mode) && errno != EEXIST)
        return -1;
    return 0;
}

static void find_user(void)
{
    const char *want = getenv("PKG_USER");
    FILE *f;
    char line[1024];
    if (!want || !*want)
        want = getenv("SUDO_USER");
    if ((!want || !*want) && geteuid() != 0) {
        tuid = geteuid();
        tgid = getegid();
        snprintf(tname, sizeof tname, "%s", getenv("USER") ? getenv("USER") : "user");
        snprintf(thome, sizeof thome, "%s", getenv("HOME") ? getenv("HOME") : "/");
        return;
    }
    f = fopen(pth("/private/etc/passwd"), "r");
    if (!f)
        f = fopen("/etc/passwd", "r");
    tuid = 0;
    tgid = 0;
    snprintf(tname, sizeof tname, "root");
    snprintf(thome, sizeof thome, "/root");
    if (!f)
        return;
    while (fgets(line, sizeof line, f)) {
        char *fld[7];
        char *s = line;
        int n = 0;
        line[strcspn(line, "\n")] = 0;
        while (n < 7) {
            fld[n++] = s;
            s = strchr(s, ':');
            if (!s)
                break;
            *s++ = 0;
        }
        if (n < 6)
            continue;
        if ((want && *want && !strcmp(fld[0], want)) || (!(want && *want) && atoi(fld[2]) == 1000)) {
            snprintf(tname, sizeof tname, "%s", fld[0]);
            tuid = (uid_t)atoi(fld[2]);
            tgid = (gid_t)atoi(fld[3]);
            snprintf(thome, sizeof thome, "%s", fld[5]);
            break;
        }
    }
    fclose(f);
}

static int runvp(int as_user, char *const argv[])
{
    pid_t pid;
    int st;
    fflush(NULL);
    pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0) {
        if (as_user && geteuid() == 0 && tuid != 0) {
            char run[64];
            gid_t g = tgid;
            snprintf(run, sizeof run, "/run/user/%u", (unsigned)tuid);
            if (setgroups(1, &g) || setgid(tgid) || setuid(tuid))
                _exit(126);
            setenv("HOME", thome, 1);
            setenv("USER", tname, 1);
            setenv("LOGNAME", tname, 1);
            if (!getenv("XDG_RUNTIME_DIR"))
                setenv("XDG_RUNTIME_DIR", run, 1);
        }
        execvp(argv[0], argv);
        fprintf(stderr, "pkg: cannot run %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
        ;
    return WIFEXITED(st) ? WEXITSTATUS(st) : 128;
}

static int runv(int as_user, ...)
{
    char *argv[64];
    int n = 0;
    va_list ap;
    char *a;
    va_start(ap, as_user);
    while (n < 63 && (a = va_arg(ap, char *)) != NULL)
        argv[n++] = a;
    va_end(ap);
    argv[n] = NULL;
    return runvp(as_user, argv);
}

static int confirm(void)
{
    char buf[32];
    if (opt_n)
        return 0;
    if (opt_y) {
        say("\n");
        return 1;
    }
    if (!isatty(0))
        return 0;
    printf("\nProceed with this action? [y/N]: ");
    fflush(stdout);
    if (!fgets(buf, sizeof buf, stdin))
        return 0;
    return buf[0] == 'y' || buf[0] == 'Y';
}

static const char *kind_name(kind_t k)
{
    return k == K_CONTAINER ? "container" : k == K_FLATPAK ? "flatpak" : k == K_AUR ? "aur-build" : "native";
}

static int alias_match(const def_t *d, const char *s)
{
    char buf[256];
    char *t, *sv = NULL;
    if (!strcasecmp(d->name, s))
        return 1;
    if (!d->aliases)
        return 0;
    snprintf(buf, sizeof buf, "%s", d->aliases);
    for (t = strtok_r(buf, ",", &sv); t; t = strtok_r(NULL, ",", &sv))
        if (!strcasecmp(t, s))
            return 1;
    return 0;
}

static const def_t *find_def(const char *s)
{
    int i;
    for (i = 0; i < NCAT; i++)
        if (alias_match(&catalog[i], s))
            return &catalog[i];
    return NULL;
}

typedef struct {
    char kind[16];
    char app[128];
    char bundle[1024];
    char container[128];
    char link[1024];
    long when;
} rec_t;

static int read_rec(const char *name, rec_t *r)
{
    FILE *f;
    char line[2048];
    memset(r, 0, sizeof *r);
    f = fopen(pth("/Library/pkg/db/%s", name), "r");
    if (!f)
        return 0;
    while (fgets(line, sizeof line, f)) {
        char *v = strchr(line, '=');
        if (!v)
            continue;
        *v++ = 0;
        v[strcspn(v, "\n")] = 0;
        if (!strcmp(line, "kind"))
            snprintf(r->kind, sizeof r->kind, "%s", v);
        else if (!strcmp(line, "app"))
            snprintf(r->app, sizeof r->app, "%s", v);
        else if (!strcmp(line, "bundle"))
            snprintf(r->bundle, sizeof r->bundle, "%s", v);
        else if (!strcmp(line, "container"))
            snprintf(r->container, sizeof r->container, "%s", v);
        else if (!strcmp(line, "link"))
            snprintf(r->link, sizeof r->link, "%s", v);
        else if (!strcmp(line, "when"))
            r->when = atol(v);
    }
    fclose(f);
    return 1;
}

static int write_rec(const char *name, const rec_t *r)
{
    FILE *f;
    mkdir_p(db_dir(), 0755);
    f = fopen(pth("/Library/pkg/db/%s", name), "w");
    if (!f)
        return -1;
    fprintf(f, "kind=%s\napp=%s\nbundle=%s\ncontainer=%s\nlink=%s\nwhen=%ld\n",
            r->kind, r->app, r->bundle, r->container, r->link, r->when);
    fclose(f);
    return 0;
}

static int installed(const char *name)
{
    return access(pth("/Library/pkg/db/%s", name), F_OK) == 0;
}

static int write_text(const char *path, const char *text)
{
    FILE *f = fopen(path, "w");
    if (!f)
        return -1;
    fputs(text, f);
    fclose(f);
    return 0;
}

static int icon_ok(const char *bundle)
{
    char p[4200];
    snprintf(p, sizeof p, "%s/Icon.png", bundle);
    return access(p, F_OK) == 0;
}

static void write_desktop(const def_t *d, const char *bundle, const char *desk, const char *cname)
{
    FILE *f = fopen(desk, "w");
    if (!f)
        return;
    fprintf(f, "[Desktop Entry]\nType=Application\nName=%s\nComment=%s\n", d->app, d->comment);
    if (d->kind == K_FLATPAK)
        fprintf(f, "Exec=%s run %s\n", FLATPAK, d->image);
    else
        fprintf(f, "Exec=/System/bin/distrobox enter -n %s -- %s\n", cname, d->exec);
    if (d->icon && icon_ok(bundle))
        fprintf(f, "Icon=%s/Icon.png\n", bundle);
    else if (d->icon)
        fprintf(f, "Icon=%s\n", d->icon);
    fprintf(f, "Terminal=%s\nCategories=%s\nStartupNotify=true\n", d->term ? "true" : "false", d->cat ? d->cat : "Utility;");
    fclose(f);
}

static void grab_icon(const def_t *d, const char *cname, const char *bundle)
{
    static const char *sizes[] = { "256x256", "128x128", "512x512", "96x96", "64x64", "48x48" };
    size_t i;
    char src[512], out[4096];
    struct stat st;
    snprintf(out, sizeof out, "%s/Icon.png", bundle);
    for (i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        snprintf(src, sizeof src, "/usr/share/icons/hicolor/%s/apps/%s.png", sizes[i], d->icon);
        runv(1, "sh", "-c", "exec \"$0\" enter -n \"$1\" -- cat \"$2\" > \"$3\" 2>/dev/null",
             (char *)DISTROBOX, (char *)cname, src, out, NULL);
        if (stat(out, &st) == 0 && st.st_size > 0)
            return;
        unlink(out);
    }
}

static void chown_tree(const char *path)
{
    if (geteuid() == 0 && tuid != 0) {
        char ug[64];
        snprintf(ug, sizeof ug, "%u:%u", (unsigned)tuid, (unsigned)tgid);
        runv(0, "chown", "-R", ug, (char *)path, NULL);
    }
}

static void rm_tree(const char *path)
{
    runv(0, "rm", "-rf", path, NULL);
}

static void make_link(const char *link, const char *target)
{
    unlink(link);
    if (symlink(target, link))
        fprintf(stderr, "pkg: cannot create %s: %s\n", link, strerror(errno));
}

static int install_container(const def_t *d)
{
    char bundle[1024], desk[1100], link[1100], cname[128], home[1100];
    rec_t r;
    int rc;
    snprintf(cname, sizeof cname, "pkg-%s", d->name);
    snprintf(bundle, sizeof bundle, "%s/%s.pkg", apps_dir(), d->app);
    snprintf(home, sizeof home, "%s/Home", bundle);
    mkdir_p(home, 0755);
    chown_tree(bundle);
    rc = runv(1, DISTROBOX, "create", "--yes", "--name", cname, "--image", d->image, "--home", home,
              (access("/dev/nvidia0", F_OK) == 0) ? "--nvidia" : "--no-entry", NULL);
    if (rc == 0 && d->inst && *d->inst)
        rc = runv(1, DISTROBOX, "enter", "-n", cname, "--", "sh", "-c", d->inst, NULL);
    if (rc) {
        runv(1, DISTROBOX, "rm", "--force", cname, NULL);
        rm_tree(bundle);
        return rc;
    }
    if (d->icon)
        grab_icon(d, cname, bundle);
    snprintf(desk, sizeof desk, "%s/%s.desktop", bundle, d->app);
    write_desktop(d, bundle, desk, cname);
    mkdir_p(share_dir(), 0755);
    snprintf(link, sizeof link, "%s/%s.desktop", share_dir(), d->name);
    make_link(link, desk);
    chown_tree(bundle);
    memset(&r, 0, sizeof r);
    snprintf(r.kind, sizeof r.kind, "container");
    snprintf(r.app, sizeof r.app, "%s", d->app);
    snprintf(r.bundle, sizeof r.bundle, "%s", bundle);
    snprintf(r.container, sizeof r.container, "%s", cname);
    snprintf(r.link, sizeof r.link, "%s", link);
    r.when = (long)time(NULL);
    return write_rec(d->name, &r);
}

static int install_flatpak(const def_t *d)
{
    char bundle[1024], desk[1100], link[1100];
    rec_t r;
    int rc;
    rc = runv(1, FLATPAK, "remote-add", "--user", "--if-not-exists", "flathub",
              "https://dl.flathub.org/repo/flathub.flatpakrepo", NULL);
    if (rc == 0)
        rc = runv(1, FLATPAK, "install", "--user", "-y", "--noninteractive", "flathub", d->image, NULL);
    if (rc)
        return rc;
    snprintf(bundle, sizeof bundle, "%s/%s.pkg", apps_dir(), d->app);
    mkdir_p(bundle, 0755);
    snprintf(desk, sizeof desk, "%s/%s.desktop", bundle, d->app);
    write_desktop(d, bundle, desk, "");
    mkdir_p(share_dir(), 0755);
    snprintf(link, sizeof link, "%s/%s.desktop", share_dir(), d->name);
    make_link(link, desk);
    chown_tree(bundle);
    memset(&r, 0, sizeof r);
    snprintf(r.kind, sizeof r.kind, "flatpak");
    snprintf(r.app, sizeof r.app, "%s", d->app);
    snprintf(r.bundle, sizeof r.bundle, "%s", bundle);
    snprintf(r.container, sizeof r.container, "%s", d->image);
    snprintf(r.link, sizeof r.link, "%s", link);
    r.when = (long)time(NULL);
    return write_rec(d->name, &r);
}

static void copy_tree(const char *stage, const char *rel, FILE *man)
{
    char src[4096], dst[4096], full[4096];
    DIR *dir;
    struct dirent *e;
    snprintf(src, sizeof src, "%s%s", stage, rel);
    dir = opendir(src);
    if (!dir)
        return;
    while ((e = readdir(dir))) {
        struct stat st;
        char r2[4096];
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        snprintf(r2, sizeof r2, "%s/%s", rel, e->d_name);
        snprintf(full, sizeof full, "%s%s", stage, r2);
        snprintf(dst, sizeof dst, "%s%s", P_ROOT, r2);
        if (lstat(full, &st))
            continue;
        if (S_ISDIR(st.st_mode)) {
            if (mkdir(dst, st.st_mode & 07777) == 0)
                fprintf(man, "D %s\n", r2);
            copy_tree(stage, r2, man);
        } else if (S_ISLNK(st.st_mode)) {
            char tgt[4096];
            ssize_t n = readlink(full, tgt, sizeof tgt - 1);
            struct stat x;
            if (n < 0 || lstat(dst, &x) == 0)
                continue;
            tgt[n] = 0;
            if (symlink(tgt, dst) == 0)
                fprintf(man, "F %s\n", r2);
        } else if (S_ISREG(st.st_mode)) {
            int in, out;
            char buf[65536];
            ssize_t n;
            out = open(dst, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 07777);
            if (out < 0)
                continue;
            in = open(full, O_RDONLY);
            while (in >= 0 && (n = read(in, buf, sizeof buf)) > 0)
                if (write(out, buf, (size_t)n) != n)
                    break;
            if (in >= 0)
                close(in);
            close(out);
            fprintf(man, "F %s\n", r2);
        }
    }
    closedir(dir);
}

static void register_shell(const char *sh)
{
    FILE *f;
    char line[512];
    int have = 0;
    f = fopen(pth("/private/etc/shells"), "r");
    if (f) {
        while (fgets(line, sizeof line, f)) {
            line[strcspn(line, "\n")] = 0;
            if (!strcmp(line, sh))
                have = 1;
        }
        fclose(f);
    }
    if (!have && (f = fopen(pth("/private/etc/shells"), "a"))) {
        fprintf(f, "%s\n", sh);
        fclose(f);
    }
}

static void write_session(const def_t *d)
{
    char path[512];
    FILE *f;
    mkdir_p(pth("/System/bin"), 0755);
    snprintf(path, sizeof path, "%s", pth("/System/bin/start-%s", d->name));
    f = fopen(path, "w");
    if (!f)
        return;
    fprintf(f, "#!/System/bin/busybox sh\n. /System/lib/fasdeqos/desktop-env\n");
    if (strcmp(d->name, "plasma")) {
        fprintf(f, "if [ -x /System/bin/dms ]; then\n    /System/bin/dms run &\nelif [ -x /System/bin/noctalia-shell ]; then\n    /System/bin/noctalia-shell &\nfi\n");
    }
    fprintf(f, "exec %s\n", d->session);
    fclose(f);
    chmod(path, 0755);
    mkdir_p(pth("/System/share/wayland-sessions"), 0755);
    f = fopen(pth("/System/share/wayland-sessions/%s.desktop", d->name), "w");
    if (f) {
        fprintf(f, "[Desktop Entry]\nName=%s\nExec=/System/bin/start-%s\nType=Application\n", d->app, d->name);
        fclose(f);
    }
}

static void post_native(const def_t *d)
{
    if (!d->post)
        return;
    if (!strncmp(d->post, "shell:", 6))
    {
        char sh[128];
        snprintf(sh, sizeof sh, "/System/bin/%s", d->post + 6);
        register_shell(sh);
    }
    if (!strncmp(d->post, "session:", 8) && strcmp(d->post + 8, "none"))
        write_session(d);
    if (!strcmp(d->post, "docker")) {
        mkdir_p(pth("/private/etc/dinit.d/boot.d"), 0755);
        write_text(pth("/private/etc/dinit.d/docker"),
                   "type = process\n"
                   "command = /System/bin/dockerd -H unix:///private/var/run/docker.sock --data-root /private/var/lib/docker\n"
                   "restart = true\n"
                   "smooth-recovery = true\n"
                   "logfile = /private/var/log/dockerd.log\n");
        if (access(pth("/private/etc/dinit.d/boot.d/docker"), F_OK))
            symlink("../docker", pth("/private/etc/dinit.d/boot.d/docker"));
        mkdir_p(pth("/private/var/lib/docker"), 0711);
    }
}

static void refresh_libs(void)
{
    if (!*P_ROOT)
        runv(0, "ldconfig", NULL);
}

static int run_fetch(const char *stage, const char *natpkgs, const char *record, int soft)
{
    char *argv[64];
    char buf[1024], *t, *sv = NULL;
    int n = 0;
    argv[n++] = (char *)ARCHFETCH;
    argv[n++] = "--quiet";
    if (soft)
        argv[n++] = "--soft";
    if (record) {
        argv[n++] = "--record";
        argv[n++] = (char *)record;
    }
    argv[n++] = "--root";
    argv[n++] = (char *)stage;
    snprintf(buf, sizeof buf, "%s", natpkgs);
    for (t = strtok_r(buf, " ", &sv); t && n < 62; t = strtok_r(NULL, " ", &sv))
        argv[n++] = strdup(t);
    argv[n] = NULL;
    return runvp(0, argv);
}

static int commit_stage(const def_t *d, const char *stage)
{
    FILE *man;
    rec_t r;
    mkdir_p(db_dir(), 0755);
    man = fopen(pth("/Library/pkg/db/%s.files", d->name), "w");
    if (!man) {
        rm_tree(stage);
        return 1;
    }
    copy_tree(stage, "", man);
    rm_tree(stage);
    post_native(d);
    if (d->post && !strncmp(d->post, "session:", 8) && strcmp(d->post + 8, "none"))
        fprintf(man, "F /System/bin/start-%s\nF /System/share/wayland-sessions/%s.desktop\n", d->name, d->name);
    if (d->post && !strcmp(d->post, "docker"))
        fprintf(man, "F /private/etc/dinit.d/docker\nF /private/etc/dinit.d/boot.d/docker\n");
    fclose(man);
    refresh_libs();
    memset(&r, 0, sizeof r);
    snprintf(r.kind, sizeof r.kind, "native");
    snprintf(r.app, sizeof r.app, "%s", d->app);
    r.when = (long)time(NULL);
    return write_rec(d->name, &r);
}

static int need_root(const def_t *d)
{
    if (geteuid() == 0)
        return 0;
    fprintf(stderr, "pkg: %s is a native package, root is required (try: su -c 'pkg install %s')\n", d->name, d->name);
    return 1;
}

static int install_native(const def_t *d)
{
    char stage[1024];
    int rc;
    if (need_root(d))
        return 1;
    snprintf(stage, sizeof stage, "%s/Library/pkg/stage/%s", P_ROOT, d->name);
    rm_tree(stage);
    mkdir_p(stage, 0755);
    mkdir_p(db_dir(), 0755);
    rc = run_fetch(stage, d->natpkgs, pth("/Library/pkg/db/%s.ver", d->name), 0);
    if (rc) {
        rm_tree(stage);
        return rc;
    }
    return commit_stage(d, stage);
}

static int install_aur(const def_t *d)
{
    char stage[1024], build[1024], home[1100], out[1200], cmd[2048], line[512];
    char *argv[200];
    int n = 0, rc, i;
    FILE *p;
    DIR *dir;
    struct dirent *e;
    char *files[128];
    int nf = 0;
    if (need_root(d))
        return 1;
    snprintf(build, sizeof build, "%s/Library/pkg/build", P_ROOT);
    snprintf(home, sizeof home, "%s/home", build);
    snprintf(out, sizeof out, "%s/out", home);
    mkdir_p(home, 0755);
    chown_tree(build);
    runv(1, DISTROBOX, "create", "--yes", "--name", "pkg-build", "--image", d->image, "--home", home, "--no-entry", NULL);
    snprintf(cmd, sizeof cmd,
             "sudo pacman -Sy --noconfirm --needed base-devel git paru && rm -rf \"$HOME/out\" \"$HOME/.cache/paru/clone\" && mkdir -p \"$HOME/out\" && "
             "paru -S --noconfirm --needed --skipreview %s && find \"$HOME/.cache/paru/clone\" -name '*.pkg.tar.*' ! -name '*-debug-*' -exec cp {} \"$HOME/out/\" \\;",
             d->aur);
    rc = runv(1, DISTROBOX, "enter", "-n", "pkg-build", "--", "sh", "-c", cmd, NULL);
    if (rc)
        return rc;
    dir = opendir(out);
    while (dir && (e = readdir(dir)) && nf < 127) {
        if (strstr(e->d_name, ".pkg.tar")) {
            char fp[1400];
            snprintf(fp, sizeof fp, "%s/%s", out, e->d_name);
            files[nf++] = strdup(fp);
        }
    }
    if (dir)
        closedir(dir);
    if (!nf) {
        fprintf(stderr, "pkg: the build produced no packages\n");
        return 1;
    }
    snprintf(stage, sizeof stage, "%s/Library/pkg/stage/%s", P_ROOT, d->name);
    rm_tree(stage);
    mkdir_p(stage, 0755);
    argv[n++] = (char *)ARCHFETCH;
    argv[n++] = "--extract";
    argv[n++] = "--root";
    argv[n++] = stage;
    for (i = 0; i < nf; i++)
        argv[n++] = files[i];
    argv[n] = NULL;
    rc = runvp(0, argv);
    if (rc) {
        rm_tree(stage);
        return rc;
    }
    {
        char deps[8192] = "";
        snprintf(cmd, sizeof cmd, "%s --deps", ARCHFETCH);
        for (i = 0; i < nf; i++) {
            strncat(cmd, " '", sizeof cmd - strlen(cmd) - 1);
            strncat(cmd, files[i], sizeof cmd - strlen(cmd) - 1);
            strncat(cmd, "'", sizeof cmd - strlen(cmd) - 1);
        }
        p = popen(cmd, "r");
        while (p && fgets(line, sizeof line, p)) {
            line[strcspn(line, "\n")] = 0;
            if (strlen(deps) + strlen(line) + 2 < sizeof deps) {
                strcat(deps, line);
                strcat(deps, " ");
            }
        }
        if (p)
            pclose(p);
        strncat(deps, d->natpkgs, sizeof deps - strlen(deps) - 1);
        run_fetch(stage, deps, pth("/Library/pkg/db/%s.ver", d->name), 1);
    }
    for (i = 0; i < nf; i++)
        free(files[i]);
    return commit_stage(d, stage);
}

static int remove_native(const char *name)
{
    FILE *f;
    char **lines = NULL;
    size_t n = 0, cap = 0, i;
    char line[4200];
    f = fopen(pth("/Library/pkg/db/%s.files", name), "r");
    if (f) {
        while (fgets(line, sizeof line, f)) {
            line[strcspn(line, "\n")] = 0;
            if (n == cap) {
                cap = cap ? cap * 2 : 1024;
                lines = realloc(lines, cap * sizeof *lines);
                if (!lines)
                    die("out of memory");
            }
            lines[n++] = strdup(line);
        }
        fclose(f);
    }
    for (i = n; i-- > 0;) {
        if (lines[i][0] == 'F')
            unlink(pth("%s", lines[i] + 2));
        else if (lines[i][0] == 'D')
            rmdir(pth("%s", lines[i] + 2));
        free(lines[i]);
    }
    free(lines);
    unlink(pth("/Library/pkg/db/%s.files", name));
    unlink(pth("/Library/pkg/db/%s.ver", name));
    return 0;
}

static int installed_list(char names[][64], int max)
{
    DIR *d = opendir(db_dir());
    struct dirent *e;
    int n = 0, i, j;
    if (!d)
        return 0;
    while ((e = readdir(d)) && n < max) {
        size_t l = strlen(e->d_name);
        if (e->d_name[0] == '.' || (l > 6 && !strcmp(e->d_name + l - 6, ".files")) || (l > 4 && !strcmp(e->d_name + l - 4, ".ver")))
            continue;
        snprintf(names[n++], 64, "%s", e->d_name);
    }
    closedir(d);
    for (i = 0; i < n; i++)
        for (j = i + 1; j < n; j++)
            if (strcmp(names[i], names[j]) > 0) {
                char t[64];
                memcpy(t, names[i], 64);
                memcpy(names[i], names[j], 64);
                memcpy(names[j], t, 64);
            }
    return n;
}

static int cmd_install(int argc, char **argv)
{
    const def_t *todo[64];
    int n = 0, i, bad = 0, rc = 0;
    for (i = 0; i < argc; i++) {
        const def_t *d = find_def(argv[i]);
        int dup = 0, j;
        if (!d) {
            fprintf(stderr, "pkg: no packages available to install matching '%s' have been found in the repositories\n", argv[i]);
            bad = 1;
            continue;
        }
        if (installed(d->name)) {
            say("%s-rolling is already installed.\n", d->name);
            continue;
        }
        for (j = 0; j < n; j++)
            if (todo[j] == d)
                dup = 1;
        if (!dup && n < 64)
            todo[n++] = d;
    }
    if (bad && !n)
        return 1;
    if (!n) {
        say("Nothing to do.\n");
        return 0;
    }
    say("Updating fasdeqos repository catalogue...\nThe following %d package(s) will be affected (of %d checked):\n\nNew packages to be INSTALLED:\n", n, NCAT);
    for (i = 0; i < n; i++)
        say("\t%s: rolling [%s]\n", todo[i]->name, kind_name(todo[i]->kind));
    say("\nNumber of packages to be installed: %d\n", n);
    if (!confirm()) {
        say("Aborted.\n");
        return opt_n ? 0 : 1;
    }
    for (i = 0; i < n; i++) {
        int r;
        say("[%d/%d] Installing %s-rolling...\n", i + 1, n, todo[i]->name);
        switch (todo[i]->kind) {
        case K_CONTAINER: r = install_container(todo[i]); break;
        case K_FLATPAK: r = install_flatpak(todo[i]); break;
        case K_AUR: r = install_aur(todo[i]); break;
        default: r = install_native(todo[i]); break;
        }
        if (r) {
            fprintf(stderr, "pkg: failed to install %s\n", todo[i]->name);
            rc = 1;
        } else if (todo[i]->note) {
            say("Message from %s-rolling:\n --\n%s\n --\n", todo[i]->name, todo[i]->note);
        }
    }
    return rc || bad;
}

static int remove_one(const char *name)
{
    rec_t r;
    if (!read_rec(name, &r))
        return 1;
    if (!strcmp(r.kind, "container") && r.container[0])
        runv(1, DISTROBOX, "rm", "--force", r.container, NULL);
    else if (!strcmp(r.kind, "flatpak") && r.container[0])
        runv(1, FLATPAK, "uninstall", "--user", "-y", "--noninteractive", r.container, NULL);
    else if (!strcmp(r.kind, "native")) {
        if (geteuid() != 0) {
            fprintf(stderr, "pkg: %s is native, root is required\n", name);
            return 1;
        }
        remove_native(name);
    }
    if (r.link[0])
        unlink(r.link);
    if (r.bundle[0])
        rm_tree(r.bundle);
    unlink(pth("/Library/pkg/db/%s", name));
    return 0;
}

static int cmd_delete(int argc, char **argv)
{
    char want[64][64];
    int n = 0, i, rc = 0;
    for (i = 0; i < argc && n < 64; i++) {
        const def_t *d = find_def(argv[i]);
        const char *nm = d ? d->name : argv[i];
        if (!installed(nm)) {
            fprintf(stderr, "pkg: no package(s) matching '%s' installed\n", argv[i]);
            rc = 1;
            continue;
        }
        snprintf(want[n++], 64, "%s", nm);
    }
    if (!n)
        return 1;
    say("Checking integrity... done (0 conflicting)\nThe following %d package(s) will be affected (of 0 checked):\n\nInstalled packages to be REMOVED:\n", n);
    for (i = 0; i < n; i++) {
        rec_t r;
        read_rec(want[i], &r);
        say("\t%s-rolling", want[i]);
        if (r.bundle[0])
            say("  (%s, including its Home)", r.bundle);
        say("\n");
    }
    say("\nNumber of packages to be removed: %d\n", n);
    if (!confirm()) {
        say("Aborted.\n");
        return opt_n ? 0 : 1;
    }
    for (i = 0; i < n; i++) {
        say("[%d/%d] Deleting %s-rolling... ", i + 1, n, want[i]);
        if (remove_one(want[i])) {
            say("failed\n");
            rc = 1;
        } else
            say("done\n");
    }
    return rc;
}

static int contains_ci(const char *h, const char *n)
{
    return h && strcasestr(h, n) != NULL;
}

static int cmd_search(int argc, char **argv)
{
    int i, hits = 0;
    for (i = 0; i < NCAT; i++) {
        const def_t *d = &catalog[i];
        int ok = argc == 0, j;
        for (j = 0; j < argc && !ok; j++)
            ok = contains_ci(d->name, argv[j]) || contains_ci(d->aliases, argv[j]) || contains_ci(d->comment, argv[j]) || contains_ci(d->app, argv[j]);
        if (!ok)
            continue;
        hits++;
        if (opt_q)
            printf("%s\n", d->name);
        else {
            char nv[96];
            snprintf(nv, sizeof nv, "%s-rolling", d->name);
            printf("%-28s %s\n", nv, d->comment);
        }
    }
    return hits ? 0 : 1;
}

static void show_info(const char *name)
{
    rec_t r;
    const def_t *d = find_def(name);
    char tb[64] = "";
    struct stat st;
    if (!read_rec(name, &r)) {
        fprintf(stderr, "pkg: no package(s) matching '%s' installed\n", name);
        return;
    }
    if (r.when) {
        time_t t = r.when;
        strftime(tb, sizeof tb, "%a %b %e %H:%M:%S %Y", localtime(&t));
    }
    printf("%s-rolling\n", name);
    printf("Name           : %s\n", name);
    printf("Version        : rolling\n");
    printf("Installed on   : %s\n", tb);
    printf("Origin         : fasdeqos/%s\n", name);
    printf("Architecture   : amd64\n");
    printf("Kind           : %s\n", r.kind);
    if (d)
        printf("Comment        : %s\n", d->comment);
    if (r.container[0])
        printf("%-15s: %s\n", strcmp(r.kind, "flatpak") ? "Container" : "Flatpak", r.container);
    if (r.bundle[0])
        printf("Bundle         : %s%s\n", r.bundle, stat(r.bundle, &st) ? " (missing)" : "");
    if (d && d->image && d->kind == K_CONTAINER)
        printf("Image          : %s\n", d->image);
    putchar('\n');
}

static int cmd_info(int argc, char **argv)
{
    char names[256][64];
    int n, i;
    if (argc > 0 && strcmp(argv[0], "-a")) {
        for (i = 0; i < argc; i++) {
            const def_t *d = find_def(argv[i]);
            show_info(d ? d->name : argv[i]);
        }
        return 0;
    }
    n = installed_list(names, 256);
    for (i = 0; i < n; i++) {
        const def_t *d = find_def(names[i]);
        char nv[96];
        snprintf(nv, sizeof nv, "%s-rolling", names[i]);
        printf("%-28s %s\n", nv, d ? d->comment : "");
    }
    return 0;
}

static int cmd_list(int argc, char **argv)
{
    int i;
    if (argc == 0)
        return cmd_info(0, NULL);
    for (i = 0; i < argc; i++) {
        rec_t r;
        const def_t *d = find_def(argv[i]);
        const char *nm = d ? d->name : argv[i];
        if (!read_rec(nm, &r)) {
            fprintf(stderr, "pkg: no package(s) matching '%s' installed\n", argv[i]);
            continue;
        }
        printf("%s-rolling owns the following files:\n", nm);
        if (r.bundle[0])
            printf("%s\n", r.bundle);
        if (r.link[0])
            printf("%s\n", r.link);
        if (!strcmp(r.kind, "native")) {
            FILE *f = fopen(pth("/Library/pkg/db/%s.files", nm), "r");
            char line[4200];
            while (f && fgets(line, sizeof line, f))
                if (line[0] == 'F')
                    fputs(line + 2, stdout);
            if (f)
                fclose(f);
        }
    }
    return 0;
}

static int check_native(const char *name, char *names, size_t cap, int show)
{
    char cmd[2048], line[1024];
    FILE *p;
    int n = 0;
    struct stat st;
    const char *ver = pth("/Library/pkg/db/%s.ver", name);
    if (stat(ver, &st))
        return 0;
    snprintf(cmd, sizeof cmd, "%s --quiet --check --list '%s' 2>/dev/null", ARCHFETCH, ver);
    p = popen(cmd, "r");
    while (p && fgets(line, sizeof line, p)) {
        char *a, *b, *c;
        line[strcspn(line, "\n")] = 0;
        a = line;
        b = strchr(a, '\t');
        if (!b)
            continue;
        *b++ = 0;
        c = strchr(b, '\t');
        if (!c)
            continue;
        *c++ = 0;
        if (show)
            say("\t%s: %s -> %s  (%s)\n", a, b, c, name);
        if (names && strlen(names) + strlen(a) + 2 < cap) {
            strcat(names, a);
            strcat(names, " ");
        }
        n++;
    }
    if (p)
        pclose(p);
    return n;
}

static int cmd_update(void)
{
    char names[256][64];
    int n = installed_list(names, 256), i, total = 0, cont = 0;
    say("Updating fasdeqos repository catalogue...\nfasdeqos repository is up to date.\nFetching Arch package databases for native packages...\n");
    for (i = 0; i < n; i++) {
        rec_t r;
        if (!read_rec(names[i], &r))
            continue;
        if (!strcmp(r.kind, "container") || !strcmp(r.kind, "flatpak"))
            cont++;
        else {
            if (!total)
                say("Upgrades available:\n");
            total += check_native(names[i], NULL, 0, 1);
        }
    }
    say("%d native package(s) can be upgraded, %d application(s) in containers or flatpak are checked while upgrading.\n", total, cont);
    return 0;
}

static int cmd_upgrade(void)
{
    char names[256][64];
    char out[256][4096];
    int n = installed_list(names, 256), i, total = 0, cont = 0, rc = 0;
    memset(out, 0, sizeof out);
    say("Updating fasdeqos repository catalogue...\nChecking for upgrades...\n");
    say("\nInstalled packages to be UPGRADED:\n");
    for (i = 0; i < n; i++) {
        rec_t r;
        if (!read_rec(names[i], &r))
            continue;
        if (!strcmp(r.kind, "container") || !strcmp(r.kind, "flatpak")) {
            say("\t%s: container or flatpak application, updated in place\n", names[i]);
            cont++;
        } else
            total += check_native(names[i], out[i], sizeof out[i], 1);
    }
    if (!total && !cont) {
        say("Your packages are up to date.\n");
        return 0;
    }
    say("\nNumber of packages to be upgraded: %d native, %d application(s)\n", total, cont);
    if (opt_n)
        return 0;
    if (!confirm()) {
        say("Aborted.\n");
        return 1;
    }
    for (i = 0; i < n; i++) {
        rec_t r;
        if (!read_rec(names[i], &r))
            continue;
        if (!strcmp(r.kind, "container")) {
            say("Upgrading %s...\n", names[i]);
            rc |= runv(1, DISTROBOX, "upgrade", r.container, NULL);
        } else if (!strcmp(r.kind, "flatpak")) {
            say("Upgrading %s...\n", names[i]);
            rc |= runv(1, FLATPAK, "update", "--user", "-y", "--noninteractive", r.container, NULL);
        } else if (out[i][0]) {
            char *argv[96];
            char *t, *sv = NULL;
            int k = 0;
            if (geteuid() != 0) {
                fprintf(stderr, "pkg: %s needs root to upgrade (try: su -c 'pkg upgrade')\n", names[i]);
                rc = 1;
                continue;
            }
            say("Upgrading %s...\n", names[i]);
            argv[k++] = (char *)ARCHFETCH;
            argv[k++] = "--quiet";
            argv[k++] = "--force";
            argv[k++] = "--soft";
            argv[k++] = "--record";
            argv[k++] = pth("/Library/pkg/db/%s.ver", names[i]);
            if (*P_ROOT) {
                argv[k++] = "--root";
                argv[k++] = (char *)P_ROOT;
            }
            for (t = strtok_r(out[i], " ", &sv); t && k < 94; t = strtok_r(NULL, " ", &sv))
                argv[k++] = t;
            argv[k] = NULL;
            rc |= runvp(0, argv);
            refresh_libs();
        }
    }
    return rc;
}

static int container_known(const char *cname)
{
    char names[256][64];
    int n = installed_list(names, 256), i;
    for (i = 0; i < n; i++) {
        rec_t r;
        if (read_rec(names[i], &r) && !strcmp(r.container, cname))
            return 1;
    }
    return 0;
}

static int cmd_gc(void)
{
    char names[256][64];
    int n = installed_list(names, 256), i, removed = 0;
    DIR *d;
    struct dirent *e;
    FILE *p;
    char line[512];
    for (i = 0; i < n; i++) {
        rec_t r;
        struct stat st;
        if (!read_rec(names[i], &r) || !r.bundle[0] || !stat(r.bundle, &st))
            continue;
        say("Removing orphan %s-rolling (bundle gone)\n", names[i]);
        if (!opt_n)
            remove_one(names[i]);
        removed++;
    }
    d = opendir(share_dir());
    while (d && (e = readdir(d))) {
        char lp[4096];
        struct stat st;
        char tg[4096];
        ssize_t k;
        snprintf(lp, sizeof lp, "%s/%s", share_dir(), e->d_name);
        k = readlink(lp, tg, sizeof tg - 1);
        if (k < 0)
            continue;
        tg[k] = 0;
        if (strncmp(tg, "/Applications/", 14) && strncmp(tg, apps_dir(), strlen(apps_dir())))
            continue;
        if (stat(lp, &st) == 0)
            continue;
        say("Removing dangling launcher %s\n", e->d_name);
        if (!opt_n)
            unlink(lp);
        removed++;
    }
    if (d)
        closedir(d);
    if (!opt_n) {
        char cmd[1024];
        snprintf(cmd, sizeof cmd, "%s list --no-color 2>/dev/null | awk -F'|' 'NR>1 {gsub(/ /,\"\",$2); print $2}'", DISTROBOX);
        p = popen(cmd, "r");
        while (p && fgets(line, sizeof line, p)) {
            line[strcspn(line, "\n")] = 0;
            if (!strncmp(line, "pkg-", 4) && !container_known(line)) {
                say("Removing orphan container %s\n", line);
                runv(1, DISTROBOX, "rm", "--force", line, NULL);
                removed++;
            }
        }
        if (p)
            pclose(p);
        runv(1, PODMAN, "image", "prune", "-f", NULL);
    }
    say("%d item(s) cleaned.\n", removed);
    return 0;
}

static int cmd_repos(void)
{
    printf("Repositories:\n");
    printf("  fasdeqos: { type: \"catalog\", packages: %d }\n", NCAT);
    printf("  cachyos:  { type: \"container\", image: \"%s\" }\n", CACHY);
    printf("  davincibox: { type: \"container\", image: \"%s\" }\n", DAVB);
    printf("  flathub:  { type: \"flatpak\", url: \"https://dl.flathub.org/repo/flathub.flatpakrepo\" }\n");
    printf("  arch:     { type: \"native\", tool: \"arch-fetch\" }\n");
    return 0;
}

static int cmd_run(int argc, char **argv, int shell)
{
    rec_t r;
    const def_t *d;
    char *av[64];
    int n = 0, i;
    if (argc < 1)
        die("usage: pkg %s name [args]", shell ? "shell" : "run");
    d = find_def(argv[0]);
    if (!read_rec(d ? d->name : argv[0], &r) || !r.container[0])
        die("%s is not installed as a container or flatpak application", argv[0]);
    if (!strcmp(r.kind, "flatpak")) {
        av[n++] = (char *)FLATPAK;
        av[n++] = "run";
        av[n++] = r.container;
    } else {
        av[n++] = (char *)DISTROBOX;
        av[n++] = "enter";
        av[n++] = "-n";
        av[n++] = r.container;
        if (!shell && d && d->exec) {
            av[n++] = "--";
            av[n++] = "sh";
            av[n++] = "-c";
            av[n++] = "exec $0 \"$@\"";
            av[n++] = (char *)d->exec;
        } else if (argc > 1) {
            av[n++] = "--";
        }
    }
    for (i = 1; i < argc && n < 62; i++)
        av[n++] = argv[i];
    av[n] = NULL;
    return runvp(1, av);
}

static int cmd_completions(void)
{
    int i;
    printf("complete -c pkg -f\n");
    printf("set -l cmds install delete remove search info list update upgrade repos gc autoremove clean run shell version help\n");
    printf("complete -c pkg -n \"not __fish_seen_subcommand_from $cmds\" -a \"$cmds\"\n");
    printf("complete -c pkg -s y -d 'assume yes'\n");
    printf("complete -c pkg -s n -d 'dry run'\n");
    printf("complete -c pkg -s q -d 'quiet'\n");
    printf("complete -c pkg -n '__fish_seen_subcommand_from install search' -a '");
    for (i = 0; i < NCAT; i++)
        printf("%s%s", i ? " " : "", catalog[i].name);
    printf("'\n");
    printf("complete -c pkg -n '__fish_seen_subcommand_from delete remove info list run shell' -a '(pkg info -a 2>/dev/null | string replace -r -- \"-rolling .*\" \"\")'\n");
    return 0;
}

static void usage(void)
{
    printf("usage: pkg [-y] [-n] [-q] <command> [<args>]\n\n"
           "Commands:\n"
           "    install     Install packages (apps get their own container in /Applications)\n"
           "    delete      Remove packages and their bundles\n"
           "    search      Search the catalogue\n"
           "    info        Display information about installed packages\n"
           "    list        List files owned by installed packages\n"
           "    update      Update the catalogue\n"
           "    upgrade     Upgrade installed packages\n"
           "    repos       Show repositories and container images\n"
           "    gc          Remove orphaned containers, launchers and records\n"
           "    run         Run an installed application\n"
           "    shell       Open a shell in an application's container\n"
           "    version     Show the pkg version\n\n"
           "Aliases: remove, rm -> delete; autoremove, clean -> gc\n");
}

static int wants_root(const char *cmd, int nr, char **rest)
{
    int i;
    if (!strcmp(cmd, "install") || !strcmp(cmd, "add") || !strcmp(cmd, "delete") || !strcmp(cmd, "remove") || !strcmp(cmd, "rm")) {
        for (i = 0; i < nr; i++) {
            const def_t *d = find_def(rest[i]);
            if (d && (d->kind == K_NATIVE || d->kind == K_AUR))
                return 1;
        }
        return 0;
    }
    if (!strcmp(cmd, "upgrade")) {
        char names[256][64];
        int n = installed_list(names, 256);
        for (i = 0; i < n; i++) {
            rec_t r;
            if (read_rec(names[i], &r) && (!strcmp(r.kind, "native") || !strcmp(r.kind, "aur")))
                return 1;
        }
    }
    return 0;
}

static void escalate(int argc, char **argv)
{
    char line[4096] = "exec ";
    int i;
    strncat(line, argv[0], sizeof line - strlen(line) - 1);
    for (i = 1; i < argc; i++) {
        strncat(line, " '", sizeof line - strlen(line) - 1);
        strncat(line, argv[i], sizeof line - strlen(line) - 1);
        strncat(line, "'", sizeof line - strlen(line) - 1);
    }
    fprintf(stderr, "pkg: root is required, switching with su (root password)\n");
    setenv("PKG_NO_SU", "1", 1);
    execlp("su", "su", "-c", line, (char *)NULL);
    fprintf(stderr, "pkg: cannot run su: %s\n", strerror(errno));
    exit(1);
}

int main(int argc, char **argv)
{
    char *rest[256];
    int nr = 0, i;
    const char *cmd = NULL;
    const char *e;
    int rc = 0;
    if ((e = getenv("PKG_ROOT")))
        P_ROOT = e;
    if ((e = getenv("PKG_DISTROBOX")))
        DISTROBOX = e;
    if ((e = getenv("PKG_FLATPAK")))
        FLATPAK = e;
    if ((e = getenv("PKG_ARCH_FETCH")))
        ARCHFETCH = e;
    if ((e = getenv("PKG_PODMAN")))
        PODMAN = e;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-y") || !strcmp(argv[i], "--yes"))
            opt_y = 1;
        else if (!strcmp(argv[i], "-n") || !strcmp(argv[i], "--dry-run"))
            opt_n = 1;
        else if (!strcmp(argv[i], "-q") || !strcmp(argv[i], "--quiet"))
            opt_q = 1;
        else if (!strcmp(argv[i], "-f") || !strcmp(argv[i], "--force"))
            opt_f = 1;
        else if (!cmd)
            cmd = argv[i];
        else if (nr < 255)
            rest[nr++] = argv[i];
    }
    rest[nr] = NULL;
    if (!cmd) {
        usage();
        return 1;
    }
    find_user();
    if (geteuid() != 0 && !getenv("PKG_NO_SU") && !opt_n && wants_root(cmd, nr, rest))
        escalate(argc, argv);
    if (!strcmp(cmd, "install") || !strcmp(cmd, "add"))
        rc = nr ? cmd_install(nr, rest) : (usage(), 1);
    else if (!strcmp(cmd, "delete") || !strcmp(cmd, "remove") || !strcmp(cmd, "rm"))
        rc = nr ? cmd_delete(nr, rest) : (usage(), 1);
    else if (!strcmp(cmd, "search"))
        rc = cmd_search(nr, rest);
    else if (!strcmp(cmd, "info"))
        rc = cmd_info(nr, rest);
    else if (!strcmp(cmd, "list"))
        rc = cmd_list(nr, rest);
    else if (!strcmp(cmd, "update"))
        rc = cmd_update();
    else if (!strcmp(cmd, "upgrade"))
        rc = cmd_upgrade();
    else if (!strcmp(cmd, "repos"))
        rc = cmd_repos();
    else if (!strcmp(cmd, "gc") || !strcmp(cmd, "autoremove") || !strcmp(cmd, "clean"))
        rc = cmd_gc();
    else if (!strcmp(cmd, "run"))
        rc = cmd_run(nr, rest, 0);
    else if (!strcmp(cmd, "shell"))
        rc = cmd_run(nr, rest, 1);
    else if (!strcmp(cmd, "completions"))
        rc = cmd_completions();
    else if (!strcmp(cmd, "version") || !strcmp(cmd, "--version")) {
        printf("pkg %s (fasdeqOS)\n", PKG_VERSION);
    } else if (!strcmp(cmd, "help") || !strcmp(cmd, "--help") || !strcmp(cmd, "-h"))
        usage();
    else {
        fprintf(stderr, "pkg: unknown command: %s\n", cmd);
        usage();
        rc = 1;
    }
    return rc;
}
