#!/usr/bin/env python3
"""Build-only Search input verification and offline assembly. Never executes payload code."""
from __future__ import annotations
import argparse, base64, csv, email, hashlib, io, json, os, posixpath, re, shutil, stat, struct, tarfile, zipfile, unicodedata
from pathlib import Path, PurePosixPath
from packaging.markers import default_environment
from packaging.requirements import Requirement
from packaging.tags import cpython_tags, compatible_tags, mac_platforms
from packaging.utils import canonicalize_name, parse_wheel_filename
from packaging.version import Version

TARGET = {'python_full_version':'3.11.17','python_version':'3.11','implementation_name':'cpython',
          'implementation_version':'3.11.17','os_name':'posix','platform_machine':'arm64',
          'platform_python_implementation':'CPython','platform_system':'Darwin','sys_platform':'darwin',
          'platform_release':'25.4.0','platform_version':'Darwin 25.4.0','extra':''}
MACOS = (26, 4)
GATES = ('native_boundary','transient_cache','searxng_waitress_compatibility')
DISTRIBUTION_GATES = ('source_license','clean_mac','signed_relocation','release_signing','notarization')
MAX_FILES, MAX_BYTES = 100000, 2_000_000_000

def fail(msg): raise ValueError(msg)
def sha(b): return hashlib.sha256(b).hexdigest()
def hash_file(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
def save(p,data):
    p=Path(p);p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')
def clean_name(name):
    p=PurePosixPath(name)
    if not name or '\\' in name or name.startswith('/') or any(x in ('','.', '..') for x in name.split('/')) or any(ord(x)<32 for x in name) or ':' in name:
        fail('unsafe archive path: '+repr(name))
    return str(p)
def register_path(name, aliases):
    for i in range(1,len(name.split('/'))+1):
        prefix='/'.join(name.split('/')[:i]);key=unicodedata.normalize('NFD',prefix).casefold()
        if key in aliases and aliases[key]!=prefix:fail('case/normalization directory alias')
        aliases[key]=prefix

def is_system_library(path):
    # Prefix checks alone admit /usr/lib/../../outside.dylib as an OS library.
    return path==posixpath.normpath(path) and path.startswith(('/usr/lib/','/System/Library/'))

def version_int(v): return (v>>16, (v>>8)&255, v&255)
def macho(data):
    """Parse arm64 load commands without importing/executing native code."""
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide=data[:4]==b'\xca\xfe\xba\xbf'; count=struct.unpack_from('>I',data,4)[0]
        if count>32:fail('oversized universal Mach-O')
        found=[]
        for i in range(count):
            off=8+i*(32 if wide else 20)
            cpu,sub=struct.unpack_from('>II',data,off)
            start,size=struct.unpack_from('>QQ' if wide else '>II',data,off+8)
            if start+size>len(data):fail('truncated universal Mach-O')
            if cpu==0x100000c:found.extend(macho(data[start:start+size]))
        if not found:fail('native file has no arm64 slice')
        return found
    if data[:4]!=b'\xcf\xfa\xed\xfe':fail('unsupported native file format or architecture')
    if len(data)<32:fail('truncated Mach-O')
    magic,cpu,sub,typ,ncmd,total,flags,res=struct.unpack_from('<8I',data)
    if cpu!=0x100000c:fail('native file is not arm64')
    if ncmd>10000 or 32+total>len(data):fail('invalid Mach-O commands')
    at=32;libs=[];rpaths=[];deployment=[];identity=None
    for _ in range(ncmd):
        if at+8>32+total:fail('truncated load command')
        cmd,size=struct.unpack_from('<II',data,at)
        if size<8 or at+size>32+total:fail('invalid load command size')
        if cmd in (0xc,0x18|0x80000000,0x1f|0x80000000,0x23|0x80000000,0x20,0xd,0x1c|0x80000000):
            if size<12:fail('truncated string load command')
            off=struct.unpack_from('<I',data,at+8)[0]
            if off<12 or off>=size:fail('invalid load string offset')
            raw=data[at+off:at+size];nul=raw.find(b'\0')
            if nul<0:fail('unterminated load string')
            s=raw[:nul].decode('utf-8')
            if cmd==0xd:identity=s
            elif cmd==0x8000001c:rpaths.append(s)
            else:libs.append(s)
        elif cmd==0x24:
            if size<16:fail('truncated deployment command')
            deployment.append(version_int(struct.unpack_from('<I',data,at+8)[0]))
        elif cmd==0x32:
            if size<24:fail('truncated build version')
            platform,v=struct.unpack_from('<II',data,at+8)
            if platform!=1:fail('non-macOS native platform')
            deployment.append(version_int(v))
        at+=size
    if at!=32+total or not deployment:fail('missing or invalid deployment evidence')
    if max(deployment)>MACOS+(0,):fail('native deployment target exceeds macOS 26.4')
    for x in libs+rpaths:
        if x.startswith('/') and not is_system_library(x):fail('external native dependency: '+x)
        if not x.startswith(('/', '@loader_path','@executable_path','@rpath')):fail('relative native dependency: '+x)
    return [{'architecture':'arm64','deployment_target':'.'.join(map(str,max(deployment))),
             'libraries':libs,'rpaths':rpaths,'install_name':identity}]

def target_tags():
    platforms=list(mac_platforms(MACOS,'arm64'))
    return set(cpython_tags((3,11),['cp311'],platforms))|set(compatible_tags((3,11),'cp311',platforms))

def inspect_wheel(path):
    path=Path(path);name,version,build,tags=parse_wheel_filename(path.name)
    if not tags & target_tags():fail('incompatible target wheel '+path.name)
    with zipfile.ZipFile(path) as z:
        infos=z.infolist();names=[];seen=set();total=0;aliases={}
        for i in infos:
            if i.is_dir():continue
            n=clean_name(i.filename);register_path(n,aliases);k=unicodedata.normalize('NFD',n).casefold()
            if k in seen:fail('duplicate/case-alias wheel member')
            seen.add(k);names.append(n);total+=i.file_size
            mode=i.external_attr>>16
            if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0,stat.S_IFREG)):fail('wheel special file')
            if i.flag_bits&1:fail('encrypted wheel')
        if len(names)>MAX_FILES or total>MAX_BYTES:fail('wheel limits exceeded')
        if z.testzip():fail('wheel CRC mismatch')
        roots={n.split('/')[0] for n in names if '.dist-info/' in n}
        if len(roots)!=1:fail('wheel requires exactly one dist-info')
        root=roots.pop();meta=email.message_from_bytes(z.read(root+'/METADATA'))
        if canonicalize_name(meta['Name'])!=name or Version(meta['Version'])!=version:fail('wheel metadata identity mismatch')
        reqpython=meta.get('Requires-Python')
        if reqpython:
            from packaging.specifiers import SpecifierSet
            if Version(TARGET['python_full_version']) not in SpecifierSet(reqpython):fail('incompatible Python version')
        wheelmeta=email.message_from_bytes(z.read(root+'/WHEEL'))
        from packaging.tags import parse_tag
        declared=set()
        for t in wheelmeta.get_all('Tag',[]):declared |= parse_tag(t)
        if declared!=tags:fail('WHEEL tags disagree with filename')
        record=root+'/RECORD';rows={}
        for row in csv.reader(io.StringIO(z.read(record).decode())):
            if len(row)!=3 or row[0] in rows:fail('invalid wheel RECORD')
            rows[row[0]]=row[1:]
        if set(rows)!=set(names):fail('wheel RECORD file set mismatch')
        native=[];notices=[]
        for n in names:
            b=z.read(n);h,s=rows[n]
            if n==record:
                if h or s:fail('RECORD must be unhashed')
            elif h!='sha256='+base64.urlsafe_b64encode(hashlib.sha256(b).digest()).rstrip(b'=').decode() or s!=str(len(b)):
                fail('wheel RECORD hash/size mismatch: '+n)
            if n.endswith(('.so','.dylib')) or b[:4] in (b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
                native.append({'path':n,'sha256':sha(b),'slices':macho(b)})
            if any(x in PurePosixPath(n).name.lower() for x in ('license','copying','notice','authors')) or '/licenses/' in n.lower():
                notices.append({'path':n,'sha256':sha(b),'size':len(b)})
            if '.data/' in n:fail('wheel .data scheme requires separately reviewed installer mapping')
            if n.endswith(('.pth','.egg-link')):fail('startup path hook in wheel')
        return {'name':name,'version':str(version),'filename':path.name,'sha256':hash_file(path),'size':path.stat().st_size,
                'tags':sorted(map(str,tags)),'requires_dist':meta.get_all('Requires-Dist',[]),'requires_python':reqpython,
                'license_expression':meta.get('License-Expression') or meta.get('License'),
                'license_classifiers':[x for x in meta.get_all('Classifier',[]) if x.startswith('License ::')],
                'license_files':meta.get_all('License-File',[]),'notice_members':notices,'native_members':native,
                'metadata_sha256':sha(z.read(root+'/METADATA')),'record_sha256':sha(z.read(record)),
                'member_count':len(names),'uncompressed_bytes':total}

def validate_closure(wheels,roots):
    by={w['name']:w for w in wheels}
    if len(by)!=len(wheels):fail('duplicate distributions')
    active={};pending=[(None,r) for r in roots];edges=[];done=set()
    while pending:
        parent,s=pending.pop();r=Requirement(s);name=canonicalize_name(r.name)
        if r.url:fail('direct URL dependency needs explicit review')
        if r.marker and not r.marker.evaluate(TARGET):continue
        if name not in by or Version(by[name]['version']) not in r.specifier:fail('unsatisfied requirement '+s)
        edges.append({'from':parent,'requirement':s,'to':name})
        extras=active.setdefault(name,{''});new=set(r.extras)|{''};extras|=new
        for extra in sorted(extras):
            if (name,extra) in done:continue
            done.add((name,extra))
            for dep in by[name]['requires_dist']:
                q=Requirement(dep);env=dict(TARGET,extra=extra)
                if q.marker is None or q.marker.evaluate(env):
                    # Evaluate marker only in its parent extra context, then strip it.
                    q.marker=None;pending.append((name,str(q)))
    if set(active)!=set(by):fail('unreachable/unnecessary wheel(s): '+','.join(sorted(set(by)-set(active))))
    return sorted(edges,key=lambda x:(x['from'] or '',x['to'],x['requirement']))

def verify_wheels(lock,wheelhouse):
    out=[]
    for w in lock['wheels']:
        p=Path(wheelhouse)/w['filename']
        if p.is_symlink() or not p.is_file() or hash_file(p)!=w['sha256'] or p.stat().st_size!=w['size']:fail('wheel artifact mismatch: '+w['filename'])
        got=inspect_wheel(p)
        for k,v in got.items():
            if w.get(k)!=v:fail('wheel audit mismatch: '+w['filename']+' '+k)
        out.append(got)
    if {p.name for p in Path(wheelhouse).iterdir()}!={w['filename'] for w in lock['wheels']}:fail('unlisted wheelhouse member')
    return validate_closure(out,lock['roots'])

def tar_regular_map(path, only_prefix=None):
    """Read bounded archive. Internal links may later be materialized, never extracted as links."""
    data={};links={};modes={};seen=set();total=0;aliases={}
    with tarfile.open(path,'r:*') as t:
        for m in t:
            if only_prefix is not None and not m.name.startswith(only_prefix):continue
            n=clean_name(m.name.rstrip('/'));register_path(n,aliases);key=unicodedata.normalize('NFD',n).casefold()
            if key in seen:fail('duplicate/case-alias archive path')
            seen.add(key)
            if len(seen)>MAX_FILES:fail('archive limit exceeded')
            if m.isdir():continue
            if m.isfile():
                total+=m.size
                if total>MAX_BYTES or len(data)+len(links)>MAX_FILES:fail('archive limit exceeded')
                data[n]=t.extractfile(m).read();modes[n]=0o755 if m.mode&0o111 else 0o644
            elif m.issym() or m.islnk():
                if not m.linkname or m.linkname.startswith('/') or '\\' in m.linkname:fail('unsafe archive link')
                target=posixpath.normpath(posixpath.join(posixpath.dirname(n),m.linkname) if m.issym() else m.linkname)
                clean_name(target)
                if target.split('/')[0]!=n.split('/')[0]:fail('external archive link')
                links[n]=target
            else:fail('special archive member')
    for n in links:
        target=links[n];visited={n}
        while target in links:
            if target in visited:fail('cyclic archive link')
            visited.add(target);target=links[target]
        if target not in data:fail('link target is not regular file: '+n)
        total+=len(data[target])
        if total>MAX_BYTES:fail('materialized archive limit exceeded')
        data[n]=data[target];modes[n]=modes[target]
    # Parent-file/child aliases cannot be materialized safely.
    for n in data:
        if any(str(p) in data for p in PurePosixPath(n).parents if str(p)!='.'):fail('archive file is also directory')
    return data,modes,links

def write_new(root,name,b,mode=0o644):
    p=root/clean_name(name)
    if p.exists() or p.is_symlink():fail('installation collision: '+name)
    p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b);p.chmod(mode)

