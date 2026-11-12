/*
 * ika-shift-held: whether a Shift key is held down on a keyboard of this
 * computer. ika asks it as Ika or an app is launched from a menu: Shift held
 * then opens the Startup Options instead (on WSLg, ika asks Windows instead,
 * as WSL has no keyboard devices).
 *
 * Wayland has no way for a program to ask which keys are held, and the
 * keyboards' devices are readable by the input group only. The packages give
 * this program the one capability to open them (cap_dac_read_search); it
 * opens nothing but /dev/input/event*, gives the capability up before it
 * reads anything, and tells only whether Shift is held, by its exit status:
 *
 *   0  a Shift key is held
 *   1  no Shift key is held
 *   2  no keyboard could be read
 */
#include <dirent.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <linux/input.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MAX_DEVICES 64
#define BITS_PER_LONG (8 * sizeof(unsigned long))
#define LONGS(bits) (((bits) + BITS_PER_LONG - 1) / BITS_PER_LONG)

static int bit_set(const unsigned long *bits, int bit) {
  return (bits[bit / BITS_PER_LONG] >> (bit % BITS_PER_LONG)) & 1;
}

static void drop_capabilities(void) {
  struct __user_cap_header_struct header = {_LINUX_CAPABILITY_VERSION_3, 0};
  struct __user_cap_data_struct data[_LINUX_CAPABILITY_U32S_3];

  memset(data, 0, sizeof(data));
  syscall(SYS_capset, &header, data);
}

int main(void) {
  int fds[MAX_DEVICES];
  int count = 0;
  int readable = 0;
  DIR *dir = opendir("/dev/input");

  if (dir != NULL) {
    struct dirent *entry;

    while (count < MAX_DEVICES && (entry = readdir(dir)) != NULL) {
      int fd;

      if (strncmp(entry->d_name, "event", 5) != 0) continue;
      fd = openat(dirfd(dir), entry->d_name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
      if (fd >= 0) fds[count++] = fd;
    }
    closedir(dir);
  }
  /* Nothing below needs the capability. */
  drop_capabilities();

  for (int i = 0; i < count; i++) {
    unsigned long keys[LONGS(KEY_CNT)];
    unsigned long state[LONGS(KEY_CNT)];

    memset(keys, 0, sizeof(keys));
    memset(state, 0, sizeof(state));
    if (ioctl(fds[i], EVIOCGBIT(EV_KEY, sizeof(keys)), keys) < 0) continue;
    if (!bit_set(keys, KEY_LEFTSHIFT) && !bit_set(keys, KEY_RIGHTSHIFT)) continue;
    if (ioctl(fds[i], EVIOCGKEY(sizeof(state)), state) < 0) continue;
    readable = 1;
    if (bit_set(state, KEY_LEFTSHIFT) || bit_set(state, KEY_RIGHTSHIFT)) return 0;
  }
  return readable ? 1 : 2;
}
