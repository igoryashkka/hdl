/*
 * beamd -- software beamforming daemon for the OFDM PHY (TestTask006)
 *
 *   beamd leader   [opts]   board A1: EPOCH leader, JP5 bus leader, sounding + data packets of its two channels, applies the
 *                           anchor's parameters (own channels via commit, the follower's via a PARAMS bus frame)
 *   beamd follower [opts]   board A2: EPOCH / bus follower, sounding + data packets of its two channels (parameters come over JP5)
 *   beamd single   [opts]   one board, two channels (milestone M1): leader without a follower
 *   beamd anchor   [opts]   board B (stock bitstream): IQ capture, sounding detection, channel estimation, Kalman filters,
 *                           parameters -> UDP (lab: PC relay -> leader) or, with --fb radio, a DBPSK burst on --fb-freq that the
 *                           leader receives with its own RX path (fbmodem.h, TestTask006 M4)
 *   beamd estimate FILE     run the anchor estimator on an int16 IQ file and print one CSV line per sounding (checked against
 *                           python/bf_anchor.py by sw/beamd/check_estimate.py)
 *   beamd selftest          host self-checks (CRC16, FFT, LTS, estimator on a synthetic packet)
 *
 * PHY side: phy_tx_axis_top BF=1 registers at 0x7C440000 (see rtl/tx/phy_tx_axis_top.v header). Algorithms mirror
 * python/bf_anchor.py (estimator, Kalman, controller) and python/bf_ref.py (units, bus frames).
 * Time base of the anchor: the sounding pattern encodes the epoch number modulo 8 (S0 -> S1 gap = 12000 + 64 * (e mod 8)); the
 * anchor counts epochs with it (wall clock resolves the multiple of 8), so dt between soundings is exact even when capture
 * blocks are lost: t = epoch * Tp + (arrival - arrival of S0) / fs + slot0 / fs, Tp = epoch period in B time.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>

#define VERSION "0.1.0"
#define PHY_BASE 0x7C440000u
#define PHY_SPAN 0x1000u
#define FS 30720000.0
#define NFFT 2048
#define LHALF 1024
#define CP 144
#define SYM 2192
#define NACT 1200
#define PILOT_AMP 12288.0
#define LTS_SEED 0x2B5D
#define BYTES_RANGE 135
#define ID_TX 0x4F465458u
#define MSG_MAGIC 0x4D504642u /* 'BFPM' */
#define NANT_MAX 4

/* PHY registers (BF = 1) */
#define R_CTRL 0x04
#define R_SNAP 0x08
#define R_CFG(i) ((i) < 28 ? 0x10 + 4 * (i) : 0x400 + 4 * ((i) - 28))
#define R_ST(i) (0x80 + 4 * (i))
#define P_COMMIT 0x04
#define P_BUSSEND 0x08
#define P_SETEP 0x10
#define P_FORCE 0x20

static const int SLOT_BASE[4] = {1000, 13000, 27000, 43000};
#define SLOT_STEP 64
#define LD_DEFAULT 60000

static volatile sig_atomic_t g_stop;
static void on_sig(int s) { (void)s; g_stop = 1; }
static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}
static int slot_of(int ant, uint32_t epoch) { return SLOT_BASE[ant] + (ant == 1 ? SLOT_STEP * (int)(epoch % 8) : 0); }

/* ================================================================================================= CRC16-CCITT, little endian */
static uint16_t crc16(const uint8_t *p, size_t n)
{
	uint16_t c = 0xFFFF;
	for (size_t i = 0; i < n; i++) {
		c ^= (uint16_t)p[i] << 8;
		for (int b = 0; b < 8; b++)
			c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
	}
	return c;
}
static void le16(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; }
static void le32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

/* channel parameters, bf_ref.py units */
struct chpar {
	uint16_t amp, phase;
	int16_t tau;
	uint16_t ctrl; /* bit0 weights, bit1 NCO */
	int32_t rho;
	uint32_t inc;
};
struct bf_msg {
	uint32_t magic, seq;
	uint8_t target_mod8, nboards;
	uint16_t flags;
	struct chpar ch[2][2];
	float snr_db[NANT_MAX];
	float nu_hz[2];
};

static size_t frame_build(uint8_t *f, uint8_t type, uint8_t seq, const uint8_t *pay, uint8_t n)
{
	f[0] = 0xA5; f[1] = 0x5A; f[2] = type; f[3] = seq; f[4] = n;
	memcpy(f + 5, pay, n);
	uint16_t c = crc16(f + 2, 3 + n);
	f[5 + n] = c >> 8; f[6 + n] = c & 0xFF;
	return 7 + n;
}
static void chpar_put(uint8_t *p, const struct chpar *c)
{
	le16(p, c->amp); le16(p + 2, c->phase); le16(p + 4, (uint16_t)c->tau); le16(p + 6, c->ctrl);
	le32(p + 8, (uint32_t)c->rho); le32(p + 12, c->inc);
}
static size_t params_frame(uint8_t *f, uint8_t seq, uint32_t target, const struct chpar ch[2])
{
	uint8_t pay[36];
	le32(pay, target);
	chpar_put(pay + 4, &ch[0]);
	chpar_put(pay + 20, &ch[1]);
	return frame_build(f, 0x01, seq, pay, 36);
}

/* ================================================================================================= sysfs / iio / registers */
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
static int dev_set(int idx, const char *attr, const char *val)
{
	char p[160];
	snprintf(p, sizeof p, "/sys/bus/iio/devices/iio:device%d/%s", idx, attr);
	int e = sysfs_write(p, val);
	if (e)
		fprintf(stderr, "  warn: %s = %s: %s\n", attr, val, strerror(-e));
	return e;
}

static volatile uint32_t *g_regs;
static int regs_open(void)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
		return -1;
	}
	void *m = mmap(NULL, PHY_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, PHY_BASE);
	if (m == MAP_FAILED) {
		fprintf(stderr, "mmap: %s\n", strerror(errno));
		return -1;
	}
	g_regs = m;
	return 0;
}
static inline uint32_t rreg(unsigned off) { return g_regs[off >> 2]; }
static inline void wreg(unsigned off, uint32_t v) { g_regs[off >> 2] = v; }
static int snapshot(uint32_t *st, int n)
{
	wreg(R_SNAP, 1);
	for (int i = 0; i < 4000; i++) {
		if (rreg(R_SNAP) & 1) {
			for (int k = 0; k < n; k++)
				st[k] = rreg(R_ST(k));
			return 0;
		}
		usleep(20);
	}
	return -1;
}

struct rfcfg { double freq, bw, tx_gain, rx_gain; };
static int rf_setup(const struct rfcfg *c, int tx)
{
	int phy = iio_find("ad9361-phy");
	if (phy < 0) {
		fprintf(stderr, "ad9361-phy not found\n");
		return -1;
	}
	char v[64];
	dev_set(phy, "ensm_mode", "fdd");
	snprintf(v, sizeof v, "%.0f", FS);
	dev_set(phy, "in_voltage_sampling_frequency", v);
	dev_set(phy, "out_voltage_sampling_frequency", v);
	snprintf(v, sizeof v, "%.0f", c->bw);
	dev_set(phy, "in_voltage_rf_bandwidth", v);
	dev_set(phy, "out_voltage_rf_bandwidth", v);
	snprintf(v, sizeof v, "%.0f", c->freq);
	dev_set(phy, "out_altvoltage0_RX_LO_frequency", v);
	dev_set(phy, "out_altvoltage1_TX_LO_frequency", v);
	if (tx) {
		snprintf(v, sizeof v, "%.2f", c->tx_gain);
		dev_set(phy, "out_voltage0_hardwaregain", v);
		dev_set(phy, "out_voltage1_hardwaregain", v);
	} else {
		dev_set(phy, "in_voltage0_gain_control_mode", "manual");
		snprintf(v, sizeof v, "%.2f", c->rx_gain);
		dev_set(phy, "in_voltage0_hardwaregain", v);
	}
	return phy;
}

struct stream { int fd, dev, bps; };
static int stream_open(struct stream *s, const char *devname, const char *prefix, size_t block_bytes, int rd)
{
	memset(s, 0, sizeof *s);
	s->fd = -1;
	s->dev = iio_find(devname);
	if (s->dev < 0) {
		fprintf(stderr, "IIO device %s not found\n", devname);
		return -1;
	}
	char a[96], v[32];
	dev_set(s->dev, "buffer/enable", "0");
	int n = 0;
	for (int i = 0; i < 4; i++) {
		snprintf(a, sizeof a, "scan_elements/%s%d_en", prefix, i);
		char p[160];
		snprintf(p, sizeof p, "/sys/bus/iio/devices/iio:device%d/%s", s->dev, a);
		if (sysfs_write(p, (rd && i >= 2) ? "0" : "1") == 0 && !(rd && i >= 2))
			n++;
	}
	s->bps = 2 * n;
	snprintf(v, sizeof v, "%zu", block_bytes / s->bps);
	dev_set(s->dev, "buffer/length", v);
	if (dev_set(s->dev, "buffer/enable", "1"))
		return -1;
	snprintf(a, sizeof a, "/dev/iio:device%d", s->dev);
	s->fd = open(a, rd ? O_RDONLY : O_WRONLY);
	if (s->fd < 0) {
		fprintf(stderr, "open %s: %s\n", a, strerror(errno));
		return -1;
	}
	return 0;
}
static void stream_close(struct stream *s)
{
	if (s->fd >= 0)
		close(s->fd);
	if (s->dev >= 0)
		dev_set(s->dev, "buffer/enable", "0");
}

