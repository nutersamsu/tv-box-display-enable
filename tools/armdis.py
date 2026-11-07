# Mini desmontador ARM32 (so o necessario para ler o driver fd655 do kernel Android)
import struct,bisect,sys
BASE=0xc0108000
d=open(sys.argv[1],'rb').read()
syms=sorted((int(l[:8],16),l[11:].strip()) for l in open(sys.argv[2]))
A=[a for a,_ in syms]
def nm(off):
    i=bisect.bisect_right(A,off)-1
    if i<0: return hex(off)
    return f'{syms[i][1]}+{off-syms[i][0]:#x}' if off!=syms[i][0] else syms[i][1]
C=['eq','ne','cs','cc','mi','pl','vs','vc','hi','ls','ge','lt','gt','le','','nv']
R=['r0','r1','r2','r3','r4','r5','r6','r7','r8','r9','r10','fp','ip','sp','lr','pc']
DP=['and','eor','sub','rsb','add','adc','sbc','rsc','tst','teq','cmp','cmn','orr','mov','bic','mvn']
SH=['lsl','lsr','asr','ror']
def ror(v,r): return ((v>>r)|(v<<(32-r)))&0xffffffff
def dis(off):
    w=struct.unpack_from('<I',d,off)[0]; c=C[w>>28]
    if (w>>25)&7==5:
        imm=w&0xffffff
        if imm&0x800000: imm-=0x1000000
        t=off+8+imm*4
        return f"b{'l' if w&(1<<24) else ''}{c} {nm(t)}"
    if w&0x0ffffff0==0x012fff10: return f'bx{c} {R[w&15]}'
    if w&0x0ffffff0==0x012fff30: return f'blx{c} {R[w&15]}'
    if w&0x0ff00000==0x03000000: return f'movw{c} {R[(w>>12)&15]}, #{((w>>4)&0xf000)|(w&0xfff):#x}'
    if w&0x0ff00000==0x03400000: return f'movt{c} {R[(w>>12)&15]}, #{((w>>4)&0xf000)|(w&0xfff):#x}'
    if w&0x0fe000f0==0x00000090: return f"mul{c} {R[(w>>16)&15]}, {R[w&15]}, {R[(w>>8)&15]}"
    if (w>>26)&3==0 and not ((w>>25)&1==0 and (w>>4)&9==9):
        op=(w>>21)&15; s='s' if w&(1<<20) and op not in(8,9,10,11) else ''
        rn=R[(w>>16)&15]; rd=R[(w>>12)&15]
        if w&(1<<25): op2=f'#{ror(w&0xff,2*((w>>8)&15)):#x}'
        else:
            rm=R[w&15]; st=SH[(w>>5)&3]
            if w&16: op2=f'{rm}, {st} {R[(w>>8)&15]}'
            else:
                a=(w>>7)&31; op2=rm if a==0 and st=='lsl' else f'{rm}, {st} #{a}'
        if op in(13,15): return f'{DP[op]}{s}{c} {rd}, {op2}'
        if op in(8,9,10,11): return f'{DP[op]}{c} {rn}, {op2}'
        return f'{DP[op]}{s}{c} {rd}, {rn}, {op2}'
    if (w>>26)&3==0 and (w>>4)&9==9:  # ldrh/strh etc
        L=(w>>20)&1; sh=(w>>5)&3; P=(w>>24)&1;U=(w>>23)&1;I=(w>>22)&1;W=(w>>21)&1
        m={1:'h',2:'sb',3:'sh'}.get(sh,'?')
        o=((w>>4)&0xf0)|(w&15) if I else R[w&15]
        return f"{'ldr' if L else 'str'}{m}{c} {R[(w>>12)&15]}, [{R[(w>>16)&15]}, {'#' if I else ''}{'' if U else '-'}{o}]"
    if (w>>26)&3==1:
        L=(w>>20)&1;B='b' if w&(1<<22) else '';P=(w>>24)&1;U=(w>>23)&1;Wb=(w>>21)&1
        rn=(w>>16)&15;rd=R[(w>>12)&15]
        if not w&(1<<25):
            imm=w&0xfff; sgn='' if U else '-'
            if rn==15 and P:
                a=off+8+(imm if U else -imm); v=struct.unpack_from('<I',d,a)[0]
                return f"{'ldr' if L else 'str'}{B}{c} {rd}, ={v:#x} ({nm(v-BASE) if BASE<=v<BASE+len(d) else ''})"
            return f"{'ldr' if L else 'str'}{B}{c} {rd}, [{R[rn]}{', #'+sgn+hex(imm) if P else ''}]{'' if P else ', #'+sgn+hex(imm)}{'!' if Wb and P else ''}"
        return f"{'ldr' if L else 'str'}{B}{c} {rd}, [{R[rn]}, {R[w&15]}{', lsl #'+str((w>>7)&31) if (w>>7)&31 else ''}]"
    if (w>>25)&7==4:
        regs=','.join(R[i] for i in range(16) if w&(1<<i))
        return f"{'ldm' if w&(1<<20) else 'stm'}{c} {R[(w>>16)&15]}{'!' if w&(1<<21) else ''}, {{{regs}}}"
    return f'.word {w:#010x}'
start=int(sys.argv[3],16); end=int(sys.argv[4],16)
for o in range(start,end,4):
    i=bisect.bisect_right(A,o)-1
    if A[i]==o: print(f'\n<{syms[i][1]}>')
    print(f'{o:08x}: {dis(o)}')
