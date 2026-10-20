#!/usr/bin/env python3
"""Prototype: cut single programs out of a multiplex capture by PID filtering (no re-encoding)."""
import sys, struct, binascii
def crc32(b):
    c=0xFFFFFFFF
    for x in b:
        c^=x<<24
        for _ in range(8): c=((c<<1)^0x04C11DB7)&0xFFFFFFFF if c&0x80000000 else (c<<1)&0xFFFFFFFF
    return c
def sections(data,pid_want):
    buf={}
    for i in range(0,len(data)-187,188):
        p=data[i:i+188]
        if p[0]!=0x47: continue
        pid=((p[1]&0x1f)<<8)|p[2]
        if pid not in pid_want or not p[3]&0x10: continue
        pl=p[4:]
        if p[3]&0x20: pl=p[5+p[4]:]
        if p[1]&0x40:
            ptr=pl[0]; buf[pid]=bytearray(pl[1+ptr:])
        elif pid in buf: buf[pid]+=pl
        b=buf.get(pid)
        while b and len(b)>=3:
            L=3+(((b[1]&15)<<8)|b[2])
            if len(b)<L: break
            yield pid,bytes(b[:L]); del b[:L]
def parse_pat(data):
    for _,s in sections(data,{0}):
        if s[0]==0 and len(s)>12:
            return {(s[i]<<8)|s[i+1]:((s[i+2]&0x1f)<<8)|s[i+3] for i in range(8,len(s)-4,4) if ((s[i]<<8)|s[i+1])!=0}
def parse_pmt(data,pid):
    for _,s in sections(data,{pid}):
        if s[0]==2:
            pcr=((s[8]&0x1f)<<8)|s[9]; pil=((s[10]&15)<<8)|s[11]; i=12+pil; es=[]
            while i<len(s)-4:
                st=s[i]; ep=((s[i+1]&0x1f)<<8)|s[i+2]; il=((s[i+3]&15)<<8)|s[i+4]; es.append((st,ep)); i+=5+il
            return pcr,es,s
def ts_packet(pid,payload,cc,pusi=True):
    pkt=bytearray([0x47,(0x40 if pusi else 0)|(pid>>8),pid&0xff,0x10|(cc&15)])+payload
    return bytes(pkt+b'\xff'*(188-len(pkt)))
def make_pat(prog,pmt_pid,tsid=1):
    body=struct.pack('>HHBBB',tsid,0xC1,0,0,0)[0:0]
    sec=bytearray([0x00,0xB0,0x0D,tsid>>8,tsid&0xff,0xC1,0x00,0x00,prog>>8,prog&0xff,0xE0|(pmt_pid>>8),pmt_pid&0xff])
    sec+=struct.pack('>I',crc32(sec)); return bytes(sec)
def main(path,prog,out):
    data=open(path,'rb').read()
    pat=parse_pat(data); pmt_pid=pat[prog]
    pcr,es,pmt_sec=parse_pmt(data,pmt_pid)
    keep={pcr}|{ep for _,ep in es}
    print('program',prog,'pmt pid',hex(pmt_pid),'pcr',hex(pcr),'streams',[(hex(st),hex(ep)) for st,ep in es])
    o=open(out,'wb'); cc_pat=cc_pmt=0
    patsec=make_pat(prog,pmt_pid); n=0
    for i in range(0,len(data)-187,188):
        p=data[i:i+188]
        if p[0]!=0x47: continue
        pid=((p[1]&0x1f)<<8)|p[2]
        if n%200==0:   # repeat our own PAT and the program's PMT regularly
            o.write(ts_packet(0,b'\x00'+patsec,cc_pat)); cc_pat+=1
            o.write(ts_packet(pmt_pid,b'\x00'+pmt_sec,cc_pmt)); cc_pmt+=1
        if pid in keep: o.write(p); n+=1
    o.close(); print('wrote',n,'packets')
if __name__=='__main__':
    main(sys.argv[1],int(sys.argv[2]),sys.argv[3])
