#define _GNU_SOURCE
#include <lean/lean.h>
#include <uv.h>
#include <stdatomic.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>

#ifndef __linux__
#error "lean-uv currently requires Linux (SO_REUSEPORT and CPU affinity)"
#endif

/* These exported Lean runtime entry points are not in lean.h in Lean 4.26. */
extern void lean_initialize_thread(void);
extern void lean_finalize_thread(void);

typedef struct worker worker;
typedef struct connection connection;
typedef struct {
    const char *host;
    uint16_t port;
    uint32_t count, backlog, read_size, max_connections, first_cpu;
    uint64_t max_queued, idle_ms, run_ms;
    atomic_bool stop;
    uv_mutex_t mutex;
    uv_cond_t cond;
    unsigned ready;
    int go, error;
    worker *workers;
    lean_object *factory;
} server;

struct worker {
    server *server;
    uv_thread_t thread;
    uv_loop_t loop;
    uv_tcp_t listener;
    uv_timer_t timer;
    uv_signal_t sigint, sigterm;
    lean_object *on_connect;
    uint32_t id, active;
    int loop_ready;
    uint64_t started, last_sweep;
    uint64_t accepted, reads, received, sends, sent, queued, errors, disconnects, elapsed;
};

struct connection {
    uv_tcp_t tcp;
    uv_shutdown_t shutdown;
    worker *worker;
    uv_thread_t owner;
    atomic_uint refs;
    atomic_bool closed;
    lean_object *callbacks, *read_buffer;
    uint64_t retained, last_active;
    int closing, draining, paused, pressure;
};

typedef struct {
    uv_write_t req;
    lean_object *bytes;
    size_t size;
} write_request;

static uv_once_t class_once = UV_ONCE_INIT;
static lean_external_class *socket_class;
static atomic_bool serving = false;
static void close_connection(connection *c);
static void alloc_read(uv_handle_t *, size_t, uv_buf_t *);
static void on_read(uv_stream_t *, ssize_t, const uv_buf_t *);

static lean_object *ok(void) { return lean_io_result_mk_ok(lean_box(0)); }
static lean_object *error(int code) {
    return lean_io_result_mk_error(lean_decode_uv_error(code, NULL));
}
static void release_connection(connection *c) {
    if (atomic_fetch_sub_explicit(&c->refs, 1, memory_order_acq_rel) == 1) free(c);
}
static void socket_finalize(void *p) { release_connection(p); }
static void socket_foreach(void *p, b_lean_obj_arg f) { (void)p; (void)f; }
static void init_class(void) {
    socket_class = lean_register_external_class(socket_finalize, socket_foreach);
}

/* Check affinity BEFORE touching any loop-owned state. `owner` never changes,
   and the external reference keeps this allocation alive even after uv_close. */
static int get_connection(b_lean_obj_arg socket, connection **out) {
    connection *c = lean_get_external_data(socket);
    uv_thread_t current = uv_thread_self();
    if (!uv_thread_equal(&c->owner, &current)) return UV_EPERM;
    if (atomic_load_explicit(&c->closed, memory_order_acquire)) return UV_EBADF;
    *out = c;
    return 0;
}

static void callback_result(connection *c, lean_object *result) {
    if (lean_io_result_is_error(result)) {
        c->worker->errors++;
        close_connection(c);
    }
    lean_dec(result);
}

static void transport_error(connection *c, int status) {
    if (status == UV_ECONNRESET || status == UV_EPIPE) c->worker->disconnects++;
    else if (status != UV_ECANCELED) c->worker->errors++;
}

static void on_closed(uv_handle_t *h) {
    connection *c = h->data;
    atomic_store_explicit(&c->closed, true, memory_order_release);
    if (c->callbacks) {
        lean_object *action = lean_ctor_get(c->callbacks, 1);
        lean_inc(action);
        lean_object *result = lean_apply_1(action, lean_box(0));
        if (lean_io_result_is_error(result)) c->worker->errors++;
        lean_dec(result);
        lean_dec(c->callbacks);
    }
    if (c->read_buffer) lean_dec(c->read_buffer);
    c->worker->active--;
    release_connection(c);
}