/* ================================================================================================= DSP: FFT, LTS, estimator */
typedef struct { double re, im; } cplx;
static inline cplx cmul(cplx a, cplx b) { return (cplx){a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re}; }
static inline cplx cconjmul(cplx a, cplx b) { return (cplx){a.re * b.re + a.im * b.im, a.re * b.im - a.im * b.re}; } /* conj(a) b */
static inline double cabs2(cplx a) { return a.re * a.re + a.im * a.im; }
static inline cplx cexpj(double ph) { return (cplx){cos(ph), sin(ph)}; }

static void fft(cplx *x, int n)
{
	for (int i = 1, j = 0; i < n; i++) {
		int b = n >> 1;
		for (; j & b; b >>= 1)
			j ^= b;
		j ^= b;
		if (i < j) { cplx t = x[i]; x[i] = x[j]; x[j] = t; }
	}
	for (int len = 2; len <= n; len <<= 1) {
		double a = -2 * M_PI / len;
		cplx w = cexpj(a);
		for (int i = 0; i < n; i += len) {
			cplx u = {1, 0};
			for (int k = 0; k < len / 2; k++) {
				cplx p = cmul(x[i + k + len / 2], u);
				cplx q = x[i + k];
				x[i + k] = (cplx){q.re + p.re, q.im + p.im};
				x[i + k + len / 2] = (cplx){q.re - p.re, q.im - p.im};
				u = cmul(u, w);
			}
		}
	}
}

static int g_act[NACT];      /* active bins sorted by signed frequency (-600 .. -1, 1 .. 600) */
static int g_ks[NACT];       /* signed bin index */
static double g_lts[NACT];   /* LTS value on those bins */
static int g_lag_n[3];
static int *g_lag_p[3];      /* pairs (i, j) with ks[j] = ks[i] + m on the same side of DC */
static const int LAGS[3] = {1, 16, 128};

static int s_of_bin(int b)
{
	if (b >= 1 && b <= 600) return b - 1;
	if (b >= NFFT - 600 && b < NFFT) return 600 + b - (NFFT - 600);
	return -1;
}
static void dsp_init(void)
{
	double lts_nat[NFFT] = {0};
	int s = LTS_SEED, k = 0;
	for (int b = 0; b < NFFT; b++) {
		if (s_of_bin(b) < 0) continue;
		int fb = ((s >> 14) ^ (s >> 13)) & 1;
		s = ((s << 1) | fb) & 0x7FFF;
		lts_nat[b] = fb ? -PILOT_AMP : PILOT_AMP;
		k++;
	}
	int i = 0;
	for (int b = NFFT - 600; b < NFFT; b++) { g_act[i] = b; g_ks[i] = b - NFFT; g_lts[i] = lts_nat[b]; i++; }
	for (int b = 1; b <= 600; b++) { g_act[i] = b; g_ks[i] = b; g_lts[i] = lts_nat[b]; i++; }
	for (int l = 0; l < 3; l++) {
		g_lag_p[l] = malloc(sizeof(int) * 2 * NACT);
		int n = 0;
		for (int a = 0; a < NACT; a++)
			for (int c = a + 1; c < NACT && g_ks[c] - g_ks[a] <= LAGS[l]; c++)
				if (g_ks[c] - g_ks[a] == LAGS[l] && ((g_ks[a] > 0) == (g_ks[c] > 0))) {
					g_lag_p[l][2 * n] = a; g_lag_p[l][2 * n + 1] = c; n++;
				}
		g_lag_n[l] = n;
	}
}

struct est { double t, f, phi, amp, snr_db; long s_sync; int ok; };

/* delay of H(k) ~ exp(-j 2 pi ks d / N): lag cascade 1, 16, 128 + least squares of the residual phase (bf_anchor.delay_est) */
static double delay_est(const cplx *H)
{
	static cplx Hc[NACT];
	double d = 0;
	for (int l = 0; l < 3; l++) {
		for (int i = 0; i < NACT; i++) Hc[i] = cmul(H[i], cexpj(2 * M_PI * g_ks[i] * d / NFFT));
		cplx acc = {0, 0};
		for (int n = 0; n < g_lag_n[l]; n++) {
			cplx p = cconjmul(Hc[g_lag_p[l][2 * n]], Hc[g_lag_p[l][2 * n + 1]]);
			acc.re += p.re; acc.im += p.im;
		}
		d += -atan2(acc.im, acc.re) * NFFT / (2 * M_PI * LAGS[l]);
	}
	cplx m = {0, 0};
	for (int i = 0; i < NACT; i++) { Hc[i] = cmul(H[i], cexpj(2 * M_PI * g_ks[i] * d / NFFT)); m.re += Hc[i].re; m.im += Hc[i].im; }
	double sw = 0, swk = 0;
	for (int i = 0; i < NACT; i++) { double w = sqrt(cabs2(Hc[i])); sw += w; swk += w * g_ks[i]; }
	double kc = swk / sw, num = 0, den = 0;
	for (int i = 0; i < NACT; i++) {
		cplx r = cconjmul(m, Hc[i]);
		double ph = atan2(r.im, r.re), w = sqrt(cabs2(Hc[i])), k = g_ks[i] - kc;
		num += w * k * ph; den += w * k * k;
	}
	return d - (num / den) * NFFT / (2 * M_PI);
}

/* one sounding packet: s_sync = sync body start in x[] (bf_anchor.estimate) */
static struct est estimate(const cplx *x, long n, long s_sync, cplx psum)
{
	struct est e = {0};
	static cplx Y[NFFT], H[NACT];
	e.f = atan2(psum.im, psum.re) / (2 * M_PI * LHALF) * FS;
	long w0 = s_sync + SYM - 32;
	if (w0 < 0 || w0 + NFFT > n)
		return e;
	for (int i = 0; i < NFFT; i++) Y[i] = cmul(x[w0 + i], cexpj(-2 * M_PI * e.f * i / FS));
	fft(Y, NFFT);
	for (int i = 0; i < NACT; i++) H[i] = (cplx){Y[g_act[i]].re / g_lts[i], Y[g_act[i]].im / g_lts[i]};
	double d = delay_est(H);
	cplx g = {0, 0};
	for (int i = 0; i < NACT; i++) { H[i] = cmul(H[i], cexpj(2 * M_PI * g_ks[i] * d / NFFT)); g.re += H[i].re / NACT; g.im += H[i].im / NACT; }
	double nz = 0;
	for (int i = 0; i < NACT; i++) nz += cabs2((cplx){H[i].re - g.re, H[i].im - g.im}) / NACT;
	e.t = w0 + d;
	e.phi = atan2(g.im, g.re) + 2 * M_PI * e.f * d / FS;
	e.amp = sqrt(cabs2(g));
	e.snr_db = 10 * log10(cabs2(g) / (nz > 1e-30 ? nz : 1e-30));
	e.s_sync = s_sync;
	e.ok = 1;
	return e;
}

/* Schmidl-Cox over x[0..n): packets as (sync body start, P sum) (bf_anchor.detect); returns count */
static int detect(const cplx *x, long n, long *start, cplx *psum, int max, double thr)
{
	long m = n - 2 * LHALF + 1;
	if (m <= 0) return 0;
	cplx P = {0, 0};
	double R = 0;
	for (int k = 0; k < LHALF; k++) {
		cplx p = cconjmul(x[k], x[k + LHALF]);
		P.re += p.re; P.im += p.im; R += cabs2(x[k + LHALF]);
	}
	int cnt = 0;
	long seg0 = -1, last = -100000;
	double mx = 0;
	static double M[1 << 20];
	static cplx PP[1 << 20];
	if (m > (1 << 20)) m = 1 << 20;
	for (long i = 0; i < m; i++) {
		M[i] = cabs2(P) / ((R > 1e-12 ? R : 1e-12) * (R > 1e-12 ? R : 1e-12));
		PP[i] = P;
		if (i + 2 * LHALF < n) {                                 /* slide */
			cplx a = cconjmul(x[i], x[i + LHALF]), b = cconjmul(x[i + LHALF], x[i + 2 * LHALF]);
			P.re += b.re - a.re; P.im += b.im - a.im;
			R += cabs2(x[i + 2 * LHALF]) - cabs2(x[i + LHALF]);
		}
	}
	for (long i = 0; i <= m; i++) {
		int above = (i < m) && M[i] > thr;
		if (above && seg0 < 0) { seg0 = i; mx = 0; }
		if (above && M[i] > mx) mx = M[i];
		if (!above && seg0 >= 0) {
			long len = i - seg0;
			if (len > CP / 4) {
				long s_end = -1;
				cplx ps = {0, 0};
				for (long k = seg0; k < i; k++)
					if (M[k] > 0.9 * mx) { s_end = k; ps.re += PP[k].re; ps.im += PP[k].im; }
				if (s_end - last > 3 * SYM && cnt < max) {
					start[cnt] = s_end; psum[cnt] = ps; cnt++; last = s_end;
				}
			}
			seg0 = -1;
		}
	}
	return cnt;
}

