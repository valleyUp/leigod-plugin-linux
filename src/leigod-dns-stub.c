#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define DNS_PORT 53
#define QUERY_MAX 4096
#define REPLY_MAX 65535
#define UPSTREAM_TIMEOUT_MS 1500
#define MAX_UPSTREAMS 4
#define WORKERS 4
#define QUEUE_MAX 32

static atomic_bool stopping;

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

static int64_t now_ms(void)
{
    struct timespec ts;
    (void)clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Expand a question name, with bounded compression traversal. Comparing wire
 * bytes directly would reject valid replies using different name compression. */
static int question(const unsigned char *packet, size_t length,
                    unsigned char *result, size_t *result_len, size_t *wire_end)
{
    size_t pos = 12, output = 0, end = 0, steps;
    if (length < 12 || packet[4] != 0 || packet[5] != 1) return -1;
    for (steps = 0; steps < 128; steps++) {
        unsigned int label;
        if (pos >= length) return -1;
        label = packet[pos++];
        if ((label & 0xc0) == 0xc0) {
            if (pos >= length) return -1;
            if (end == 0) end = pos + 1;
            pos = ((label & 0x3f) << 8) | packet[pos];
            continue;
        }
        if (label > 63 || pos + label > length || output + label + 1 > 255) return -1;
        result[output++] = (unsigned char)label;
        for (unsigned int index = 0; index < label; index++) {
            unsigned char ch = packet[pos++];
            result[output++] = ch >= 'A' && ch <= 'Z' ? (unsigned char)(ch + 32) : ch;
        }
        if (label == 0) {
            if (end == 0) end = pos;
            if (end + 4 > length) return -1;
            memcpy(result + output, packet + end, 4);
            *result_len = output + 4;
            *wire_end = end + 4;
            return 0;
        }
    }
    return -1;
}

static bool valid_reply(const char *query, size_t query_len, const char *reply, size_t reply_len)
{
    unsigned char q[260], r[260];
    size_t qlen, rlen, end;
    const unsigned char *response = (const unsigned char *)reply;
    if (reply_len < 12 || memcmp(query, reply, 2) != 0 ||
        !(response[2] & 0x80) || ((unsigned char)query[2] & 0x78) != (response[2] & 0x78)) return false;
    return question((const unsigned char *)query, query_len, q, &qlen, &end) == 0 &&
        question(response, reply_len, r, &rlen, &end) == 0 && qlen == rlen && memcmp(q, r, qlen) == 0;
}

static int transfer(int fd, void *buffer, size_t length, bool writing, int64_t deadline)
{
    size_t offset = 0;
    while (offset < length && !stopping) {
        int64_t remaining = deadline - now_ms();
        struct pollfd pfd = { .fd = fd, .events = writing ? POLLOUT : POLLIN };
        ssize_t count;
        if (remaining <= 0 || poll(&pfd, 1, (int)remaining) <= 0) return -1;
        count = writing ? send(fd, (char *)buffer + offset, length - offset, MSG_NOSIGNAL | MSG_DONTWAIT)
                        : recv(fd, (char *)buffer + offset, length - offset, MSG_DONTWAIT);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count <= 0) return -1;
        offset += (size_t)count;
    }
    return offset == length ? 0 : -1;
}

static ssize_t query_tcp(const struct sockaddr_in *upstream, const char *query, size_t query_len,
                         char *reply, size_t reply_cap)
{
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    int error = 0;
    socklen_t error_len = sizeof(error);
    int64_t deadline = now_ms() + UPSTREAM_TIMEOUT_MS;
    unsigned char header[2] = { (unsigned char)(query_len >> 8), (unsigned char)query_len };
    size_t length;
    ssize_t result = -1;
    struct pollfd pfd = { .fd = fd, .events = POLLOUT };
    if (fd < 0) return -1;
    if (connect(fd, (const struct sockaddr *)upstream, sizeof(*upstream)) != 0 && errno != EINPROGRESS) goto out;
    if (poll(&pfd, 1, UPSTREAM_TIMEOUT_MS) <= 0 ||
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_len) != 0 || error != 0) goto out;
    if (transfer(fd, header, 2, true, deadline) != 0 ||
        transfer(fd, (void *)query, query_len, true, deadline) != 0 ||
        transfer(fd, header, 2, false, deadline) != 0) goto out;
    length = ((size_t)header[0] << 8) | header[1];
    if (length < 12 || length > reply_cap || transfer(fd, reply, length, false, deadline) != 0) goto out;
    if (valid_reply(query, query_len, reply, length) && !((unsigned char)reply[2] & 0x02)) result = (ssize_t)length;
out:
    close(fd);
    return result;
}

