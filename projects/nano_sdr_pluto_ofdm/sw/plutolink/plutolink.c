/*
 * plutolink -- traffic generator / logger for the OFDM PHY running in the Pluto's PL (two roles, run by hand on two boards).
 *
 *   plutolink tx   [options]   board with the TX-only bitstream: builds test packets (PRBS + CRC) and streams them to the PHY
 *   plutolink rx   [options]   board with the RX-only bitstream: reads decoded packet records, checks them, logs SNR/BER/CFO/...
 *   plutolink diag [options]   register / RF / IIO sanity check of whatever bitstream is loaded (no traffic)
 *   plutolink selftest         host-only check of the packet builder / parser / statistics (no hardware)
 *
 * Both PHY builds expose the same AXI-Lite register block (rtl/common/phy_regs_axil.v) at 0x7C440000; the packet stream goes
 * through the axi_dmac IIO buffer (RX: cf-ad9361-lpc, TX: cf-ad9361-dds-core-lpc). The AD9361 is configured through the
 * ad9361-phy sysfs attributes. Everything uses plain sysfs / /dev/iio / /dev/mem -- no libiio needed.
 *
 * Application payload (inside the PHY packet of nsyms*550 bytes, little endian):
 *   [0]  u32 magic 'PLNK'     [4] u32 seq        [8] u16 nsyms  [10] u16 nbytes   [12] u16 step_id  [14] i16 tx_gain_x100
 *   [16] u32 tx_ms (uptime)   [20] u32 freq_khz  [24] u32 prbs_seed                [28] u32 crc32(bytes 0..27)
 *   [32 .. nbytes-5] PRBS bytes (xorshift32 seeded by prbs_seed)                    [nbytes-4] u32 crc32(bytes 0..nbytes-5)
 * The receiver regenerates the PRBS from the header, so the bit error count does not depend on the CRC.
 *
 * Build: see Makefile (static ARM binary for the Pluto: make arm; host build for selftest: make host).
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define VERSION "0.1.0"

/* ---- PHY / register constants (must match the RTL) ----------------------------------------------------------------- */
#define PHY_BASE       0x7C440000u
#define PHY_SPAN       0x1000u
#define BYTES_UNCODED  550
#define BYTES_CODED    450      /* MAX RATE: 16-QAM, LDPC R=5/6: 2 codewords x 225 bytes per OFDM symbol */
#define BYTES_RANGE    135      /* MAX RANGE: QPSK, LDPC R=1/2: 1 codeword x 135 bytes per OFDM symbol */
#define PHY_FS_HZ      30720000.0
#define REG_ID         0x00
#define REG_CTRL       0x04
#define REG_SNAP       0x08
#define REG_CFG0       0x10
#define REG_STAT0      0x80
#define NST            32
#define ID_RX          0x4F465258u
#define ID_TX          0x4F465458u
#define PILOTS_PER_SYM 100
#define CONST_RMS      12952.0    /* rms of the 16-QAM constellation in the PHY (unit 4096: 4096*sqrt(10)) */
#define ADC_FS         2048.0     /* 12-bit full scale */
#define RSSI_QSH       8
#define RSSI_L         1024

#define APP_MAGIC      0x4B4E4C50u    /* 'PLNK' */
#define APP_HDR        32
#define APP_MAX        (8 * BYTES_UNCODED)
#define SYM_LEN        2192
#define REG_FEATURE_W  31     /* status word 31: bit0 = coded PHY */

static int g_coded;           /* set from the PHY feature word (or --coded / --uncoded) */
static int g_mode = 1;        /* dual-mode PHY: 0 = MAX RANGE (QPSK + LDPC 1/2), 1 = MAX RATE (16-QAM + LDPC 5/6) */
static inline int bytes_per_sym(void) { return g_coded ? (g_mode ? BYTES_CODED : BYTES_RANGE) : BYTES_UNCODED; }

static volatile sig_atomic_t g_stop;
static void on_sig(int s) { (void)s; g_stop = 1; }

/* ======================================================================================================================
 * small utilities
 * ==================================================================================================================== */
static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint32_t crc_tab[256];
static void crc_init(void)
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		crc_tab[i] = c;
	}
}
static uint32_t crc32_buf(const uint8_t *p, size_t n)
{
	uint32_t c = 0xFFFFFFFFu;
	while (n--)
		c = crc_tab[(c ^ *p++) & 0xFF] ^ (c >> 8);
	return ~c;
}

static inline uint32_t rd32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static inline uint16_t rd16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static inline void wr32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static inline void wr16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }

static uint32_t prbs_seed_for(uint32_t run_seed, uint32_t seq)
{
	uint32_t x = run_seed ^ (seq * 2654435761u);
	x ^= x >> 15; x *= 2246822519u; x ^= x >> 13;
	return x ? x : 1u;
}
static void prbs_fill(uint8_t *p, size_t n, uint32_t seed)
{
	uint32_t x = seed ? seed : 1u;
	for (size_t i = 0; i < n; i++) {
		x ^= x << 13; x ^= x >> 17; x ^= x << 5;
		p[i] = (uint8_t)(x >> 11);
	}
}

/* ======================================================================================================================
 * application packet: build / check
 * ==================================================================================================================== */
struct app_info {
	uint32_t seq, tx_ms, freq_khz, seed;
	uint16_t nsyms, nbytes, step_id;
	int16_t gain_x100;
};

static void app_build(uint8_t *buf, int nsyms, uint32_t seq, uint32_t run_seed, uint16_t step_id, int gain_x100,
		      uint32_t freq_khz, uint32_t tx_ms)
{
	size_t n = (size_t)nsyms * bytes_per_sym();
	uint32_t seed = prbs_seed_for(run_seed, seq);
	wr32(buf + 0, APP_MAGIC);
	wr32(buf + 4, seq);
	wr16(buf + 8, nsyms);
	wr16(buf + 10, (uint16_t)n);
	wr16(buf + 12, step_id);
	wr16(buf + 14, (uint16_t)(int16_t)gain_x100);
	wr32(buf + 16, tx_ms);
	wr32(buf + 20, freq_khz);
	wr32(buf + 24, seed);
	wr32(buf + 28, crc32_buf(buf, 28));
	prbs_fill(buf + APP_HDR, n - APP_HDR - 4, seed);
	wr32(buf + n - 4, crc32_buf(buf, n - 4));
}

struct app_result {
	int hdr_ok, crc_ok;
	struct app_info info;
	uint64_t bits, bit_errors, byte_errors;   /* over the PRBS region */
	uint32_t seed_used;
};

/* Check a received payload; `guess_seq` is used for the PRBS when the header CRC fails. */
static void app_check(const uint8_t *buf, size_t n, uint32_t run_seed, uint32_t guess_seq, struct app_result *r)
{
	memset(r, 0, sizeof(*r));
	r->hdr_ok = (n >= APP_HDR + 4) && rd32(buf) == APP_MAGIC && rd32(buf + 28) == crc32_buf(buf, 28);
	uint32_t seq = guess_seq;
	if (r->hdr_ok) {
		r->info.seq = rd32(buf + 4);
		r->info.nsyms = rd16(buf + 8);
		r->info.nbytes = rd16(buf + 10);
		r->info.step_id = rd16(buf + 12);
		r->info.gain_x100 = (int16_t)rd16(buf + 14);
		r->info.tx_ms = rd32(buf + 16);
		r->info.freq_khz = rd32(buf + 20);
		r->info.seed = rd32(buf + 24);
		seq = r->info.seq;
	}
	r->seed_used = r->hdr_ok ? r->info.seed : prbs_seed_for(run_seed, seq);
	if (n >= APP_HDR + 4) {
		r->crc_ok = rd32(buf + n - 4) == crc32_buf(buf, n - 4);
		size_t m = n - APP_HDR - 4;
		uint8_t exp[APP_MAX];
		prbs_fill(exp, m, r->seed_used);
		for (size_t i = 0; i < m; i++) {
			uint8_t d = exp[i] ^ buf[APP_HDR + i];
			if (d) {
				r->byte_errors++;
				r->bit_errors += __builtin_popcount(d);
			}
		}
		r->bits = (uint64_t)m * 8;
	}
}