/* slot pattern: nant 4 -> (S0, S1, S2, S3), nant 2 -> (S0, S1); -> index of S0 in start[] and e mod 8, or -1 */
static int assign(const long *t, int n, int nant, int *m8)
{
	const int tol = 24;
	for (int i = 0; i + nant <= n; i++) {
		double g1 = t[i + 1] - t[i] - (SLOT_BASE[1] - SLOT_BASE[0]);
		double mm = g1 / SLOT_STEP;
		int mi = (int)lround(mm);
		if (mi < 0 || mi > 7 || fabs(mm - mi) * SLOT_STEP >= tol) continue;
		if (nant == 4 && (labs(t[i + 2] - t[i] - (SLOT_BASE[2] - SLOT_BASE[0])) >= tol || labs(t[i + 3] - t[i + 2] - (SLOT_BASE[3] - SLOT_BASE[2])) >= tol))
			continue;
		*m8 = mi;
		return i;
	}
	return -1;
}

#include "fbmodem.h"

/* ================================================================================================= Kalman + controller */
struct kal { int init, nacc; double x[3], P[3][3], q, rp, rf, acc; };
static void kal_F(double dt, double F[3][3])
{
	double f[3][3] = {{1, 2 * M_PI * dt, M_PI * dt * dt}, {0, 1, dt}, {0, 0, 1}};
	memcpy(F, f, sizeof f);
}
static void mat3_mul(double A[3][3], double B[3][3], double C[3][3])
{
	double T[3][3];
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++) {
			T[i][j] = 0;
			for (int k = 0; k < 3; k++) T[i][j] += A[i][k] * B[k][j];
		}
	memcpy(C, T, sizeof T);
}
static void kal_predict(struct kal *k, double dt)
{
	double F[3][3], Ft[3][3];
	kal_F(dt, F);
	double x[3];
	for (int i = 0; i < 3; i++) x[i] = F[i][0] * k->x[0] + F[i][1] * k->x[1] + F[i][2] * k->x[2];
	memcpy(k->x, x, sizeof x);
	for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) Ft[i][j] = F[j][i];
	mat3_mul(F, k->P, k->P);
	mat3_mul(k->P, Ft, k->P);
	double t2 = 2 * M_PI, q = k->q;
	double Q[3][3] = {{q * t2 * t2 * pow(dt, 5) / 20, q * t2 * pow(dt, 4) / 8, q * t2 * pow(dt, 3) / 6},
	                  {q * t2 * pow(dt, 4) / 8, q * pow(dt, 3) / 3, q * dt * dt / 2},
	                  {q * t2 * pow(dt, 3) / 6, q * dt * dt / 2, q * dt}};
	for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) k->P[i][j] += Q[i][j];
}
/* dt: prediction interval; dt_alias: time since the previous measurement. Alias guard (bf_anchor.Kalman): phases measured once
 * per epoch cannot tell frequencies k / dt_alias apart, so the coarse CFO is averaged against the state over 8 updates and the
 * state is moved by k / dt_alias when the mean exceeds half a step. */
static void kal_update(struct kal *k, double dt, double ph, double f, double dt_alias)
{
	if (!k->init) {
		k->x[0] = ph; k->x[1] = f; k->x[2] = 0;
		memset(k->P, 0, sizeof k->P);
		k->P[0][0] = 10; k->P[1][1] = 1e6; k->P[2][2] = 1e4;
		k->acc = 0; k->nacc = 0;
		k->init = 1;
		return;
	}
	kal_predict(k, dt);
	if (dt_alias > 0) {
		k->acc += f - k->x[1];
		if (++k->nacc >= 8) {
			double m = k->acc / k->nacc;
			long n = lround(m * dt_alias);
			if (n) k->x[1] += n / dt_alias;
			k->acc = 0; k->nacc = 0;
		}
	}
	double z0 = k->x[0] + remainder(ph - k->x[0], 2 * M_PI);
	double S[2][2] = {{k->P[0][0] + k->rp, k->P[0][1]}, {k->P[1][0], k->P[1][1] + k->rf}};
	double det = S[0][0] * S[1][1] - S[0][1] * S[1][0];
	double Si[2][2] = {{S[1][1] / det, -S[0][1] / det}, {-S[1][0] / det, S[0][0] / det}};
	double K[3][2];
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 2; j++) K[i][j] = k->P[i][0] * Si[0][j] + k->P[i][1] * Si[1][j];
	double y0 = z0 - k->x[0], y1 = f - k->x[1];
	for (int i = 0; i < 3; i++) k->x[i] += K[i][0] * y0 + K[i][1] * y1;
	double P[3][3];
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++) P[i][j] = k->P[i][j] - (K[i][0] * k->P[0][j] + K[i][1] * k->P[1][j]);
	memcpy(k->P, P, sizeof P);
}

struct ctl {
	int nant, D, ld;
	double fc, period_s;                 /* epoch period (s) */
	struct kal kf[NANT_MAX];
	double t_last[NANT_MAX];
	struct est meas[NANT_MAX];
	double slot[NANT_MAX];
	double nco[2];                       /* Hz in force per board */
	int nev;
	struct { double t, d; int b; } ev[16];
};
static int board_of(int a) { return a / 2; }
static void ctl_nco_change(struct ctl *c, double t, int b, double hz)
{
	double d = hz - c->nco[b];
	if (d != 0 && c->nev < 16) { c->ev[c->nev].t = t; c->ev[c->nev].d = d; c->ev[c->nev].b = b; c->nev++; }
	c->nco[b] = hz;
}
static void ctl_update(struct ctl *c, const struct est *e, const double *t, const double *slot)
{
	for (int a = 0; a < c->nant; a++) {
		c->slot[a] = slot[a];
		if (!e[a].ok) continue;
		struct kal *k = &c->kf[a];
		if (!k->init) kal_update(k, 0, e[a].phi, e[a].f, 0);
		else {
			double tt = c->t_last[a];
			for (int i = 0; i < c->nev; i++)
				if (c->ev[i].b == board_of(a) && c->ev[i].t > tt && c->ev[i].t <= t[a]) {
					kal_predict(k, c->ev[i].t - tt); k->x[1] += c->ev[i].d; tt = c->ev[i].t;
				}
			kal_update(k, t[a] - tt, e[a].phi, e[a].f, t[a] - c->t_last[a]);
		}
		c->t_last[a] = t[a];
		c->meas[a] = e[a];
	}
	double tmin = 1e300;
	for (int a = 0; a < c->nant; a++) if (c->kf[a].init && c->t_last[a] < tmin) tmin = c->t_last[a];
	int j = 0;
	for (int i = 0; i < c->nev; i++) if (c->ev[i].t > tmin) c->ev[j++] = c->ev[i];
	c->nev = j;
}
/* state of antenna a propagated to t (NCO steps of its board applied), without changing the filter */
static void ctl_advance(const struct ctl *c, int a, double t_to, double x[3])
{
	const struct kal *k = &c->kf[a];
	double t = c->t_last[a], F[3][3], y[3];
	memcpy(x, k->x, sizeof k->x);
	for (int i = 0; i < c->nev; i++)
		if (c->ev[i].b == board_of(a) && c->ev[i].t > t && c->ev[i].t <= t_to) {
			kal_F(c->ev[i].t - t, F);
			for (int r = 0; r < 3; r++) y[r] = F[r][0] * x[0] + F[r][1] * x[1] + F[r][2] * x[2];
			memcpy(x, y, sizeof y); x[1] += c->ev[i].d; t = c->ev[i].t;
		}
	kal_F(t_to - t, F);
	for (int r = 0; r < 3; r++) y[r] = F[r][0] * x[0] + F[r][1] * x[1] + F[r][2] * x[2];
	memcpy(x, y, sizeof y);
}
/* NCO of board b in force at time t (scheduled steps after t not yet effective) */
static double ctl_nco_at(const struct ctl *c, int b, double t)
{
	double v = c->nco[b];
	for (int i = 0; i < c->nev; i++)
		if (c->ev[i].b == b && c->ev[i].t > t) v -= c->ev[i].d;
	return v;
}
/* parameters taking effect at the tick t_tick (s), data at t_data (s) (bf_anchor.Controller.params) */
static void ctl_params(const struct ctl *c, double t_tick, double t_data, int mrt, struct chpar out[2][2], double nco_new[2])
{
	int nb = (c->nant + 1) / 2;
	double raw[2] = {0, 0};
	for (int b = 0; b < nb; b++) raw[b] = c->kf[2 * b].x[1] - ctl_nco_at(c, b, c->t_last[2 * b]);
	nco_new[0] = 0;
	nco_new[1] = nb > 1 ? -(raw[1] - raw[0]) : 0;
	double ph[NANT_MAX], amp[NANT_MAX], amax = 1e-30;
	for (int a = 0; a < c->nant; a++) {
		double x[3], F[3][3], y[3];
		ctl_advance(c, a, t_tick, x);
		x[1] += nco_new[board_of(a)] - c->nco[board_of(a)];
		kal_F(t_data - t_tick, F);
		for (int r = 0; r < 3; r++) y[r] = F[r][0] * x[0] + F[r][1] * x[1] + F[r][2] * x[2];
		ph[a] = y[0];
		amp[a] = c->meas[a].amp;
		if (amp[a] > amax) amax = amp[a];
	}
	for (int a = 0; a < c->nant; a++) {
		int b = board_of(a), ch = a % 2;
		double eps_b = raw[b] / c->fc, eps0 = raw[0] / c->fc;
		double rho = -(eps_b - eps0);
		double off_slot = (c->meas[a].t - c->slot[a]) - (c->meas[0].t - c->slot[0]);
		double off_data = off_slot + rho * (c->ld - c->slot[a]);
		double tau_set = off_data - rho * c->ld;
		double phw = -(ph[a] - ph[0]);
		struct chpar *p = &out[b][ch];
		p->amp = (uint16_t)lround(32767.0 * (mrt ? amp[a] / amax : 1.0));
		p->phase = (uint16_t)((long)lround(phw / (2 * M_PI) * 65536.0) & 0xFFFF);
		p->tau = (int16_t)lround(tau_set * 256);
		p->rho = (int32_t)lround(rho * 4294967296.0);
		p->inc = (uint32_t)((int64_t)llround(nco_new[b] / FS * 4294967296.0) & 0xFFFFFFFF);
		p->ctrl = 1 | (b ? 2 : 0);
	}
}