static ssize_t query_upstream(const struct sockaddr_in *upstreams, size_t upstream_count,
                              const char *query, size_t query_len, char *reply, size_t reply_cap,
                              bool tcp)
{
    size_t index;
    unsigned char name[260];
    size_t name_len, question_end;

    if (query_len < 12 || query_len > QUERY_MAX ||
        question((const unsigned char *)query, query_len, name, &name_len, &question_end) != 0) {
        errno = EINVAL;
        return -1;
    }

    for (index = 0; index < upstream_count && !stopping; index++) {
        int fd;
        int64_t deadline;
        ssize_t received = -1;
        if (tcp) {
            received = query_tcp(&upstreams[index], query, query_len, reply, reply_cap);
            if (received >= 12) return received;
            continue;
        }
        fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (fd < 0) {
            continue;
        }
        /* A connected UDP socket accepts packets only from this upstream. */
        if (connect(fd, (const struct sockaddr *)&upstreams[index], sizeof(upstreams[index])) != 0 ||
            send(fd, query, query_len, 0) != (ssize_t)query_len) {
            close(fd);
            continue;
        }

        deadline = now_ms() + UPSTREAM_TIMEOUT_MS;
        while (!stopping && now_ms() < deadline) {
            struct pollfd pfd = { .fd = fd, .events = POLLIN };
            int64_t remaining = deadline - now_ms();
            if (remaining <= 0 || poll(&pfd, 1, (int)remaining) <= 0) break;
            received = recv(fd, reply, reply_cap, MSG_TRUNC | MSG_DONTWAIT);
            if (received < 0) break;
            if ((size_t)received <= reply_cap && valid_reply(query, query_len, reply, (size_t)received)) break;
            received = -1;
        }
        close(fd);
        if (received >= 12) {
            if ((unsigned char)reply[2] & 0x02) {
                received = query_tcp(&upstreams[index], query, query_len, reply, reply_cap);
                if (received < 12) continue;
            }
            return received;
        }
    }

    errno = ETIMEDOUT;
    return -1;
}

static ssize_t servfail(const char *query, size_t query_len, char *reply)
{
    unsigned char name[260];
    size_t name_len, end;
    if (question((const unsigned char *)query, query_len, name, &name_len, &end) != 0) return -1;
    memcpy(reply, query, end);
    reply[2] = (char)(((unsigned char)query[2] & 0x79) | 0x80);
    reply[3] = (char)0x82;
    memset(reply + 6, 0, 6);
    return (ssize_t)end;
}

static ssize_t fit_udp_reply(const char *query, size_t query_len, char *reply, ssize_t length)
{
    unsigned char name[260], flags[2];
    size_t name_len, end, capacity = 512;
    const unsigned char *q = (const unsigned char *)query;
    if (question(q, query_len, name, &name_len, &end) != 0) return -1;
    /* The common EDNS OPT record immediately follows the question. Unknown
     * additional sections conservatively retain the classic 512-byte limit. */
    if (q[10] == 0 && q[11] == 1 && end + 11 <= query_len &&
        q[end] == 0 && q[end + 1] == 0 && q[end + 2] == 41) {
        capacity = ((size_t)q[end + 3] << 8) | q[end + 4];
        if (capacity < 512) capacity = 512;
        if (capacity > QUERY_MAX) capacity = QUERY_MAX;
    }
    if (length <= (ssize_t)capacity) return length;
    flags[0] = (unsigned char)reply[2] | 0x02;
    flags[1] = (unsigned char)reply[3];
    memcpy(reply, query, end);
    reply[2] = (char)flags[0];
    reply[3] = (char)flags[1];
    memset(reply + 6, 0, 6);
    return (ssize_t)end;
}

static void handle_tcp_client(int client, const struct sockaddr_in *upstreams,
                              size_t upstream_count)
{
    unsigned char header[2];
    char query[QUERY_MAX];
    char reply[REPLY_MAX];
    uint16_t query_len;
    ssize_t reply_len;
    unsigned char reply_header[2];
    int64_t deadline = now_ms() + 2000;
    if (transfer(client, header, 2, false, deadline) != 0) {
        return;
    }
    query_len = (uint16_t)((header[0] << 8) | header[1]);
    if (query_len < 12 || query_len > QUERY_MAX) {
        return;
    }
    if (transfer(client, query, query_len, false, deadline) != 0 || ((unsigned char)query[2] & 0x80)) {
        return;
    }

    reply_len = query_upstream(upstreams, upstream_count, query, query_len, reply, sizeof(reply), true);
    if (reply_len < 12) reply_len = servfail(query, query_len, reply);
    if (reply_len < 12) {
        return;
    }
    reply_header[0] = (unsigned char)((reply_len >> 8) & 0xff);
    reply_header[1] = (unsigned char)(reply_len & 0xff);
    deadline = now_ms() + 2000;
    if (transfer(client, reply_header, 2, true, deadline) != 0) {
        return;
    }
    (void)transfer(client, reply, (size_t)reply_len, true, deadline);
}

