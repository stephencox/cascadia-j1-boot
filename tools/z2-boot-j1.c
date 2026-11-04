/* z2-boot-j1 -- bring up the iPad 3's (J1) Z2F13,3 digitizer the way
 * iOS 9.3.5's MTSPIBootloader_Z2 does (touch/README.md has the sequence and
 * where each value was read). Built from Project-Cascadia's tools/z2-boot.c
 * (the iPad mini's): its HBPP packet, download, GET/SET and frame-poll code
 * is reused as is; the mini-only parts (N1 calibration sequence, ee wake,
 * PMU and grape-clk pokes through /dev/mem) are gone.
 *
 * J1 differences from the mini:
 *   - enable_download (GPIO 166, HXT_IOC_SET_DL) follows reset and is held
 *     around the HBPP check and the whole bootload
 *   - calibration (1024 bytes, j1-mtcal.bin) goes to 0x1000c000, and before
 *     the firmware (-f sends the firmware first, as iOS 8 did on the mini)
 *   - performCalibSeq: read 0x10008ffc; unless 0x5a020028, write
 *     0x10001c04 <- fll-mval 0x189c (mask 0x1fff), 0x10001c08 <- 0x840000
 *     (mask 0xff0000), 0x1000300c <- 5 (mask 0x85), 0x1000304c <- 0x20;
 *     then 1f 01, 65 ms, ATN_ACK
 *   - EXECUTE at 0x10001800
 *
 * usage: z2-boot-j1 [-c cal] [-F fll-mval] [-f] [-B] [-p secs] [-N] [-t secs] [mtprops]
 *   -c  panel calibration (default /lib/firmware/j1-mtcal.bin if present)
 *   -f  firmware before calibration
 *   -B  do not send the mini's bf/af scan-start reports
 *   -p  poll frames for that many seconds before READY
 *   -N  no READY: close instead of handing the chip to the kernel
 *   -t  hold the device open this many seconds after READY (default forever)
 *   -i  invert enable_download (the DT already marks it active-low)
 *   -d  never drive enable_download
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>

#define HXT_IOC_SET_CS          _IOW('h', 1, uint32_t)
#define HXT_IOC_RESET           _IO('h', 2)
#define HXT_IOC_READY           _IO('h', 3)
#define HXT_IOC_SETUP_IRQ       _IO('h', 4)
#define HXT_IOC_WAIT_IRQ        _IOW('h', 5, uint32_t)
struct hxt_metrics { int left, right, top, bottom; };
#define HXT_IOC_METRICS         _IOW('h', 6, struct hxt_metrics)
#define HXT_IOC_SET_DL          _IOW('h', 7, uint32_t)

#define CHUNK   16384

static int fd = -1;
static uint8_t scratch[CHUNK];
static struct timespec t_start;

static void hex(const char *tag, const uint8_t *p, size_t n)
{
    size_t i;
    printf("  %-16s", tag);
    for(i = 0; i < n && i < 16; i++)
        printf(" %02x", p[i]);
    printf("%s\n", n > 16 ? " ..." : "");
}

static void cs(int on)
{
    if(ioctl(fd, HXT_IOC_SET_CS, on) < 0)
        perror("SET_CS");
}

/* One chip-select window: n bytes out, n bytes in. */
static int xfer(const uint8_t *tx, uint8_t *rx, size_t n)
{
    size_t off = 0, c;

    cs(1);
    usleep(1000);
    while(off < n) {
        c = n - off > CHUNK ? CHUNK : n - off;
        if(write(fd, tx + off, c) != (ssize_t)c) {
            perror("write");
            cs(0);
            return -1;
        }
        if(read(fd, rx ? rx + off : scratch, c) != (ssize_t)c) {
            perror("read");
            cs(0);
            return -1;
        }
        off += c;
    }
    cs(0);
    usleep(1000);
    return 0;
}


static void arm_attn(void)
{
    ioctl(fd, HXT_IOC_SETUP_IRQ);
}