/* ================================================================================================= options */
struct opts {
	double freq, tx_gain, rx_gain, epoch_ms;
	int nant, D, data, ld, port, mrt, nsyms, verbose, data_mask, hold;
	double seconds;                      /* run time, 0 = until Ctrl-C */
	long bus_test;                       /* leader: send this many PARAMS frames over JP5 and check the follower's answers */
	double bus_rate;                     /* bus test: frames per second (0 = as fast as the answers come) */
	int fb;                              /* feedback: 0 UDP (lab relay), 1 radio burst (fbmodem.h) */
	double fb_freq, fb_gain;
	char relay[64], log[128], file[200];
	uint32_t epoch0;
	long cap;                            /* anchor capture block (samples) */
};
static void usage(void)
{
	printf("beamd " VERSION " -- software beamforming (TestTask006)\n"
	       "usage: beamd leader|follower|single|anchor [opts]   beamd estimate FILE   beamd selftest\n"
	       "  --freq HZ (2450e6)  --tx-gain DB (-10)  --rx-gain DB (40)  --epoch MS (10)  --D N (2)  --ld N (60000)\n"
	       "  --no-data (soundings only)  --data-mask 1|2|3 (channels of the data packet, 3)  --hold (ignore the anchor: unit weights)\n"
	       "  --nant 4|2  --equal-gain  --port N (5005)  --relay IP[:PORT] (anchor: where to send)\n"
	       "  --fb udp|radio (feedback path, udp)  --fb-freq HZ (2470e6)  --fb-gain DB (B transmit level of the burst, -20)\n"
	       "  --log PREFIX (/tmp/beamd)  --cap SAMPLES (anchor capture block, 524288)  --epoch0 N (100)  --seconds S  -v\n"
	       "  --bus-test N       leader: send N PARAMS frames over JP5 (the follower must run), count answers, compare the epoch numbers\n");
}
static int parse(int argc, char **argv, struct opts *o)
{
	*o = (struct opts){.freq = 2450e6, .tx_gain = -10, .rx_gain = 40, .epoch_ms = 10, .nant = 4, .D = 2, .data = 1, .ld = LD_DEFAULT,
	                   .port = 5005, .mrt = 1, .nsyms = 1, .epoch0 = 100, .cap = 524288, .data_mask = 3, .fb_freq = 2470e6, .fb_gain = -20};
	snprintf(o->log, sizeof o->log, "/tmp/beamd");
	snprintf(o->relay, sizeof o->relay, "192.168.3.10:5005");
	for (int i = 2; i < argc; i++) {
#define ARG(x) (!strcmp(argv[i], x) && i + 1 < argc)
		if (ARG("--freq")) o->freq = atof(argv[++i]);
		else if (ARG("--tx-gain")) o->tx_gain = atof(argv[++i]);
		else if (ARG("--rx-gain")) o->rx_gain = atof(argv[++i]);
		else if (ARG("--epoch")) o->epoch_ms = atof(argv[++i]);
		else if (ARG("--D")) o->D = atoi(argv[++i]);
		else if (ARG("--ld")) o->ld = atoi(argv[++i]);
		else if (ARG("--nant")) o->nant = atoi(argv[++i]);
		else if (ARG("--port")) o->port = atoi(argv[++i]);
		else if (ARG("--relay")) snprintf(o->relay, sizeof o->relay, "%s", argv[++i]);
		else if (ARG("--log")) snprintf(o->log, sizeof o->log, "%s", argv[++i]);
		else if (ARG("--cap")) o->cap = atol(argv[++i]);
		else if (ARG("--epoch0")) o->epoch0 = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--no-data")) o->data = 0;
		else if (ARG("--data-mask")) o->data_mask = atoi(argv[++i]) & 3;
		else if (!strcmp(argv[i], "--hold")) o->hold = 1;
		else if (ARG("--seconds")) o->seconds = atof(argv[++i]);
		else if (ARG("--bus-test")) o->bus_test = atol(argv[++i]);
		else if (ARG("--bus-rate")) o->bus_rate = atof(argv[++i]);
		else if (ARG("--fb")) o->fb = !strcmp(argv[++i], "radio");
		else if (ARG("--fb-freq")) o->fb_freq = atof(argv[++i]);
		else if (ARG("--fb-gain")) o->fb_gain = atof(argv[++i]);
		else if (!strcmp(argv[i], "--equal-gain")) o->mrt = 0;
		else if (!strcmp(argv[i], "-v")) o->verbose = 1;
		else if (argv[i][0] != '-' && !o->file[0]) snprintf(o->file, sizeof o->file, "%s", argv[i]);
		else { fprintf(stderr, "unknown option %s\n", argv[i]); return -1; }
	}
	return 0;
}

/* ================================================================================================= feedback receiver (leader) */
/* RX thread: continuous capture on the feedback LO, energy gate, fbmodem demodulation; the newest message is handed over in g_fb */
#define FB_BLK 65536
static pthread_mutex_t g_fb_mx = PTHREAD_MUTEX_INITIALIZER;
static struct bf_msg g_fb_msg;
static int g_fb_new;
static long g_fb_ok, g_fb_bad;
static void *fb_rx_thread(void *arg)
{
	struct stream *s = arg;
	static int16_t raw[2 * FB_BLK];
	static cplx x[2 * FB_BLK];
	uint32_t last_seq = 0xFFFFFFFF;
	long have = 0;                                       /* samples kept from the previous block (burst across blocks) */
	while (!g_stop) {
		size_t want = (size_t)FB_BLK * 4, got = 0;
		while (got < want && !g_stop) {
			ssize_t r = read(s->fd, (uint8_t *)raw + got, want - got);
			if (r < 0) { if (errno == EINTR) continue; return NULL; }
			got += (size_t)r;
		}
		for (long i = 0; i < FB_BLK; i++) x[have + i] = (cplx){raw[2 * i], raw[2 * i + 1]};
		long n = have + FB_BLK;
		/* energy gate: 256-sample segments, peak against the median-ish floor (mean of the lower half) */
		double emax = 0, esum = 0;
		int ne = (int)(n / 256);
		for (int i = 0; i < ne; i++) {
			double a = 0;
			for (int j = 0; j < 256; j += 4) a += cabs2(x[256 * i + j]);
			esum += a; if (a > emax) emax = a;
		}
		struct bf_msg m;
		double corr;
		long pos;
		/* search only around the burst: from a little before the first segment above emax / 4, burst length + margin */
		long w0 = 0, wl = n;
		if (ne && emax > 4.0 * esum / ne) {
			long first = 0;
			for (int i = 0; i < ne; i++) {
				double a = 0;
				for (int j = 0; j < 256; j += 4) a += cabs2(x[256 * i + j]);
				if (a > emax / 4) { first = i; break; }
			}
			w0 = 256 * first - 2048; if (w0 < 0) w0 = 0;
			wl = (long)fb_nsym(sizeof m) * FB_SPS + 8192; if (w0 + wl > n) wl = n - w0;
		}
		if (ne && emax > 4.0 * esum / ne && fb_demod(x + w0, wl, (uint8_t *)&m, sizeof m, &corr, &pos) && m.magic == MSG_MAGIC) {
			if (m.seq != last_seq) {
				pthread_mutex_lock(&g_fb_mx); g_fb_msg = m; g_fb_new = 1; g_fb_ok++; pthread_mutex_unlock(&g_fb_mx);
				last_seq = m.seq;
			}
		} else if (ne && emax > 4.0 * esum / ne) g_fb_bad++;
		/* keep the last 32768 samples for the next search window */
		long keep = 32768;
		memmove(x, x + n - keep, sizeof(cplx) * keep);
		have = keep;
	}
	return NULL;
}