static void close_connection(connection *c) {
    if (!c->closing) {
        c->closing = 1;
        uv_read_stop((uv_stream_t *)&c->tcp);
        uv_close((uv_handle_t *)&c->tcp, on_closed);
    }
}

static void on_shutdown(uv_shutdown_t *req, int status) {
    (void)status;
    close_connection(req->handle->data);
}

static int drain_connection(connection *c) {
    if (c->closing || c->draining) return 0;
    c->draining = 1;
    uv_read_stop((uv_stream_t *)&c->tcp);
    int rc = uv_shutdown(&c->shutdown, (uv_stream_t *)&c->tcp, on_shutdown);
    if (rc < 0) close_connection(c);
    return rc;
}

static int start_read(connection *c) {
    if (c->closing || c->draining || c->paused || c->pressure) return 0;
    int rc = uv_read_start((uv_stream_t *)&c->tcp, alloc_read, on_read);
    return rc == UV_EALREADY ? 0 : rc;
}

static void on_written(uv_write_t *req, int status) {
    write_request *w = (write_request *)req;
    connection *c = req->handle->data;
    c->retained -= w->size;
    lean_dec(w->bytes);
    free(w);
    if (status < 0) {
        transport_error(c, status);
        close_connection(c);
    } else if (c->pressure && c->retained < c->worker->server->max_queued / 4) {
        c->pressure = 0;
        int rc = start_read(c);
        if (rc < 0) { c->worker->errors++; close_connection(c); }
    }
}

LEAN_EXPORT lean_obj_res leanuv_send(b_lean_obj_arg socket, lean_obj_arg bytes) {
    connection *c = NULL;
    int rc = get_connection(socket, &c);
    if (rc < 0) { lean_dec(bytes); return error(rc); }
    if (c->closing || c->draining) { lean_dec(bytes); return error(UV_EPIPE); }
    size_t len = lean_sarray_size(bytes);
    if (!len) { lean_dec(bytes); return ok(); }
    uint64_t limit = c->worker->server->max_queued;
    if (len > UINT_MAX || len > limit || c->retained > limit - len) {
        lean_dec(bytes);
        return error(UV_ENOBUFS);
    }
    uv_buf_t buf = uv_buf_init((char *)lean_sarray_cptr(bytes), (unsigned)len);
    size_t offset = 0;
    if (!c->tcp.write_queue_size) {
        rc = uv_try_write((uv_stream_t *)&c->tcp, &buf, 1);
        if (rc == (int64_t)len) {
            c->worker->sends++;
            c->worker->sent += len;
            lean_dec(bytes);
            return ok();
        }
        if (rc < 0 && rc != UV_EAGAIN && rc != UV_ENOSYS) {
            lean_dec(bytes); close_connection(c); return error(rc);
        }
        if (rc > 0) offset = (size_t)rc;
    }
    write_request *w = malloc(sizeof(*w));
    if (!w) {
        lean_dec(bytes);
        /* A prefix may already be on the wire: do not permit a retry. */
        close_connection(c);
        return error(UV_ENOMEM);
    }
    w->bytes = bytes;
    w->size = len;
    buf.base += offset;
    buf.len -= offset;
    rc = uv_write(&w->req, (uv_stream_t *)&c->tcp, &buf, 1, on_written);
    if (rc < 0) {
        lean_dec(bytes); free(w); close_connection(c); return error(rc);
    }
    c->retained += len;
    c->worker->queued++;
    c->worker->sends++;
    c->worker->sent += len;
    if (c->retained >= limit / 2) {
        c->pressure = 1;
        uv_read_stop((uv_stream_t *)&c->tcp);
    }
    return ok();
}

