/*
 * fbmodem.h -- feedback radio of the beamforming loop (TestTask006 section 6, option 2): DBPSK burst modem, B -> A1.
 *
 * Burst: [reference symbol][64-bit preamble][payload bytes, LSB first][CRC32 (zlib) of the payload, LSB first], differential
 * encoding (bit 1 = phase flip), rectangular pulse of FB_SPS = 32 samples (0.96 Mbaud at 30.72 MS/s), then zeros. 100-byte
 * message: 1 + 64 + 832 symbols = 28704 samples = 0.93 ms. FDD: B sends on --fb-freq (another LO than the soundings), A1 listens
 * there with its RX path (the BF bitstream keeps the stock ADC path).
 * Receiver: decimation by 4 (8 samples per symbol), for each of the 8 symbol phases: symbol sums y_k, differential products
 * z_k = y_k conj(y_{k-1}), normalised preamble correlation sum(e_m Re z) / sum |z|; the best phase / start above FB_THR gives
 * the bits (Re z < 0 -> 1) and the CRC check. Insensitive to the carrier phase and to CFO << 1 / (2 pi T_sym) (~150 kHz).
 */
#ifndef FBMODEM_H
#define FBMODEM_H

#define FB_SPS 32
#define FB_PRE 64
#define FB_THR 0.6
static const uint64_t FB_PREAMBLE = 0xA7F1B3C5D2E68F49ull;

static uint32_t crc32_le(const uint8_t *p, size_t n)
{
	uint32_t c = 0xFFFFFFFFu;
	for (size_t i = 0; i < n; i++) {
		c ^= p[i];
		for (int b = 0; b < 8; b++) c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
	}
	return ~c;
}
static int fb_nsym(int nbytes) { return 1 + FB_PRE + 8 * (nbytes + 4); }

/* burst -> interleaved int16 I/Q, returns the number of samples written (rest of iq[] up to nmax is zero) */
static int fb_modulate(const uint8_t *msg, int nbytes, int16_t *iq, int nmax, double amp)
{
	int nsym = fb_nsym(nbytes);
	if (nsym * FB_SPS > nmax) return -1;
	uint8_t buf[512];
	memcpy(buf, msg, nbytes);
	uint32_t c = crc32_le(msg, nbytes);
	for (int i = 0; i < 4; i++) buf[nbytes + i] = (uint8_t)(c >> (8 * i));
	memset(iq, 0, sizeof(int16_t) * 2 * nmax);
	int d = 0;
	for (int k = 0; k < nsym; k++) {
		int bit = 0;
		if (k >= 1 && k <= FB_PRE) bit = (int)((FB_PREAMBLE >> (k - 1)) & 1);
		else if (k > FB_PRE) { int b = k - 1 - FB_PRE; bit = (buf[b >> 3] >> (b & 7)) & 1; }
		if (k) d ^= bit;
		int16_t v = (int16_t)lround(d ? -amp : amp);
		for (int s = 0; s < FB_SPS; s++) { iq[2 * (k * FB_SPS + s)] = v; iq[2 * (k * FB_SPS + s) + 1] = 0; }
	}
	return nsym * FB_SPS;
}

/* search x[0..n) for a burst of nbytes; returns 1 with msg filled when the CRC is good. *corr / *pos: best correlation / start */
static int fb_demod(const cplx *x, long n, uint8_t *msg, int nbytes, double *corr, long *pos)
{
	int nsym = fb_nsym(nbytes);
	long m4 = n / 4;
	static cplx r4[1 << 18], y[(1 << 16) + 8], z[(1 << 16) + 8];
	if (m4 > (1 << 18)) m4 = 1 << 18;
	for (long i = 0; i < m4; i++) {
		cplx s = {0, 0};
		for (int j = 0; j < 4; j++) { s.re += x[4 * i + j].re; s.im += x[4 * i + j].im; }
		r4[i] = s;
	}
	static double az[(1 << 16) + 8];
	static float ep[FB_PRE + 1];
	for (int m = 1; m <= FB_PRE; m++) ep[m] = ((FB_PREAMBLE >> (m - 1)) & 1) ? -1.0f : 1.0f;
	double best = 0;
	long best_k = -1;
	int best_p = 0;
	for (int p = 0; p < 8; p++) {
		long ns = (m4 - p) / 8;
		if (ns > (1 << 16)) ns = 1 << 16;
		for (long k = 0; k < ns; k++) {
			cplx s = {0, 0};
			for (int j = 0; j < 8; j++) { s.re += r4[p + 8 * k + j].re; s.im += r4[p + 8 * k + j].im; }
			y[k] = s;
			z[k] = k ? cconjmul(y[k - 1], y[k]) : (cplx){0, 0};
			az[k] = sqrt(cabs2(z[k]));
		}
		double den = 0;                                  /* sliding sum of |z| over the preamble window */
		for (int m = 1; m <= FB_PRE && m < ns; m++) den += az[m];
		for (long k0 = 0; k0 + nsym <= ns; k0++) {
			double num = 0;
			for (int m = 1; m <= FB_PRE; m++) num += ep[m] * z[k0 + m].re;
			double c = den > 0 ? num / den : 0;
			if (c > best) { best = c; best_k = k0; best_p = p; }
			den += az[k0 + FB_PRE + 1] - az[k0 + 1];
		}
	}
	*corr = best;
	*pos = best_k >= 0 ? 4 * (best_p + 8 * best_k) : -1;
	if (best < FB_THR) return 0;
	/* recompute the symbol sums of the winning phase and slice the payload */
	long ns = (m4 - best_p) / 8;
	if (ns > (1 << 16)) ns = 1 << 16;
	for (long k = 0; k < ns; k++) {
		cplx s = {0, 0};
		for (int j = 0; j < 8; j++) { s.re += r4[best_p + 8 * k + j].re; s.im += r4[best_p + 8 * k + j].im; }
		y[k] = s;
	}
	uint8_t buf[512] = {0};
	for (int b = 0; b < 8 * (nbytes + 4); b++) {
		long k = best_k + 1 + FB_PRE + b;
		cplx zz = cconjmul(y[k - 1], y[k]);
		if (zz.re < 0) buf[b >> 3] |= (uint8_t)(1 << (b & 7));
	}
	uint32_t c = 0;
	for (int i = 0; i < 4; i++) c |= (uint32_t)buf[nbytes + i] << (8 * i);
	if (crc32_le(buf, nbytes) != c) return 0;
	memcpy(msg, buf, nbytes);
	return 1;
}
#endif