static int wait_attn(unsigned ms)
{
    return ioctl(fd, HXT_IOC_WAIT_IRQ, ms) == 0;
}

/* No /dev/mem pad read here: the poll loop's "L" column shows '?'. */
static char attn_level(void)
{
    return '?';
}

static void stamp(const char *what)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    printf("  [%6.3f s] %s\n", (t.tv_sec - t_start.tv_sec) + (t.tv_nsec - t_start.tv_nsec) / 1e9, what);
}

/* enable_download: -i inverts the inferred active-high, -d never drives it. */
static int dl_invert, dl_skip;

static void dl(int on)
{
    if(dl_skip)
        return;
    if(ioctl(fd, HXT_IOC_SET_DL, dl_invert ? !on : on) < 0)
        perror("SET_DL");
}

/* ---- HBPP ------------------------------------------------------------ */

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = v >> 8; p[1] = v; p[2] = v >> 24; p[3] = v >> 16;
}

static uint16_t sum16(const uint8_t *p, size_t n)
{
    uint16_t s = 0;
    while(n--)
        s += *p++;
    return s;
}

static int atn_ack(uint16_t *st)
{
    uint8_t tx[2] = { 0x1a, 0xa1 }, rx[2];
    if(xfer(tx, rx, 2))
        return -1;
    *st = rx[0] << 8 | rx[1];
    return 0;
}

static int long_atn_ack(uint32_t *v)
{
    uint8_t tx[8] = { 0x1a, 0xa1, 0x18, 0xe1, 0x18, 0xe1, 0x18, 0xe1 }, rx[8];
    if(xfer(tx, rx, 8))
        return -1;
    *v = (uint32_t)rx[4] << 24 | (uint32_t)rx[5] << 16 | (uint32_t)rx[2] << 8 | rx[3];
    return 0;
}

static int is_status_word(uint16_t w)
{
    return w == 0x18e1 || w == 0x1aa1 || w == 0x1f01 || w == 0x4879 ||
           w == 0x4969 || w == 0x4ad1 || w == 0x4bc1;
}

static int hbpp_check(void)
{
    uint8_t tx[16] = { 0x1a, 0xa1 }, rx[16];
    int i;
    for(i = 2; i < 16; i += 2) {
        tx[i] = 0x18;
        tx[i + 1] = 0xe1;
    }
    if(xfer(tx, rx, 16))
        return 0;
    hex("HBPP check ->", rx, 16);
    return is_status_word(rx[0] << 8 | rx[1]) && is_status_word(rx[2] << 8 | rx[3]);
}

static int reg_read(uint32_t addr, uint32_t *v)
{
    uint8_t p[8] = { 0x1c, 0x73 };
    uint16_t c;
    int attn;

    put32(p + 2, addr);
    c = sum16(p + 2, 4);
    p[6] = c >> 8; p[7] = c;
    arm_attn();
    if(xfer(p, NULL, 8))
        return -1;
    attn = wait_attn(20);
    if(long_atn_ack(v))
        return -1;
    printf("  read  %08x = %08x%s\n", addr, *v, attn ? "" : "   (no ATTN)");
    return 0;
}

static int reg_write(uint32_t addr, uint32_t val, uint32_t mask)
{
    uint8_t p[16] = { 0x1e, 0x33 };
    uint16_t c, st;
    int attn;

    put32(p + 2, addr);
    put32(p + 6, mask);
    put32(p + 10, val);
    c = sum16(p + 2, 12);
    p[14] = c >> 8; p[15] = c;
    arm_attn();
    if(xfer(p, NULL, 16))
        return -1;
    attn = wait_attn(20);
    if(atn_ack(&st))
        return -1;
    printf("  write %08x <- %08x (mask %08x): ack %04x%s%s\n", addr, val, mask, st,
           st == 0x4ad1 ? "" : "   NOT 4ad1", attn ? "" : "   (no ATTN)");
    return st == 0x4ad1 ? 0 : -1;
}