LEAN_EXPORT lean_obj_res leanuv_close(b_lean_obj_arg socket) {
    connection *c = NULL;
    int rc = get_connection(socket, &c);
    if (rc == UV_EBADF) return ok();
    if (rc < 0) return error(rc);
    close_connection(c);
    return ok();
}
LEAN_EXPORT lean_obj_res leanuv_shutdown(b_lean_obj_arg socket) {
    connection *c = NULL;
    int rc = get_connection(socket, &c);
    if (rc < 0) return error(rc);
    rc = drain_connection(c);
    return rc < 0 ? error(rc) : ok();
}
LEAN_EXPORT lean_obj_res leanuv_pause(b_lean_obj_arg socket) {
    connection *c = NULL;
    int rc = get_connection(socket, &c);
    if (rc < 0) return error(rc);
    c->paused = 1;
    uv_read_stop((uv_stream_t *)&c->tcp);
    return ok();
}
LEAN_EXPORT lean_obj_res leanuv_resume(b_lean_obj_arg socket) {
    connection *c = NULL;
    int rc = get_connection(socket, &c);
    if (rc < 0) return error(rc);
    if (c->closing || c->draining) return error(UV_EPIPE);
    c->paused = 0;
    rc = start_read(c);
    return rc < 0 ? error(rc) : ok();
}
LEAN_EXPORT lean_obj_res leanuv_queued_bytes(b_lean_obj_arg socket) {
    connection *c = NULL;
    int rc = get_connection(socket, &c);
    if (rc < 0) return error(rc);
    return lean_io_result_mk_ok(lean_box_uint64(c->retained));
}
LEAN_EXPORT lean_obj_res leanuv_stop(b_lean_obj_arg socket) {
    connection *c = NULL;
    int rc = get_connection(socket, &c);
    if (rc < 0) return error(rc);
    atomic_store(&c->worker->server->stop, true);
    return ok();
}

static void alloc_read(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
    (void)suggested;
    connection *c = h->data;
    size_t size = c->worker->server->read_size;
    c->read_buffer = lean_alloc_sarray(1, 0, size);
    *buf = uv_buf_init((char *)lean_sarray_cptr(c->read_buffer), (unsigned)size);
}

static void on_read(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf) {
    (void)buf;
    connection *c = stream->data;
    lean_object *bytes = c->read_buffer;
    c->read_buffer = NULL;
    if (nread <= 0) {
        if (bytes) lean_dec(bytes);
        if (nread == UV_EOF) drain_connection(c);
        else if (nread < 0) { transport_error(c, (int)nread); close_connection(c); }
        return;
    }
    c->last_active = uv_now(stream->loop);
    c->worker->reads++;
    c->worker->received += (uint64_t)nread;
    lean_sarray_set_size(bytes, (size_t)nread);
    lean_object *callback = lean_ctor_get(c->callbacks, 0);
    lean_inc(callback);
    callback_result(c, lean_apply_2(callback, bytes, lean_box(0)));
}

static void on_connection(uv_stream_t *listener, int status) {
    worker *w = listener->data;
    if (status < 0) { w->errors++; return; }
    connection *c = calloc(1, sizeof(*c));
    if (!c) { w->errors++; atomic_store(&w->server->stop, true); return; }
    c->worker = w;
    c->owner = uv_thread_self();
    atomic_init(&c->refs, 1);  /* native handle reference */
    atomic_init(&c->closed, false);
    int rc = uv_tcp_init(&w->loop, &c->tcp);
    if (rc < 0) { free(c); w->errors++; return; }
    w->active++;
    c->tcp.data = c;
    rc = uv_accept(listener, (uv_stream_t *)&c->tcp);
    if (rc < 0) { w->errors++; close_connection(c); return; }
    if (w->active > w->server->max_connections) { close_connection(c); return; }
    rc = uv_tcp_nodelay(&c->tcp, 1);
    if (rc < 0) { w->errors++; close_connection(c); return; }
    w->accepted++;
    c->last_active = uv_now(&w->loop);
    atomic_fetch_add_explicit(&c->refs, 1, memory_order_relaxed);
    lean_object *socket = lean_alloc_external(socket_class, c);
    lean_inc(w->on_connect);
    lean_object *result = lean_apply_2(w->on_connect, socket, lean_box(0));
    if (lean_io_result_is_error(result)) { callback_result(c, result); return; }
    c->callbacks = lean_io_result_take_value(result);
    rc = start_read(c);
    if (rc < 0) { w->errors++; close_connection(c); }
}

static void close_walk(uv_handle_t *h, void *arg) {
    worker *w = arg;
    if (uv_is_closing(h)) return;
    if (h->type == UV_TCP && h != (uv_handle_t *)&w->listener) close_connection(h->data);
    else uv_close(h, NULL);
}

