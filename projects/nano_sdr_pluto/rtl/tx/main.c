#include <errno.h>
#include <fcntl.h>
#include <iio.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define DMAC_BASE 0x7c420000UL
#define DMAC_MAP_SIZE 0x1000UL

#define DMAC_REG_INTERFACE_DESC     0x10
#define DMAC_REG_IRQ_PENDING        0x84
#define DMAC_REG_CTRL               0x400
#define DMAC_REG_TRANSFER_ID        0x404
#define DMAC_REG_START_TRANSFER     0x408
#define DMAC_REG_FLAGS              0x40c
#define DMAC_REG_DEST_ADDRESS       0x410
#define DMAC_REG_SRC_ADDRESS        0x414
#define DMAC_REG_X_LENGTH           0x418
#define DMAC_REG_Y_LENGTH           0x41c
#define DMAC_REG_TRANSFER_DONE      0x428
#define DMAC_REG_ACTIVE_TRANSFER_ID 0x42c
#define DMAC_REG_STATUS             0x430
#define DMAC_REG_CURRENT_SRC_ADDR   0x434
#define DMAC_REG_CURRENT_DEST_ADDR  0x438

#define DMAC_CTRL_ENABLE            (1U << 0)
#define DMAC_FLAG_LAST              (1U << 1)
#define DMAC_IRQ_SOT                (1U << 0)
#define DMAC_IRQ_EOT                (1U << 1)

#define HW69_DBG_AXIS_BASE    0x79030000UL
#define HW69_DBG_CURRENT_BASE 0x79040000UL
#define HW69_DBG_STATE_BASE   0x79050000UL
#define HW69_DBG_COUNTS0_BASE 0x79060000UL
#define HW69_DBG_COUNTS1_BASE 0x79070000UL
#define HW69_DBG_TX_BASE      0x79080000UL

#define MAP_SIZE              0x1000UL
#define RFM69_PREAMBLE_LEN    4U
#define RFM69_SYNC_LEN        2U

#define AXI_DMAC_BUS_TYPE_AXI_MM     0U
#define AXI_DMAC_BUS_TYPE_AXI_STREAM 1U

struct mapped_block {
    const char *name;
    off_t phys;
    volatile uint8_t *ptr;
};

struct dma_caps {
    unsigned int src_type;
    unsigned int dest_type;
    unsigned int src_width;
    unsigned int dest_width;
    unsigned int address_align_mask;
    unsigned int length_align_mask;
    unsigned int max_length;
};

struct radio_config {
    const char *tx_gain_db;
    long long tx_lo_hz;
    long long tx_bw_hz;
    long long tx_fs_hz;
};

struct hold_config {
    int hold_ms;
    int snapshot_interval_ms;
};

static const uint8_t rfm69_sync[RFM69_SYNC_LEN] = { 0x2d, 0xd4 };

static struct mapped_block debug_blocks[] = {
    { "hw69_dbg_axis", HW69_DBG_AXIS_BASE, NULL },
    { "hw69_dbg_current", HW69_DBG_CURRENT_BASE, NULL },
    { "hw69_dbg_state", HW69_DBG_STATE_BASE, NULL },
    { "hw69_dbg_counts0", HW69_DBG_COUNTS0_BASE, NULL },
    { "hw69_dbg_counts1", HW69_DBG_COUNTS1_BASE, NULL },
    { "hw69_dbg_tx", HW69_DBG_TX_BASE, NULL },
};

static void die(const char *msg)
{
    perror(msg);
    exit(1);
}

static uint32_t mmio_read32(volatile uint8_t *base, off_t off)
{
    return *(volatile uint32_t *)(base + off);
}

static void mmio_write32(volatile uint8_t *base, off_t off, uint32_t value)
{
    *(volatile uint32_t *)(base + off) = value;
}