/* ======================================================================================================================
 * PHY packet record (RX): beat0 {A55A,ver,flags,nbytes,seq} beat1 {cfo_inc,n_best} beat2 {angle16,rssi16,evm32} payload
 * ==================================================================================================================== */
struct phy_rec {
	uint8_t flags, version, nh;            /* nh = number of header beats (3 for v2, 6 for v3) */
	uint16_t nbytes, seq;
	uint32_t n_best;
	int32_t cfo_inc;
	uint32_t evm_sum;
	uint16_t rssi_code;
	int16_t angle16;
	/* v3 (coded PHY): channel quality, LDPC statistics, fine timing, SFO slope */
	int16_t snr_avg_code, snr_min_code, noise_code;
	uint16_t bad_sc;
	uint8_t ldpc_fail, ldpc_iter_max, mode_bits, hdr_bits;     /* hdr_bits = {header nsyms mismatch, header CRC ok, MODE_ID, dual-mode} */
	uint16_t ldpc_iter_sum;
	int32_t tau_q8;
	uint32_t angle_first;
	int32_t slope;
	const uint8_t *payload;
};

/* Try to find a record at acc[0..len); returns bytes consumed (>0) when a record was extracted into *r, 0 when more data is
 * needed, and sets *skipped to the number of garbage bytes dropped in front of it. */
static size_t phy_parse(const uint8_t *acc, size_t len, unsigned expect_nbytes, struct phy_rec *r, size_t *skipped)
{
	size_t o = 0;
	*skipped = 0;
	while (o + 24 <= len) {
		const uint8_t *p = acc + o;
		int ver = p[5];
		if ((ver == 2 || ver == 3) && p[6] == 0x5A && p[7] == 0xA5 && rd16(p + 2) == expect_nbytes) {
			unsigned nh = (ver == 3) ? 6 : 3;
			size_t total = 8 * nh + (((size_t)expect_nbytes + 7) & ~(size_t)7);
			if (o + total > len) {
				*skipped = o;
				return 0;
			}
			memset(r, 0, sizeof *r);
			r->flags = p[4];
			r->version = ver;
			r->nh = nh;
			r->nbytes = rd16(p + 2);
			r->seq = rd16(p);
			r->n_best = rd32(p + 8);
			r->cfo_inc = (int32_t)rd32(p + 12);
			r->evm_sum = rd32(p + 16);
			r->rssi_code = rd16(p + 20);
			r->angle16 = (int16_t)rd16(p + 22);
			if (ver == 3) {
				r->snr_avg_code = (int16_t)rd16(p + 30);        /* beat 3 = {snr_avg, snr_min, bad, noise} (MSB first) */
				r->snr_min_code = (int16_t)rd16(p + 28);
				r->bad_sc = rd16(p + 26);
				r->noise_code = (int16_t)rd16(p + 24);
				r->tau_q8 = (int32_t)(rd32(p + 32) << 12) >> 12;   /* beat 4 = {fail, imax, isum, mode, 4'b0, tau20} */
				r->mode_bits = p[35];
				r->hdr_bits = p[34] >> 4;
				r->ldpc_iter_sum = rd16(p + 36) & 0xFFF;
				r->ldpc_iter_max = p[38] & 0x1F;
				r->ldpc_fail = p[39];
				r->slope = (int32_t)rd32(p + 40);                 /* beat 5 = {angle_first, slope_last} */
				r->angle_first = rd32(p + 44);
			}
			r->payload = p + 8 * nh;
			*skipped = o;
			return o + total;
		}
		o += 8;
	}
	*skipped = o;
	return 0;
}

static double rssi_dbfs(uint16_t code)
{
	if (!code)
		return -999.0;
	int pos = code >> 10, mant = code & 0x3FF;
	double r = ldexp(1.0 + mant / 1024.0, pos);
	double p = r * (1 << RSSI_QSH) / RSSI_L;           /* mean |x|^2 in LSB^2 */
	return 10.0 * log10(p / (ADC_FS * ADC_FS));
}
static double evm_pct(uint32_t sum, int nsyms)
{
	double m = (double)sum / ((double)nsyms * PILOTS_PER_SYM);   /* mean L1 error per pilot (|dI| + |dQ|) */
	return 100.0 * 0.8862 * m / CONST_RMS;                       /* gaussian: rms error vector = 0.8862 * mean L1 */
}
static double cfo_hz(int32_t inc) { return -(double)inc * PHY_FS_HZ / 4294967296.0; }

/* ======================================================================================================================
 * sysfs / iio helpers
 * ==================================================================================================================== */
static int sysfs_write(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY);
	if (fd < 0)
		return -errno;
	ssize_t w = write(fd, val, strlen(val));
	int e = (w < 0) ? -errno : 0;
	close(fd);
	return e;
}
static int sysfs_read(const char *path, char *buf, size_t n)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return -errno;
	ssize_t r = read(fd, buf, n - 1);
	close(fd);
	if (r < 0)
		return -errno;
	buf[r] = 0;
	while (r > 0 && (buf[r - 1] == '\n' || buf[r - 1] == ' '))
		buf[--r] = 0;
	return 0;
}
static int iio_find(const char *name)
{
	for (int i = 0; i < 32; i++) {
		char p[128], b[64];
		snprintf(p, sizeof p, "/sys/bus/iio/devices/iio:device%d/name", i);
		if (sysfs_read(p, b, sizeof b) == 0 && strcmp(b, name) == 0)
			return i;
	}
	return -1;
}
static int dev_set(int idx, const char *attr, const char *val, int verbose)
{
	char p[160];
	snprintf(p, sizeof p, "/sys/bus/iio/devices/iio:device%d/%s", idx, attr);
	int e = sysfs_write(p, val);
	if (e && verbose)
		fprintf(stderr, "  warn: write %s = %s failed (%s)\n", attr, val, strerror(-e));
	return e;
}
static int dev_get(int idx, const char *attr, char *buf, size_t n)
{
	char p[160];
	snprintf(p, sizeof p, "/sys/bus/iio/devices/iio:device%d/%s", idx, attr);
	return sysfs_read(p, buf, n);
}

/* ======================================================================================================================
 * register access (/dev/mem)
 * ==================================================================================================================== */
static volatile uint32_t *g_regs;
static int g_mem_fd = -1;

static int regs_open(void)
{
	g_mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (g_mem_fd < 0) {
		fprintf(stderr, "open /dev/mem: %s (run as root)\n", strerror(errno));
		return -1;
	}
	void *m = mmap(NULL, PHY_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, g_mem_fd, PHY_BASE);
	if (m == MAP_FAILED) {
		fprintf(stderr, "mmap 0x%08x: %s\n", PHY_BASE, strerror(errno));
		return -1;
	}
	g_regs = m;
	return 0;
}
static inline uint32_t rreg(unsigned off) { return g_regs[off >> 2]; }
static inline void wreg(unsigned off, uint32_t v) { g_regs[off >> 2] = v; }

struct hwstat { uint32_t w[NST]; double t; };

