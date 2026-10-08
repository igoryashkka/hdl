import sys; sys.path.insert(0,'.')
import numpy as np, qam_ref, phy2_ref as P, ofdm_ref
from phy_params import FFT_SIZE, PILOT_AMP, NUM_DATA_SC
rng=np.random.default_rng(1)
DS=P._DS; PS=P._PS
def make_y(words_sym, H, sigma2, nsym):
    """per symbol full 2048-bin FFT outputs with Y=H*X+N (H on active bins; unit gain scale g folded into H)"""
    X=[]
    ws=np.array(words_sym).reshape(nsym,NUM_DATA_SC)
    ys=[]
    for s in range(nsym):
        bits=((ws[s][:,None]>>np.array([3,2,1,0]))&1).reshape(-1)
        q=qam_ref.map_symbols(bits,order=16); pts=q[:,0]+1j*q[:,1]
        x=np.zeros(1200,complex); x[DS]=pts; x[PS]=P._pilot_sg()*PILOT_AMP
        yf=np.zeros(FFT_SIZE,complex)
        yf[P.ACT]=H*x
        yf+= np.sqrt(sigma2/2)*(rng.standard_normal(FFT_SIZE)+1j*rng.standard_normal(FFT_SIZE))
        ys.append(yf)
    ylts=np.zeros(FFT_SIZE,complex); ylts[P.ACT]=H*P._lts_sg()*PILOT_AMP
    ylts+=np.sqrt(sigma2/2)*(rng.standard_normal(FFT_SIZE)+1j*rng.standard_normal(FFT_SIZE))
    return ylts, ys
def chan(kind):
    k=np.arange(1200)-600
    if kind=="awgn": return np.ones(1200,complex)*0.3
    if kind=="2path": return 0.3*(1+0.5*np.exp(-2j*np.pi*(k)*11/2048+0.8j))
def run(code,eq,soft,snr,kind,npk=20,nsym=2,smooth=0):
    H=chan(kind); sigma2=np.mean(np.abs(H)**2)*P.P_DATA/10**(snr/10)
    bad=0
    for _ in range(npk):
        nb=P.bytes_per_sym(code)*nsym
        pay=bytes(rng.integers(0,256,nb,dtype=np.uint8))
        words=P.tx_words(pay,nsym,code)
        ylts,ys=make_y(words,H,sigma2,nsym)
        r=P.rx_symbols(ylts,ys,eq,soft,smooth)
        if code=="ldpc":
            d=P.decode_payload(r["llr"],nsym,nb)
            got=d["bytes"]
        else:
            import interleaver_ref as ilr, scrambler_ref
            deint=P.deinterleave_llr(r["llr"])
            bits=(deint<0).astype(np.uint8).reshape(-1)
            got=bytes(scrambler_ref.scramble(list(np.packbits(bits))))[:nb]
        bad+= got!=pay
    return bad/npk, r["quality"]
if __name__=="__main__":
    for kind in ("awgn","2path"):
        for name,args in (("uncoded zf hard",("none","zf","uniform")),("ldpc zf uniform",("ldpc","zf","uniform")),("ldpc mmse uniform",("ldpc","mmse","uniform")),("ldpc zf weighted",("ldpc","zf","weighted")),("ldpc mmse weighted",("ldpc","mmse","weighted"))):
            print(kind,name,[ (s,run(*args,s,kind)[0]) for s in (10,12,14,16,18,22,26)],flush=True)