static size_t align_up(size_t value, size_t alignment)
{
    if (alignment <= 1)
        return value;

    return (value + alignment - 1) & ~(alignment - 1);
}

static void hexdump_bytes(const char *label, const uint8_t *data, size_t len)
{
    size_t shown = len < 64 ? len : 64;

    printf("%s (%zu bytes, first %zu shown):\n", label, len, shown);
    for (size_t index = 0; index < shown; index++) {
        if ((index % 16) == 0)
            printf("  %04zx:", index);
        printf(" %02x", data[index]);
        if ((index % 16) == 15 || index + 1 == shown)
            printf("\n");
    }
}

static volatile uint8_t *map_block_or_null(int memfd, off_t phys)
{
    void *mapped = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, phys);

    if (mapped == MAP_FAILED)
        return NULL;

    return mapped;
}

static void dump_block32(const struct mapped_block *block)
{
    if (!block->ptr) {
        printf("%-16s @ 0x%08lx : unavailable\n", block->name, (unsigned long)block->phys);
        return;
    }

    printf("%-16s @ 0x%08lx : [0x00]=0x%08" PRIx32 " [0x04]=0x%08" PRIx32
           " [0x08]=0x%08" PRIx32 " [0x0c]=0x%08" PRIx32 "\n",
           block->name,
           (unsigned long)block->phys,
           mmio_read32(block->ptr, 0x00),
           mmio_read32(block->ptr, 0x04),
           mmio_read32(block->ptr, 0x08),
           mmio_read32(block->ptr, 0x0c));
}

static void dump_all_regs(const struct mapped_block *dmac)
{
    puts("Register snapshot:");
    dump_block32(dmac);
    for (size_t index = 0; index < sizeof(debug_blocks) / sizeof(debug_blocks[0]); index++)
        dump_block32(&debug_blocks[index]);
}

static void dump_dma_runtime(volatile uint8_t *dmac)
{
    printf("DMA runtime: status=0x%08" PRIx32 " queued_id=%" PRIu32
           " active_id=%" PRIu32 " done=0x%08" PRIx32 " current_src=0x%08" PRIx32
           " current_dst=0x%08" PRIx32 "\n",
           mmio_read32(dmac, DMAC_REG_STATUS),
           mmio_read32(dmac, DMAC_REG_TRANSFER_ID),
           mmio_read32(dmac, DMAC_REG_ACTIVE_TRANSFER_ID),
           mmio_read32(dmac, DMAC_REG_TRANSFER_DONE),
           mmio_read32(dmac, DMAC_REG_CURRENT_SRC_ADDR),
           mmio_read32(dmac, DMAC_REG_CURRENT_DEST_ADDR));
}

static size_t bytes_to_axis_words(size_t byte_len, unsigned int stream_width_bytes)
{
    if (stream_width_bytes == 0)
        return 0;

    return (byte_len + stream_width_bytes - 1U) / stream_width_bytes;
}

static void hold_tx_window(const struct mapped_block *dmac,
                           const struct hold_config *hold)
{
    if (hold->hold_ms <= 0)
        return;

    printf("Holding process alive for %d ms so TX stays active for external register polling\n",
           hold->hold_ms);

    if (hold->snapshot_interval_ms > 0) {
        int snapshots = hold->hold_ms / hold->snapshot_interval_ms;

        for (int index = 0; index < snapshots; index++) {
            usleep((useconds_t)hold->snapshot_interval_ms * 1000U);
            printf("Hold snapshot %d/%d:\n", index + 1, snapshots);
            dump_dma_runtime(dmac->ptr);
            dump_block32(&debug_blocks[3]);
            dump_block32(&debug_blocks[1]);
            dump_block32(&debug_blocks[5]);
        }

        int remainder_ms = hold->hold_ms - snapshots * hold->snapshot_interval_ms;
        if (remainder_ms > 0)
            usleep((useconds_t)remainder_ms * 1000U);
    } else {
        usleep((useconds_t)hold->hold_ms * 1000U);
    }
}