static int hw_snapshot(struct hwstat *s)
{
	wreg(REG_SNAP, 1);
	int ok = 0;
	for (int i = 0; i < 2000; i++) {                    /* ~ few ms at most */
		if (rreg(REG_SNAP) & 1) { ok = 1; break; }
		usleep(50);
	}
	if (!ok)
		return -1;
	for (int i = 0; i < NST; i++)
		s->w[i] = rreg(REG_STAT0 + 4 * i);
	s->t = now_s();
	return 0;
}

/* ======================================================================================================================
 * AD9361 setup
 * ==================================================================================================================== */
struct rfcfg {
	double freq_hz;
	double fs_hz;
	double bw_hz;
	double tx_gain_db;     /* TX attenuation: 0 .. -89.75 */
	double rx_gain_db;     /* manual RX gain */
	int rx_agc;            /* 1 = slow attack AGC */
};

static int rf_setup(const struct rfcfg *c, int role_tx)
{
	int phy = iio_find("ad9361-phy");
	if (phy < 0) {
		fprintf(stderr, "ad9361-phy not found in /sys/bus/iio/devices\n");
		return -1;
	}
	char v[64];
	printf("RF: ad9361-phy = iio:device%d\n", phy);
	dev_set(phy, "ensm_mode", "fdd", 1);
	snprintf(v, sizeof v, "%.0f", c->fs_hz);
	dev_set(phy, "in_voltage_sampling_frequency", v, 1);
	dev_set(phy, "out_voltage_sampling_frequency", v, 1);
	snprintf(v, sizeof v, "%.0f", c->bw_hz);
	dev_set(phy, "in_voltage_rf_bandwidth", v, 1);
	dev_set(phy, "out_voltage_rf_bandwidth", v, 1);
	snprintf(v, sizeof v, "%.0f", c->freq_hz);
	dev_set(phy, "out_altvoltage0_RX_LO_frequency", v, 1);
	dev_set(phy, "out_altvoltage1_TX_LO_frequency", v, 1);
	if (role_tx) {
		snprintf(v, sizeof v, "%.2f", c->tx_gain_db);
		dev_set(phy, "out_voltage0_hardwaregain", v, 1);
	} else {
		dev_set(phy, "in_voltage0_gain_control_mode", c->rx_agc ? "slow_attack" : "manual", 1);
		if (!c->rx_agc) {
			snprintf(v, sizeof v, "%.2f", c->rx_gain_db);
			dev_set(phy, "in_voltage0_hardwaregain", v, 1);
		}
	}
	char b[64];
	if (!dev_get(phy, "in_voltage_sampling_frequency", b, sizeof b))
		printf("RF: rx sampling_frequency = %s\n", b);
	if (!dev_get(phy, "out_altvoltage0_RX_LO_frequency", b, sizeof b))
		printf("RF: rx LO = %s\n", b);
	if (!dev_get(phy, "out_altvoltage1_TX_LO_frequency", b, sizeof b))
		printf("RF: tx LO = %s\n", b);
	if (!dev_get(phy, "out_voltage0_hardwaregain", b, sizeof b))
		printf("RF: tx hardwaregain = %s\n", b);
	if (!dev_get(phy, "in_voltage0_hardwaregain", b, sizeof b))
		printf("RF: rx hardwaregain = %s\n", b);
	return phy;
}
static void rf_set_tx_gain(int phy, double db)
{
	char v[32];
	snprintf(v, sizeof v, "%.2f", db);
	dev_set(phy, "out_voltage0_hardwaregain", v, 1);
}

/* ======================================================================================================================
 * IIO stream buffer (DMA <-> PHY packet stream)
 * ==================================================================================================================== */
struct stream {
	int fd, dev;
	int bytes_per_scan;
	char node[48];
};

/* enable all `prefix%d_en` channels that exist (voltage0..3), returns the number enabled */
static int enable_channels(int dev, const char *prefix)
{
	int n = 0;
	for (int i = 0; i < 4; i++) {
		char a[96];
		snprintf(a, sizeof a, "scan_elements/%s%d_en", prefix, i);
		if (dev_set(dev, a, "1", 0) == 0)
			n++;
	}
	dev_set(dev, "scan_elements/in_timestamp_en", "0", 0);
	return n;
}

static int stream_open(struct stream *s, const char *devname, const char *prefix, size_t block_bytes, int rd)
{
	memset(s, 0, sizeof *s);
	s->fd = -1;
	s->dev = iio_find(devname);
	if (s->dev < 0) {
		fprintf(stderr, "IIO device '%s' not found (device tree / bitstream mismatch?)\n", devname);
		return -1;
	}
	dev_set(s->dev, "buffer/enable", "0", 0);
	int nch = enable_channels(s->dev, prefix);
	if (nch == 0) {
		fprintf(stderr, "%s: no scan channel could be enabled\n", devname);
		return -1;
	}
	s->bytes_per_scan = 2 * nch;
	char v[32];
	snprintf(v, sizeof v, "%zu", block_bytes / s->bytes_per_scan);
	if (dev_set(s->dev, "buffer/length", v, 1))
		fprintf(stderr, "  (continuing with the driver's default buffer length)\n");
	if (dev_set(s->dev, "buffer/enable", "1", 1))
		return -1;
	snprintf(s->node, sizeof s->node, "/dev/iio:device%d", s->dev);
	s->fd = open(s->node, rd ? O_RDONLY : O_WRONLY);
	if (s->fd < 0) {
		fprintf(stderr, "open %s: %s\n", s->node, strerror(errno));
		return -1;
	}
	printf("stream: %s = iio:device%d, %d channels (%d bytes/scan), block %zu bytes, fd %s\n", devname, s->dev, nch,
	       s->bytes_per_scan, block_bytes, rd ? "read" : "write");
	return 0;
}
static void stream_close(struct stream *s)
{
	if (s->fd >= 0)
		close(s->fd);
	if (s->dev >= 0)
		dev_set(s->dev, "buffer/enable", "0", 0);
}

/* ======================================================================================================================
 * options
 * ==================================================================================================================== */
struct opts {
	int nsyms;
	double freq_hz;
	double tx_gain_db;
	double rx_gain_db;
	int rx_agc;
	uint32_t run_seed;
	uint32_t gap_samples;
	double rate_pps;          /* TX: packets per second, 0 = as fast as the PHY accepts */
	long count;               /* number of packets (0 = unlimited) */
	double duration_s;
	double stats_s;
	char log_prefix[200];
	/* TX gain sweep */
	int sweep;
	double sw_from, sw_to, sw_step;
	long sw_count;
	int sw_loops;
	int rmin_set;
	uint32_t rmin;
	int gain_sh;
	int no_rf;
	double fs_hz;
	int bytes_chunk;
	int force_coded;          /* -1 = auto from the PHY feature word */
	int mmse, max_iter, ft_en, tau_tgt;
	int mode, hdr_en, smooth;      /* dual-mode PHY: --mode 0|1, RX: --hdr 0|1 (mode from the header symbol), --smooth 0|1 */
	double bad_snr_db;
};

