#include "CPhoneShim.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

int tp_shm_create(const char *name, size_t size) {
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)size) != 0) { close(fd); shm_unlink(name); return -1; }
    return fd;
}

int tp_shm_unlink(const char *name) { return shm_unlink(name); }

int tp_kevent(int queue, const struct kevent *changes, int change_count,
              struct kevent *events, int event_count, const struct timespec *timeout) {
    return kevent(queue, changes, change_count, events, event_count, timeout);
}