def exact_component_inputs(lock):
    """Expected artifact/source/notice identities; unknown native sources stay unresolved.

    These are provenance checks against the reviewed lock, not a legal opinion or
    proof that an upstream source archive reproduces a publisher's binary.
    """
    expected={}
    for w in lock.get('wheels',[]):
        expected[w['name']]={'artifact':w.get('sha256'),'sources':[w['source']] if w.get('source') else [],
                            'notices':w.get('notice_members',[])}
    py=lock.get('python',{});sx=lock.get('searxng',{})
    def add(name,artifact,source=None):
        expected[name]={'artifact':artifact.get('sha256'),'sources':[source] if source else [],'notices':[]}
    add('searxng',sx.get('archive',{}),sx.get('archive'))
    add('cpython',py.get('install_only',{}),py.get('source_inputs',{}).get('cpython-3.11'))
    add('python-build-standalone',py.get('build_source',{}),py.get('build_source'))
    for name in py.get('native_components',[]):
        kind,_,component=name.partition(':')
        if kind=='cpython-native':
            add(name,py.get('install_only',{}),py.get('source_inputs',{}).get(component))
        else:
            parent={'lxml-native':'lxml','curl-cffi-native':'curl-cffi','pyyaml-native':'pyyaml'}.get(kind)
            add(name,{'sha256':expected.get(parent,{}).get('artifact')})
    return expected