static void usage(void)
{
	puts("plutolink " VERSION "\n"
	     "usage: plutolink <tx|rx|diag|selftest> [options]\n"
	     "common:\n"
	     "  --freq HZ          carrier (default 2450e6)       --nsyms N     OFDM data symbols per packet, 1..8 (default 2)\n"
	     "  --seed N           PRBS run seed (default 1; must match on both boards)\n"
	     "  --log PREFIX       log file prefix (default plutolink_<role>_<time>)      --stats SEC  status interval (default 1)\n"
	     "  --duration SEC     stop after SEC seconds         --count N     stop after N packets (tx: sent, rx: received)\n"
	     "  --no-rf            do not touch the AD9361 (already configured)\n"
	     "tx:\n"
	     "  --gain DB          TX attenuation setting, 0 .. -89.75 (default -40)\n"
	     "  --rate PPS         packet rate limit (default: as fast as the PHY gap allows)\n"
	     "  --gap SAMPLES      minimum gap between frames in samples (default 16384)\n"
	     "  --sweep FROM:TO:STEP:COUNT[:LOOPS]   TX gain sweep, COUNT packets per step (each step gets its own step_id)\n"
	     "rx:\n"
	     "  --rx-gain DB       manual RX gain (default 40)    --agc        slow-attack AGC instead of manual gain\n"
	     "  --rmin N           detector energy gate           --gain-sh N  digital gain shift before the detector (-8..7)\n"
	     "  --mmse 0|1         coded PHY: ZF / MMSE equalizer (default 1)    --max-iter N  LDPC iteration limit (default 10)\n"
	     "  --hdr 0|1          take the PHY mode from the header symbol (default 1; 0 = use --mode)    --smooth 0|1  channel estimate smoothing (default 1)\n"
	     "  --no-ft            disable the fine-timing loop   --tau-tgt N   wanted LTS window earliness in samples (default 56)\n"
	     "  --bad-snr DB       a subcarrier is bad below this SNR (default 10 dB)    --coded/--uncoded  override the PHY mode detection\n"
	     "WARNING: use cables + 30..60 dB of attenuation between the boards for the first runs (the receiver front end is easy to overload).");
}

static int parse_opts(int argc, char **argv, struct opts *o)
{
	memset(o, 0, sizeof *o);
	o->nsyms = 2;
	o->freq_hz = 2450e6;
	o->tx_gain_db = -40.0;
	o->rx_gain_db = 40.0;
	o->run_seed = 1;
	o->gap_samples = 16384;
	o->stats_s = 1.0;
	o->fs_hz = PHY_FS_HZ;
	o->force_coded = -1;
	o->mmse = 1;
	o->mode = 1; o->hdr_en = 1; o->smooth = 1;
	o->max_iter = 10;
	o->ft_en = 1;
	o->tau_tgt = 56;
	o->bad_snr_db = 10.0;
	for (int i = 2; i < argc; i++) {
		const char *a = argv[i];
#define ARG(name) (!strcmp(a, name) && i + 1 < argc)
		if (ARG("--freq")) o->freq_hz = atof(argv[++i]);
		else if (ARG("--nsyms")) o->nsyms = atoi(argv[++i]);
		else if (ARG("--seed")) o->run_seed = strtoul(argv[++i], NULL, 0);
		else if (ARG("--log")) snprintf(o->log_prefix, sizeof o->log_prefix, "%s", argv[++i]);
		else if (ARG("--stats")) o->stats_s = atof(argv[++i]);
		else if (ARG("--duration")) o->duration_s = atof(argv[++i]);
		else if (ARG("--count")) o->count = atol(argv[++i]);
		else if (!strcmp(a, "--no-rf")) o->no_rf = 1;
		else if (ARG("--gain")) o->tx_gain_db = atof(argv[++i]);
		else if (ARG("--rate")) o->rate_pps = atof(argv[++i]);
		else if (ARG("--gap")) o->gap_samples = strtoul(argv[++i], NULL, 0);
		else if (ARG("--rx-gain")) o->rx_gain_db = atof(argv[++i]);
		else if (!strcmp(a, "--agc")) o->rx_agc = 1;
		else if (!strcmp(a, "--coded")) o->force_coded = 1;
		else if (!strcmp(a, "--uncoded")) o->force_coded = 0;
		else if (ARG("--mmse")) o->mmse = atoi(argv[++i]);
		else if (ARG("--mode")) o->mode = atoi(argv[++i]);
		else if (ARG("--hdr")) o->hdr_en = atoi(argv[++i]);
		else if (ARG("--smooth")) o->smooth = atoi(argv[++i]);
		else if (ARG("--max-iter")) o->max_iter = atoi(argv[++i]);
		else if (!strcmp(a, "--no-ft")) o->ft_en = 0;
		else if (ARG("--tau-tgt")) o->tau_tgt = atoi(argv[++i]);
		else if (ARG("--bad-snr")) o->bad_snr_db = atof(argv[++i]);
		else if (ARG("--rmin")) { o->rmin = strtoul(argv[++i], NULL, 0); o->rmin_set = 1; }
		else if (ARG("--gain-sh")) o->gain_sh = atoi(argv[++i]);
		else if (ARG("--sweep")) {
			o->sw_loops = 1;
			int n = sscanf(argv[++i], "%lf:%lf:%lf:%ld:%d", &o->sw_from, &o->sw_to, &o->sw_step, &o->sw_count, &o->sw_loops);
			if (n < 4 || o->sw_step == 0 || o->sw_count <= 0) {
				fprintf(stderr, "bad --sweep (FROM:TO:STEP:COUNT[:LOOPS])\n");
				return -1;
			}
			o->sweep = 1;
		} else {
			fprintf(stderr, "unknown or incomplete option: %s\n", a);
			return -1;
		}
	}
	g_mode = o->mode ? 1 : 0;
	if (o->nsyms < 1 || o->nsyms > 8) {
		fprintf(stderr, "--nsyms must be 1..8\n");
		return -1;
	}
	return 0;
}

static FILE *open_log(const struct opts *o, const char *role, const char *suffix, const char *header)
{
	char path[256];
	char pre[200];
	if (o->log_prefix[0])
		snprintf(pre, sizeof pre, "%s", o->log_prefix);
	else {
		time_t t = time(NULL);
		struct tm tm;
		localtime_r(&t, &tm);
		snprintf(pre, sizeof pre, "plutolink_%s_%04d%02d%02d_%02d%02d%02d", role, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
			 tm.tm_hour, tm.tm_min, tm.tm_sec);
	}
	snprintf(path, sizeof path, "%s_%s.csv", pre, suffix);
	FILE *f = fopen(path, "w");
	if (!f) {
		fprintf(stderr, "cannot create %s: %s\n", path, strerror(errno));
		return NULL;
	}
	fprintf(f, "%s\n", header);
	printf("log: %s\n", path);
	return f;
}

static void write_meta(const struct opts *o, const char *role)
{
	char pre[200];
	if (o->log_prefix[0])
		snprintf(pre, sizeof pre, "%s", o->log_prefix);
	else
		return;                       /* default names: meta is skipped, the CSV rows carry the parameters */
	char path[256];
	snprintf(path, sizeof path, "%s_%s.meta", pre, role);
	FILE *f = fopen(path, "w");
	if (!f)
		return;
	fprintf(f, "plutolink=%s\nrole=%s\nfreq_hz=%.0f\nnsyms=%d\nseed=%u\ntx_gain_db=%.2f\nrx_gain_db=%.2f\nagc=%d\nsweep=%d\n",
		VERSION, role, o->freq_hz, o->nsyms, o->run_seed, o->tx_gain_db, o->rx_gain_db, o->rx_agc, o->sweep);
	fclose(f);
}

/* ======================================================================================================================
 * stats line (shared)
 * ==================================================================================================================== */
static const char *STATS_HDR_RX =
	"t_s,det,pkt,drop,wd,flags,busy,samples,clks,adc_peak_i,adc_peak_q,adc_clip,beats,stall_clks,rate_msps,clk_mhz,last_rssi_dbfs";