static uint8_t *read_file(const char *path, size_t *size_out)
{
    struct stat st;
    if (stat(path, &st) < 0)
        die("stat");

    FILE *fp = fopen(path, "rb");
    if (!fp)
        die("fopen");

    uint8_t *buf = malloc(st.st_size);
    if (!buf)
        die("malloc");

    if (fread(buf, 1, st.st_size, fp) != (size_t)st.st_size) {
        fclose(fp);
        free(buf);
        die("fread");
    }

    fclose(fp);
    *size_out = st.st_size;
    return buf;
}

static uint8_t *dup_cstr_bytes(const char *text, size_t *size_out)
{
    size_t len = strlen(text);
    uint8_t *buf = malloc(len);

    if (!buf)
        die("malloc message");

    memcpy(buf, text, len);
    *size_out = len;
    return buf;
}

static uint8_t *build_rfm69_style_packet(const uint8_t *payload,
                                         size_t payload_len,
                                         size_t *frame_len_out)
{
    if (payload_len > 255) {
        fprintf(stderr, "payload too large for 1-byte length field: %zu\n", payload_len);
        exit(1);
    }

    size_t frame_len = RFM69_PREAMBLE_LEN + RFM69_SYNC_LEN + 1 + payload_len;
    uint8_t *frame = calloc(1, frame_len);
    if (!frame)
        die("calloc frame");

    memset(frame, 0xaa, RFM69_PREAMBLE_LEN);
    memcpy(frame + RFM69_PREAMBLE_LEN, rfm69_sync, RFM69_SYNC_LEN);
    frame[RFM69_PREAMBLE_LEN + RFM69_SYNC_LEN] = (uint8_t)payload_len;
    memcpy(frame + RFM69_PREAMBLE_LEN + RFM69_SYNC_LEN + 1, payload, payload_len);

    *frame_len_out = frame_len;
    return frame;
}

static int parse_long_long(const char *text, long long *out)
{
    char *end = NULL;
    errno = 0;
    long long value = strtoll(text, &end, 0);

    if (errno || !end || *end != '\0')
        return -1;

    *out = value;
    return 0;
}

static int iio_write_attr_ll(struct iio_channel *channel, const char *attr, long long value)
{
    char text[32];
    snprintf(text, sizeof(text), "%lld", value);
    return iio_channel_attr_write(channel, attr, text);
}

static int configure_ad9361_phy(struct iio_context *ctx, const struct radio_config *cfg)
{
    struct iio_device *phy = iio_context_find_device(ctx, "ad9361-phy");
    if (!phy) {
        fprintf(stderr, "IIO device not found: ad9361-phy\n");
        return -1;
    }

    struct iio_channel *tx0 = iio_device_find_channel(phy, "voltage0", true);
    struct iio_channel *tx1 = iio_device_find_channel(phy, "voltage1", true);
    struct iio_channel *tx_lo = iio_device_find_channel(phy, "altvoltage1", true);
    if (!tx0)
        fprintf(stderr, "warning: TX channel voltage0 not found on ad9361-phy\n");
    if (!tx_lo)
        fprintf(stderr, "warning: TX LO channel altvoltage1 not found on ad9361-phy\n");

    if (cfg->tx_fs_hz > 0 && tx0) {
        if (iio_write_attr_ll(tx0, "sampling_frequency", cfg->tx_fs_hz) < 0)
            fprintf(stderr, "warning: failed to set TX sampling_frequency\n");
        else
            printf("ad9361-phy: sampling_frequency=%lld\n", cfg->tx_fs_hz);
    }

    if (cfg->tx_bw_hz > 0 && tx0) {
        if (iio_write_attr_ll(tx0, "rf_bandwidth", cfg->tx_bw_hz) < 0)
            fprintf(stderr, "warning: failed to set TX rf_bandwidth\n");
        else
            printf("ad9361-phy: rf_bandwidth=%lld\n", cfg->tx_bw_hz);
    }

    if (cfg->tx_lo_hz > 0 && tx_lo) {
        if (iio_write_attr_ll(tx_lo, "frequency", cfg->tx_lo_hz) < 0)
            fprintf(stderr, "warning: failed to set TX LO frequency\n");
        else
            printf("ad9361-phy: tx_lo=%lld\n", cfg->tx_lo_hz);
    }

    if (cfg->tx_gain_db) {
        if (tx0 && iio_channel_attr_write(tx0, "hardwaregain", cfg->tx_gain_db) >= 0)
            printf("ad9361-phy: tx0 hardwaregain=%s\n", cfg->tx_gain_db);
        else if (tx0)
            fprintf(stderr, "warning: failed to set TX0 hardwaregain\n");

        if (tx1 && iio_channel_attr_write(tx1, "hardwaregain", cfg->tx_gain_db) >= 0)
            printf("ad9361-phy: tx1 hardwaregain=%s\n", cfg->tx_gain_db);
        else if (tx1)
            fprintf(stderr, "warning: failed to set TX1 hardwaregain\n");
    }

    return 0;
}

