#include <errno.h>
#include <unistd.h>

/* Purpose-built CLI fixture: no documents, UI, sockets, writes or signals.
 * The owning test closes stdin; EOF is the sole normal shutdown mechanism. */
int main(void) {
    if (write(STDOUT_FILENO, "READY\n", 6) != 6) return 2;
    char bytes[16];
    for (;;) {
        ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count == 0) return 0;
        if (count < 0 && errno != EINTR) return 3;
    }
}