def assemble(lock,inputs,out,helper):
    """Offline archive/wheel unpack; no pip, build hook, imports, or subprocesses."""
    out=Path(out);inputs=Path(inputs);helper=Path(helper)
    if out.exists():fail('output must be a new directory')
    verify_wheels(lock,inputs/'wheels')
    for item in [lock['python']['install_only'],lock['searxng']['archive']]:
        p=inputs/item['filename']
        if p.is_symlink() or hash_file(p)!=item['sha256'] or p.stat().st_size!=item['size']:fail('archive identity mismatch')
    for item in lock['helper_inputs']:
        p=helper/item['path']
        if p.is_symlink() or hash_file(p)!=item['sha256']:fail('helper input mismatch: '+item['path'])
    out.mkdir(parents=True)
    aliases={}
    def install(name,data,mode=0o644):
        # Validate the whole assembled namespace, including aliases spanning
        # separate wheels, on case-sensitive Linux build hosts too.
        register_path(clean_name(name),aliases)
        write_new(out,name,data,mode)
    pdata,modes,links=tar_regular_map(inputs/lock['python']['install_only']['filename'])
    pruned=[]
    for n,b in pdata.items():
        if n.startswith('python/lib/python3.11/site-packages/') or n.endswith('.pyc'):
            pruned.append(n);continue
        install(n,b,modes[n])
    site='python/lib/python3.11/site-packages/'
    for w in lock['wheels']:
        with zipfile.ZipFile(inputs/'wheels'/w['filename']) as z:
            for i in z.infolist():
                if not i.is_dir():install(site+i.filename,z.read(i),0o644)
    prefix='searxng-'+lock['searxng']['revision']+'/'
    src,_,source_links=tar_regular_map(inputs/lock['searxng']['archive']['filename'],prefix+'searx/')
    if source_links:fail('unexpected SearXNG source links')
    for n,b in src.items():
        if n.startswith(prefix+'searx/'):
            install(site+n[len(prefix):],b)
    frozen=lock['searxng']['version_frozen']
    install(site+'searx/version_frozen.py',frozen.encode())
    ddg=out/site/'searx/engines/duckduckgo.py'
    b=ddg.read_bytes();patch=lock['searxng']['transient_patch']
    if sha(b)!=patch['original_sha256'] or b.count(patch['old'].encode())!=1:fail('DDG original source mismatch')
    b=b.replace(patch['old'].encode(),patch['new'].encode())
    if sha(b)!=patch['patched_sha256']:fail('DDG patched source mismatch')
    ddg.write_bytes(b)
    for item in lock['helper_inputs']:
        install(item['path'],(helper/item['path']).read_bytes())
    inv=[{'path':p.relative_to(out).as_posix(),'size':p.stat().st_size,'sha256':hash_file(p)} for p in sorted(out.rglob('*')) if p.is_file()]
    # This is deliberately NOT a production runtime manifest or acceptance receipt.
    save(out/'evidence/assembly-input-receipt.json',{'schema':1,'status':'unaccepted-static-assembly','lock_sha256':sha(json.dumps(lock,sort_keys=True,separators=(',',':')).encode()),'materialized_links':links,'pruned_from_python_archive':pruned,'files':inv,'native_executed':False})
    return {'files':len(inv),'native_executed':False,'production_admitted':False}

