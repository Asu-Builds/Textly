# Misst pro Textblock den Versatz zwischen Bildschirm (screen-pN.png) und PDF.
# Aufruf im Ordner build/fidelity nach: SPIKE_RATIO=8 flutter test
# Benötigt: pip install pymupdf pillow numpy
import json, sys, fitz
from PIL import Image
import numpy as np
Image.MAX_IMAGE_PIXELS=None
d=fitz.open('textly-spike.pdf')
R=round(Image.open('screen-p1.png').width/(210*72/25.4)); k=72/25.4*R  # Faktor aus der Bildbreite
for pi in range(len(d)): d[pi].get_pixmap(dpi=72*R).save(f'pdf8-p{pi+1}.png')
print(f'Auflösung: {R} Bildpunkte pro pt, Messgenauigkeit {1/k:.3f} mm')
imgs={}
def img(p):
    if p not in imgs: imgs[p]=(np.asarray(Image.open(f'screen-p{p}.png').convert('L'),dtype=float), np.asarray(Image.open(f'pdf8-p{p}.png').convert('L'),dtype=float))
    return imgs[p]
worst=(0,'')
for b in json.load(open('blocks.json',encoding='utf8')):
    A,B=img(b['page']); m=12
    x0,y0=int(b['x']*R)-m,int(b['y']*R)-m; x1,y1=int((b['x']+b['w'])*R)+m,int((b['y']+b['h'])*R)+m
    a=A[y0+m:y1-m,x0+m:x1-m]; best=None
    for dy in range(-m,m+1):
        for dx in range(-m,m+1):
            e=np.abs(a-B[y0+m+dy:y1-m+dy,x0+m+dx:x1-m+dx]).mean()
            if best is None or e<best[0]: best=(e,dx,dy)
    e,dx,dy=best; mm=max(abs(dx),abs(dy))/k
    if mm>worst[0]: worst=(mm,b['text'])
    print(f"S{b['page']} {b['kind']:9s} {b['text'][:22]:22s} dx={dx/k:+.3f} dy={dy/k:+.3f} mm")
print(f'GROESSTE {worst[0]:.3f} mm ({worst[1]})')