struct job {
    int client;
    struct sockaddr_in from;
    size_t length;
    char query[QUERY_MAX];
};
struct pool {
    pthread_mutex_t mutex;
    pthread_cond_t available;
    struct job jobs[QUEUE_MAX];
    size_t head, count;
    bool done;
    int udp_fd;
    const struct sockaddr_in *upstreams;
    size_t upstream_count;
};

static void *worker(void *argument)
{
    struct pool *pool = argument;
    for (;;) {
        struct job job;
        char reply[REPLY_MAX];
        ssize_t length;
        pthread_mutex_lock(&pool->mutex);
        while (!pool->count && !pool->done) pthread_cond_wait(&pool->available, &pool->mutex);
        if (pool->done) { pthread_mutex_unlock(&pool->mutex); break; }
        job = pool->jobs[pool->head];
        pool->head = (pool->head + 1) % QUEUE_MAX;
        pool->count--;
        pthread_mutex_unlock(&pool->mutex);
        if (job.client >= 0) {
            handle_tcp_client(job.client, pool->upstreams, pool->upstream_count);
            close(job.client);
        } else {
            length = query_upstream(pool->upstreams, pool->upstream_count, job.query, job.length,
                                    reply, sizeof(reply), false);
            if (length < 12) length = servfail(job.query, job.length, reply);
            if (length >= 12) length = fit_udp_reply(job.query, job.length, reply, length);
            if (length >= 12) (void)sendto(pool->udp_fd, reply, (size_t)length, 0,
                                          (struct sockaddr *)&job.from, sizeof(job.from));
        }
    }
    return NULL;
}

static void enqueue(struct pool *pool, const struct job *job)
{
    pthread_mutex_lock(&pool->mutex);
    if (pool->count < QUEUE_MAX) {
        pool->jobs[(pool->head + pool->count) % QUEUE_MAX] = *job;
        pool->count++;
        pthread_cond_signal(&pool->available);
    } else if (job->client >= 0) {
        close(job->client);
    } else {
        char reply[QUERY_MAX];
        ssize_t length = servfail(job->query, job->length, reply);
        if (length >= 12) (void)sendto(pool->udp_fd, reply, (size_t)length, 0,
                                      (const struct sockaddr *)&job->from, sizeof(job->from));
    }
    pthread_mutex_unlock(&pool->mutex);
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
    query[5] = 1;
    query[14] = 1;
    query[16] = 1;
    memcpy(reply, query, 17);
    reply[2] = (char)0x81;
    if (!valid_reply(query, 17, reply, 17)) return 1;
    reply[1]++;
    if (valid_reply(query, 17, reply, 17)) return 1;
    if (query_upstream(&upstream, 1, query, 17, reply, sizeof(reply), false) >= 0) {
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
    pthread_t workers[WORKERS];
    struct pool pool = { .mutex = PTHREAD_MUTEX_INITIALIZER, .available = PTHREAD_COND_INITIALIZER };

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
    pool.udp_fd = udp_fd;
    pool.upstreams = upstreams;
    pool.upstream_count = upstream_count;
    for (arg = 0; arg < WORKERS; arg++) {
        int error = pthread_create(&workers[arg], NULL, worker, &pool);
        if (error != 0) { errno = error; die("cannot create DNS worker"); }
    }

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
            struct job job = { .client = -1 };
            socklen_t from_len = sizeof(job.from);
            ssize_t query_len;
            query_len = recvfrom(udp_fd, job.query, sizeof(job.query), MSG_TRUNC, (struct sockaddr *)&job.from,
                                 &from_len);
            if (query_len >= 12 && query_len <= QUERY_MAX && !((unsigned char)job.query[2] & 0x80)) {
                job.length = (size_t)query_len;
                enqueue(&pool, &job);
            }
        }

        if (fds[1].revents & POLLIN) {
            int client = accept4(tcp_fd, NULL, NULL, SOCK_CLOEXEC);
            if (client >= 0) {
                struct job job = { .client = client };
                enqueue(&pool, &job);
            }
        }
    }

    pthread_mutex_lock(&pool.mutex);
    pool.done = true;
    pthread_cond_broadcast(&pool.available);
    pthread_mutex_unlock(&pool.mutex);
    for (arg = 0; arg < WORKERS; arg++) pthread_join(workers[arg], NULL);
    for (size_t index = 0; index < pool.count; index++) {
        int client = pool.jobs[(pool.head + index) % QUEUE_MAX].client;
        if (client >= 0) close(client);
    }
    close(udp_fd);
    close(tcp_fd);
    return 0;
}