/* A blob into the chip's memory the way MTSPIBootloader_Z2 sends calibration
 * (0x80607f04): DATA packets of at most 0x3f0 bytes, each answered by
 * ATN_ACK 4bc1, up to five tries per packet.  The length is padded to whole
 * words with zeros, as iOS rounds it up. */
static int download(const char *what, uint32_t addr, const uint8_t *src, size_t len)
{
    static uint8_t pkt[2 + 10 + 0x3f0 + 4];
    size_t alen = (len + 3) & ~(size_t)3, off, chunk, i;
    uint8_t *o, w[4];
    uint32_t dsum;
    uint16_t st = 0;
    int tries, attn;

    for(off = 0; off < alen; off += chunk) {
        chunk = alen - off > 0x3f0 ? 0x3f0 : alen - off;
        pkt[0] = 0x18; pkt[1] = 0xe1;
        o = pkt + 2;
        o[0] = 0x30; o[1] = 0x01;
        o[2] = chunk >> 10; o[3] = chunk >> 2;
        put32(o + 4, addr + off);
        o[8] = sum16(o + 2, 6) >> 8; o[9] = sum16(o + 2, 6);
        dsum = 0;
        for(i = 0; i < chunk; i += 4) {
            memset(w, 0, 4);
            memcpy(w, src + off + i, off + i + 4 <= len ? 4 : len > off + i ? len - off - i : 0);
            put32(o + 10 + i, (uint32_t)w[3] << 24 | (uint32_t)w[2] << 16 | w[1] << 8 | w[0]);
            dsum += o[10 + i] + o[11 + i] + o[12 + i] + o[13 + i];
        }
        put32(o + 10 + chunk, dsum);
        for(tries = 0; tries < 5; tries++) {
            arm_attn();
            if(xfer(pkt, NULL, chunk + 16))
                return -1;
            attn = wait_attn(200);
            if(atn_ack(&st))
                return -1;
            if(st == 0x4bc1)
                break;
            printf("  %s @ %08x: ack %04x%s, retrying\n", what, addr + (uint32_t)off, st,
                   attn ? "" : " (no ATTN)");
        }
        if(st != 0x4bc1) {
            printf("  %s @ %08x: gave up after 5 tries\n", what, addr + (uint32_t)off);
            return -1;
        }
    }
    printf("  %s: %zu bytes to %08x, every packet 4bc1\n", what, len, addr);
    return 0;
}

