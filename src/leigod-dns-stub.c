#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define DNS_PORT 53
#define QUERY_MAX 4096
#define UPSTREAM_TIMEOUT_MS 1500
#define MAX_UPSTREAMS 4

static volatile sig_atomic_t stopping;

static void on_stop(int signo)
{
    (void)signo;
    stopping = 1;
}

static void die(const char *message)
{
    if (errno != 0) {
        fprintf(stderr, "leigod-dns-stub: %s: %s\n", message, strerror(errno));
    } else {
        fprintf(stderr, "leigod-dns-stub: %s\n", message);
    }
    exit(EXIT_FAILURE);
}

static bool parse_ipv4(const char *text, struct in_addr *address)
{
    return text != NULL && inet_pton(AF_INET, text, address) == 1;
}

static bool parse_upstream(const char *text, struct sockaddr_in *upstream)
{
    char host[INET_ADDRSTRLEN];
    const char *colon;
    const char *port_text;
    char *end = NULL;
    unsigned long parsed;
    struct in_addr address;
    size_t host_len;

    if (text == NULL) {
        return false;
    }
    colon = strrchr(text, ':');
    if (colon == NULL) {
        if (!parse_ipv4(text, &address)) {
            return false;
        }
        memset(upstream, 0, sizeof(*upstream));
        upstream->sin_family = AF_INET;
        upstream->sin_port = htons(DNS_PORT);
        upstream->sin_addr = address;
        return true;
    }
    host_len = (size_t)(colon - text);
    if (host_len == 0 || host_len >= sizeof(host)) {
        return false;
    }
    memcpy(host, text, host_len);
    host[host_len] = '\0';
    port_text = colon + 1;
    errno = 0;
    parsed = strtoul(port_text, &end, 10);
    if (!parse_ipv4(host, &address) || errno != 0 || end == port_text || *end != '\0' ||
        parsed == 0 || parsed > 65535UL) {
        return false;
    }
    memset(upstream, 0, sizeof(*upstream));
    upstream->sin_family = AF_INET;
    upstream->sin_port = htons((uint16_t)parsed);
    upstream->sin_addr = address;
    return true;
}

static int create_udp_socket(const struct in_addr *address, uint16_t port)
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

    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = htons(port);
    local.sin_addr = *address;
    if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        die("cannot bind UDP socket");
    }
    return fd;
}

static int create_tcp_socket(const struct in_addr *address, uint16_t port)
{
    int fd;
    int enable = 1;
    struct sockaddr_in local;

    fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        die("cannot create TCP socket");
    }
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, sizeof(enable)) != 0) {
        die("cannot set SO_REUSEADDR");
    }

    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = htons(port);
    local.sin_addr = *address;
    if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        die("cannot bind TCP socket");
    }
    if (listen(fd, 16) != 0) {
        die("cannot listen on TCP socket");
    }
    return fd;
}

static ssize_t query_upstream(const struct sockaddr_in *upstreams, size_t upstream_count,
                              const char *query, size_t query_len, char *reply, size_t reply_cap)
{
    size_t index;

    if (query_len < 12 || query_len > QUERY_MAX) {
        errno = EINVAL;
        return -1;
    }

    for (index = 0; index < upstream_count; index++) {
        int fd;
        struct pollfd pollfd;
        ssize_t received;

        fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (fd < 0) {
            continue;
        }
        if (sendto(fd, query, query_len, 0, (const struct sockaddr *)&upstreams[index],
                   sizeof(upstreams[index])) < 0) {
            close(fd);
            continue;
        }

        pollfd.fd = fd;
        pollfd.events = POLLIN;
        pollfd.revents = 0;
        if (poll(&pollfd, 1, UPSTREAM_TIMEOUT_MS) <= 0) {
            close(fd);
            continue;
        }
        received = recv(fd, reply, reply_cap, 0);
        close(fd);
        if (received >= 12) {
            return received;
        }
    }

    errno = ETIMEDOUT;
    return -1;
}

static int read_full(int fd, void *buffer, size_t length)
{
    size_t offset = 0;

    while (offset < length) {
        ssize_t count = recv(fd, (char *)buffer + offset, length - offset, 0);
        if (count <= 0) {
            return -1;
        }
        offset += (size_t)count;
    }
    return 0;
}

static int write_full(int fd, const void *buffer, size_t length)
{
    size_t offset = 0;

    while (offset < length) {
        ssize_t count = send(fd, (const char *)buffer + offset, length - offset, MSG_NOSIGNAL);
        if (count <= 0) {
            return -1;
        }
        offset += (size_t)count;
    }
    return 0;
}

static void handle_tcp_client(int client, const struct sockaddr_in *upstreams,
                              size_t upstream_count)
{
    unsigned char header[2];
    char query[QUERY_MAX];
    char reply[QUERY_MAX];
    uint16_t query_len;
    ssize_t reply_len;
    unsigned char reply_header[2];
    struct timeval timeout;

    timeout.tv_sec = 2;
    timeout.tv_usec = 0;
    (void)setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    if (read_full(client, header, 2) != 0) {
        return;
    }
    query_len = (uint16_t)((header[0] << 8) | header[1]);
    if (query_len < 12 || query_len > QUERY_MAX) {
        return;
    }
    if (read_full(client, query, query_len) != 0) {
        return;
    }

    reply_len = query_upstream(upstreams, upstream_count, query, query_len, reply, sizeof(reply));
    if (reply_len < 12) {
        return;
    }
    reply_header[0] = (unsigned char)((reply_len >> 8) & 0xff);
    reply_header[1] = (unsigned char)(reply_len & 0xff);
    if (write_full(client, reply_header, 2) != 0) {
        return;
    }
    (void)write_full(client, reply, (size_t)reply_len);
}