def audit_native_tree(root):
    root=Path(root).resolve();native=[]
    for p in sorted(root.rglob('*')):
        if p.is_symlink():fail('native audit refuses symlinks')
        if not p.is_file():continue
        with p.open('rb') as f:magic=f.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):continue
        native.append({'path':p.relative_to(root).as_posix(),'sha256':hash_file(p),'slices':macho(p.read_bytes())})
    indexed={n['path'] for n in native};edges=[]
    for n in native:
        loader=posixpath.dirname(n['path'])
        def expand(path):
            if path.startswith('@loader_path/'):return posixpath.normpath(posixpath.join(loader,path[len('@loader_path/'):]))
            if path.startswith('@executable_path/'):return posixpath.normpath('python/bin/'+path[len('@executable_path/'):])
            return path
        for sl in n['slices']:
            for lib in sl['libraries']:
                if is_system_library(lib):
                    edges.append({'from':n['path'],'to':lib,'kind':'system'});continue
                if lib.startswith('@rpath/'):
                    candidates=[expand(r)+'/'+lib[len('@rpath/'):] for r in sl['rpaths']]
                else:candidates=[expand(lib)]
                candidates=[posixpath.normpath(x) for x in candidates]
                matches=[x for x in candidates if x in indexed]
                if len(set(matches))!=1:fail('unresolved/ambiguous bundled native dependency: '+n['path']+' '+lib)
                edges.append({'from':n['path'],'to':matches[0],'kind':'bundled'})
    return {'schema':1,'native_files':native,'dynamic_edges':edges,'native_execution':False,
            'static_vendored_source_provenance':'unresolved; Mach-O load commands cannot enumerate static libraries'}