static void idle_walk(uv_handle_t *h, void *arg) {
    worker *w = arg;
    if (h->type != UV_TCP || h == (uv_handle_t *)&w->listener || uv_is_closing(h)) return;
    connection *c = h->data;
    if (uv_now(&w->loop) - c->last_active >= w->server->idle_ms) close_connection(c);
}

static void on_tick(uv_timer_t *timer) {
    worker *w = timer->data;
    if (w->server->run_ms && (uv_hrtime() - w->started) / 1000000 >= w->server->run_ms)
        atomic_store(&w->server->stop, true);
    if (atomic_load(&w->server->stop)) { uv_walk(&w->loop, close_walk, w); return; }
    uint64_t now = uv_now(&w->loop);
    if (w->server->idle_ms && now - w->last_sweep >= 1000) {
        w->last_sweep = now;
        uv_walk(&w->loop, idle_walk, w);
    }
}
static void on_signal(uv_signal_t *signal, int number) {
    (void)number;
    worker *w = signal->data;
    atomic_store(&w->server->stop, true);
}

static int setup_worker(worker *w) {
    server *s = w->server;
    if (s->first_cpu != UINT32_MAX) {
        uint64_t cpu = (uint64_t)s->first_cpu + w->id;
        if (cpu >= CPU_SETSIZE) return UV_EINVAL;
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(cpu, &set);
        int rc = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
        if (rc) return uv_translate_sys_error(rc);
    }
    int rc = uv_loop_init(&w->loop);
    if (rc < 0) return rc;
    w->loop_ready = 1;
    rc = uv_tcp_init(&w->loop, &w->listener);
    if (rc < 0) return rc;
    w->listener.data = w;
    struct sockaddr_storage addr;
    int family = strchr(s->host, ':') ? AF_INET6 : AF_INET;
    if (family == AF_INET6) rc = uv_ip6_addr(s->host, s->port, (struct sockaddr_in6 *)&addr);
    else rc = uv_ip4_addr(s->host, s->port, (struct sockaddr_in *)&addr);
    if (rc < 0) return rc;
    int fd = socket(family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return uv_translate_sys_error(errno);
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) ||
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) ||
        (family == AF_INET6 && setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one)))) {
        rc = uv_translate_sys_error(errno); close(fd); return rc;
    }
    if (bind(fd, (struct sockaddr *)&addr, family == AF_INET6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in))) {
        rc = uv_translate_sys_error(errno); close(fd); return rc;
    }
    rc = uv_tcp_open(&w->listener, fd);
    if (rc < 0) { close(fd); return rc; }
    rc = uv_listen((uv_stream_t *)&w->listener, (int)s->backlog, on_connection);
    if (rc < 0) return rc;
    rc = uv_timer_init(&w->loop, &w->timer);
    if (rc < 0) return rc;
    w->timer.data = w;
    rc = uv_timer_start(&w->timer, on_tick, 10, 10);
    if (rc < 0) return rc;
    if (w->id == 0) {
        rc = uv_signal_init(&w->loop, &w->sigint);
        if (rc < 0) return rc;
        w->sigint.data = w;
        rc = uv_signal_start(&w->sigint, on_signal, SIGINT);
        if (rc < 0) return rc;
        rc = uv_signal_init(&w->loop, &w->sigterm);
        if (rc < 0) return rc;
        w->sigterm.data = w;
        rc = uv_signal_start(&w->sigterm, on_signal, SIGTERM);
        if (rc < 0) return rc;
    }
    lean_inc(s->factory);
    lean_object *result = lean_apply_2(s->factory, lean_box_uint32(w->id), lean_box(0));
    if (lean_io_result_is_error(result)) {
        lean_io_result_show_error(result);
        lean_dec(result);
        return UV_EINVAL;
    }
    w->on_connect = lean_io_result_take_value(result);
    return 0;
}