static int read_pagemap_entry(int fd, uintptr_t virt, uint64_t *entry_out)
{
    long page_size = sysconf(_SC_PAGESIZE);
    off_t offset = (off_t)((virt / (uintptr_t)page_size) * sizeof(uint64_t));
    uint64_t entry = 0;

    if (pread(fd, &entry, sizeof(entry), offset) != (ssize_t)sizeof(entry))
        return -1;

    *entry_out = entry;
    return 0;
}

static uint64_t virt_to_phys_or_die(void *addr)
{
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0)
        die("open /proc/self/pagemap");

    long page_size = sysconf(_SC_PAGESIZE);
    uintptr_t virt = (uintptr_t)addr;
    uint64_t entry = 0;

    if (read_pagemap_entry(fd, virt, &entry) < 0) {
        close(fd);
        die("pread /proc/self/pagemap");
    }

    close(fd);

    if (!(entry & (1ULL << 63))) {
        fprintf(stderr, "virtual address 0x%08" PRIxPTR " is not present\n", virt);
        exit(1);
    }

    uint64_t pfn = entry & ((1ULL << 55) - 1);
    if (!pfn) {
        fprintf(stderr, "pagemap returned PFN 0 for address 0x%08" PRIxPTR "\n", virt);
        fprintf(stderr, "run as root and ensure the kernel exposes PFNs in /proc/self/pagemap\n");
        exit(1);
    }

    return (pfn * (uint64_t)page_size) + (virt & (uintptr_t)(page_size - 1));
}

static void read_dma_caps(volatile uint8_t *dmac, struct dma_caps *caps)
{
    uint32_t desc = mmio_read32(dmac, DMAC_REG_INTERFACE_DESC);
    if (!desc) {
        fprintf(stderr, "DMAC interface descriptor reads zero\n");
        exit(1);
    }

    caps->src_type = (desc >> 12) & 0x3;
    caps->dest_type = (desc >> 4) & 0x3;
    caps->src_width = 1U << ((desc >> 8) & 0xf);
    caps->dest_width = 1U << (desc & 0xf);
    caps->address_align_mask = (caps->src_width > caps->dest_width ? caps->src_width : caps->dest_width) - 1U;

    uint32_t saved_x = mmio_read32(dmac, DMAC_REG_X_LENGTH);
    mmio_write32(dmac, DMAC_REG_X_LENGTH, 0xffffffffU);
    caps->max_length = mmio_read32(dmac, DMAC_REG_X_LENGTH);
    if (caps->max_length != UINT32_MAX)
        caps->max_length++;

    mmio_write32(dmac, DMAC_REG_X_LENGTH, 0x0U);
    caps->length_align_mask = mmio_read32(dmac, DMAC_REG_X_LENGTH);
    mmio_write32(dmac, DMAC_REG_X_LENGTH, saved_x);

    if (caps->length_align_mask == 0)
        caps->length_align_mask = caps->address_align_mask;

    printf("DMAC caps: src_type=%u dst_type=%u src_width=%u dst_width=%u align=%u len_align=%u max_length=%u\n",
           caps->src_type,
           caps->dest_type,
           caps->src_width,
           caps->dest_width,
           caps->address_align_mask + 1U,
           caps->length_align_mask + 1U,
           caps->max_length);
}

