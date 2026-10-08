import sys; sys.path.insert(0,'.')
import numpy as np, ldpc_ref as l
def fer(base, snr, frames=300, iters=25, seed=5):
    rng=np.random.default_rng(seed); k=(36-base.shape[0])*60; rate=k/2160
    sig=np.sqrt(1/(2*rate*10**(snr/10)))
    info=rng.integers(0,2,(frames,k),dtype=np.uint8); cw=l.encode(info,base)
    y=(1-2.0*cw)+sig*rng.standard_normal(cw.shape)
    h,u,ok=l.decode(2*y/sig**2,iters,base=base)
    return float((~ok).mean())
cands={'all3':[3]*18,'mix8x3':[8]*3+[3]*15,'mix6x4':[6]*4+[3]*14,'mix7_4_3':[7]*2+[4]*6+[3]*10,'all4':[4]*18}
for name,deg in cands.items():
    best=None
    for s in range(1,7):
        try: b=l.build_base(s,mb=18,info_deg=deg)
        except RuntimeError: continue
        f=fer(b,1.4,frames=120)
        if best is None or f<best[0]: best=(f,s)
    print(name,best,flush=True)
