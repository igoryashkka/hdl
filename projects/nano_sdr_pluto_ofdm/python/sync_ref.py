"""Fixed-point Schmidl-Cox detector (bit-exact golden model of phy_sync_sc).

Per valid input sample n (r = I + jQ, 16-bit signed):
    rl      = r[n-L]                                   (0 while n < L)
    q       = conj(rl) * r  >> QSH                     qr = (rl.I*r.I + rl.Q*r.Q) >> QSH ; qi = (rl.I*r.Q - rl.Q*r.I) >> QSH
    e       = (r.I^2 + r.Q^2) >> QSH
    P[n]    = P[n-1] + q[n] - q[n-L]                   (complex running sum over the last L products)
    R[n]    = R[n-1] + e[n] - e[n-L]                   (energy of the last L samples)
    mag     = max(|Pi|,|Pq|) + 0.375*min(|Pi|,|Pq|)    (alpha-max-beta-min:  mx + (mn>>1) - (mn>>3))
    cond    = R >= RMIN  and  mag > R/2   (R>>1)
    mc      = cond ? mag : 0                           S[n] = sum of mc over the last BOX samples (running sum)
FSM: IDLE -> first cond -> TRACK for TRACK_LEN samples (counting the first one): keep the maximum of S and the
sample index / P snapshot of that maximum -> event (n_decl, n_best, P_snap) -> DONE until rearm.
Output timing is expressed in the sample index n of the sample whose metrics are evaluated (RTL aligns its counter).
"""
import numpy as np

L = 1024
QSH = 8
BOX = 128
TRACK_LEN = 704
RMIN_DEFAULT = 1 << 18


def detect(i, q, rmin=RMIN_DEFAULT, L=L, qsh=QSH, box=BOX, track_len=TRACK_LEN):
    """i, q: integer sample arrays. Returns None or dict(n_decl, n_best, p_re, p_im, r, sbest) of the first event."""
    n_s = len(i)
    i = np.asarray(i, dtype=np.int64)
    q = np.asarray(q, dtype=np.int64)
    qr_h = np.zeros(L, np.int64); qi_h = np.zeros(L, np.int64); e_h = np.zeros(L, np.int64)
    mc_h = np.zeros(box, np.int64)
    Pr = Pi = R = S = 0
    state = 0   # 0 idle, 1 track, 2 done
    t = 0
    sbest = -1; nbest = 0; psn = (0, 0)
    for n in range(n_s):
        ri, rq = int(i[n]), int(q[n])
        li, lq = (int(i[n - L]), int(q[n - L])) if n >= L else (0, 0)
        qr = (li * ri + lq * rq) >> qsh
        qi = (li * rq - lq * ri) >> qsh
        e = (ri * ri + rq * rq) >> qsh
        slot = n % L
        qr_old, qi_old, e_old = (qr_h[slot], qi_h[slot], e_h[slot]) if n >= L else (0, 0, 0)
        qr_h[slot], qi_h[slot], e_h[slot] = qr, qi, e
        Pr += qr - qr_old; Pi += qi - qi_old; R += e - e_old
        a, b = abs(Pr), abs(Pi)
        mx, mn = max(a, b), min(a, b)
        mag = mx + (mn >> 1) - (mn >> 3)
        cond = (R >= rmin) and (mag > (R >> 1))
        mc = mag if cond else 0
        bslot = n % box
        mc_old = mc_h[bslot] if n >= box else 0
        mc_h[bslot] = mc
        S += mc - mc_old
        if state == 0 and cond:
            state = 1; t = 0; sbest = -1
        if state == 1:
            if S > sbest:
                sbest, nbest, psn = S, n, (Pr, Pi)
            t += 1
            if t == track_len:
                return dict(n_decl=n, n_best=nbest, p_re=psn[0], p_im=psn[1], r=R, sbest=sbest)
    return None


# ------------------------------------------------------------------ CORDIC vectoring + coarse CFO (golden for phy_cordic_vec / phy_cfo_coarse)
CORDIC_ITER = 24
CORDIC_XW = 18        # input width (signed)


def cordic_atan_table(n=CORDIC_ITER):
    return [int(np.floor(np.arctan(2.0 ** -i) / (2 * np.pi) * 4294967296.0 + 0.5)) for i in range(n)]


def cordic_vec(x, y, n=CORDIC_ITER):
    """angle of (x + jy) in 2^32 = 2*pi units, returned as unsigned 32-bit (mod 2^32). x, y signed integers (|.| < 2^17)."""
    atan = cordic_atan_table(n)
    z = 0
    if x < 0:
        x, y, z = -x, -y, 1 << 31
    for i in range(n):
        if y >= 0:
            x, y, z = x + (y >> i), y - (x >> i), z + atan[i]
        else:
            x, y, z = x - (y >> i), y + (x >> i), z - atan[i]
    return z & 0xFFFFFFFF


def cfo_inc(p_re, p_im, log2l=10):
    """NCO phase increment (2^32 = 2*pi per cycle) that CANCELS the CFO: inc = -angle(P)/L (arithmetic shift)."""
    m = max(abs(p_re), abs(p_im))
    s = max(0, int(m).bit_length() - (CORDIC_XW - 1))
    ang = cordic_vec(p_re >> s, p_im >> s)
    ang_s = ang - (1 << 32) if ang >= (1 << 31) else ang
    return (-(ang_s >> log2l)) & 0xFFFFFFFF