static uint8_t *load_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    uint8_t *p;
    long sz;

    if(!f) {
        perror(path);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    rewind(f);
    p = malloc(sz > 0 ? sz : 1);
    if(!p || fread(p, 1, sz, f) != (size_t)sz) {
        fprintf(stderr, "%s: short read\n", path);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *len = sz;
    return p;
}

static int execute(uint32_t addr)
{
    uint8_t p[12] = { 0x1d, 0x53 };
    uint16_t c;

    put32(p + 2, addr);
    put32(p + 6, 1);
    c = sum16(p + 2, 8);
    p[10] = c >> 8; p[11] = c;
    hex("EXECUTE", p, 12);
    return xfer(p, NULL, 12);
}

static int b64(int ch)
{
    if(ch >= 'A' && ch <= 'Z') return ch - 'A';
    if(ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
    if(ch >= '0' && ch <= '9') return ch - '0' + 52;
    if(ch == '+') return 62;
    if(ch == '/') return 63;
    return -1;
}

static uint8_t *load_firmware(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    char *txt, *p, *e;
    long sz;
    uint8_t *out;
    unsigned acc = 0, bits = 0;
    size_t n = 0;

    if(!f) {
        perror(path);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    rewind(f);
    txt = malloc(sz + 1);
    if(!txt || fread(txt, 1, sz, f) != (size_t)sz) {
        fprintf(stderr, "%s: short read\n", path);
        return NULL;
    }
    fclose(f);
    txt[sz] = 0;

    p = strstr(txt, "<key>PreconstructedBootloadPacketType</key>");
    if(p && (p = strstr(p, "<string>")) && (e = strchr(p + 8, '<')))
        printf("  packet type %.*s\n", (int)(e - p - 8), p + 8);
    p = strstr(txt, "<key>Constructed Firmware</key>");
    if(!p || !(p = strstr(p, "<data>")) || !(e = strstr(p, "</data>"))) {
        fprintf(stderr, "%s: no Constructed Firmware\n", path);
        return NULL;
    }
    out = malloc(e - p);
    for(p += 6; p < e; p++) {
        int v = b64(*p);
        if(v < 0)
            continue;
        acc = acc << 6 | v;
        bits += 6;
        if(bits >= 8) {
            bits -= 8;
            out[n++] = acc >> bits;
        }
    }
    free(txt);
    *len = n;
    return out;
}

/* ---- post-boot, as iOS does it ----------------------------------------- */

static int z2_quiet(const uint8_t *in, uint8_t *r)
{
    uint8_t b[16];
    uint16_t s;

    memcpy(b, in, 16);
    s = sum16(b, 14);
    b[14] = s; b[15] = s >> 8;
    return xfer(b, r, 16);
}

static int z2_cmd(const uint8_t *in, uint8_t *res)
{
    uint8_t r[16];

    if(z2_quiet(in, r))
        return -1;
    printf("  cmd %02x %02x ->", in[0], in[1]);
    hex("", r, 16);
    if(res)
        memcpy(res, r, 16);
    return 0;
}

/* e3 id, twice: the answer to a command comes back during the next
 * transfer.  1 and the 16 answer bytes -- e3 id status len(LE16) data[9]
 * csum -- when it is that report's, with a good sum. */
static int get_report(uint8_t id, uint8_t *r)
{
    uint8_t c[16] = { 0xe3, id };

    if(z2_quiet(c, r) || z2_quiet(c, r))
        return 0;
    return r[0] == 0xe3 && r[1] == id && (r[14] | r[15] << 8) == sum16(r, 14);
}

/* GET report the way AppleMultitouchZ2SPI's control read does it: a stage-0
 * command, then stage 1 which carries the answer -- 16 bytes for a short
 * read (e6), len + 5 for a long one (e7), the csum at the very end. */
static uint8_t d9[64];          /* the last answer to GET d9 */

static void ios_get(uint8_t id, unsigned len, int lng)
{
    uint8_t c[16] = { lng ? 0xe7 : 0xe6, id, 0, len }, r[16], b[64], a[64];
    uint16_t s = c[0] + id + len;
    unsigned n = lng ? len + 5 : 16;

    c[14] = s; c[15] = s >> 8;
    if(xfer(c, r, 16) || n > sizeof(b))
        return;
    memset(b, 0, n);
    memcpy(b, c, 4);
    b[2] = 1;
    b[n - 2] = s; b[n - 1] = s >> 8;
    if(xfer(b, a, n))
        return;
    if(id == 0xd9)
        memcpy(d9, a, n);
    printf("  GET %02x ->", id);
    hex("", a, n);
    if(n > 16)
        hex("     ...", a + 16, n - 16);
}

static void set_report(uint8_t id, const uint8_t *data, uint8_t len)
{
    uint8_t c[16] = { 0xe4, id, len };
    memcpy(c + 3, data, len);
    z2_cmd(c, NULL);
    memset(c, 0, 16);           /* a clean e1 00, as iOS sends it */
    c[0] = 0xe1;
    z2_cmd(c, NULL);
}

static void poll_frames(int secs)
{
    uint8_t q[16], r[16], last[16] = { 0 }, lastfr[32] = { 0 }, pkt[2048], fr[2048];
    unsigned seq = 1, nattn = 0, nframes = 0, nres = 0, nlow = 0, nsamp = 0, lines = 0, len, n;
    time_t end = time(NULL) + secs;
    uint16_t s;
    int attn, good;
    char lvl;

    time_t next = time(NULL) + 2;

    printf("== poll %d s before READY -- touch the glass now (L = ATTN pin level)\n", secs);
    while(time(NULL) < end) {
        if(time(NULL) >= next) {
            stamp("polling");
            next = time(NULL) + 2;
        }
        arm_attn();
        attn = wait_attn(50);
        nattn += attn;
        lvl = attn_level();
        nsamp++;
        nlow += lvl == '0';
        memset(q, 0, 16);
        q[0] = 0xeb; q[1] = seq;
        s = sum16(q, 14); q[14] = s; q[15] = s >> 8;
        if(xfer(q, r, 16))
            break;
        len = r[1] | r[2] << 8;
        good = (r[0] & 0xf0) == 0xe0 && (r[14] | r[15] << 8) == sum16(r, 14);
        if(good && len) {
            nres++;
            n = len + 5 > sizeof(pkt) ? sizeof(pkt) : len + 5;
            if(n < 16)
                n = 16;
            memset(pkt, 0, n);
            pkt[0] = 0xeb; pkt[1] = seq; pkt[2] = 1;
            s = sum16(pkt, 14); pkt[n - 2] = s; pkt[n - 1] = s >> 8;
            if(xfer(pkt, fr, n))
                break;
            if(fr[0] == 0xea || fr[0] == 0xeb) {
                nframes++;
                seq = seq == 1 ? 2 : 1;
            }
            if((attn || memcmp(fr, lastfr, n < 32 ? n : 32)) && lines++ < 60) {
                printf("  %s L%c len %-4u", attn ? "ATTN" : "    ", lvl, len);
                hex("", r, 16);
                printf("            data");
                hex("", fr, n);
                if(n > 16)
                    hex("        ...", fr + 16, n - 16);
            }
            memcpy(lastfr, fr, n < 32 ? n : 32);
        } else if(attn || memcmp(r, last, 16)) {
            if(lines++ < 60) {
                printf("  %s L%c %s", attn ? "ATTN" : "    ", lvl, good ? "no data " : "bad hdr ");
                hex("", r, 16);
            }
        }
        memcpy(last, r, 16);
    }
    printf("  %u ATTN, %u results read, %u of them frames (ea/eb), in %d s\n", nattn, nres, nframes, secs);
    printf("  ATTN pin low in %u of %u samples, now %c\n", nlow, nsamp, attn_level());
}


/* -X: after EXECUTE, try several first contacts and print every answer. */
static void explore(void)
{
    uint8_t c[16], r[16];
    uint16_t s;
    int i;

    printf("== explore after execute\n");
    for(i = 0; i < 3; i++) {
        memset(c, 0, 16);
        xfer(c, r, 16);
        hex("zeros ->", r, 16);
    }
    memset(c, 0, 16); c[0] = 0x1a; c[1] = 0xa1;
    xfer(c, r, 2);
    hex("1a a1 ->", r, 2);
    memset(c, 0, 16); c[0] = 0xee;
    z2_cmd(c, r);
    usleep(2000);
    memset(c, 0, 16); c[0] = 0xe2;
    z2_cmd(c, r);
    z2_cmd(c, r);
    usleep(200000);
    z2_cmd(c, r);
    z2_cmd(c, r);
    memset(c, 0, 16); c[0] = 0xeb; c[1] = 1;
    s = sum16(c, 14); c[14] = s; c[15] = s >> 8;
    xfer(c, r, 16);
    hex("eb 01 ->", r, 16);
}

static int send_cal(const uint8_t *cal, size_t callen)
{
    if(!cal)
        return 0;
    return download("calibration", 0x1000c000, cal, callen);
}

static int send_fw(const uint8_t *fw, size_t fwlen)
{
    uint16_t st;
    int attn;

    arm_attn();
    if(xfer(fw, NULL, fwlen))
        return -1;
    attn = wait_attn(200);
    if(atn_ack(&st))
        return -1;
    printf("  firmware: ack %04x%s%s\n", st, st == 0x4bc1 ? " (accepted)" : "   NOT 4bc1",
           attn ? "" : " (no ATTN)");
    return st == 0x4bc1 ? 0 : -1;
}

int main(int argc, char **argv)
{
    const char *mtprops = "/lib/firmware/J1.mtprops", *calpath = NULL;
    int do_explore = 0;
    int opt, fwfirst = 0, noscan = 0, poll = 0, noready = 0, hold = -1, ok;
    uint8_t *fw, *cal = NULL, c[16], res[16];
    size_t fwlen, callen = 0;
    uint32_t ver, fll = 0x189c;
    uint16_t st;
    struct hxt_metrics m = { 0, 0, 0, 0 };

    while((opt = getopt(argc, argv, "c:F:fBp:Nt:idX")) != -1) {
        switch(opt) {
        case 'c': calpath = optarg; break;
        case 'F': fll = strtoul(optarg, NULL, 0); break;
        case 'f': fwfirst = 1; break;
        case 'B': noscan = 1; break;
        case 'p': poll = atoi(optarg); break;
        case 'N': noready = 1; break;
        case 't': hold = atoi(optarg); break;
        case 'i': dl_invert = 1; break;
        case 'd': dl_skip = 1; break;
        case 'X': do_explore = 1; break;
        default:
            fprintf(stderr, "usage: %s [-c cal] [-F fll-mval] [-f] [-B] [-p secs] [-N] [-t secs] [-i] [-d] [mtprops]\n", argv[0]);
            return 2;
        }
    }
    if(optind < argc)
        mtprops = argv[optind];
    if(!calpath && access("/lib/firmware/j1-mtcal.bin", R_OK) == 0)
        calpath = "/lib/firmware/j1-mtcal.bin";
    setvbuf(stdout, NULL, _IOLBF, 0);
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    printf("== firmware\n");
    fw = load_firmware(mtprops, &fwlen);
    if(!fw)
        return 1;
    printf("  %zu bytes, starts", fwlen);
    hex("", fw, 16);
    if(calpath) {
        cal = load_file(calpath, &callen);
        if(!cal)
            return 1;
        printf("  calibration %s, %zu bytes, starts", calpath, callen);
        hex("", cal, callen);
    } else {
        printf("  no calibration -- iOS never runs the chip without it\n");
    }

    /* Opening powers the rails (LDO, then the PMU GPIO clock enable) and
     * the chip select; iOS waits 15 ms after the clock. */
    fd = open("/dev/hx-touch", O_RDWR);
    if(fd < 0) {
        perror("/dev/hx-touch");
        return 1;
    }
    stamp("opened");
    usleep(15000);

    /* resetDevice: reset asserted with enable_download following it; the
     * driver's RESET does assert, 2 ms, release. Then an idle transfer
     * ("ensuring S_CLK is high") and the reset that counts. */
    printf("== reset\n");
    dl(1);
    if(ioctl(fd, HXT_IOC_RESET) < 0)
        perror("RESET");
    memset(c, 0, 4);
    if(write(fd, c, 4) == 4 && read(fd, res, 4) == 4)
        hex("idle transfer ->", res, 4);
    usleep(1000);
    arm_attn();
    if(ioctl(fd, HXT_IOC_RESET) < 0)
        perror("RESET");
    dl(0);
    usleep(2000);
    printf("  boot ATTN: %s\n", wait_attn(500) ? "yes" : "NO (500 ms)");

    dl(1);
    ok = hbpp_check();
    dl(0);
    if(!ok)
        printf("  not in HBPP -- carrying on to see what the chip does\n");

    printf("== bootload (enable_download held)\n");
    dl(1);
    if(fwfirst) {
        if(send_fw(fw, fwlen) || send_cal(cal, callen))
            goto fail;
    } else {
        if(send_cal(cal, callen) || send_fw(fw, fwlen))
            goto fail;
    }
    printf("== performCalibSeq (MTSPIBootloader_Z2)\n");
    if(reg_read(0x10008ffc, &ver) == 0 && ver == 0x5a020028) {
        printf("  version 5a020028: iOS skips the writes and disables touch\n");
    } else {
        reg_write(0x10001c04, fll, 0x1fff);
        reg_write(0x10001c08, 0x840000, 0xff0000);
        reg_write(0x1000300c, 5, 0x85);
        reg_write(0x1000304c, 0x20, 0xffffffff);
    }
    c[0] = 0x1f; c[1] = 0x01;
    arm_attn();
    xfer(c, res, 2);
    hex("calib request ->", res, 2);
    usleep(65000);
    printf("  ATTN during calibration: %s\n", wait_attn(100) ? "yes" : "no");
    if(atn_ack(&st) == 0)
        printf("  calibration ack %04x\n", st);
    printf("== execute\n");
    arm_attn();
    execute(0x10001800);
    dl(0);
    usleep(40000);
    printf("  ATTN after execute: %s\n", wait_attn(200) ? "yes" : "no");
    stamp("executed");

    if(do_explore)
        explore();
    printf("== post-boot\n");
    usleep(2000);
    memset(c, 0, 16); c[0] = 0xe2;
    z2_cmd(c, res);
    z2_cmd(c, res);
    printf("  device info: family %02x, max packet %u\n", res[1], res[3] | res[4] << 8);
    ios_get(0xd1, 1, 0);
    ios_get(0xd3, 12, 1);
    ios_get(0xd0, 8, 0);
    ios_get(0xa1, 6, 0);
    ios_get(0xd9, 8, 0);                /* J1: short, 8 bytes (iOS's trace) */
    if(!noscan) {
        /* iOS 9.3.5 on this iPad (touch/ios-mtlog-j1.txt): SET bf, SET af,
         * GET 9d (status 2, so nothing is sent), then bf and af again. */
        static const uint8_t bf[4] = { 0x9f, 0x0b, 0x0b, 0x02 }, af[1] = { 0 };
        printf("  bf = 9f 0b 0b 02, af = 00, twice (iOS's scan start)\n");
        set_report(0xbf, bf, 4);
        set_report(0xaf, af, 1);
        set_report(0xbf, bf, 4);
        set_report(0xaf, af, 1);
    }
    if(poll > 0)
        poll_frames(poll);
    if(noready) {
        close(fd);
        return 0;
    }
    /* J1's d9 is a short read, e6 d9 00 then two LE u32: 99 39 00 00 cc 4c
     * 00 00 = 14745 x 19660, the panel in 0.01 mm (147.5 x 196.6). Touch
     * coordinates come in that range (bring-up trace: x 1878..5034,
     * y 10523..14420 for one drag). Unchecked against the corners. */
    if(d9[0] == 0xe6 && d9[1] == 0xd9 && d9[2] == 0) {
        m.left = 0;
        m.top = 0;
        m.right = (int)(d9[3] | d9[4] << 8 | d9[5] << 16 | (uint32_t)d9[6] << 24);
        m.bottom = (int)(d9[7] | d9[8] << 8 | d9[9] << 16 | (uint32_t)d9[10] << 24);
    }
    printf("  metrics x %d..%d y %d..%d\n", m.left, m.right, m.top, m.bottom);
    if(ioctl(fd, HXT_IOC_METRICS, &m) < 0)
        perror("METRICS");
    printf("== READY -- touch the glass; reports go to the kernel\n");
    if(ioctl(fd, HXT_IOC_READY) < 0)
        perror("READY");
    if(hold < 0)
        for(;;)
            sleep(60);
    sleep(hold);
    return 0;
fail:
    dl(0);
    printf("== bootload failed\n");
    return 1;
}
