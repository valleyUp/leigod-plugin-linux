#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define DISCOVERY_PORT 6066
#define PACKET_MAX 2048
#define REPLY_TIMEOUT_MS 400

static volatile sig_atomic_t stopping;

static void on_stop(int signo)
{
    (void)signo;
    stopping = 1;
}

static void die(const char *message)
{
    if (errno != 0) {
        fprintf(stderr, "leigod-discover-proxy: %s: %s\n", message, strerror(errno));
    } else {
        fprintf(stderr, "leigod-discover-proxy: %s\n", message);
    }
    exit(EXIT_FAILURE);
}

static bool parse_ipv4(const char *text, struct in_addr *address)
{
    return text != NULL && inet_pton(AF_INET, text, address) == 1;
}

static int rewrite_ip_field(char *buffer, size_t *length, size_t capacity, const char *new_ip)
{
    char *field;
    char *end;
    size_t old_len;
    size_t new_len;
    size_t tail;

    if (buffer == NULL || length == NULL || new_ip == NULL) {
        return -1;
    }
    field = memmem(buffer, *length, "ip=", 3);
    if (field == NULL) {
        return 0;
    }
    field += 3;
    end = field;
    while ((size_t)(end - buffer) < *length &&
           ((*end >= '0' && *end <= '9') || *end == '.')) {
        end++;
    }
    old_len = (size_t)(end - field);
    new_len = strlen(new_ip);
    if (*length - old_len + new_len >= capacity) {
        errno = 0;
        return -1;
    }
    tail = *length - (size_t)(end - buffer);
    if (new_len != old_len && tail > 0) {
        memmove(field + new_len, end, tail);
    }
    memcpy(field, new_ip, new_len);
    *length = *length - old_len + new_len;
    return 1;
}

static int self_test(void)
{
    char buffer[256];
    const char *input =
        "<NBOX> WHO abc acc-gw (model=SteamDeck, sn=02:11:22:33:44:55, "
        "fw=, sw=1.2.2.15, ip=172.21.0.2, bound=true)";
    const char *expected =
        "<NBOX> WHO abc acc-gw (model=SteamDeck, sn=02:11:22:33:44:55, "
        "fw=, sw=1.2.2.15, ip=192.168.1.165, bound=true)";
    size_t length = strlen(input);
    char unchanged[32];
    size_t unchanged_len;

    memcpy(buffer, input, length + 1);
    if (rewrite_ip_field(buffer, &length, sizeof(buffer), "192.168.1.165") != 1) {
        fprintf(stderr, "leigod-discover-proxy: self-test rewrite failed\n");
        return 1;
    }
    buffer[length] = '\0';
    if (strcmp(buffer, expected) != 0) {
        fprintf(stderr, "leigod-discover-proxy: self-test mismatch: %s\n", buffer);
        return 1;
    }

    memcpy(unchanged, "no-ip-field", 12);
    unchanged_len = 11;
    if (rewrite_ip_field(unchanged, &unchanged_len, sizeof(unchanged), "1.2.3.4") != 0) {
        fprintf(stderr, "leigod-discover-proxy: self-test missing-field failed\n");
        return 1;
    }
    return 0;
}

static void usage(void)
{
    fprintf(stderr,
            "usage: leigod-discover-proxy --bind ADDRESS --container ADDRESS [--port PORT]\n"
            "       leigod-discover-proxy --self-test\n");
}

static int create_socket(const struct in_addr *address, uint16_t port, bool pktinfo)
{
    int fd;
    int enable = 1;
    struct sockaddr_in local;

    fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        die("cannot create UDP socket");
    }
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, sizeof(enable)) != 0) {
        die("cannot set SO_REUSEADDR");
    }
    if (setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, sizeof(enable)) != 0) {
        die("cannot set SO_BROADCAST");
    }
    if (pktinfo &&
        setsockopt(fd, IPPROTO_IP, IP_PKTINFO, &enable, sizeof(enable)) != 0) {
        die("cannot set IP_PKTINFO");
    }

    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = htons(port);
    local.sin_addr = *address;
    if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        die("cannot bind UDP socket");
    }
    return fd;
}

static ssize_t recv_lan_packet(int fd, char *buffer, size_t capacity,
                               struct sockaddr_in *from, struct in_addr *local_ip)
{
    struct iovec iov = { .iov_base = buffer, .iov_len = capacity };
    char control[CMSG_SPACE(sizeof(struct in_pktinfo))];
    struct msghdr message;
    struct cmsghdr *cmsg;
    ssize_t received;

    memset(&message, 0, sizeof(message));
    memset(from, 0, sizeof(*from));
    memset(control, 0, sizeof(control));
    memset(local_ip, 0, sizeof(*local_ip));
    message.msg_name = from;
    message.msg_namelen = sizeof(*from);
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);

    received = recvmsg(fd, &message, 0);
    if (received < 0) {
        return received;
    }

    for (cmsg = CMSG_FIRSTHDR(&message); cmsg != NULL; cmsg = CMSG_NXTHDR(&message, cmsg)) {
        if (cmsg->cmsg_level == IPPROTO_IP && cmsg->cmsg_type == IP_PKTINFO) {
            const struct in_pktinfo *info = (const struct in_pktinfo *)CMSG_DATA(cmsg);
            *local_ip = info->ipi_spec_dst;
            break;
        }
    }
    return received;
}