static const char *STATS_HDR_TX =
	"t_s,accepted,done,overflow,trunc,underflow,bad_hdr,dropped_beats,dac_samples,clks,busy_clks,active_samples,peak_i,peak_q,"
	"beats,stall_clks,rate_msps,clk_mhz,gain";

/* ======================================================================================================================
 * RX role
 * ==================================================================================================================== */
struct rx_acc {
	uint64_t pkts, hdr_bad, crc_bad, lost, resync_bytes, bits, bit_errors, byte_errors, pkts_with_err;
	double evm_sum, rssi_sum, cfo_sum;
	long n_meas;
	long last_seq;
	int have_seq;
};

static void rx_stats_line(struct rx_acc *win, const struct hwstat *cur, const struct hwstat *prev, double t0, FILE *fs)
{
	double dt = cur->t - prev->t;
	double rate = dt > 0 ? (double)(uint32_t)(cur->w[3] - prev->w[3]) / dt / 1e6 : 0;
	double clkmhz = dt > 0 ? (double)(uint32_t)(cur->w[4] - prev->w[4]) / dt / 1e6 : 0;
	double rs = rssi_dbfs((uint16_t)(cur->w[7] & 0xFFFF));
	double ber = win->bits ? (double)win->bit_errors / win->bits : 0;
	printf("[%7.1fs] rx ok %4llu (hdr_bad %llu crc_bad %llu lost %llu) BER %.2e | EVM %5.2f%% SNR~%5.1f dB CFO %+7.0f Hz RSSI %6.1f dBFS | "
	       "det %u pkt %u drop %u wd %u peak %u/%u clip %u | fs %.3f MS/s clk %.2f MHz\n",
	       cur->t - t0, (unsigned long long)win->pkts, (unsigned long long)win->hdr_bad, (unsigned long long)win->crc_bad,
	       (unsigned long long)win->lost, ber, win->n_meas ? win->evm_sum / win->n_meas : 0.0,
	       win->n_meas && win->evm_sum > 0 ? -20.0 * log10(win->evm_sum / win->n_meas / 100.0) : 0.0,
	       win->n_meas ? win->cfo_sum / win->n_meas : 0.0, win->n_meas ? win->rssi_sum / win->n_meas : rs,
	       cur->w[0] & 0xFFFF, cur->w[0] >> 16, cur->w[1] & 0xFFFF, cur->w[1] >> 16, cur->w[5] & 0xFFFF, cur->w[5] >> 16, cur->w[6], rate,
	       clkmhz);
	fprintf(fs, "%.3f,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%.4f,%.3f,%.2f\n", cur->t - t0, cur->w[0] & 0xFFFF, cur->w[0] >> 16,
		cur->w[1] & 0xFFFF, cur->w[1] >> 16, cur->w[2] & 0xFF, (cur->w[2] >> 8) & 1, cur->w[3], cur->w[4], cur->w[5] & 0xFFFF,
		cur->w[5] >> 16, cur->w[6], cur->w[12], cur->w[13], rate, clkmhz, rs);
	fflush(fs);
	memset(win, 0, sizeof *win);
}

/* feeds one PHY record into the accumulators + log */
static void rx_handle(const struct phy_rec *r, const struct opts *o, struct rx_acc *tot, struct rx_acc *win, FILE *fp, double t)
{
	struct app_result ar;
	uint32_t guess = tot->have_seq ? (uint32_t)(tot->last_seq + 1) : 0;
	app_check(r->payload, r->nbytes, o->run_seed, guess, &ar);
	double evm = evm_pct(r->evm_sum, o->nsyms);
	double snr = evm > 0 ? -20.0 * log10(evm / 100.0) : 99.0;
	double rs = rssi_dbfs(r->rssi_code);
	double cfo = cfo_hz(r->cfo_inc);
	long lost = 0;
	if (ar.hdr_ok) {
		if (tot->have_seq && ar.info.seq > (uint32_t)tot->last_seq + 1 && ar.info.seq - (uint32_t)tot->last_seq < 100000)
			lost = ar.info.seq - tot->last_seq - 1;
		tot->last_seq = ar.info.seq;
		tot->have_seq = 1;
	}
	struct rx_acc *x[2] = { tot, win };
	for (int k = 0; k < 2; k++) {
		x[k]->pkts++;
		x[k]->hdr_bad += !ar.hdr_ok;
		x[k]->crc_bad += !ar.crc_ok;
		x[k]->lost += lost;
		x[k]->bits += ar.bits;
		x[k]->bit_errors += ar.bit_errors;
		x[k]->byte_errors += ar.byte_errors;
		x[k]->pkts_with_err += (ar.bit_errors != 0);
		x[k]->evm_sum += evm;
		x[k]->rssi_sum += rs;
		x[k]->cfo_sum += cfo;
		x[k]->n_meas++;
	}
	/* v3 extras: channel SNR from the LTS, LDPC, fine timing, SFO slope, residual CFO from the CPE angle drift */
	const double k_db = 3.0103 / 32.0;
	double snr_avg = -999, snr_min = -999, tau = -999, sfo_ppm = -999, cfo_res = -999, it_avg = -999;
	if (r->version == 3) {
		snr_avg = r->snr_avg_code * k_db;
		snr_min = r->snr_min_code * k_db;
		tau = r->tau_q8 / 256.0;
		it_avg = (double)r->ldpc_iter_sum / ((((r->hdr_bits >> 1) & 1) ? 2 : 1) * o->nsyms);
		double slope = (double)r->slope / 4294967296.0 * 2.0 * M_PI;                 /* rad per bin at the last data symbol */
		sfo_ppm = slope * 2048.0 / (2.0 * M_PI) / ((double)o->nsyms * SYM_LEN) * 1e6;
		if (o->nsyms > 1) {
			int16_t d16 = (int16_t)(r->angle16 - (int16_t)(r->angle_first >> 16));
			cfo_res = (double)d16 / 65536.0 / (o->nsyms - 1) * PHY_FS_HZ / SYM_LEN;
		}
	}
	fprintf(fp, "%.4f,%u,%u,%d,%d,%u,%d,%.2f,%u,%llu,%llu,%llu,%.3f,%.2f,%.1f,%.2f,%.1f,%u,%u,%u,%.2f,%.2f,%u,%d,%u,%u,%.2f,%.3f,%.2f,%.2f\n",
		t, r->seq, ar.info.seq, ar.hdr_ok, ar.crc_ok, ar.info.step_id, ar.info.gain_x100, ar.info.gain_x100 / 100.0, r->flags,
		(unsigned long long)ar.bits, (unsigned long long)ar.bit_errors, (unsigned long long)ar.byte_errors, evm, snr, cfo, rs,
		r->angle16 * 360.0 / 65536.0, r->n_best, r->evm_sum, r->rssi_code, snr_avg, snr_min, r->bad_sc, r->noise_code, r->ldpc_fail,
		r->ldpc_iter_max, it_avg, tau, sfo_ppm, cfo_res);
}

static const char *RX_HDR =
	"t_s,phy_seq,app_seq,hdr_ok,crc_ok,step_id,tx_gain_x100,tx_gain_db,flags,bits,bit_errors,byte_errors,evm_pct,snr_db,cfo_hz,"
	"rssi_dbfs,cpe_deg,n_best,evm_sum,rssi_code,chan_snr_db,chan_snr_min_db,bad_subcarriers,noise_code,ldpc_cw_failed,ldpc_iter_max,"
	"ldpc_iter_avg,tau_samples,sfo_ppm_est,cfo_resid_hz";

