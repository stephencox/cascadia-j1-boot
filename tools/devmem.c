/* devmem addr [count] | devmem -w addr value: 32-bit MMIO peek/poke via mmap. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

int main(int argc, char **argv)
{
    int w = argc > 1 && !strcmp(argv[1], "-w"), a = w ? 2 : 1, fd, i, n;
    unsigned long addr, page;
    volatile uint32_t *p;

    if(argc < a + 1 || (w && argc < 4)) {
        fprintf(stderr, "usage: devmem addr [count] | devmem -w addr value\n");
        return 2;
    }
    addr = strtoul(argv[a], NULL, 0);
    n = !w && argc > a + 1 ? atoi(argv[a + 1]) : 1;
    page = addr & ~0xfffUL;
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if(fd < 0) { perror("/dev/mem"); return 1; }
    p = mmap(NULL, 0x2000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page);
    if(p == MAP_FAILED) { perror("mmap"); return 1; }
    p += (addr - page) / 4;
    if(w) {
        *p = strtoul(argv[a + 1], NULL, 0);
        printf("%08lx <- %08lx, reads %08x\n", addr, strtoul(argv[a + 1], NULL, 0), *p);
        return 0;
    }
    for(i = 0; i < n; i++)
        printf("%08lx: %08x\n", addr + i * 4, p[i]);
    return 0;
}