/* ================================================================================================= transmit boards */
static uint8_t g_pay[BYTES_RANGE];
static int queue_packet(struct stream *s, size_t blk, uint16_t flags, uint32_t launch)
{
	static uint8_t buf[8 * 64];
	memset(buf, 0, blk);
	le32(buf, (uint32_t)BYTES_RANGE | ((uint32_t)flags << 16));
	le32(buf + 4, ID_TX);
	le32(buf + 8, launch);
	memcpy(buf + 16, g_pay, BYTES_RANGE);
	size_t off = 0;
	while (off < blk && !g_stop) {
		ssize_t w = write(s->fd, buf + off, blk - off);
		if (w < 0) {
			if (errno == EINTR) continue;
			fprintf(stderr, "dma write: %s\n", strerror(errno));
			return -1;
		}
		off += (size_t)w;
	}
	return 0;
}

/* JP5 bus stress test (M2): PARAMS frames with a varying payload (weights off, so harmless), one per answer. The follower's answer carries
 * its epoch number; it is compared with the leader's epoch read right after the answer (a tick between the two reads gives a +-1 difference). */
static int bus_test(const struct opts *o, uint8_t seq)
{
	uint8_t frm[64];
	long sent = 0, ans_ok_prev = 0, no_answer = 0, hist[5] = {0};  /* leader epoch - follower epoch: <-1, -1, 0, +1, >1 */
	long last_d = 1000, nev = 0;
	uint32_t st[64];
	if (snapshot(st, 64) < 0) { fprintf(stderr, "snapshot timeout\n"); return 1; }
	uint16_t pok = st[25] & 0xFFFF, pbad = st[25] >> 16;      /* previous 16-bit hardware counters */
	long ok_tot = 0, bad_tot = 0;                              /* accumulated across the 16-bit wrap */
	double t0 = now_s(), tlog = t0;
	signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
	printf("bus test: %ld PARAMS frames, SCLK %.2f MHz\n", o->bus_test, FS * 4 / 24 / 1e6);
	while (!g_stop && sent < o->bus_test) {
		struct chpar ch[2] = {{.amp = (uint16_t)(sent * 7), .phase = (uint16_t)(sent * 13), .tau = (int16_t)(sent * 29), .ctrl = 0,
		                       .rho = (int32_t)(sent * 1013904223u), .inc = (uint32_t)(sent * 1664525u)},
		                      {.amp = (uint16_t)(~sent), .phase = (uint16_t)(sent >> 3), .tau = (int16_t)(-sent), .ctrl = 0,
		                       .rho = (int32_t)(sent * 22695477u), .inc = (uint32_t)(sent * 69069u)}};
		size_t n = params_frame(frm, seq++, 0xFFFFFFFFu, ch);
		for (size_t i = 0; i < 48; i += 4) {
			uint32_t w = 0;
			for (int k = 0; k < 4; k++) if (i + k < n) w |= (uint32_t)frm[i + k] << (8 * k);
			wreg(R_CFG(28 + i / 4), w);
		}
		wreg(R_CFG(3), 1u | (12u << 16) | ((uint32_t)n << 24));
		wreg(R_CTRL, P_BUSSEND);
		sent++;
		int got = 0;
		for (int w = 0; w < 4000 && !g_stop; w++) {
			if (snapshot(st, 64) < 0) continue;
			uint16_t cok = st[25] & 0xFFFF, cbad = st[25] >> 16;
			ok_tot += (uint16_t)(cok - pok); bad_tot += (uint16_t)(cbad - pbad); pok = cok; pbad = cbad;
			if (!(st[29] & 1) && (ok_tot + bad_tot) >= sent - no_answer) {      /* frame and answer done */
				if (ok_tot > ans_ok_prev) {
					uint32_t fe = (st[45] >> 24) | ((st[46] & 0xFFFFFFu) << 8);            /* epoch number inside the answer (bytes 7..10) */
					long d = (long)(int32_t)(st[16] - fe);
					hist[d < -1 ? 0 : d > 1 ? 4 : d + 2]++;
					if (d != last_d && nev++ < 60)
						printf("  [%7.3fs] frame %ld: epoch difference %ld -> %ld (leader %u, follower %u)\n", now_s() - t0, sent, last_d, d, st[16], fe);
					last_d = d;
				}
				ans_ok_prev = ok_tot;
				got = 1;
				break;
			}
		}
		if (!got) no_answer++;
		if (o->bus_rate > 0)
			usleep((useconds_t)(1e6 / o->bus_rate));
		double t = now_s();
		if (t - tlog >= 2.0) {
			tlog = t;
			printf("[%6.1fs] sent %ld  answers ok %ld bad %ld  no answer %ld   epoch diff (leader - follower) -1/0/+1: %ld/%ld/%ld\n", t - t0, sent,
			       ok_tot, bad_tot, no_answer, hist[1], hist[2], hist[3]);
		}
	}
	double dt = now_s() - t0;
	printf("bus test done: sent %ld in %.1f s (%.0f frames/s), answers ok %ld, bad %ld, no answer %ld\n", sent, dt, sent / dt, ok_tot, bad_tot, no_answer);
	printf("epoch number leader - follower at the answer: <-1: %ld   -1: %ld   0: %ld   +1: %ld   >+1: %ld\n", hist[0], hist[1], hist[2], hist[3], hist[4]);
	printf("(counters are 16 bit and wrap at 65536; the follower's own rx_ok / crc_err are in its status line)\n");
	return 0;
}