static int run_rx(const struct opts *o)
{
	if (regs_open())
		return 1;
	uint32_t id = rreg(REG_ID);
	if (id != ID_RX) {
		fprintf(stderr, "register ID 0x%08x is not the RX PHY (0x%08x): wrong bitstream loaded on this board\n", id, ID_RX);
		return 1;
	}
	struct rfcfg rf = { o->freq_hz, o->fs_hz, 20e6, 0, o->rx_gain_db, o->rx_agc };
	if (!o->no_rf && rf_setup(&rf, 0) < 0)
		return 1;
	{
		struct hwstat f;
		g_coded = (hw_snapshot(&f) == 0) ? (int)(f.w[REG_FEATURE_W] & 1) : 0;
		if (o->force_coded >= 0)
			g_coded = o->force_coded;
		printf("PHY mode: %s\n", g_coded ? "coded (LDPC R=5/6, soft LLR, MMSE/ZF, SFO tracking)" : "uncoded (hard decision)");
	}
	/* PHY configuration + reset + clear */
	wreg(REG_CTRL, 1);
	usleep(1000);
	wreg(REG_CFG0 + 0, o->nsyms);
	if (o->rmin_set)
		wreg(REG_CFG0 + 4, o->rmin);
	wreg(REG_CFG0 + 8, (uint32_t)o->gain_sh & 0xF);
	if (g_coded) {
		wreg(REG_CFG0 + 12, (uint32_t)(o->mmse | (o->hdr_en << 1) | (o->mode << 2)));      /* MMSE | HDR_EN | MODE (fallback / manual) */
		wreg(REG_CFG0 + 16, o->max_iter);
		wreg(REG_CFG0 + 20, (uint32_t)lround(o->bad_snr_db / 0.0941) & 0x1FFF);
		wreg(REG_CFG0 + 24, (uint32_t)(o->ft_en | (o->smooth << 1)));
		wreg(REG_CFG0 + 28, o->tau_tgt);
	}
	wreg(REG_CTRL, 0);
	usleep(1000);
	wreg(REG_CTRL, 2);

	size_t nbytes = (size_t)o->nsyms * bytes_per_sym();
	size_t rec_bytes = (g_coded ? 48 : 24) + ((nbytes + 7) & ~(size_t)7);
	struct stream st;
	if (stream_open(&st, "cf-ad9361-lpc", "in_voltage", rec_bytes, 1) < 0)
		return 1;

	FILE *fp = open_log(o, "rx", "packets", RX_HDR);
	FILE *fs = open_log(o, "rx", "stats", STATS_HDR_RX);
	if (!fp || !fs)
		return 1;
	write_meta(o, "rx");
	printf("rx: nsyms %d (%zu payload bytes, %zu bytes per PHY record), freq %.3f MHz. Ctrl-C to stop.\n", o->nsyms, nbytes, rec_bytes,
	       o->freq_hz / 1e6);

	static uint8_t acc[1 << 18];
	size_t alen = 0;
	struct rx_acc tot, win;
	memset(&tot, 0, sizeof tot);
	memset(&win, 0, sizeof win);
	struct hwstat prev, cur;
	hw_snapshot(&prev);
	double t0 = now_s(), tnext = t0 + o->stats_s;
	while (!g_stop) {
		if (o->duration_s > 0 && now_s() - t0 > o->duration_s)
			break;
		if (o->count && (long)tot.pkts >= o->count)
			break;
		struct pollfd pfd = { st.fd, POLLIN, 0 };
		int pr = poll(&pfd, 1, 200);
		if (pr > 0 && (pfd.revents & POLLIN)) {
			ssize_t n = read(st.fd, acc + alen, sizeof acc - alen);
			if (n > 0)
				alen += n;
			else if (n < 0 && errno != EINTR && errno != EAGAIN) {
				fprintf(stderr, "read: %s\n", strerror(errno));
				break;
			}
		}
		for (;;) {
			struct phy_rec r;
			size_t skipped;
			size_t used = phy_parse(acc, alen, nbytes, &r, &skipped);
			if (!used) {
				if (skipped) {                                     /* garbage in front: drop it, keep the tail */
					memmove(acc, acc + skipped, alen - skipped);
					alen -= skipped;
					tot.resync_bytes += skipped;
				}
				break;
			}
			tot.resync_bytes += skipped;
			rx_handle(&r, o, &tot, &win, fp, now_s() - t0);
			memmove(acc, acc + used, alen - used);
			alen -= used;
		}
		if (alen > sizeof acc - 4096)
			alen = 0;
		if (now_s() >= tnext) {
			tnext += o->stats_s;
			if (hw_snapshot(&cur) == 0) {
				rx_stats_line(&win, &cur, &prev, t0, fs);
				prev = cur;
			}
			fflush(fp);
		}
	}
	printf("\n== rx summary ==\npackets %llu  hdr_bad %llu  crc_bad %llu  lost(seq gaps) %llu  resync bytes %llu\n",
	       (unsigned long long)tot.pkts, (unsigned long long)tot.hdr_bad, (unsigned long long)tot.crc_bad,
	       (unsigned long long)tot.lost, (unsigned long long)tot.resync_bytes);
	printf("bits %llu  bit errors %llu  BER %.3e  packets with errors %llu (PER %.3e)\n", (unsigned long long)tot.bits,
	       (unsigned long long)tot.bit_errors, tot.bits ? (double)tot.bit_errors / tot.bits : 0.0, (unsigned long long)tot.pkts_with_err,
	       tot.pkts ? (double)tot.pkts_with_err / tot.pkts : 0.0);
	fclose(fp);
	fclose(fs);
	stream_close(&st);
	return 0;
}

/* ======================================================================================================================
 * TX role
 * ==================================================================================================================== */
static void tx_stats_line(const struct hwstat *cur, const struct hwstat *prev, double t0, double gain, long sent, FILE *fs)
{
	double dt = cur->t - prev->t;
	double rate = dt > 0 ? (double)(uint32_t)(cur->w[3] - prev->w[3]) / dt / 1e6 : 0;
	double clkmhz = dt > 0 ? (double)(uint32_t)(cur->w[4] - prev->w[4]) / dt / 1e6 : 0;
	printf("[%7.1fs] tx sent %ld | phy accepted %u done %u overflow %u trunc %u underflow %u bad_hdr %u | busy %.1f%% | peak %u/%u | "
	       "dac %.3f MS/s clk %.2f MHz gain %.1f dB\n",
	       cur->t - t0, sent, cur->w[0] & 0xFFFF, cur->w[0] >> 16, cur->w[1] & 0xFFFF, cur->w[1] >> 16, cur->w[2] & 0xFFFF,
	       cur->w[2] >> 16, 100.0 * (double)(uint32_t)(cur->w[5] - prev->w[5]) / (double)(uint32_t)(cur->w[4] - prev->w[4] ? cur->w[4] - prev->w[4] : 1),
	       cur->w[7] & 0xFFFF, cur->w[7] >> 16, rate, clkmhz, gain);
	fprintf(fs, "%.3f,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%.4f,%.3f,%.2f\n", cur->t - t0, cur->w[0] & 0xFFFF, cur->w[0] >> 16,
		cur->w[1] & 0xFFFF, cur->w[1] >> 16, cur->w[2] & 0xFFFF, cur->w[2] >> 16, cur->w[15], cur->w[3], cur->w[4], cur->w[5],
		cur->w[6], cur->w[7] & 0xFFFF, cur->w[7] >> 16, cur->w[8], cur->w[9], rate, clkmhz, gain);
	fflush(fs);
}