static void usage(void)
{
    fprintf(stderr,
            "usage: leigod-dns-stub --bind ADDRESS [--port PORT] [--upstream ADDRESS]...\n"
            "       leigod-dns-stub --self-test\n");
}

static int self_test(void)
{
    struct sockaddr_in upstream;
    struct in_addr loopback;
    char query[32];
    char reply[32];
    int fd;

    memset(&upstream, 0, sizeof(upstream));
    upstream.sin_family = AF_INET;
    upstream.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    upstream.sin_port = htons(1);
    memset(query, 0, sizeof(query));
    query[0] = 0x12;
    query[1] = 0x34;
    query[2] = 0x01;
    if (query_upstream(&upstream, 1, query, 12, reply, sizeof(reply)) >= 0) {
        fprintf(stderr, "leigod-dns-stub: self-test expected upstream timeout\n");
        return 1;
    }

    loopback.s_addr = htonl(INADDR_LOOPBACK);
    fd = create_udp_socket(&loopback, 0);
    close(fd);
    fd = create_tcp_socket(&loopback, 0);
    close(fd);
    return 0;
}

int main(int argc, char **argv)
{
    const char *bind_text = NULL;
    uint16_t port = DNS_PORT;
    struct in_addr bind_address;
    struct sockaddr_in upstreams[MAX_UPSTREAMS];
    size_t upstream_count = 0;
    int udp_fd;
    int tcp_fd;
    int arg;

    for (arg = 1; arg < argc; arg++) {
        if (strcmp(argv[arg], "--self-test") == 0) {
            return self_test();
        }
        if (strcmp(argv[arg], "--bind") == 0 && arg + 1 < argc) {
            bind_text = argv[++arg];
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
        if (strcmp(argv[arg], "--upstream") == 0 && arg + 1 < argc) {
            if (upstream_count >= MAX_UPSTREAMS) {
                errno = 0;
                die("too many --upstream values");
            }
            if (!parse_upstream(argv[++arg], &upstreams[upstream_count])) {
                errno = 0;
                die("invalid --upstream");
            }
            upstream_count++;
            continue;
        }
        if (strcmp(argv[arg], "-h") == 0 || strcmp(argv[arg], "--help") == 0) {
            usage();
            return 0;
        }
        usage();
        return 2;
    }

    if (bind_text == NULL) {
        bind_text = "127.0.0.53";
    }
    if (!parse_ipv4(bind_text, &bind_address)) {
        usage();
        return 2;
    }
    if (upstream_count == 0) {
        if (!parse_ipv4("223.6.6.6", &upstreams[0].sin_addr) ||
            !parse_ipv4("114.114.114.114", &upstreams[1].sin_addr)) {
            die("cannot parse default upstreams");
        }
        upstreams[0].sin_family = AF_INET;
        upstreams[0].sin_port = htons(DNS_PORT);
        upstreams[1].sin_family = AF_INET;
        upstreams[1].sin_port = htons(DNS_PORT);
        upstream_count = 2;
    }

    signal(SIGTERM, on_stop);
    signal(SIGINT, on_stop);
    signal(SIGPIPE, SIG_IGN);

    udp_fd = create_udp_socket(&bind_address, port);
    tcp_fd = create_tcp_socket(&bind_address, port);

    fprintf(stderr, "leigod-dns-stub: listening on %s:%u\n", bind_text, port);

    while (stopping == 0) {
        struct pollfd fds[2] = {
            { .fd = udp_fd, .events = POLLIN, .revents = 0 },
            { .fd = tcp_fd, .events = POLLIN, .revents = 0 },
        };

        if (poll(fds, 2, 1000) <= 0) {
            continue;
        }

        if (fds[0].revents & POLLIN) {
            struct sockaddr_in from;
            socklen_t from_len = sizeof(from);
            char query[QUERY_MAX];
            char reply[QUERY_MAX];
            ssize_t query_len;
            ssize_t reply_len;

            query_len = recvfrom(udp_fd, query, sizeof(query), 0, (struct sockaddr *)&from,
                                 &from_len);
            if (query_len >= 12) {
                reply_len = query_upstream(upstreams, upstream_count, query, (size_t)query_len,
                                           reply, sizeof(reply));
                if (reply_len >= 12) {
                    (void)sendto(udp_fd, reply, (size_t)reply_len, 0, (struct sockaddr *)&from,
                                 from_len);
                }
            }
        }

        if (fds[1].revents & POLLIN) {
            int client = accept4(tcp_fd, NULL, NULL, SOCK_CLOEXEC);
            if (client >= 0) {
                handle_tcp_client(client, upstreams, upstream_count);
                close(client);
            }
        }
    }

    close(udp_fd);
    close(tcp_fd);
    return 0;
}