static int run_tx(const struct opts *o, int role /* 1 leader, 2 follower, 3 single */)
{
	if (regs_open() < 0) return 1;
	if (rreg(0x00) != ID_TX || !(rreg(R_ST(31)) & 4)) {        /* status 31 bit2 = BF build */
		fprintf(stderr, "PHY at 0x%08x is not the BF transmitter (ID %08x, feature %08x)\n", PHY_BASE, rreg(0), rreg(R_ST(31)));
		return 1;
	}
	struct rfcfg rf = {o->freq, 18e6, o->tx_gain, o->rx_gain};
	if (rf_setup(&rf, 1) < 0) return 1;
	uint32_t period = (uint32_t)lround(o->epoch_ms * 1e-3 * FS);
	int hwrole = (role == 2) ? 2 : 1;
	wreg(R_CTRL, 1); usleep(1000); wreg(R_CTRL, 0);
	wreg(R_CFG(1), 0);                                   /* GAP: timing comes from the launch index */
	wreg(R_CFG(2), 1 | (0 << 1) | (1 << 2) | (1 << 4));  /* ENABLE, MAX RANGE, default mask ch0, tick-phase compensation */
	wreg(R_CFG(12), period);
	wreg(R_CFG(3), (uint32_t)hwrole | (0 << 8) | (12u << 16));
	for (int i = 4; i < 12; i++) wreg(R_CFG(i), 0);       /* unit weights, no NCO until the anchor speaks */
	for (int i = 0; i < BYTES_RANGE; i++) g_pay[i] = (uint8_t)(i * 37 + 11);
	uint8_t frm[64];
	uint8_t seq = 0;
	if (hwrole == 1) {
		wreg(R_CFG(14), o->epoch0); wreg(R_CTRL, P_SETEP); usleep(100); wreg(R_CTRL, P_FORCE);
		usleep(2000);
		if (role == 1) {                                 /* follower epoch = ours + 1 at the next tick */
			uint8_t pay[4];
			le32(pay, o->epoch0 + 1);
			size_t n = frame_build(frm, 0x02, seq++, pay, 4);
			for (size_t i = 0; i < 48; i += 4) {
				uint32_t w = 0;
				for (int k = 0; k < 4; k++) if (i + k < n) w |= (uint32_t)frm[i + k] << (8 * k);
				wreg(R_CFG(28 + i / 4), w);
			}
			wreg(R_CFG(3), 1u | (12u << 16) | ((uint32_t)n << 24));
			wreg(R_CTRL, P_BUSSEND);
		}
	}
	if (role == 1 && o->bus_test > 0) {
		usleep(300000);                                  /* the SET_EPOCH frame and the next tick */
		return bus_test(o, seq);
	}
	size_t blk = 8 * (2 + (BYTES_RANGE + 7) / 8);
	struct stream s;
	if (stream_open(&s, "cf-ad9361-dds-core-lpc", "out_voltage", blk, 0) < 0) return 1;
	int sock = -1;
	struct stream frx;
	pthread_t fbt;
	if (hwrole == 1 && o->fb) {
		int phy = iio_find("ad9361-phy");
		char v[64];
		snprintf(v, sizeof v, "%.0f", o->fb_freq);
		dev_set(phy, "out_altvoltage0_RX_LO_frequency", v);
		dev_set(phy, "in_voltage0_gain_control_mode", "manual");
		snprintf(v, sizeof v, "%.2f", o->rx_gain);
		dev_set(phy, "in_voltage0_hardwaregain", v);
		if (stream_open(&frx, "cf-ad9361-lpc", "in_voltage", (size_t)FB_BLK * 4, 1) < 0) return 1;
		pthread_create(&fbt, NULL, fb_rx_thread, &frx);
		printf("feedback: radio on %.3f MHz (RX gain %.1f dB)\n", o->fb_freq / 1e6, o->rx_gain);
	} else if (hwrole == 1) {
		sock = socket(AF_INET, SOCK_DGRAM, 0);
		struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(o->port), .sin_addr.s_addr = INADDR_ANY};
		if (bind(sock, (struct sockaddr *)&a, sizeof a) < 0) { fprintf(stderr, "bind %d: %s\n", o->port, strerror(errno)); return 1; }
		fcntl(sock, F_SETFL, O_NONBLOCK);
	}
	char fn[200];
	snprintf(fn, sizeof fn, "%s_%s.csv", o->log, role == 1 ? "leader" : role == 2 ? "follower" : "single");
	FILE *lf = fopen(fn, "w");
	if (lf) fprintf(lf, "t_s,epoch,launches,misses,applies,late,stale,bus_ok,bus_bad,rx_ok,crc_err,tick_phase,msgs\n");
	printf("beamd %s: period %u strobes (%.2f ms), slots ", role == 1 ? "leader" : role == 2 ? "follower" : "single", period, o->epoch_ms);
	int a0 = (role == 2) ? 2 : 0;
	printf("%d %d (+64*(e mod 8) on S1), data at %d (%s). Ctrl-C to stop.\n", SLOT_BASE[a0], SLOT_BASE[a0 + 1], o->ld, o->data ? "on" : "off");
	uint32_t st[64], last_ep = 0xFFFFFFFF;
	long msgs = 0;
	double t0 = now_s(), tlog = t0;
	signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
	while (!g_stop && !(o->seconds > 0 && now_s() - t0 > o->seconds)) {
		if (snapshot(st, 32) < 0) { fprintf(stderr, "snapshot timeout\n"); usleep(1000); continue; }
		uint32_t ep = st[16];
		if (ep != last_ep) {
			/* packets for the next epoch: they are taken by the PHY after this epoch's data packet and launch at their index */
			uint32_t e1 = ep + 1;
			queue_packet(&s, blk, 0x8000 | 0x0008 | 0x0004 | 0x1, (uint32_t)slot_of(a0, e1));
			queue_packet(&s, blk, 0x8000 | 0x0008 | 0x0004 | 0x2, (uint32_t)slot_of(a0 + 1, e1));
			if (o->data) queue_packet(&s, blk, 0x8000 | 0x0008 | (uint16_t)o->data_mask, (uint32_t)o->ld);
			last_ep = ep;
		}
		if (sock >= 0 || (hwrole == 1 && o->fb)) {
			struct bf_msg m;
			ssize_t r = -1;
			if (sock >= 0) r = recv(sock, &m, sizeof m, 0);
			else {
				pthread_mutex_lock(&g_fb_mx);
				if (g_fb_new) { m = g_fb_msg; g_fb_new = 0; r = sizeof m; }
				pthread_mutex_unlock(&g_fb_mx);
			}
			if (r == (ssize_t)sizeof m && m.magic == MSG_MAGIC && o->hold) msgs++;
			else if (r == (ssize_t)sizeof m && m.magic == MSG_MAGIC) {
				uint32_t cur = st[16], tgt = cur + 1;
				while ((tgt % 8) != m.target_mod8) tgt++;
				for (int c = 0; c < 2; c++) {
					const struct chpar *p = &m.ch[0][c];
					wreg(R_CFG(4 + 4 * c), p->amp | ((uint32_t)p->phase << 16));
					wreg(R_CFG(5 + 4 * c), (uint16_t)p->tau | ((uint32_t)p->ctrl << 16));
					wreg(R_CFG(6 + 4 * c), (uint32_t)p->rho);
					wreg(R_CFG(7 + 4 * c), p->inc);
				}
				wreg(R_CFG(13), tgt);
				wreg(R_CTRL, P_COMMIT);
				if (role == 1) {
					size_t n = params_frame(frm, seq++, tgt, m.ch[1]);
					for (size_t i = 0; i < 48; i += 4) {
						uint32_t w = 0;
						for (int k = 0; k < 4; k++) if (i + k < n) w |= (uint32_t)frm[i + k] << (8 * k);
						wreg(R_CFG(28 + i / 4), w);
					}
					wreg(R_CFG(3), 1u | (12u << 16) | ((uint32_t)n << 24));
					wreg(R_CTRL, P_BUSSEND);
				}
				msgs++;
				if (o->verbose) printf("msg %u -> epoch %u (now %u)\n", m.seq, tgt, cur);
			}
		}
		double t = now_s();
		if (t - tlog >= 1.0) {
			tlog = t;
			printf("[%6.1fs] epoch %u launches %u misses %u applies %u late %u stale %u bus ok/bad %u/%u rx_ok %u crc_err %u tick_phase %u msgs %ld",
			       t - t0, st[16], st[22], st[23], st[20] & 0xFFFF, st[20] >> 16, st[21] >> 31, st[25] & 0xFFFF, st[25] >> 16,
			       st[24] & 0xFFFF, st[24] >> 16, st[21] & 0xFF, msgs);
			if (o->fb) printf(" (radio ok %ld, bursts without CRC %ld)", g_fb_ok, g_fb_bad);
			printf("\n");
			if (lf) {
				fprintf(lf, "%.3f,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%ld\n", t - t0, st[16], st[22], st[23], st[20] & 0xFFFF, st[20] >> 16,
				        st[21] >> 31, st[25] & 0xFFFF, st[25] >> 16, st[24] & 0xFFFF, st[24] >> 16, st[21] & 0xFF, msgs);
				fflush(lf);
			}
		}
		usleep(500);
	}
	stream_close(&s);
	if (lf) fclose(lf);
	return 0;
}

/* ================================================================================================= anchor */
struct epoch_res { int ok, m8; struct est e[NANT_MAX]; struct est data; };
static int g_ld = LD_DEFAULT;

/* find the soundings of one epoch in a capture (energy -> windows -> Schmidl-Cox / estimate), times relative to x[0] */
static int anchor_epoch(const cplx *x, long n, int nant, struct epoch_res *r)
{
	static long st[64];
	static cplx ps[64];
	int nd = detect(x, n, st, ps, 64, 0.2);
	memset(r, 0, sizeof *r);
	int m8, i0 = -1;
	long tt[64];
	for (int i = 0; i < nd; i++) tt[i] = st[i];
	i0 = assign(tt, nd, nant, &m8);
	if (i0 < 0) return 0;
	r->m8 = m8;
	for (int a = 0; a < nant; a++) r->e[a] = estimate(x, n, st[i0 + a], ps[i0 + a]);
	/* the data packet of this epoch (all channels with the weights in force): sync start ~ S0 + (LD - slot0) */
	for (int i = i0 + nant; i < nd; i++)
		if (labs(st[i] - st[i0] - (g_ld - SLOT_BASE[0])) < 64) { r->data = estimate(x, n, st[i], ps[i]); break; }
	r->ok = 1;
	return 1;
}