static void worker_main(void *arg) {
    worker *w = arg;
    server *s = w->server;
    lean_initialize_thread();
    int rc = setup_worker(w);
    uv_mutex_lock(&s->mutex);
    if (rc < 0 && !s->error) s->error = rc;
    s->ready++;
    uv_cond_broadcast(&s->cond);
    while (!s->go) uv_cond_wait(&s->cond, &s->mutex);
    int failed = s->error;
    uv_mutex_unlock(&s->mutex);
    w->started = uv_hrtime();
    if (w->loop_ready) {
        if (failed) uv_walk(&w->loop, close_walk, w);
        uv_run(&w->loop, UV_RUN_DEFAULT);
        rc = uv_loop_close(&w->loop);
        if (rc < 0) {
            uv_mutex_lock(&s->mutex);
            if (!s->error) s->error = rc;
            uv_mutex_unlock(&s->mutex);
        }
    }
    w->elapsed = uv_hrtime() - w->started;
    if (w->on_connect) lean_dec(w->on_connect);
    lean_finalize_thread();
}

LEAN_EXPORT lean_obj_res leanuv_run(b_lean_obj_arg host, uint16_t port,
        uint32_t threads, uint32_t backlog, uint32_t read_size, uint64_t max_queued,
        uint32_t max_connections, uint64_t idle_ms, uint64_t run_ms, uint32_t first_cpu,
        lean_obj_arg factory) {
    if (!port || !threads || threads > 256 || !backlog || backlog > INT_MAX ||
        !read_size || read_size > 16 * 1024 * 1024 || max_queued < 4096 || !max_connections) {
        lean_dec(factory); return error(UV_EINVAL);
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(&serving, &expected, true)) {
        lean_dec(factory); return error(UV_EBUSY);
    }
    uv_once(&class_once, init_class);
    server s = { .host = lean_string_cstr(host), .port = port, .count = threads,
        .backlog = backlog, .read_size = read_size, .max_queued = max_queued,
        .max_connections = max_connections, .idle_ms = idle_ms, .run_ms = run_ms,
        .first_cpu = first_cpu, .factory = factory };
    atomic_init(&s.stop, false);
    int rc = uv_mutex_init(&s.mutex);
    if (rc < 0) goto early_error;
    rc = uv_cond_init(&s.cond);
    if (rc < 0) { uv_mutex_destroy(&s.mutex); goto early_error; }
    s.workers = calloc(threads, sizeof(worker));
    if (!s.workers) {
        rc = UV_ENOMEM;
        uv_cond_destroy(&s.cond); uv_mutex_destroy(&s.mutex);
        goto early_error;
    }
    lean_mark_mt(factory);
    unsigned created = 0;
    for (; created < threads; created++) {
        worker *w = &s.workers[created];
        w->server = &s;
        w->id = created;
        rc = uv_thread_create(&w->thread, worker_main, w);
        if (rc < 0) break;
    }
    uv_mutex_lock(&s.mutex);
    if (rc < 0 && !s.error) s.error = rc;
    while (s.ready < created) uv_cond_wait(&s.cond, &s.mutex);
    s.go = 1;
    uv_cond_broadcast(&s.cond);
    uv_mutex_unlock(&s.mutex);
    for (unsigned i = 0; i < created; i++) uv_thread_join(&s.workers[i].thread);
    lean_object *stats = lean_alloc_array(0, threads);
    for (unsigned i = 0; i < threads && !s.error; i++) {
        worker *w = &s.workers[i];
        lean_object *stat = lean_alloc_ctor(0, 0, 9 * sizeof(uint64_t));
        lean_ctor_set_uint64(stat, 0, w->accepted);
        lean_ctor_set_uint64(stat, 8, w->reads);
        lean_ctor_set_uint64(stat, 16, w->received);
        lean_ctor_set_uint64(stat, 24, w->sends);
        lean_ctor_set_uint64(stat, 32, w->sent);
        lean_ctor_set_uint64(stat, 40, w->queued);
        lean_ctor_set_uint64(stat, 48, w->errors);
        lean_ctor_set_uint64(stat, 56, w->disconnects);
        lean_ctor_set_uint64(stat, 64, w->elapsed);
        stats = lean_array_push(stats, stat);
    }
    free(s.workers);
    uv_cond_destroy(&s.cond);
    uv_mutex_destroy(&s.mutex);
    lean_dec(factory);
    atomic_store(&serving, false);
    if (s.error) { lean_dec(stats); return error(s.error); }
    return lean_io_result_mk_ok(stats);
early_error:
    lean_dec(factory);
    atomic_store(&serving, false);
    return error(rc);
}
