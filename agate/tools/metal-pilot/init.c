#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* This signed program runs once from the diagnostic RAM volume.
 * Keep PID 1 for the regular iOS launchd and retain its argument list. */
int main(int argc, char **argv)
{
    (void)argc;
    pid_t child = fork();
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
        if (strncmp(argv[0], "/Developer/", 11) == 0) {
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