static int run_estimate(const struct opts *o)
{
	FILE *f = fopen(o->file, "rb");
	if (!f) { fprintf(stderr, "%s: %s\n", o->file, strerror(errno)); return 1; }
	fseek(f, 0, SEEK_END);
	long n = ftell(f) / 4;
	fseek(f, 0, SEEK_SET);
	int16_t *raw = malloc(n * 4);
	cplx *x = malloc(n * sizeof(cplx));
	if (fread(raw, 4, n, f) != (size_t)n) return 1;
	fclose(f);
	for (long i = 0; i < n; i++) x[i] = (cplx){raw[2 * i], raw[2 * i + 1]};
	static long st[64];
	static cplx ps[64];
	int nd = detect(x, n, st, ps, 64, 0.2);
	printf("idx,s_sync,t,f,phi,amp,snr_db\n");
	for (int i = 0; i < nd; i++) {
		struct est e = estimate(x, n, st[i], ps[i]);
		printf("%d,%ld,%.6f,%.4f,%.6f,%.6f,%.3f\n", i, st[i], e.t, e.f, e.phi, e.amp, e.snr_db);
	}
	struct epoch_res r;
	if (anchor_epoch(x, n, o->nant, &r)) printf("# assigned: e mod 8 = %d\n", r.m8);
	return 0;
}

static int run_anchor(const struct opts *o)
{
	struct rfcfg rf = {o->freq, 18e6, o->tx_gain, o->rx_gain};
	if (rf_setup(&rf, 0) < 0) return 1;
	struct stream s;
	if (stream_open(&s, "cf-ad9361-lpc", "in_voltage", (size_t)o->cap * 4, 1) < 0) return 1;
	int16_t *raw = malloc(o->cap * 4);
	cplx *x = malloc(o->cap * sizeof(cplx));
	struct stream ftx;
	static int16_t fbuf[2 * 32768];
	if (o->fb) {
		int phy = iio_find("ad9361-phy");
		char v[64];
		snprintf(v, sizeof v, "%.0f", o->fb_freq);
		dev_set(phy, "out_altvoltage1_TX_LO_frequency", v);
		snprintf(v, sizeof v, "%.2f", o->fb_gain);
		dev_set(phy, "out_voltage0_hardwaregain", v);
		if (stream_open(&ftx, "cf-ad9361-dds-core-lpc", "out_voltage", sizeof fbuf, 0) < 0) return 1;
		printf("feedback: radio bursts on %.3f MHz, TX level %.1f dB\n", o->fb_freq / 1e6, o->fb_gain);
	}
	int sock = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in dst = {.sin_family = AF_INET, .sin_port = htons(5005)};
	char host[64];
	snprintf(host, sizeof host, "%s", o->relay);
	char *c = strchr(host, ':');
	if (c) { *c = 0; dst.sin_port = htons(atoi(c + 1)); }
	inet_aton(host, &dst.sin_addr);
	struct ctl C = {.nant = o->nant, .D = o->D, .ld = o->ld, .fc = o->freq, .period_s = o->epoch_ms * 1e-3};
	g_ld = o->ld;
	for (int a = 0; a < NANT_MAX; a++) { C.kf[a].q = 1.0; C.kf[a].rp = 0.05 * 0.05; C.kf[a].rf = 30.0 * 30.0; }
	char fn[200];
	snprintf(fn, sizeof fn, "%s_anchor.csv", o->log);
	FILE *lf = fopen(fn, "w");
	if (lf) {
		fprintf(lf, "t_s,epoch,m8,proc_ms");
		for (int a = 0; a < o->nant; a++) fprintf(lf, ",t%d,f%d,phi%d,amp%d,snr%d", a, a, a, a, a);
		fprintf(lf, ",nu1_hz,w_amp1,w_phase1,w_tau1,w_amp2,w_phase2,w_tau2,w_amp3,w_phase3,w_tau3,data_amp,data_snr\n");
	}
	printf("beamd anchor: capture %ld samples per block, %d antennas, epoch %.2f ms, feedback %d epochs, parameters -> %s\n", o->cap,
	       o->nant, o->epoch_ms, o->D, o->relay);
	signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
	double t0 = now_s(), t_ep0 = -1;
	long ep_cnt = -1, nmsg = 0;
	int last_m8 = -1;
	uint32_t seq = 0;
	while (!g_stop && !(o->seconds > 0 && now_s() - t0 > o->seconds)) {
		size_t want = (size_t)o->cap * 4, got = 0;
		while (got < want && !g_stop) {
			ssize_t r = read(s.fd, (uint8_t *)raw + got, want - got);
			if (r < 0) { if (errno == EINTR) continue; fprintf(stderr, "read: %s\n", strerror(errno)); return 1; }
			got += (size_t)r;
		}
		double tw = now_s(), tp0 = tw;
		for (long i = 0; i < o->cap; i++) x[i] = (cplx){raw[2 * i], raw[2 * i + 1]};
		struct epoch_res r;
		if (!anchor_epoch(x, o->cap, o->nant, &r)) {
			if (o->verbose) printf("[%6.1fs] no sounding pattern in this block\n", tw - t0);
			continue;
		}
		/* epoch counter on the A1 grid: wall clock gives the number of epochs since the last one, e mod 8 the exact value */
		if (ep_cnt < 0) { ep_cnt = r.m8; t_ep0 = tw; }
		else {
			long approx = ep_cnt + lround((tw - t_ep0) / C.period_s);
			long best = approx;
			for (long k = approx - 4; k <= approx + 4; k++) if (((k % 8) + 8) % 8 == r.m8 && labs(k - approx) < labs(best - approx) + (((best % 8) + 8) % 8 != r.m8 ? 100 : 0)) best = k;
			ep_cnt = best; t_ep0 = tw - 0;   /* re-anchor the wall-clock estimate */
		}
		(void)last_m8; last_m8 = r.m8;
		double slot[NANT_MAX], t[NANT_MAX];
		for (int a = 0; a < o->nant; a++) slot[a] = slot_of(a, (uint32_t)r.m8);
		double base = r.e[0].t - slot[0];                     /* tick of this epoch in capture samples (+ fixed latency) */
		for (int a = 0; a < o->nant; a++) {
			t[a] = ep_cnt * C.period_s + (r.e[a].t - base) / FS;
			r.e[a].t = r.e[a].t - base;                       /* arrival relative to the tick (samples) */
		}
		ctl_update(&C, r.e, t, slot);
		struct chpar pr[2][2];
		double nco_new[2];
		double t_tick = (ep_cnt + o->D) * C.period_s, t_data = t_tick + o->ld / FS;
		ctl_params(&C, t_tick, t_data, o->mrt, pr, nco_new);
		for (int b = 0; b < (o->nant + 1) / 2; b++) ctl_nco_change(&C, t_tick, b, nco_new[b]);
		struct bf_msg m = {.magic = MSG_MAGIC, .seq = seq++, .target_mod8 = (uint8_t)((r.m8 + o->D) % 8), .nboards = (uint8_t)((o->nant + 1) / 2)};
		memcpy(m.ch, pr, sizeof pr);
		for (int a = 0; a < o->nant; a++) m.snr_db[a] = (float)r.e[a].snr_db;
		m.nu_hz[0] = (float)(C.kf[0].x[1] - C.nco[0]);
		if (o->nant > 2) m.nu_hz[1] = (float)(C.kf[2].x[1] - C.nco[1]);
		if (o->fb) {
			fb_modulate((const uint8_t *)&m, sizeof m, fbuf, 32768, 1500.0);
			size_t off = 0;
			while (off < sizeof fbuf && !g_stop) {
				ssize_t w = write(ftx.fd, (uint8_t *)fbuf + off, sizeof fbuf - off);
				if (w < 0) { if (errno == EINTR) continue; fprintf(stderr, "feedback write: %s\n", strerror(errno)); break; }
				off += (size_t)w;
			}
		} else
			sendto(sock, &m, sizeof m, 0, (struct sockaddr *)&dst, sizeof dst);
		nmsg++;
		double proc = (now_s() - tp0) * 1e3;
		if (lf) {
			fprintf(lf, "%.3f,%ld,%d,%.2f", tw - t0, ep_cnt, r.m8, proc);
			for (int a = 0; a < o->nant; a++) fprintf(lf, ",%.4f,%.2f,%.5f,%.2f,%.1f", r.e[a].t, r.e[a].f, r.e[a].phi, r.e[a].amp, r.e[a].snr_db);
			fprintf(lf, ",%.3f", o->nant > 2 ? C.kf[2].x[1] - C.kf[0].x[1] : 0.0);
			for (int a = 1; a < 4; a++)
				if (a < o->nant) fprintf(lf, ",%u,%u,%d", pr[a / 2][a % 2].amp, pr[a / 2][a % 2].phase, pr[a / 2][a % 2].tau);
				else fprintf(lf, ",,,");
			fprintf(lf, ",%.3f,%.2f\n", r.data.ok ? r.data.amp : 0.0, r.data.ok ? r.data.snr_db : 0.0);
			fflush(lf);
		}
		if (o->verbose || nmsg % 20 == 1)
			printf("[%6.1fs] epoch %ld (mod8 %d) snr %.1f/%.1f/%.1f/%.1f dB  amp %.1f/%.1f  data amp %.1f (%+.1f dB vs ant0)  dnu %.2f Hz  proc %.1f ms\n",
			       tw - t0, ep_cnt, r.m8, r.e[0].snr_db, r.e[1].snr_db, o->nant > 2 ? r.e[2].snr_db : 0, o->nant > 3 ? r.e[3].snr_db : 0,
			       r.e[0].amp, r.e[1].amp, r.data.ok ? r.data.amp : 0.0,
			       r.data.ok ? 20 * log10(r.data.amp / (r.e[0].amp > 0 ? r.e[0].amp : 1)) : 0.0, o->nant > 2 ? C.kf[2].x[1] - C.kf[0].x[1] : 0.0, proc);
	}
	stream_close(&s);
	if (lf) fclose(lf);
	return 0;
}

