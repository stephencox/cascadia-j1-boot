/* i2creg bus addr reg [count]      read 8-bit registers
 * i2creg -w bus addr reg value     write one (I2C_SLAVE_FORCE: the PMU is bound) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>

int main(int argc, char **argv)
{
    int w = argc > 1 && !strcmp(argv[1], "-w"), a = w ? 2 : 1, fd, i, n;
    char dev[32];
    unsigned char b[2], v;

    if(argc < a + 3 || (w && argc < a + 4)) {
        fprintf(stderr, "usage: i2creg bus addr reg [count] | i2creg -w bus addr reg value\n");
        return 2;
    }
    snprintf(dev, sizeof(dev), "/dev/i2c-%s", argv[a]);
    fd = open(dev, O_RDWR);
    if(fd < 0 || ioctl(fd, I2C_SLAVE_FORCE, strtoul(argv[a + 1], NULL, 0)) < 0) {
        perror(dev);
        return 1;
    }
    b[0] = strtoul(argv[a + 2], NULL, 0);
    if(w) {
        b[1] = strtoul(argv[a + 3], NULL, 0);
        if(write(fd, b, 2) != 2) { perror("write"); return 1; }
    }
    n = !w && argc > a + 3 ? atoi(argv[a + 3]) : 1;
    for(i = 0; i < n; i++) {
        unsigned char r = b[0] + i;
        if(write(fd, &r, 1) != 1 || read(fd, &v, 1) != 1) { perror("read"); return 1; }
        printf("%02x: %02x\n", r, v);
    }
    return 0;
}
