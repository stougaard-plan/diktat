import json,re,subprocess,glob,os,statistics,sys
refs=json.load(open("refs.json"))
def norm(s): return re.sub(r"[^\wæøå ]","",s.lower().replace("-"," ")).split()
def wer(ref,hyp):
    r,h=norm(ref),norm(hyp)
    d=[[0]*(len(h)+1) for _ in range(len(r)+1)]
    for i in range(len(r)+1): d[i][0]=i
    for j in range(len(h)+1): d[0][j]=j
    for i in range(1,len(r)+1):
        for j in range(1,len(h)+1):
            d[i][j]=min(d[i-1][j]+1,d[i][j-1]+1,d[i-1][j-1]+(r[i-1]!=h[j-1]))
    return d[len(r)][len(h)]/max(1,len(r))
rows=[]  # model, group, file, ref, text, ms
def refof(f):
    g,i=f.replace(".wav","").split("_"); return g,refs[g][int(i)]
for l in open("parakeet_clips.jsonl"):
    o=json.loads(l); g,r=refof(o["file"])
    rows.append(("Parakeet V3, hint=da" if o["hint"]=="da" else "Parakeet V3, uden hint",g,o["file"],r,o["text"],o["ms"]))
def wtime(m,d):
    t=open(f"{d}/run.log").read()
    load=float(re.search(r"load time =\s+([\d.]+)",t).group(1)); tot=float(re.search(r"total time =\s+([\d.]+)",t).group(1))
    return load,tot
for m in ["small","medium","large-v3"]:
    d=f"w_{m}"; load,tot=wtime(m,d); n=len(glob.glob(d+"/*.wav")); per=(tot-load)/n
    for f in sorted(glob.glob(d+"/*.wav")):
        g,r=refof(os.path.basename(f)); txt=open(f+".txt").read().strip().replace("\n"," ")
        rows.append((f"Whisper {m}, language=da",g,os.path.basename(f),r,txt,per))
texts=[r[4] for r in rows]
ids=json.loads(subprocess.run(["./langid"],input=json.dumps(texts),capture_output=True,text=True).stdout)
out={}
for r,i in zip(rows,ids):
    m,g=r[0],r[1]
    w=wer(r[3],r[4])
    # forkert sprog: tydeligt ikke-dansk (NL: topsprog != da med konfidens>=0.6) ELLER mindst ét helt engelsk/fransk ord midt i en ellers rigtig sætning kan ikke ses, så vi tæller også WER>0.5 og NL-da<0.5 
    wrong = (i["lang"]!="da" and i["conf"]>=0.6 and w>0.2)
    k=(m,g); out.setdefault(k,[]).append((wrong,w,r[5],r[2],r[4],i["lang"]))
print(f'{"model":34} {"gruppe":7} {"n":>3} {"forkert sprog":>13} {"ord-fejl%":>9} {"ms/klip(gns)":>12} {"ms(median)":>10}')
for k in sorted(out):
    v=out[k]; print(f'{k[0]:34} {k[1]:7} {len(v):3d} {sum(x[0] for x in v):13d} {100*statistics.mean(x[1] for x in v):9.1f} {statistics.mean(x[2] for x in v):12.0f} {statistics.median(x[2] for x in v):10.0f}')
json.dump({f"{k[0]}|{k[1]}":v for k,v in out.items()},open("resultat.json","w"),ensure_ascii=False,indent=1)
if len(sys.argv)>1:
    for k in sorted(out):
        if "hint=da" in k[0] or "large" in k[0]:
            for x in out[k]:
                if x[0] or x[1]>0.5: print("  ",k[0],x[3],"|",x[4],"|",x[5],round(x[1],2))