static int run_tx(const struct opts *o)
{
	if (regs_open())
		return 1;
	uint32_t id = rreg(REG_ID);
	if (id != ID_TX) {
		fprintf(stderr, "register ID 0x%08x is not the TX PHY (0x%08x): wrong bitstream loaded on this board\n", id, ID_TX);
		return 1;
	}
	{
		struct hwstat f;
		g_coded = (hw_snapshot(&f) == 0) ? (int)(f.w[REG_FEATURE_W] & 1) : 0;
		if (o->force_coded >= 0)
			g_coded = o->force_coded;
		printf("PHY mode: %s\n", g_coded ? "coded (LDPC R=5/6, 450 payload bytes per OFDM symbol)" : "uncoded (550 bytes per symbol)");
	}
	double gain = o->sweep ? o->sw_from : o->tx_gain_db;
	struct rfcfg rf = { o->freq_hz, o->fs_hz, 20e6, gain, 0, 0 };
	int phy = -1;
	if (!o->no_rf && (phy = rf_setup(&rf, 1)) < 0)
		return 1;
	if (phy < 0)
		phy = iio_find("ad9361-phy");
	/* TX PHY config: gain 16384 (1.0), gap, enable */
	wreg(REG_CTRL, 1);
	usleep(1000);
	wreg(REG_CFG0 + 0, 16384);
	wreg(REG_CFG0 + 4, o->gap_samples);
	wreg(REG_CFG0 + 8, (uint32_t)(1 | (o->mode << 1)));            /* ENABLE | MODE (0 = MAX RANGE, 1 = MAX RATE) */
	wreg(REG_CTRL, 0);
	usleep(1000);
	wreg(REG_CTRL, 2);

	size_t nbytes = (size_t)o->nsyms * bytes_per_sym();
	size_t beats = 1 + (nbytes + 7) / 8;
	size_t blk = beats * 8;
	struct stream st;
	if (stream_open(&st, "cf-ad9361-dds-core-lpc", "out_voltage", blk, 0) < 0)
		return 1;
	uint8_t *buf = calloc(1, blk);
	uint8_t *pay = malloc(APP_MAX);
	FILE *fp = open_log(o, "tx", "packets", "t_s,seq,step_id,gain_db,nbytes,write_us");
	FILE *fs = open_log(o, "tx", "stats", STATS_HDR_TX);
	if (!buf || !pay || !fp || !fs)
		return 1;
	write_meta(o, "tx");
	printf("tx: nsyms %d (%zu bytes/packet, %zu DMA beats), gap %u samples, freq %.3f MHz, %s. Ctrl-C to stop.\n", o->nsyms, nbytes, beats,
	       o->gap_samples, o->freq_hz / 1e6, o->sweep ? "gain sweep" : "fixed gain");

	double t0 = now_s(), tnext = t0 + o->stats_s, tpkt = t0;
	struct hwstat prev, cur;
	hw_snapshot(&prev);
	long sent = 0, in_step = 0;
	uint16_t step_id = 0;
	int loops_done = 0;
	double g = gain;
	uint32_t freq_khz = (uint32_t)(o->freq_hz / 1000.0);
	while (!g_stop) {
		double t = now_s();
		if (o->duration_s > 0 && t - t0 > o->duration_s)
			break;
		if (o->count && sent >= o->count)
			break;
		if (o->sweep && in_step >= o->sw_count) {
			in_step = 0;
			step_id++;
			g += (o->sw_to >= o->sw_from) ? fabs(o->sw_step) : -fabs(o->sw_step);
			int past = (o->sw_to >= o->sw_from) ? g > o->sw_to + 1e-9 : g < o->sw_to - 1e-9;
			if (past) {
				if (++loops_done >= o->sw_loops)
					break;
				g = o->sw_from;
				step_id = 0;
			}
			rf_set_tx_gain(phy, g);
			usleep(50000);                                   /* let the gain settle before the next packets */
			printf("tx: step %u gain %.2f dB\n", step_id, g);
		}
		if (o->rate_pps > 0) {
			double dly = tpkt - t;
			if (dly > 0)
				usleep((useconds_t)(dly * 1e6));
			tpkt += 1.0 / o->rate_pps;
		}
		uint32_t ms = (uint32_t)((now_s() - t0) * 1000.0);
		app_build(pay, o->nsyms, (uint32_t)sent, o->run_seed, step_id, (int)lround(g * 100.0), freq_khz, ms);
		memset(buf, 0, blk);
		wr32(buf + 0, (uint32_t)nbytes);                        /* DMA beat 0: {OFTX magic, 0, nbytes} */
		wr32(buf + 4, 0x4F465458u);
		memcpy(buf + 8, pay, nbytes);
		double tw = now_s();
		size_t off = 0;
		while (off < blk && !g_stop) {
			ssize_t w = write(st.fd, buf + off, blk - off);
			if (w < 0) {
				if (errno == EINTR || errno == EAGAIN)
					continue;
				fprintf(stderr, "write: %s\n", strerror(errno));
				g_stop = 1;
				break;
			}
			off += w;
		}
		fprintf(fp, "%.4f,%ld,%u,%.2f,%zu,%.0f\n", now_s() - t0, sent, step_id, g, nbytes, (now_s() - tw) * 1e6);
		sent++;
		in_step++;
		if (now_s() >= tnext) {
			tnext += o->stats_s;
			if (hw_snapshot(&cur) == 0) {
				tx_stats_line(&cur, &prev, t0, g, sent, fs);
				prev = cur;
			}
			fflush(fp);
		}
	}
	if (hw_snapshot(&cur) == 0)
		tx_stats_line(&cur, &prev, t0, g, sent, fs);
	printf("\n== tx summary ==\nsent %ld packets in %.1f s (%.1f pkt/s)\n", sent, now_s() - t0, sent / (now_s() - t0));
	fclose(fp);
	fclose(fs);
	stream_close(&st);
	return 0;
}

/* ======================================================================================================================
 * diag role
 * ==================================================================================================================== */
static int run_diag(const struct opts *o)
{
	printf("plutolink " VERSION " diag\n");
	if (regs_open())
		return 1;
	uint32_t id = rreg(REG_ID);
	printf("PHY register block @0x%08x: ID 0x%08x (%s)\n", PHY_BASE, id,
	       id == ID_RX ? "RX PHY" : id == ID_TX ? "TX PHY" : "UNKNOWN -- not an OFDM PHY bitstream");
	if (id != ID_RX && id != ID_TX)
		return 1;
	for (int i = 0; i < 3; i++)
		printf("  cfg[%d] = 0x%08x\n", i, rreg(REG_CFG0 + 4 * i));
	struct hwstat a, b;
	if (hw_snapshot(&a)) {
		puts("snapshot timeout -- the PHY clock (l_clk) may be missing");
		return 1;
	}
	sleep(1);
	hw_snapshot(&b);
	double dt = b.t - a.t;
	printf("l_clk  ~ %.3f MHz   sample strobe ~ %.4f MS/s  (expected fs %.4f MS/s)\n", (uint32_t)(b.w[4] - a.w[4]) / dt / 1e6,
	       (uint32_t)(b.w[3] - a.w[3]) / dt / 1e6, o->fs_hz / 1e6);
	printf("raw status words:");
	for (int i = 0; i < NST; i++)
		printf("%s%08x", i % 4 ? " " : "\n  ", b.w[i]);
	puts("");
	if (id == ID_RX)
		printf("RX: ADC peak I/Q = %u/%u, samples within 8 LSB of full scale = %u, det %u pkt %u\n", b.w[5] & 0xFFFF, b.w[5] >> 16, b.w[6],
		       b.w[0] & 0xFFFF, b.w[0] >> 16);
	int phy = iio_find("ad9361-phy");
	printf("IIO: ad9361-phy %s, cf-ad9361-lpc %s, cf-ad9361-dds-core-lpc %s\n", phy >= 0 ? "ok" : "MISSING",
	       iio_find("cf-ad9361-lpc") >= 0 ? "ok" : "MISSING", iio_find("cf-ad9361-dds-core-lpc") >= 0 ? "ok" : "MISSING");
	if (phy >= 0) {
		char v[64];
		static const char *attrs[] = { "ensm_mode", "in_voltage_sampling_frequency", "in_voltage_rf_bandwidth", "out_altvoltage0_RX_LO_frequency",
					       "out_altvoltage1_TX_LO_frequency", "out_voltage0_hardwaregain", "in_voltage0_hardwaregain",
					       "in_voltage0_gain_control_mode", "in_voltage0_rssi", "in_voltage0_rf_port_select", "out_voltage0_rf_port_select" };
		for (size_t i = 0; i < sizeof attrs / sizeof *attrs; i++)
			if (!dev_get(phy, attrs[i], v, sizeof v))
				printf("  %-34s %s\n", attrs[i], v);
	}
	return 0;
}

