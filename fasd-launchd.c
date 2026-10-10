#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define RC_PATH "/System/bin/fasdeqos-rc"
#define MAX_JOBS 8
#define BURST_WINDOW 60
#define BURST_LIMIT 5

struct job {
    const char *name;
    const char *tty;
    char *const *argv;
    pid_t pid;
    time_t window_start;
    int starts;
    int dead;
};

static char *dinit_argv[] = {"/System/bin/dinit", "--container", "--services-dir", "/private/etc/dinit.d", NULL};
static char *tty1_argv[] = {"/System/bin/fasdeqos-session", NULL};
static char *tty2_argv[] = {"/System/bin/busybox", "sh", "-c", "export HOME=/root USER=root LOGNAME=root; cd /root; exec /System/bin/bash -l", NULL};

static struct job jobs[MAX_JOBS] = {
    {"dinit", NULL, dinit_argv, 0, 0, 0, 0},
    {"tty1", "/dev/tty1", tty1_argv, 0, 0, 0, 0},
    {"tty2", "/dev/tty2", tty2_argv, 0, 0, 0, 0},
};
static int njobs = 3;

static void logmsg(const char *msg, const char *arg)
{
    int fd = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (fd < 0) {
        return;
    }
    dprintf(fd, "fasd-launchd: %s%s%s\n", msg, arg ? ": " : "", arg ? arg : "");
    close(fd);
}

static void spawn(struct job *j)
{
    pid_t p;
    time_t now = time(NULL);

    if (now - j->window_start > BURST_WINDOW) {
        j->window_start = now;
        j->starts = 0;
    }
    if (++j->starts > BURST_LIMIT) {
        logmsg("giving up on a job that keeps dying, see /private/var/log/fasd-<job>.log", j->name);
        j->dead = 1;
        return;
    }
    p = fork();
    if (p < 0) {
        return;
    }
    if (p == 0) {
        sigset_t all;
        sigemptyset(&all);
        sigprocmask(SIG_SETMASK, &all, NULL);
        setsid();
        if (j->tty) {
            int fd = open(j->tty, O_RDWR);
            if (fd < 0) {
                _exit(127);
            }
            ioctl(fd, TIOCSCTTY, 1);
            dup2(fd, 0);
            dup2(fd, 1);
            dup2(fd, 2);
            if (fd > 2) {
                close(fd);
            }
        }
        if (!j->tty) {
            char path[128];
            int lf;
            snprintf(path, sizeof(path), "/private/var/log/fasd-%s.log", j->name);
            lf = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (lf < 0) {
                lf = open("/dev/null", O_RDWR);
            }
            if (lf >= 0) {
                dup2(lf, 1);
                dup2(lf, 2);
                if (lf > 2) {
                    close(lf);
                }
            }
        }
        setenv("TERM", "linux", 1);
        setenv("TERMINFO", "/System/share/terminfo", 1);
        setenv("PATH", "/System/bin:/bin", 1);
        execv(j->argv[0], j->argv);
        _exit(127);
    }
    j->pid = p;
}

static void run_rc(void)
{
    pid_t p = fork();
    if (p == 0) {
        execl(RC_PATH, RC_PATH, (char *)NULL);
        _exit(127);
    }
    if (p > 0) {
        waitpid(p, NULL, 0);
    }
}

static void shutdown_system(int cmd)
{
    logmsg("shutting down", NULL);
    kill(-1, SIGTERM);
    sleep(2);
    kill(-1, SIGKILL);
    sync();
    umount2("/run/live/iso", MNT_DETACH);
    reboot(cmd);
    for (;;) {
        pause();
    }
}

static void reap(void)
{
    int status;
    pid_t p;
    int i;

    while ((p = waitpid(-1, &status, WNOHANG)) > 0) {
        for (i = 0; i < njobs; i++) {
            if (jobs[i].pid == p) {
                jobs[i].pid = 0;
                logmsg("job exited, restarting", jobs[i].name);
                break;
            }
        }
    }
}

int main(void)
{
    sigset_t set;
    struct timespec ts = {1, 0};
    int sig, i;

    sigfillset(&set);
    sigprocmask(SIG_BLOCK, &set, NULL);
    chdir("/");
    setsid();
    run_rc();
    for (i = 0; i < njobs; i++) {
        spawn(&jobs[i]);
    }
    for (;;) {
        sig = sigtimedwait(&set, NULL, &ts);
        if (sig == SIGTERM || sig == SIGINT) {
            shutdown_system(RB_AUTOBOOT);
        } else if (sig == SIGUSR1) {
            shutdown_system(RB_HALT_SYSTEM);
        } else if (sig == SIGUSR2) {
            shutdown_system(RB_POWER_OFF);
        }
        reap();
        for (i = 0; i < njobs; i++) {
            if (jobs[i].pid == 0 && !jobs[i].dead) {
                spawn(&jobs[i]);
            }
        }
    }
    return 0;
}