static void submit_dma_transfer(volatile uint8_t *dmac,
                                const struct mapped_block *dmac_block,
                                const struct dma_caps *caps,
                                uint64_t phys_addr,
                                size_t len)
{
    if (caps->src_type != AXI_DMAC_BUS_TYPE_AXI_MM) {
        fprintf(stderr, "DMAC source is not AXI-MM; raw userspace buffer submit is unsupported\n");
        exit(1);
    }

    if (caps->dest_type == AXI_DMAC_BUS_TYPE_AXI_MM) {
        fprintf(stderr, "DMAC destination is AXI-MM; this helper expects a stream TX path\n");
        exit(1);
    }

    if ((phys_addr & caps->address_align_mask) != 0) {
        fprintf(stderr, "DMA source address 0x%08" PRIx64 " is not %u-byte aligned\n",
                phys_addr,
                caps->address_align_mask + 1U);
        exit(1);
    }

    if ((len & caps->length_align_mask) != 0) {
        fprintf(stderr, "DMA length %zu is not %u-byte aligned\n",
                len,
                caps->length_align_mask + 1U);
        exit(1);
    }

    if (caps->max_length && len > caps->max_length) {
        fprintf(stderr, "DMA length %zu exceeds max single transfer %u\n", len, caps->max_length);
        exit(1);
    }

    uint32_t transfer_id = mmio_read32(dmac, DMAC_REG_TRANSFER_ID) & 0x1fU;
    uint32_t done_before = mmio_read32(dmac, DMAC_REG_TRANSFER_DONE);

    mmio_write32(dmac, DMAC_REG_IRQ_PENDING, DMAC_IRQ_SOT | DMAC_IRQ_EOT);
    mmio_write32(dmac, DMAC_REG_CTRL, DMAC_CTRL_ENABLE);
    mmio_write32(dmac, DMAC_REG_SRC_ADDRESS, (uint32_t)phys_addr);
    if (caps->dest_type == AXI_DMAC_BUS_TYPE_AXI_MM)
        mmio_write32(dmac, DMAC_REG_DEST_ADDRESS, 0);
    mmio_write32(dmac, DMAC_REG_Y_LENGTH, 0);
    mmio_write32(dmac, DMAC_REG_X_LENGTH, (uint32_t)len - 1U);
    mmio_write32(dmac, DMAC_REG_FLAGS, DMAC_FLAG_LAST);
    mmio_write32(dmac, DMAC_REG_START_TRANSFER, 1U);

    printf("DMA submit: transfer_id=%u src=0x%08" PRIx64
           " len=%zu done_before=0x%08" PRIx32 "\n",
           transfer_id,
           phys_addr,
           len,
           done_before);

    for (int tries = 0; tries < 2000; tries++) {
        uint32_t irq_pending = mmio_read32(dmac, DMAC_REG_IRQ_PENDING);
        uint32_t done = mmio_read32(dmac, DMAC_REG_TRANSFER_DONE);

        if (irq_pending & DMAC_IRQ_EOT) {
            printf("DMA completed: irq_pending=0x%08" PRIx32
                   " transfer_done=0x%08" PRIx32 "\n",
                   irq_pending,
                   done);
            return;
        }
        usleep(1000);
    }

    fprintf(stderr, "DMA transfer timeout waiting for fresh EOT\n");
    dump_dma_runtime(dmac);
    dump_all_regs(dmac_block);
    exit(1);
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s [-f payload.bin | -m message] [--rfm69] [-r repeat_count]\n"
            "          [--hold-ms ms] [--snapshot-interval-ms ms]\n"
            "          [--tx-lo-hz hz] [--tx-bw-hz hz] [--tx-fs-hz hz] [--tx-gain-db value]\n"
            "  -f payload.bin     read raw bytes from file\n"
            "  -m message         use ASCII message as raw payload\n"
            "  --rfm69            wrap the payload as AA x4 | 2D D4 | len | payload\n"
            "  -r count           repeat the same wire payload count times (default 1)\n"
            "  --hold-ms ms       keep the process alive after DMA submit for manual register polling\n"
            "  --snapshot-interval-ms ms  during hold, print counts/current/tx snapshots every ms\n"
            "  --tx-lo-hz hz      set ad9361 TX LO frequency\n"
            "  --tx-bw-hz hz      set ad9361 TX RF bandwidth\n"
            "  --tx-fs-hz hz      set ad9361 TX sampling frequency\n"
            "  --tx-gain-db val   set ad9361 TX hardwaregain string, e.g. -10\n",
            prog);
}