/* ======================================================================================================================
 * selftest (host only)
 * ==================================================================================================================== */
static int selftest(void)
{
	int errs = 0;
	for (int cod = 0; cod < 2; cod++)
	for (int nsyms = 1; nsyms <= 8; nsyms += 7) {
		g_coded = cod;
		size_t n = (size_t)nsyms * bytes_per_sym();
		uint8_t pay[APP_MAX];
		app_build(pay, nsyms, 12345, 7, 3, -3550, 2450000, 99);
		struct app_result r;
		app_check(pay, n, 7, 0, &r);
		if (!r.hdr_ok || !r.crc_ok || r.bit_errors || r.info.seq != 12345 || r.info.step_id != 3 || r.info.gain_x100 != -3550) {
			printf("selftest: clean packet failed (nsyms %d)\n", nsyms);
			errs++;
		}
		pay[100] ^= 0x81;
		pay[400] ^= 0x01;
		app_check(pay, n, 7, 0, &r);
		if (r.crc_ok || r.bit_errors != 3 || r.byte_errors != 2 || !r.hdr_ok) {
			printf("selftest: error counting failed (%llu bits)\n", (unsigned long long)r.bit_errors);
			errs++;
		}
		pay[5] ^= 0x10;                                    /* corrupt the header: BER must still be right via the guessed seq */
		app_check(pay, n, 7, 12345, &r);
		if (r.hdr_ok || r.bit_errors != 3) {
			printf("selftest: header-bad path failed (hdr_ok %d, %llu bits)\n", r.hdr_ok, (unsigned long long)r.bit_errors);
			errs++;
		}
		/* PHY record framing with leading garbage and a split read (v2 uncoded record or v3 coded record) */
		unsigned nh = cod ? 6 : 3;
		uint8_t stream[8 * 6 + APP_MAX + 64], rec[8 * 6 + APP_MAX + 8];
		size_t rb = 8 * nh + ((n + 7) & ~(size_t)7);
		memset(rec, 0, sizeof rec);
		wr16(rec + 0, 77); wr16(rec + 2, (uint16_t)n); rec[4] = 0; rec[5] = cod ? 3 : 2; rec[6] = 0x5A; rec[7] = 0xA5;
		wr32(rec + 8, 4242);                                /* n_best */
		wr32(rec + 12, (uint32_t)-1000000);                 /* cfo_inc */
		wr32(rec + 16, 100 * 2 * nsyms * 500);              /* evm sum: mean L1 per pilot = 1000 */
		wr16(rec + 20, (20u << 10) | 512);
		wr16(rec + 22, 0x4000);
		if (cod) {
			wr16(rec + 24, (uint16_t)-300);                 /* noise code */
			wr16(rec + 26, 7);                              /* bad subcarriers */
			wr16(rec + 28, (uint16_t)203);                  /* snr_min code */
			wr16(rec + 30, 379);                            /* snr_avg code */
			wr32(rec + 32, 0x000FFF00u & 0x000FFFFFu);      /* tau = -256 (20 bit two's complement 0xFFF00) */
			rec[35] = 0x03;                                 /* mode bits */
			wr16(rec + 36, 11);                             /* iteration sum */
			rec[38] = 4;                                    /* iteration max */
			rec[39] = 1;                                    /* failed codewords */
			wr32(rec + 40, (uint32_t)-5000000);             /* slope */
			wr32(rec + 44, 0x12340000u);                    /* first angle */
		}
		app_build(pay, nsyms, 5, 7, 0, -4000, 2450000, 1);
		memcpy(rec + 8 * nh, pay, n);
		memset(stream, 0xEE, 16);
		memcpy(stream + 16, rec, rb);
		struct phy_rec pr;
		size_t skip, used = phy_parse(stream, 16 + rb - 8, n, &pr, &skip);
		if (used) { printf("selftest: parsed an incomplete record\n"); errs++; }
		used = phy_parse(stream, 16 + rb, n, &pr, &skip);
		if (used != 16 + rb || skip != 16 || pr.seq != 77 || pr.n_best != 4242 || pr.cfo_inc != -1000000 || pr.angle16 != 0x4000) {
			printf("selftest: record parse failed (used %zu skip %zu)\n", used, skip);
			errs++;
		}
		if (cod && (pr.version != 3 || pr.snr_avg_code != 379 || pr.snr_min_code != 203 || pr.bad_sc != 7 || pr.noise_code != -300 ||
			    pr.tau_q8 != -256 || pr.ldpc_iter_sum != 11 || pr.ldpc_iter_max != 4 || pr.ldpc_fail != 1 || pr.slope != -5000000 ||
			    pr.angle_first != 0x12340000u || pr.mode_bits != 3)) {
			printf("selftest: v3 fields wrong (snr %d/%d bad %u noise %d tau %d it %u/%u fail %u slope %d)\n", pr.snr_avg_code, pr.snr_min_code,
			       pr.bad_sc, pr.noise_code, pr.tau_q8, pr.ldpc_iter_sum, pr.ldpc_iter_max, pr.ldpc_fail, pr.slope);
			errs++;
		}
		double evm = evm_pct(pr.evm_sum, nsyms);
		if (fabs(evm - 100.0 * 0.8862 * 1000.0 / CONST_RMS) > 1e-9) {
			printf("selftest: evm %.4f\n", evm);
			errs++;
		}
		double cfo = cfo_hz(pr.cfo_inc);
		if (fabs(cfo - 1000000.0 * 30720000.0 / 4294967296.0) > 1e-6) { printf("selftest: cfo %.3f\n", cfo); errs++; }
		double rs = rssi_dbfs(pr.rssi_code);
		double expect = 10 * log10(ldexp(1.5, 20) * 256 / 1024 / (2048.0 * 2048.0));
		if (fabs(rs - expect) > 1e-9) { printf("selftest: rssi %.3f vs %.3f\n", rs, expect); errs++; }
	}
	printf("selftest %s\n", errs ? "FAILED" : "passed");
	return errs != 0;
}

/* ====================================================================================================================== */
int main(int argc, char **argv)
{
	if (argc < 2) {
		usage();
		return 2;
	}
	crc_init();
	if (!strcmp(argv[1], "selftest"))
		return selftest();
	struct opts o;
	if (parse_opts(argc, argv, &o)) {
		usage();
		return 2;
	}
	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);
	if (!strcmp(argv[1], "tx"))
		return run_tx(&o);
	if (!strcmp(argv[1], "rx"))
		return run_rx(&o);
	if (!strcmp(argv[1], "diag"))
		return run_diag(&o);
	usage();
	return 2;
}
