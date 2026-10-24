/* Minimal C/libuv throughput control. Only scans CRLFCRLF; it is NOT an HTTP
   parser or a production server. Its cheaper application work is intentional
   and must be disclosed when comparing it with the Lean HTTP benchmark. */
#define _GNU_SOURCE
#include <uv.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct worker worker;
typedef struct {
    uv_tcp_t tcp;
    worker *owner;
    unsigned match;
    char input[8192];
} connection;
struct worker {
    uv_loop_t loop;
    uv_tcp_t listener;
    uv_timer_t timer;
    pthread_t thread;
    unsigned id, port, cpu;
    unsigned long long sends;
};
static volatile sig_atomic_t stopped;
static char response[2048];
static unsigned response_size;
static void signal_stop(int sig) { (void)sig; stopped = 1; }
static void on_closed(uv_handle_t *h) { free(h->data); }
static void close_client(connection *c) {
    if (!uv_is_closing((uv_handle_t *)&c->tcp)) uv_close((uv_handle_t *)&c->tcp, on_closed);
}
static void written(uv_write_t *req, int status) {
    if (status < 0) close_client(req->handle->data);
    free(req);
}
static void send_reply(connection *c) {
    uv_buf_t b = uv_buf_init(response, response_size);
    int n = c->tcp.write_queue_size ? UV_EAGAIN : uv_try_write((uv_stream_t *)&c->tcp, &b, 1);
    if (n == (int)response_size) { c->owner->sends++; return; }
    if (n < 0 && n != UV_EAGAIN) { close_client(c); return; }
    if (n > 0) { b.base += n; b.len -= n; }
    uv_write_t *req = malloc(sizeof(*req));
    if (!req) { close_client(c); return; }
    if (uv_write(req, (uv_stream_t *)&c->tcp, &b, 1, written) < 0) { free(req); close_client(c); }
    else c->owner->sends++;
}
static void allocate(uv_handle_t *h, size_t suggested, uv_buf_t *b) {
    (void)suggested;
    connection *c = h->data;
    *b = uv_buf_init(c->input, sizeof(c->input));
}
static void read_data(uv_stream_t *stream, ssize_t n, const uv_buf_t *b) {
    connection *c = stream->data;
    if (n < 0) { close_client(c); return; }
    static const char delimiter[] = "\r\n\r\n";
    for (ssize_t i = 0; i < n; i++) {
        char ch = b->base[i];
        c->match = ch == delimiter[c->match] ? c->match + 1 : (ch == '\r' ? 1 : 0);
        if (c->match == 4) {
            c->match = 0;
            send_reply(c);
            if (uv_is_closing((uv_handle_t *)stream)) return;
        }
    }
}
static void accept_client(uv_stream_t *listener, int status) {
    if (status < 0) return;
    worker *w = listener->data;
    connection *c = calloc(1, sizeof(*c));
    if (!c) return;
    c->owner = w;
    if (uv_tcp_init(&w->loop, &c->tcp) < 0) { free(c); return; }
    c->tcp.data = c;
    if (uv_accept(listener, (uv_stream_t *)&c->tcp) < 0) { close_client(c); return; }
    uv_tcp_nodelay(&c->tcp, 1);
    if (uv_read_start((uv_stream_t *)&c->tcp, allocate, read_data) < 0) close_client(c);
}
static void close_all(uv_handle_t *h, void *arg) {
    worker *w = arg;
    if (uv_is_closing(h)) return;
    if (h->type == UV_TCP && h != (uv_handle_t *)&w->listener) close_client(h->data);
    else uv_close(h, NULL);
}
static void tick(uv_timer_t *timer) {
    if (stopped) uv_walk(timer->loop, close_all, timer->data);
}
static void check(int rc) {
    if (rc < 0) { fprintf(stderr, "libuv: %s\n", uv_strerror(rc)); exit(1); }
}
static void *run(void *arg) {
    worker *w = arg;
    if (w->cpu != (unsigned)-1) {
        cpu_set_t set; CPU_ZERO(&set); CPU_SET(w->cpu, &set);
        if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set)) exit(2);
    }
    check(uv_loop_init(&w->loop));
    check(uv_tcp_init(&w->loop, &w->listener));
    w->listener.data = w;
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0), one = 1;
    if (fd < 0 || setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) ||
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one))) exit(2);
    struct sockaddr_in addr;
    check(uv_ip4_addr("127.0.0.1", w->port, &addr));
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr))) exit(2);
    check(uv_tcp_open(&w->listener, fd));
    check(uv_listen((uv_stream_t *)&w->listener, 1024, accept_client));
    check(uv_timer_init(&w->loop, &w->timer));
    w->timer.data = w;
    check(uv_timer_start(&w->timer, tick, 10, 10));
    uv_run(&w->loop, UV_RUN_DEFAULT);
    check(uv_loop_close(&w->loop));
    return NULL;
}
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        printf("libuv %s (headers %d.%d.%d)\n", uv_version_string(), UV_VERSION_MAJOR, UV_VERSION_MINOR, UV_VERSION_PATCH);
        return 0;
    }
    unsigned port = argc > 1 ? (unsigned)atoi(argv[1]) : 8080;
    unsigned count = argc > 2 ? (unsigned)atoi(argv[2]) : 4;
    unsigned cpu = argc > 3 ? (unsigned)atoi(argv[3]) : (unsigned)-1;
    if (!port || port > 65535 || !count || count > 256 ||
        (cpu != (unsigned)-1 && (cpu >= CPU_SETSIZE || count > CPU_SETSIZE - cpu))) return 2;
    int header = snprintf(response, sizeof(response), "HTTP/1.1 200 OK\r\nContent-Length: 1024\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\n\r\n");
    memset(response + header, 'x', 1024);
    response_size = header + 1024;
    signal(SIGINT, signal_stop); signal(SIGTERM, signal_stop); signal(SIGPIPE, SIG_IGN);
    worker *workers = calloc(count, sizeof(*workers));
    if (!workers) return 2;
    for (unsigned i = 0; i < count; i++) {
        workers[i] = (worker){ .port = port, .id = i, .cpu = cpu == (unsigned)-1 ? cpu : cpu+i };
        if (pthread_create(&workers[i].thread, NULL, run, &workers[i])) exit(2);
    }
    for (unsigned i = 0; i < count; i++) {
        pthread_join(workers[i].thread, NULL);
        printf("worker=%u sends=%llu\n", i, workers[i].sends);
    }
    free(workers);
    return 0;
}
