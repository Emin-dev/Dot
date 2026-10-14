#!/usr/bin/env python3
"""Fetch only exact reviewed inputs. Build-time network only; never resolves or runs packages."""
import argparse,concurrent.futures,json,pathlib
from urllib.parse import urlparse,unquote
from search_payload import sha,hash_file,clean_name
from search_download import open_artifact,safe_target,validate_url
def entries(lock):
    for w in lock['wheels']:
        yield 'wheels/'+w['filename'],w
        yield 'sources/'+w['source']['filename'],w['source']
    yield lock['searxng']['archive']['filename'],lock['searxng']['archive']
    for kind in ('install_only','full','build_source'):
        v=lock['python'][kind];yield v['filename'],v
    for key,v in lock['python']['source_inputs'].items():
        yield 'sources/python/'+unquote(urlparse(v['url']).path.split('/')[-1]),v

def fetch(item,dest):
    relative,pin=item;p=safe_target(pathlib.Path(dest)/clean_name(relative))
    validate_url(pin['url'])
    if p.exists():
        if hash_file(p)!=pin['sha256'] or p.stat().st_size!=pin['size']:raise ValueError('cached artifact mismatch '+relative)
        return relative
    with open_artifact(pin['url']) as r:b=r.read(pin['size']+1)
    if len(b)!=pin['size'] or sha(b)!=pin['sha256']:raise ValueError('download identity mismatch '+relative)
    p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('xb') as f:f.write(b)
    return relative

def main():
    p=argparse.ArgumentParser();p.add_argument('--lock',required=True);p.add_argument('--output',required=True);p.add_argument('--workers',type=int,default=4);a=p.parse_args()
    lock=json.loads(pathlib.Path(a.lock).read_text());items=list(entries(lock))
    if len({n for n,_ in items})!=len(items):raise ValueError('duplicate input target')
    if not 1<=a.workers<=8:raise ValueError('workers must be 1–8')
    with concurrent.futures.ThreadPoolExecutor(a.workers) as ex:
        for name in ex.map(lambda i:fetch(i,a.output),items):print(name,flush=True)
if __name__=='__main__':main()
