#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <sched.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_ENV_BYTES (1024U * 1024U)

extern char **environ;

static void die(const char *message)
{
    if (errno != 0) {
        fprintf(stderr, "leigod-netns-exec: %s: %s\n", message, strerror(errno));
    } else {
        fprintf(stderr, "leigod-netns-exec: %s\n", message);
    }
    exit(EXIT_FAILURE);
}

static unsigned long parse_id(const char *value, const char *label)
{
    char *end = NULL;
    unsigned long result;

    errno = 0;
    result = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || result > UINT_MAX) {
        errno = 0;
        die(label);
    }
    return result;
}

static int open_proc_file(pid_t pid, const char *suffix, int flags)
{
    char path[PATH_MAX];
    int length = snprintf(path, sizeof(path), "/proc/%ld/%s", (long)pid, suffix);

    if (length < 0 || (size_t)length >= sizeof(path)) {
        errno = 0;
        die("proc path is too long");
    }
    return open(path, flags);
}

static char **read_environment(int env_fd, off_t expected_size)
{
    char *buffer;
    char **environment;
    size_t size = (size_t)expected_size;
    size_t offset = 0;
    size_t entries = 0;
    size_t index = 0;

    buffer = calloc(size + 1, 1);
    if (buffer == NULL) {
        die("cannot allocate environment buffer");
    }

    while (offset < size) {
        ssize_t count = read(env_fd, buffer + offset, size - offset);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            die("cannot read environment file");
        }
        if (count == 0) {
            break;
        }
        offset += (size_t)count;
    }

    if (offset == 0 || buffer[offset - 1] != '\0') {
        errno = 0;
        die("environment file is incomplete");
    }

    for (size_t position = 0; position < offset; position++) {
        if (buffer[position] == '\0') {
            entries++;
        }
    }

    environment = calloc(entries + 1, sizeof(*environment));
    if (environment == NULL) {
        die("cannot allocate environment table");
    }

    for (size_t position = 0; position < offset;) {
        char *entry = buffer + position;
        size_t entry_length = strlen(entry);
        char *equals = strchr(entry, '=');

        if (entry_length == 0 || equals == NULL || equals == entry) {
            errno = 0;
            die("environment file contains an invalid entry");
        }
        environment[index++] = entry;
        position += entry_length + 1;
    }
    environment[index] = NULL;
    return environment;
}

int main(int argc, char **argv)
{
    pid_t target_pid;
    uid_t target_uid;
    gid_t target_gid;
    int env_fd;
    int netns_fd;
    struct stat env_stat;
    struct passwd *target_user;
    char **game_environment;

    errno = 0;
    if (argc < 7 || strcmp(argv[5], "--") != 0) {
        die("usage: PID UID GID ENV_FILE -- COMMAND [ARG ...]");
    }
    if (geteuid() != 0) {
        die("must be invoked as root by the restricted launcher");
    }

    target_pid = (pid_t)parse_id(argv[1], "invalid container PID");
    target_uid = (uid_t)parse_id(argv[2], "invalid target UID");
    target_gid = (gid_t)parse_id(argv[3], "invalid target GID");
    if (target_pid <= 1 || target_uid == 0) {
        die("refusing an unsafe PID or UID");
    }

    target_user = getpwuid(target_uid);
    if (target_user == NULL || target_user->pw_uid != target_uid) {
        errno = 0;
        die("cannot resolve target user");
    }
    if (initgroups(target_user->pw_name, target_gid) != 0) {
        die("cannot prepare target user groups");
    }

    env_fd = open(argv[4], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (env_fd < 0 || fstat(env_fd, &env_stat) != 0) {
        die("cannot open environment file");
    }
    if (!S_ISREG(env_stat.st_mode) || env_stat.st_uid != target_uid ||
        (env_stat.st_mode & 077) != 0 || env_stat.st_size <= 0 ||
        env_stat.st_size > (off_t)MAX_ENV_BYTES) {
        errno = 0;
        die("environment file ownership, mode, or size is invalid");
    }

    netns_fd = open_proc_file(target_pid, "ns/net", O_RDONLY | O_CLOEXEC);
    if (netns_fd < 0) {
        die("cannot open accelerator network namespace");
    }

    if (setns(netns_fd, CLONE_NEWNET) != 0) {
        die("cannot enter accelerator network namespace");
    }

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        die("cannot enable no-new-privileges");
    }
#ifdef PR_CAP_AMBIENT
    if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0 &&
        errno != EINVAL) {
        die("cannot clear ambient capabilities");
    }
#endif
    if (setresgid(target_gid, target_gid, target_gid) != 0 ||
        setresuid(target_uid, target_uid, target_uid) != 0) {
        die("cannot drop root privileges");
    }
    umask(022);

    game_environment = read_environment(env_fd, env_stat.st_size);
    close(env_fd);
    close(netns_fd);

    environ = game_environment;
    execvp(argv[6], &argv[6]);
    die("cannot execute game command");
}