def release_gate(lock,coverage,payload,manifest,source_root=None):
    """Fail closed on unresolved artifact/source/license/native evidence. Does not set gates."""
    problems=[];by={x['component']:x for x in coverage.get('components',[])}
    if len(by)!=len(coverage.get('components',[])):problems.append('duplicate compliance component')
    pinned=exact_component_inputs(lock);expected=set(pinned)
    if set(by)!=expected:problems.append('component inventory does not equal exact dependency/native closure')
    for name in sorted(expected):
        row=by.get(name,{})
        identity=pinned[name]
        if not identity['artifact'] or row.get('artifact_sha256')!=identity['artifact']:
            problems.append(name+': artifact identity does not match lock')
        # Collecting a different archive with a plausible filename cannot stand
        # in for the exact publisher source pinned for this selected binary.
        for source in identity['sources']:
            if not any(ref.get('sha256')==source.get('sha256') and ref.get('size')==source.get('size')
                       for ref in row.get('sources',[]) if isinstance(ref,dict)):
                problems.append(name+': pinned source evidence missing')
        for notice in identity['notices']:
            if not any(ref.get('sha256')==notice.get('sha256') and ref.get('size')==notice.get('size')
                       for ref in row.get('notices',[]) if isinstance(ref,dict)):
                problems.append(name+': pinned notice evidence missing')
        for key in ('license_review','source_correspondence','source_fulfillment','notice_coverage'):
            if row.get(key)!='verified':problems.append(name+': '+key+' unresolved')
        for field in ('notices','sources','review_evidence'):
            if not row.get(field):problems.append(name+': missing '+field)
            for ref in row.get(field,[]):
                try:
                    base=Path(source_root) if field=='sources' and source_root is not None else Path(payload)
                    relative=clean_name(ref['path']);p=base/relative
                    aliases=any((base/parent).is_symlink() for parent in PurePosixPath(relative).parents if str(parent)!='.')
                    if (base.is_symlink() or p.is_symlink() or aliases or not p.is_file()
                            or p.stat().st_nlink!=1 or not p.resolve().is_relative_to(base.resolve())
                            or hash_file(p)!=ref['sha256']
                            or ('size' in ref and p.stat().st_size!=ref['size'])):
                        problems.append(name+': bad '+field+' artifact')
                except (KeyError,ValueError,OSError,TypeError):problems.append(name+': invalid evidence reference')
    if manifest.get('protocol')!=1 or manifest.get('searxng_revision')!=lock.get('searxng',{}).get('revision') or manifest.get('waitress_version')!='3.0.2':problems.append('manifest source/protocol identity mismatch')
    if manifest.get('native_bootstrap')!='bin/dot-search-bootstrap' or manifest.get('acceptance_receipt')!='evidence/search-acceptance.json':problems.append('manifest native bootstrap/receipt contract mismatch')
    files=manifest.get('files',[]);indexed={x['path']:x for x in files}
    if len(indexed)!=len(files):problems.append('duplicate manifest files')
    if not {'python/bin/python3','bin/dot-search-bootstrap','dot_search.py','search.sb','evidence/search-acceptance.json'}.issubset(indexed):problems.append('required native payload files absent')
    actual={p.relative_to(payload).as_posix() for p in Path(payload).rglob('*') if p.is_file() and p.relative_to(payload).as_posix()!='search-runtime-manifest.json'}
    if set(indexed)!=actual:problems.append('manifest does not seal exact payload')
    for p in [Path(payload),*Path(payload).rglob('*')]:
        st=p.lstat()
        if (not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode))
                or st.st_mode&0o022 or (stat.S_ISREG(st.st_mode) and st.st_nlink!=1)):
            problems.append('unsafe payload filesystem identity')
    for name,ref in indexed.items():
        try:
            p=Path(payload)/clean_name(name)
            if not p.is_file() or p.stat().st_size!=ref['size'] or hash_file(p)!=ref['sha256']:problems.append('payload manifest mismatch')
        except (KeyError,ValueError,OSError):problems.append('invalid payload manifest entry')
    try:
        p=Path(payload)/clean_name(manifest['acceptance_receipt']);receipt=json.loads(p.read_text())
        digest=sha(''.join(f"{r['path']}\t{r['size']}\t{r['sha256']}\n" for r in sorted(files,key=lambda r:r['path'].encode()) if not r['path'].startswith('evidence/')).encode())
        if receipt['schema']!=1 or receipt['platform']!='macOS-arm64' or receipt['payload_digest']!=digest:problems.append('acceptance receipt identity mismatch')
        for g in GATES:
            e=receipt['gates'][g];ref=indexed.get(e['report'],{})
            if e['result']!='passed' or not e['report'].startswith('evidence/') or ref.get('sha256')!=e['sha256']:problems.append(g+': acceptance unresolved')
    except (KeyError,ValueError,OSError):problems.append('native acceptance receipt absent/invalid')
    for g in DISTRIBUTION_GATES:
        e=coverage.get('distribution_gates',{}).get(g,{})
        ref=indexed.get(e.get('report'),{})
        if e.get('result')!='passed' or not str(e.get('report','')).startswith('evidence/') or not e.get('sha256') or ref.get('sha256')!=e.get('sha256'):
            problems.append(g+': final distribution evidence unresolved')
    # Passing this build-data check never replaces native code-signature/team/resource-seal verification.
    return sorted(set(problems))