/* ================================================================================================= self-test */
static int selftest(void)
{
	int fail = 0;
	if (crc16((const uint8_t *)"123456789", 9) != 0x29B1) { printf("crc16 FAIL\n"); fail++; }
	/* FFT vs DFT */
	static cplx a[NFFT], b[NFFT];
	for (int i = 0; i < NFFT; i++) a[i] = b[i] = (cplx){sin(i * 0.37) + 0.1 * i / NFFT, cos(i * 1.3)};
	fft(a, NFFT);
	double err = 0;
	for (int k = 0; k < NFFT; k += 97) {
		cplx s = {0, 0};
		for (int n = 0; n < NFFT; n++) { cplx w = cexpj(-2 * M_PI * (double)k * n / NFFT); cplx p = cmul(b[n], w); s.re += p.re; s.im += p.im; }
		err = fmax(err, sqrt(cabs2((cplx){s.re - a[k].re, s.im - a[k].im})));
	}
	if (err > 1e-6) { printf("fft FAIL %g\n", err); fail++; }
	/* LTS: 1200 bins of +-PILOT_AMP, first LFSR bits as python/ofdm_ref.preamble(1) */
	int npos = 0;
	for (int i = 0; i < NACT; i++) npos += g_lts[i] > 0;
	printf("LTS: %d positive / %d bins, lag pairs %d %d %d\n", npos, NACT, g_lag_n[0], g_lag_n[1], g_lag_n[2]);
	/* synthetic LTS through a known delay / phase: estimator must return them */
	static cplx x[3 * SYM + NFFT];
	static cplx F[NFFT];
	for (int dd = 0; dd < 3; dd++) {
		double d = 0.3 + 1.7 * dd, ph = 1.1 - dd;
		memset(F, 0, sizeof F);
		for (int i = 0; i < NACT; i++) F[g_act[i]] = cmul((cplx){g_lts[i], 0}, cexpj(ph - 2 * M_PI * g_ks[i] * d / NFFT));
		/* inverse FFT via conj trick */
		for (int i = 0; i < NFFT; i++) F[i].im = -F[i].im;
		fft(F, NFFT);
		for (int i = 0; i < NFFT; i++) F[i] = (cplx){F[i].re / NFFT, -F[i].im / NFFT};
		memset(x, 0, sizeof x);
		long s0 = 500;
		for (int i = 0; i < SYM; i++) x[s0 + SYM - CP + i] = F[(i + NFFT - CP) % NFFT];
		struct est e = estimate(x, 3 * SYM + NFFT, s0, (cplx){1, 0});
		double t_exp = s0 + SYM + d;
		if (fabs(e.t - t_exp) > 1e-3 || fabs(remainder(e.phi - ph, 2 * M_PI)) > 1e-3) {
			printf("estimate FAIL d %.2f: t %.4f exp %.4f phi %.4f exp %.4f\n", d, e.t, t_exp, e.phi, ph); fail++;
		}
	}
	/* feedback modem: burst of a bf_msg through CFO 5 kHz, random phase, delay, noise (6 dB below the signal per sample) */
	{
		static int16_t tx[2 * 32768];
		static cplx rx[60000];
		struct bf_msg m = {.magic = MSG_MAGIC, .seq = 1234, .target_mod8 = 5}, r;
		for (int i = 0; i < 2; i++) for (int c = 0; c < 2; c++) m.ch[i][c] = (struct chpar){.amp = 1000 + i, .phase = 77 * c, .tau = -5, .rho = 99, .inc = 0xDEADBEEF};
		int ns = fb_modulate((const uint8_t *)&m, sizeof m, tx, 32768, 1000.0);
		uint32_t rs = 1;
		int ok = 0;
		for (int trial = 0; trial < 3; trial++) {
			long d = 1000 + 3777 * trial;
			double ph = 0.7 + trial, f = 5000.0 * (trial - 1);
			for (long i = 0; i < 60000; i++) {
				rs = rs * 1103515245u + 12345u; double n1 = ((rs >> 8) & 0xFFFF) / 65536.0 - 0.5;
				rs = rs * 1103515245u + 12345u; double n2 = ((rs >> 8) & 0xFFFF) / 65536.0 - 0.5;
				cplx v = {n1 * 2000 * 1.73, n2 * 2000 * 1.73};          /* uniform noise, rms 1000 per component */
				long k = i - d;
				if (k >= 0 && k < ns) {
					cplx s = cmul((cplx){tx[2 * k], tx[2 * k + 1]}, cexpj(ph + 2 * M_PI * f * i / FS));
					v.re += s.re; v.im += s.im;
				}
				rx[i] = v;
			}
			double corr; long pos;
			memset(&r, 0, sizeof r);
			if (fb_demod(rx, 60000, (uint8_t *)&r, sizeof r, &corr, &pos) && !memcmp(&r, &m, sizeof m) && labs(pos - d) <= 4) ok++;
			else printf("fbmodem trial %d: corr %.2f pos %ld (exp %ld)\n", trial, corr, pos, d);
		}
		if (ok != 3) { printf("fbmodem FAIL (%d/3)\n", ok); fail++; }
		else printf("fbmodem: 3/3 bursts decoded (CFO -5/0/+5 kHz, SNR 0 dB per sample, %d samples = %.2f ms)\n", ns, ns / FS * 1e3);
	}
	printf("selftest %s\n", fail ? "FAILED" : "passed");
	return fail ? 1 : 0;
}

/* controller check (sw/beamd/check_ctl.py): one line per epoch
 *   t_tick t_data mrt slot0..3 then per antenna: ok t_samples f phi amp
 * -> per epoch: per antenna amp phase tau rho inc, the same sequence of calls as the anchor (update, params, nco_change) */
static int run_ctltest(const struct opts *o)
{
	FILE *f = fopen(o->file, "r");
	if (!f) { fprintf(stderr, "%s: %s\n", o->file, strerror(errno)); return 1; }
	struct ctl C = {.nant = o->nant, .D = o->D, .ld = o->ld, .fc = o->freq, .period_s = o->epoch_ms * 1e-3};
	for (int a = 0; a < NANT_MAX; a++) { C.kf[a].q = 1.0; C.kf[a].rp = 0.05 * 0.05; C.kf[a].rf = 30.0 * 30.0; }
	double tt, td, slot[NANT_MAX], t[NANT_MAX];
	int mrt;
	while (fscanf(f, "%lf %lf %d", &tt, &td, &mrt) == 3) {
		struct est e[NANT_MAX];
		memset(e, 0, sizeof e);
		for (int a = 0; a < o->nant; a++) if (fscanf(f, "%lf", &slot[a]) != 1) return 1;
		for (int a = 0; a < o->nant; a++) {
			if (fscanf(f, "%d %lf %lf %lf %lf", &e[a].ok, &e[a].t, &e[a].f, &e[a].phi, &e[a].amp) != 5) return 1;
			t[a] = e[a].t / FS;
		}
		ctl_update(&C, e, t, slot);
		struct chpar pr[2][2];
		double nco_new[2];
		ctl_params(&C, tt, td, mrt, pr, nco_new);
		for (int b = 0; b < (o->nant + 1) / 2; b++) ctl_nco_change(&C, tt, b, nco_new[b]);
		for (int a = 0; a < o->nant; a++) {
			const struct chpar *p = &pr[a / 2][a % 2];
			printf("%u %u %d %d %u%s", p->amp, p->phase, p->tau, p->rho, p->inc, a + 1 < o->nant ? " " : "\n");
		}
	}
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) { usage(); return 1; }
	dsp_init();
	struct opts o;
	if (strcmp(argv[1], "selftest") && parse(argc, argv, &o) < 0) { usage(); return 1; }
	if (!strcmp(argv[1], "selftest")) return selftest();
	if (!strcmp(argv[1], "estimate")) return run_estimate(&o);
	if (!strcmp(argv[1], "ctltest")) return run_ctltest(&o);
	if (!strcmp(argv[1], "anchor")) return run_anchor(&o);
	if (!strcmp(argv[1], "leader")) return run_tx(&o, 1);
	if (!strcmp(argv[1], "follower")) return run_tx(&o, 2);
	if (!strcmp(argv[1], "single")) return run_tx(&o, 3);
	usage();
	return 1;
}