int main(int argc, char **argv)
{
    const char *payload_file = NULL;
    const char *message = NULL;
    int repeat_count = 1;
    bool wrap_rfm69 = false;
    struct radio_config radio = { 0 };
    struct hold_config hold = { 0 };

    for (int argi = 1; argi < argc; argi++) {
        if (!strcmp(argv[argi], "-f") && argi + 1 < argc) {
            payload_file = argv[++argi];
        } else if (!strcmp(argv[argi], "-m") && argi + 1 < argc) {
            message = argv[++argi];
        } else if (!strcmp(argv[argi], "-r") && argi + 1 < argc) {
            repeat_count = atoi(argv[++argi]);
        } else if (!strcmp(argv[argi], "--rfm69")) {
            wrap_rfm69 = true;
        } else if (!strcmp(argv[argi], "--hold-ms") && argi + 1 < argc) {
            hold.hold_ms = atoi(argv[++argi]);
        } else if (!strcmp(argv[argi], "--snapshot-interval-ms") && argi + 1 < argc) {
            hold.snapshot_interval_ms = atoi(argv[++argi]);
        } else if (!strcmp(argv[argi], "--tx-lo-hz") && argi + 1 < argc) {
            if (parse_long_long(argv[++argi], &radio.tx_lo_hz) < 0) {
                fprintf(stderr, "bad --tx-lo-hz value\n");
                return 1;
            }
        } else if (!strcmp(argv[argi], "--tx-bw-hz") && argi + 1 < argc) {
            if (parse_long_long(argv[++argi], &radio.tx_bw_hz) < 0) {
                fprintf(stderr, "bad --tx-bw-hz value\n");
                return 1;
            }
        } else if (!strcmp(argv[argi], "--tx-fs-hz") && argi + 1 < argc) {
            if (parse_long_long(argv[++argi], &radio.tx_fs_hz) < 0) {
                fprintf(stderr, "bad --tx-fs-hz value\n");
                return 1;
            }
        } else if (!strcmp(argv[argi], "--tx-gain-db") && argi + 1 < argc) {
            radio.tx_gain_db = argv[++argi];
        } else {
            print_usage(argv[0]);
            return 1;
        }
    }

    if (!!payload_file == !!message) {
        print_usage(argv[0]);
        return 1;
    }

    if (repeat_count < 1) {
        fprintf(stderr, "repeat count must be >= 1\n");
        return 1;
    }

    if (hold.hold_ms < 0 || hold.snapshot_interval_ms < 0) {
        fprintf(stderr, "hold values must be >= 0\n");
        return 1;
    }

    if (hold.snapshot_interval_ms > 0 && hold.hold_ms == 0) {
        fprintf(stderr, "--snapshot-interval-ms requires --hold-ms > 0\n");
        return 1;
    }

    size_t payload_len = 0;
    uint8_t *payload = payload_file ? read_file(payload_file, &payload_len)
                                    : dup_cstr_bytes(message, &payload_len);

    size_t wire_len = 0;
    uint8_t *wire = NULL;

    if (wrap_rfm69) {
        wire = build_rfm69_style_packet(payload, payload_len, &wire_len);
        hexdump_bytes("payload", payload, payload_len);
        hexdump_bytes("rfm69-style frame", wire, wire_len);
    } else {
        wire = payload;
        wire_len = payload_len;
        hexdump_bytes("raw payload", wire, wire_len);
    }

    int memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (memfd < 0)
        die("open /dev/mem");

    struct mapped_block dmac = {
        .name = "tx_dma",
        .phys = DMAC_BASE,
        .ptr = map_block_or_null(memfd, DMAC_BASE),
    };
    if (!dmac.ptr)
        die("mmap dmac");

    for (size_t index = 0; index < sizeof(debug_blocks) / sizeof(debug_blocks[0]); index++)
        debug_blocks[index].ptr = map_block_or_null(memfd, debug_blocks[index].phys);

    struct dma_caps caps = { 0 };
    read_dma_caps(dmac.ptr, &caps);

    size_t total_wire_len = wire_len * (size_t)repeat_count;
    size_t dma_len = align_up(total_wire_len, (size_t)caps.length_align_mask + 1U);
    size_t map_len = align_up(dma_len, (size_t)sysconf(_SC_PAGESIZE));

    void *dma_buf = mmap(NULL, map_len, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (dma_buf == MAP_FAILED)
        die("mmap dma buffer");

    memset(dma_buf, 0, map_len);
    for (int repeat = 0; repeat < repeat_count; repeat++)
        memcpy((uint8_t *)dma_buf + (size_t)repeat * wire_len, wire, wire_len);

    if (mlock(dma_buf, map_len) < 0)
        perror("warning: mlock");

    uint64_t phys_addr = virt_to_phys_or_die(dma_buf);

    printf("TX buffer: wire_len=%zu repeats=%d total=%zu dma_len=%zu phys=0x%08" PRIx64 "\n",
           wire_len,
           repeat_count,
           total_wire_len,
           dma_len,
           phys_addr);
        printf("Expected AXIS words: total=%zu dma=%zu (stream_width=%u bytes)\n",
            bytes_to_axis_words(total_wire_len, caps.dest_width),
            bytes_to_axis_words(dma_len, caps.dest_width),
            caps.dest_width);

    puts("Before TX:");
    dump_all_regs(&dmac);
    dump_dma_runtime(dmac.ptr);

    struct iio_context *ctx = iio_create_context_from_uri("local:");
    if (!ctx) {
        fprintf(stderr, "failed to create IIO local context\n");
        return 2;
    }

    if (configure_ad9361_phy(ctx, &radio) < 0)
        return 3;

    submit_dma_transfer(dmac.ptr, &dmac, &caps, phys_addr, dma_len);
    hold_tx_window(&dmac, &hold);
    usleep(100000);

    puts("After TX:");
    dump_all_regs(&dmac);
    dump_dma_runtime(dmac.ptr);

    iio_context_destroy(ctx);
    munmap(dma_buf, map_len);
    munmap((void *)dmac.ptr, DMAC_MAP_SIZE);
    for (size_t index = 0; index < sizeof(debug_blocks) / sizeof(debug_blocks[0]); index++) {
        if (debug_blocks[index].ptr)
            munmap((void *)debug_blocks[index].ptr, MAP_SIZE);
    }
    close(memfd);
    if (wire != payload)
        free(wire);
    free(payload);
    return 0;
}