static int send_lan_packet(int fd, const char *buffer, size_t length,
                           const struct sockaddr_in *to, const struct in_addr *local_ip)
{
    struct iovec iov = { .iov_base = (void *)buffer, .iov_len = length };
    char control[CMSG_SPACE(sizeof(struct in_pktinfo))];
    struct msghdr message;
    struct cmsghdr *cmsg;
    struct in_pktinfo *info;

    memset(&message, 0, sizeof(message));
    message.msg_name = (void *)to;
    message.msg_namelen = sizeof(*to);
    message.msg_iov = &iov;
    message.msg_iovlen = 1;

    if (local_ip != NULL && local_ip->s_addr != 0 && local_ip->s_addr != htonl(INADDR_ANY)) {
        memset(control, 0, sizeof(control));
        message.msg_control = control;
        message.msg_controllen = sizeof(control);
        cmsg = CMSG_FIRSTHDR(&message);
        cmsg->cmsg_level = IPPROTO_IP;
        cmsg->cmsg_type = IP_PKTINFO;
        cmsg->cmsg_len = CMSG_LEN(sizeof(struct in_pktinfo));
        info = (struct in_pktinfo *)CMSG_DATA(cmsg);
        memset(info, 0, sizeof(*info));
        info->ipi_spec_dst = *local_ip;
    }

    if (sendmsg(fd, &message, 0) < 0) {
        return -1;
    }
    return 0;
}

static ssize_t query_container(int fd, const struct sockaddr_in *container,
                               const char *request, size_t request_len,
                               char *reply, size_t reply_cap)
{
    struct pollfd pollfd;
    ssize_t received;

    if (sendto(fd, request, request_len, 0, (const struct sockaddr *)container,
               sizeof(*container)) < 0) {
        return -1;
    }

    pollfd.fd = fd;
    pollfd.events = POLLIN;
    pollfd.revents = 0;
    if (poll(&pollfd, 1, REPLY_TIMEOUT_MS) <= 0) {
        errno = ETIMEDOUT;
        return -1;
    }
    received = recv(fd, reply, reply_cap, 0);
    return received;
}

int main(int argc, char **argv)
{
    const char *bind_text = NULL;
    const char *container_text = NULL;
    uint16_t port = DISCOVERY_PORT;
    struct in_addr bind_address;
    struct in_addr container_address;
    struct in_addr any_address;
    struct sockaddr_in container;
    int lan_fd;
    int ns_fd;
    int arg;
    char advertise[INET_ADDRSTRLEN];

    for (arg = 1; arg < argc; arg++) {
        if (strcmp(argv[arg], "--self-test") == 0) {
            return self_test();
        }
        if (strcmp(argv[arg], "--bind") == 0 && arg + 1 < argc) {
            bind_text = argv[++arg];
            continue;
        }
        if (strcmp(argv[arg], "--container") == 0 && arg + 1 < argc) {
            container_text = argv[++arg];
            continue;
        }
        if (strcmp(argv[arg], "--port") == 0 && arg + 1 < argc) {
            char *end = NULL;
            unsigned long parsed;

            errno = 0;
            parsed = strtoul(argv[++arg], &end, 10);
            if (errno != 0 || end == argv[arg] || *end != '\0' || parsed == 0 ||
                parsed > 65535UL) {
                errno = 0;
                die("invalid --port");
            }
            port = (uint16_t)parsed;
            continue;
        }
        if (strcmp(argv[arg], "-h") == 0 || strcmp(argv[arg], "--help") == 0) {
            usage();
            return 0;
        }
        usage();
        return 2;
    }

    if (!parse_ipv4(bind_text, &bind_address) || !parse_ipv4(container_text, &container_address)) {
        usage();
        return 2;
    }

    signal(SIGTERM, on_stop);
    signal(SIGINT, on_stop);

    lan_fd = create_socket(&bind_address, port, true);
    any_address.s_addr = htonl(INADDR_ANY);
    ns_fd = create_socket(&any_address, 0, false);

    memset(&container, 0, sizeof(container));
    container.sin_family = AF_INET;
    container.sin_port = htons(port);
    container.sin_addr = container_address;

    fprintf(stderr,
            "leigod-discover-proxy: listening on %s:%u, forwarding to %s:%u\n",
            bind_text, port, container_text, port);

    while (stopping == 0) {
        struct pollfd pollfd = { .fd = lan_fd, .events = POLLIN, .revents = 0 };
        struct sockaddr_in from;
        struct in_addr local_ip;
        char request[PACKET_MAX];
        char reply[PACKET_MAX];
        ssize_t request_len;
        ssize_t received;
        size_t reply_len;
        int status;

        if (poll(&pollfd, 1, 1000) <= 0) {
            continue;
        }
        request_len = recv_lan_packet(lan_fd, request, sizeof(request), &from, &local_ip);
        if (request_len <= 0) {
            continue;
        }
        if (from.sin_addr.s_addr == container_address.s_addr) {
            continue;
        }

        received = query_container(ns_fd, &container, request, (size_t)request_len, reply,
                                   sizeof(reply));
        if (received <= 0) {
            fprintf(stderr, "leigod-discover-proxy: container discovery reply timed out\n");
            continue;
        }
        reply_len = (size_t)received;

        if (local_ip.s_addr == 0 || local_ip.s_addr == htonl(INADDR_ANY)) {
            local_ip = bind_address;
        }
        if (local_ip.s_addr == 0 || local_ip.s_addr == htonl(INADDR_ANY)) {
            continue;
        }
        if (inet_ntop(AF_INET, &local_ip, advertise, sizeof(advertise)) == NULL) {
            continue;
        }

        status = rewrite_ip_field(reply, &reply_len, sizeof(reply), advertise);
        if (status < 0) {
            fprintf(stderr, "leigod-discover-proxy: cannot rewrite advertised IP\n");
            continue;
        }
        if (send_lan_packet(lan_fd, reply, reply_len, &from, &local_ip) != 0) {
            fprintf(stderr, "leigod-discover-proxy: cannot send rewritten reply: %s\n",
                    strerror(errno));
        }
    }

    close(lan_fd);
    close(ns_fd);
    return 0;
}
