#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* This signed program runs once from the diagnostic RAM volume.
 * Keep PID 1 for the regular iOS launchd and retain its argument list. */
static void say(const char *what, const char *name, long value)
{
    int fd = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);
    if (fd >= 0) {
        dprintf(fd, "AGATE FONTS: %s %s (%ld)\n", what, name, value);
        close(fd);
    }
}

/* The trimmed iOS root lacks /System/Library/Fonts/CoreAddition: the keyboard's keycap fonts
 * (.Keycaps-Keys, .PhoneKeyCaps) are missing and keys show '?'. Copy what the volume carries in
 * agate-fonts/ once (absent or different size), through a temporary file and rename. */
static void install_fonts(const char *from, const char *to)
{
    DIR *dir = opendir(from);
    if (dir == NULL) {
        return;
    }
    if (mkdir(to, 0755) != 0 && errno != EEXIST) {
        say("cannot create", to, errno);
        closedir(dir);
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') {
            continue;
        }
        char src[512], dst[512], tmp[512];
        struct stat in, out;
        snprintf(src, sizeof(src), "%s/%s", from, entry->d_name);
        snprintf(dst, sizeof(dst), "%s/%s", to, entry->d_name);
        snprintf(tmp, sizeof(tmp), "%s/.%s.agate", to, entry->d_name);
        if (stat(src, &in) != 0 || !S_ISREG(in.st_mode)) {
            continue;
        }
        if (stat(dst, &out) == 0 && out.st_size == in.st_size) {
            say("present", entry->d_name, (long)out.st_size);
            continue;
        }
        int r = open(src, O_RDONLY | O_CLOEXEC);
        int w = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        long copied = -1;
        if (r >= 0 && w >= 0) {
            static char buffer[65536];
            ssize_t n;
            copied = 0;
            while ((n = read(r, buffer, sizeof(buffer))) > 0) {
                if (write(w, buffer, (size_t)n) != n) {
                    copied = -1;
                    break;
                }
                copied += n;
            }
            if (n < 0 || copied != (long)in.st_size || fsync(w) != 0) {
                copied = -1;
            }
        }
        if (r >= 0) {
            close(r);
        }
        if (w >= 0) {
            close(w);
        }
        if (copied >= 0 && rename(tmp, dst) == 0) {
            say("installed", entry->d_name, copied);
        } else {
            say("FAILED", entry->d_name, errno);
            unlink(tmp);
        }
    }
    closedir(dir);
    sync();
}

int main(int argc, char **argv)
{
    (void)argc;
    const int pilot = strncmp(argv[0], "/Developer/", 11) == 0;
    if (!pilot) {
        install_fonts("/System/Library/Extensions/agate-fonts", "/System/Library/Fonts/CoreAddition");
    }
    struct stat smoke;
    const int have_smoke = stat(pilot ? "/Developer/metal-smoke" : "/System/Library/Extensions/metal-smoke", &smoke) == 0;
    pid_t child = have_smoke ? fork() : 1;
    if (child == 0) {
        /* sweetnull=metal-smoke sends the child's output to the kernel log. */
        int fd = open("/dev/null", O_WRONLY);
        if (fd >= 0) {
            (void)dup2(fd, STDOUT_FILENO);
            (void)dup2(fd, STDERR_FILENO);
            if (fd > STDERR_FILENO) {
                close(fd);
            }
        }
        /* agategpu=7 starts /Developer/metal-init (pilot), agategpu=6 the copy in /System/Library/Extensions,
         * where the volume is a union mount and Metal finds the driver itself. */
        if (pilot) {
            execl("/Developer/metal-smoke", "metal-smoke", (char *)NULL);
        } else {
            execl("/System/Library/Extensions/metal-smoke", "metal-smoke", "--system-suite", (char *)NULL);
        }
        dprintf(STDERR_FILENO, "AGATE METAL: starting metal-smoke failed\n");
        _exit(127);
    }
    if (child < 0) {
        int fd = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);
        if (fd >= 0) {
            dprintf(fd, "AGATE METAL: could not start the diagnostic process\n");
            close(fd);
        }
    }
    argv[0] = "/sbin/launchd";
    execv(argv[0], argv);
    int fd = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (fd >= 0) {
        dprintf(fd, "AGATE METAL: could not resume launchd\n");
    }
    return 127;
}