def main():
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='cmd',required=True)
    q=sub.add_parser('verify');q.add_argument('--lock',required=True);q.add_argument('--wheelhouse',required=True)
    q=sub.add_parser('assemble');q.add_argument('--lock',required=True);q.add_argument('--inputs',required=True);q.add_argument('--output',required=True);q.add_argument('--helper',required=True)
    q=sub.add_parser('audit-native');q.add_argument('--lock',required=True);q.add_argument('--payload',required=True);q.add_argument('--report',required=True)
    q=sub.add_parser('release-gate');q.add_argument('--lock',required=True);q.add_argument('--coverage',required=True);q.add_argument('--payload',required=True);q.add_argument('--manifest',required=True);q.add_argument('--source-root')
    a=p.parse_args();lock=json.loads(Path(a.lock).read_text())
    if a.cmd=='verify':print(json.dumps({'edges':len(verify_wheels(lock,a.wheelhouse)),'native_executed':False}))
    elif a.cmd=='assemble':print(json.dumps(assemble(lock,a.inputs,a.output,a.helper)))
    elif a.cmd=='audit-native':save(a.report,audit_native_tree(a.payload));print('Static native dependency audit written; no native execution.')
    else:
        problems=release_gate(lock,json.loads(Path(a.coverage).read_text()),Path(a.payload),json.loads(Path(a.manifest).read_text()),a.source_root)
        print(json.dumps({'input_evidence_gate_passed':not problems,'blockers':problems},indent=2));return bool(problems)
    return 0
if __name__=='__main__':
    try:raise SystemExit(main())
    except (ValueError,OSError,zipfile.BadZipFile,tarfile.TarError) as e:raise SystemExit('Search input verification failed: '+str(e))
