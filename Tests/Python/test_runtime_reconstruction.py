"""Portable adversarial contracts. Every accepted tiny basis is isolated test data.

No fixture is installed in production policy; no portable run finalizes a runtime.
"""
import copy
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('runtime_reconstruction', ROOT / 'scripts/reconstruct_runtime_payload.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def file(path, raw=b'fixture\n', mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw); path.chmod(mode)
    return {'bytes':len(raw),'sha256':m.digest(raw)}


class Fixture(unittest.TestCase):
    def setUp(self):
        # macOS may spell its system temp directory through /var -> /private/var.
        # Canonicalize only that trusted base before allocating our test fixture;
        # production Root must still reject aliases in supplied runtime paths.
        self.tmp = tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve())
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source'; self.source.mkdir()
        self.runtime = self.root / 'original'; self.runtime.mkdir(mode=0o700)
        self.upstream = self.root / 'upstream'; self.upstream.mkdir()
        self.stage = self.root / 'stage'
        self.collector = self.root / 'collector'; self.collector.mkdir()
        self.inventory = self.root / 'inventory.json'
        self.policy = json.loads((ROOT / m.POLICY_PATH).read_text())
        self.policy['source_bindings'] = {}
        self.policy['phase_source_paths'] = {'prepare':[m.POLICY_PATH,'scripts/reconstruct_runtime_payload.py','scripts/patch_splash_listener.py','Resources/Runtime/splash-managed-listener-patch.json']}
        self.policy['phase_source_paths']['native'] = self.policy['phase_source_paths']['prepare'] + ['Resources/Runtime/dot_process.py']
        self.policy['source_bindings']['Resources/Runtime/dot_process.py'] = file(self.source/'Resources/Runtime/dot_process.py',b'# synthetic native helper\n')
        self.policy['speech_asset_pins'] = []
        self.policy['overlay']['files'] = []
        names = ['Splash/install/launcher.py','Splash/server/serve_options.py','Splash/server/server.py']
        for n, name in enumerate(names):
            before = ('# old-v1-' + str(n) + '\n').encode()
            upstream = ('# pristine-' + str(n) + '\n').encode()
            after = ('# new-v2-' + str(n) + '\n').encode()
            file(self.runtime / name, before)
            file(self.upstream / name.removeprefix('Splash/'), upstream)
            self.policy['overlay']['files'].append({'path':name,'upstream_sha256':m.digest(upstream),
                'old_v1_sha256':m.digest(before),'new_v2_sha256':m.digest(after)})
        patcher = b"from pathlib import Path\ndef overlay(root):\n    names=('install/launcher.py','server/serve_options.py','server/server.py')\n    for i,p in enumerate(names):\n        assert (Path(root)/p).read_bytes() == ('# pristine-' + str(i) + '\\n').encode()\n    return {p: '# new-v2-' + str(i) + '\\n' for i,p in enumerate(names)}\n"
        self.policy['source_bindings']['scripts/patch_splash_listener.py'] = file(self.source / 'scripts/patch_splash_listener.py', patcher)
        file(self.source / 'scripts/reconstruct_runtime_payload.py', b'# isolated fixture recipe\n')
        for directory in ('Splash','Voice','STT'):
            file(self.runtime / directory / 'LICENSE', ('test notice ' + directory).encode())
        file(self.runtime / 'Voice/python/bin/python3', b'inert interpreter bytes', 0o755)
        os.symlink('python3', self.runtime / 'Voice/python/bin/python')
        self.historical = file(self.runtime / m.MANIFEST, b'{"fixture_only":true,"import_probe":{"status":"passed_offline"}}\n')
        self.basis = {'id':'fixture-historical','mode':'reviewed_owner_historical_closure',
            'historical_manifest':self.historical,'collector_bundle':{},
            'acceptance':{'scope':'personal_candidate','decision_id':'TEST ONLY; not a real approval'},
            'closure':[], 'components':[], 'bytecode_removals':[],
            'module_inventory_review':{'collector_bundle_identity':'','alternate_module_paths':[]},
            'native_inventory':[]}
        self.rebaseline()
        self.inventory.write_bytes(m.canonical({'schema_version':1,'locations':{
            'runtime':str(self.runtime),'collector_report':str(self.collector),'upstream':str(self.upstream)}}))

    def rebaseline(self):
        self.basis['closure'] = m.tree(self.runtime, m.Budget(self.policy['bounds']), self.historical)
        self.basis['components'] = []
        for directory, role in zip(('Splash','Voice','STT'),self.policy['component_roles']):
            self.basis['components'].append({'role':role,'license':'test-only',
                'license_paths':[directory + '/LICENSE'],
                'files':[r['path'] for r in self.basis['closure'] if r['path']==directory or r['path'].startswith(directory+'/')]})
        self.emit_collector()
        self.save_policy()

    def emit_collector(self):
        manifest={'schema_version':1,'kind':'verified_runtime_payload',
            'transport_patch':self.policy['overlay']['from_id'],'components':self.basis['components'],
            'files':[row for row in self.basis['closure'] if row['kind']!='directory'],
            'import_probe':{'status':'passed_offline'},'dependency_lock_complete':True}
        self.historical=file(self.runtime/m.MANIFEST,m.canonical(manifest))
        self.basis['historical_manifest']=self.historical
        all_rows=m.tree(self.runtime,m.Budget(self.policy['bounds']),self.historical)
        entries={};directories={}
        for row in all_rows+[{'path':m.MANIFEST,'kind':'file'}]:
            name=row['path'];path=self.runtime/name;info=path.lstat()
            token=[info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_ctime_ns]
            if row['kind']=='directory':directories[name]=token
            elif row['kind']=='file':
                raw=path.read_bytes();entries[name]={'kind':'file','bytes':len(raw),'sha256':m.digest(raw),
                    'stat':token,'hardlink_count':1,'mach_o_magic':raw[:4] in (b'\xcf\xfa\xed\xfe',)}
            else:
                resolved=path.resolve();entries[name]={'kind':'symlink','target':os.readlink(path),
                    'resolved':str(resolved.relative_to(self.runtime)),'resolved_kind':'directory' if resolved.is_dir() else 'file','stat':token}
        scope={'runtime':m.COLLECTOR_RUNTIME,'support':list(m.COLLECTOR_SCOPES),
               'excluded':['Contents/Resources/OfflineModels','user data/history','assembly caches']}
        limits={'manifest_bytes':16000000,'entries':100000,'closure_bytes':5000000000,'native_files':2048,
                'wall_seconds':1800,'cumulative_path_bytes':16000000,'tool_output_each':262144,'tool_output_total':32000000}
        start={'schema_version':2,'started_utc':'2026-10-14T00:00:00Z','app_path':'/synthetic/Dot.app',
               'status':'collecting','trust_conclusion':'not_established','scope':scope,'limits':limits,
               'limitations':['SYNTHETIC FIXTURE ONLY; no native observation']}
        support={scope:{'status':'missing'} for scope in m.COLLECTOR_SCOPES}
        native={n:v['sha256'] for n,v in entries.items() if v.get('mach_o_magic')}
        events=[('chip_family_only','sysctl'),('app','outer_signature_display'),
                ('app','outer_signature_verify_strict'),('app','outer_signature_verify_deep_strict')]
        events += [(m.COLLECTOR_RUNTIME+'/'+n,operation) for n in native for operation in sorted(m.COLLECTOR_NATIVE_OPS)]
        tools=[]
        for target,operation in events:
            event={'target':target,'operation':operation,'result':{'argv':['/synthetic/test-only'],
                'returncode':0,'reason':None,'stdout':'synthetic fixture','stderr':'','output_bytes':17,
                'elapsed_seconds':0.125,'sandbox':'deny_writes_network_and_bundle_execution_v1',
                'sandbox_profile_sha256':m.digest(b'synthetic profile'),
                'exit_code_scope':'observed sandbox-exec process; target tool may not have started'}}
            if target=='chip_family_only':event['result']['argv']=['/usr/sbin/sysctl','-n','machdep.cpu.brand_string']
            elif target=='app':
                prefixes={'outer_signature_display':['--display','--verbose=4','--requirements','-'],
                    'outer_signature_verify_strict':['--verify','--strict','--verbose=4'],
                    'outer_signature_verify_deep_strict':['--verify','--deep','--strict','--verbose=4']}
                event['result']['argv']=['/usr/bin/codesign']+prefixes[operation]+[start['app_path']]
            else:
                prefixes={'architecture':['/usr/bin/lipo','-archs'],'dependencies':['/usr/bin/otool','-L'],
                    'load_commands':['/usr/bin/otool','-l'],'signature_display':['/usr/bin/codesign','--display','--verbose=4','--requirements','-'],
                    'signature_verify_strict':['/usr/bin/codesign','--verify','--strict','--verbose=4']}
                event['result']['argv']=prefixes[operation]+['/dev/fd/9']
            if target.startswith(m.COLLECTOR_RUNTIME+'/'):
                event.update(sha256=native[target[len(m.COLLECTOR_RUNTIME)+1:]],descriptor_bound=True)
            tools.append(event)
        summary={**start,'status':'collected','finished_utc':'2026-10-14T00:01:00Z','collector_exit_code':0,
            'runtime_manifest':{**self.historical,'historical_report_digest_matches':False,
                'historical_digest_is_not_vendor_provenance':True,'entries':len(manifest['files']),
                'transport_patch':manifest['transport_patch'],'components':manifest['components']},
            'runtime_comparison':{'matches':True,'missing':[],'extra':[],'mismatches':[]},
            'speech_assets':{},'metadata':{
                'Contents/Info.plist':{'bytes':123,'sha256':m.digest(b'fixture plist'),'selected_fields':{'CFBundleIdentifier':'test.fixture'}},
                'Contents/Resources/build-provenance.json':{'status':'missing'},
                'Contents/_CodeSignature/CodeResources':{'bytes':123,'sha256':m.digest(b'fixture seal'),
                    'manifest_entries':{'files2':{'hash2':{'bytes_hex':'00'}}},
                    'rules':{'rules':None,'rules2':{'^Resources/':{'weight':10000.5}}},'seal_coverage_conclusion':'unreviewed'}},
            'direct_hashed_bytes':sum(v.get('bytes',0) for v in entries.values()),
            'actual_entries_including_directories':len(entries)+len(directories)-1,
            'trusted_tool_availability':{x:True for x in ('codesign','otool','lipo','sysctl','sandbox')},
            'native_file_count':len(native),'metadata_stable_across_collection':True,
            'all_tool_invocations_completed':True,'all_tool_returncodes_zero':True}
        objects={'collection-start.json':start,'runtime-inventory.json':{'entries':entries,'directories':directories},
                 'support-inventory.json':support,'apple-tools.json':tools,'report.json':summary}
        for name,value in objects.items():file(self.collector/name,(json.dumps(value,indent=2)+'\n').encode())
        file(self.collector/'runtime-manifest.original.json',(self.runtime/m.MANIFEST).read_bytes())
        file(self.collector/'COMPLETE.txt',b'Collection finished; inspect report.json. Exit code: 0\nA complete report is not an admission or vendor-origin approval.\n')
        self.repin_collector()

    def repin_collector(self):
        pins={name:{'bytes':(self.collector/name).stat().st_size,'sha256':m.digest((self.collector/name).read_bytes())}
              for name in m.COLLECTOR_ARTIFACTS}
        self.basis['collector_bundle']={'schema_version':2,'collector_source_sha256':m.COLLECTOR_SHA,'artifacts':pins}
        self.basis['module_inventory_review']['collector_bundle_identity']=m.digest(m.canonical(self.basis['collector_bundle']))
        inventory=json.loads((self.collector/'runtime-inventory.json').read_text())
        self.basis['native_inventory']=[{'path':n,'sha256':v['sha256']} for n,v in sorted(inventory['entries'].items()) if v.get('mach_o_magic')]

    def save_policy(self):
        patch_record={'id':self.policy['overlay']['to_id'],'upstream_revision':self.policy['overlay']['upstream_revision'],
            'files':[{'path':x['path'],'upstream_sha256':x['upstream_sha256'],'sha256':x['new_v2_sha256']} for x in self.policy['overlay']['files']]}
        self.policy['source_bindings']['Resources/Runtime/splash-managed-listener-patch.json']=file(
            self.source/'Resources/Runtime/splash-managed-listener-patch.json',m.canonical(patch_record))
        self.policy['accepted_historical_baselines'] = [self.basis]
        file(self.source / m.POLICY_PATH, m.canonical(self.policy))

    def context(self, phase='prepare'):
        return m.Context(self.source, phase)

    def prepare(self):
        return m._prepare(self.context(), self.basis['id'], self.inventory, self.stage)

    def rejects(self, function, code=None):
        with self.assertRaises(m.Rejected) as error:
            function()
        if code is not None:
            self.assertEqual(error.exception.code, code)
        return str(error.exception)

    def test_prepare_is_inert_and_preserves_source(self):
        before = m.tree(self.runtime, m.Budget(self.policy['bounds']), self.historical)
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('subprocess forbidden')), \
             patch.object(socket, 'socket', side_effect=AssertionError('network forbidden')):
            result = self.prepare()
            status = m._status(self.context(), self.stage)
        self.assertEqual(result['kind'],'runtime_reconstruction_prepared')
        self.assertFalse(result['native_accepted']); self.assertFalse(status['native_accepted'])
        self.assertFalse((self.stage/'payload'/m.MANIFEST).exists())
        self.assertFalse((self.stage/'accepted-runtime.json').exists())
        self.assertEqual(m.tree(self.runtime,m.Budget(self.policy['bounds']),self.historical),before)
        self.assertEqual(stat.S_IMODE(self.stage.stat().st_mode),0o700)
        for row in before:
            if row['kind']=='file':
                a=(self.runtime/row['path']).stat(); b=(self.stage/'payload'/row['path']).stat()
                self.assertNotEqual((a.st_dev,a.st_ino),(b.st_dev,b.st_ino))
                self.assertEqual(b.st_nlink,1)

    def test_patcher_never_reopens_mutable_source_paths(self):
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('unbounded pathname read forbidden')):
            self.prepare()
            m._status(self.context(), self.stage)

    def test_casefolded_affected_bytecode_aliases_are_rejected(self):
        variants=('Splash/server/__PYCACHE__/SERVER.cpython-313.PYC',
                  'Splash/server/__pycache__/SERVER.CPYTHON-313.PYC',
                  'Splash/server/SERVER.PYC',
                  'Splash/server/__PYCACHE__/server.pyc')
        for name in variants:
            with self.subTest(name=name):
                target=self.runtime/name
                file(target,b'stale alias')
                try:
                    self.rebaseline()
                    self.assertIn('bytecode',self.rejects(self.prepare))
                    self.assertFalse(self.stage.exists())
                finally:
                    target.unlink()
                    if target.parent.name.casefold() == '__pycache__':
                        target.parent.rmdir()

    def test_affected_cache_directory_symlinks_are_rejected(self):
        file(self.runtime/'Voice/cache/server.cpython-313.pyc',b'old source cache')
        for spelling in ('__pycache__','__PYCACHE__'):
            with self.subTest(spelling=spelling):
                link=self.runtime/'Splash/server'/spelling
                os.symlink('../../Voice/cache',link)
                try:
                    self.rebaseline()
                    self.assertIn('cache directory symlink',self.rejects(self.prepare))
                    self.assertFalse(self.stage.exists())
                finally:
                    link.unlink()

    def test_reserved_manifest_case_alias_rejected_in_tree_and_rows(self):
        alias='RUNTIME-MANIFEST.JSON'
        # Rename through a distinct entry so case-insensitive filesystems retain
        # the alias spelling instead of overwriting the canonical manifest.
        (self.runtime/m.MANIFEST).rename(self.runtime/'manifest-case-rename').rename(self.runtime/alias)
        self.assertIn(alias,{path.name for path in self.runtime.iterdir()})
        self.assertEqual((self.runtime/alias).read_bytes(),(self.collector/'runtime-manifest.original.json').read_bytes())
        self.assertIn('manifest case alias',self.rejects(lambda:m.tree(
            self.runtime,self.context().budget,self.historical)))
        rows=copy.deepcopy(self.basis['closure'])
        rows.append({'path':alias,'kind':'file','mode':0o644,**self.historical})
        self.assertIn('manifest',self.rejects(lambda:m.validate_rows(rows,self.policy['bounds'])))
        # Preparation opens the canonical manifest before walking the tree.
        # Supply it separately only where both spellings can physically coexist.
        if not (self.runtime/m.MANIFEST).exists():
            file(self.runtime/m.MANIFEST,(self.runtime/alias).read_bytes())
        self.assertIn('manifest case alias',self.rejects(self.prepare))
        self.assertFalse(self.stage.exists())

    def test_readonly_overlay_parents_and_sources_preserve_exact_modes(self):
        self.runtime.chmod(0o555)
        for name in ('Splash/install','Splash/server'):
            (self.runtime/name).chmod(0o555)
        for item in self.policy['overlay']['files']:
            (self.runtime/item['path']).chmod(0o444)
        self.rebaseline()
        original=copy.deepcopy(self.basis['closure'])
        self.prepare();m._status(self.context(),self.stage)
        self.assertEqual(m.tree(self.runtime,self.context().budget,self.historical),original)
        for name in ('.','Splash/install','Splash/server'):
            self.assertEqual(stat.S_IMODE((self.stage/'payload'/name).stat().st_mode),0o555)
        for item in self.policy['overlay']['files']:
            self.assertEqual(stat.S_IMODE((self.stage/'payload'/item['path']).stat().st_mode),0o444)

    def test_readonly_private_parent_mode_is_restored_on_transform_failure(self):
        (self.runtime/'Splash/server').chmod(0o555)
        self.rebaseline()
        original=m.write_new
        def fail_transform(fd,name,data,mode=0o600):
            if name=='Splash/server/serve_options.py':
                raise m.Rejected('injected transform failure',m.MUTATION)
            return original(fd,name,data,mode)
        with patch.object(m,'write_new',side_effect=fail_transform):
            self.rejects(self.prepare,m.MUTATION)
        hidden=list(self.root.glob('.stage.reconstruct-*'))
        self.assertEqual(len(hidden),1)
        self.assertEqual(stat.S_IMODE((hidden[0]/'payload/Splash/server').stat().st_mode),0o555)
        self.assertEqual(stat.S_IMODE((self.runtime/'Splash/server').stat().st_mode),0o555)
        self.assertFalse(self.stage.exists())
        self.assertEqual(m.tree(self.runtime,self.context().budget,self.historical),self.basis['closure'])

    def test_descriptor_ancestry_rejects_source_alias_before_mkdir(self):
        # Simulated destination capability whose pathname label is unrelated;
        # no real mount or macOS firmlink is created by this portable test.
        target=self.runtime/'Voice/python'
        with m.Root(target) as held:
            class AliasCapability:
                fds=[held.fd]  # descendant-rooted alias omits original ancestors
                def check(self):
                    held.check()
            self.assertIn('descriptor',self.rejects(lambda:m.reject_descriptor_overlap(
                AliasCapability(),[self.runtime],self.context().budget)))
        self.assertFalse(self.stage.exists())

    def test_descriptor_containment_runs_before_any_stage_creation(self):
        with patch.object(m,'reject_descriptor_overlap',side_effect=m.Rejected('alias refused')):
            self.rejects(self.prepare)
        self.assertFalse(self.stage.exists())
        self.assertEqual(list(self.root.glob('.stage.reconstruct-*')),[])

    def test_oversized_json_integer_uses_declared_rejection(self):
        raw=b'{"schema_version":'+b'9'*5000+b',"locations":{}}'
        self.rejects(lambda:m.strict_json(raw),m.MUTATION)
        with patch.object(m,'prepare',side_effect=lambda *args:m.strict_json(raw)):
            self.assertEqual(m.main(['prepare','--basis-id','x','--inputs','x','--stage','x']),m.MUTATION)
        self.rejects(lambda:m.canonical({'value':10**5000}),m.MUTATION)

    def test_deterministic_checkpoint_across_fresh_locations(self):
        first = self.prepare(); self.stage=self.root/'second'
        second = self.prepare()
        self.assertEqual(m.canonical(first),m.canonical(second))

    def test_source_owned_production_policy_has_no_accepted_basis(self):
        production=json.loads((ROOT/m.POLICY_PATH).read_text())
        self.assertEqual(production['accepted_historical_baselines'],[])
        self.assertFalse(production['archive_basis']['supported'])
        self.assertFalse(production['native_finalizer']['supported'])

    def test_unknown_basis_and_self_manifest_are_not_authority(self):
        self.rejects(lambda:m._prepare(self.context(),'unapproved',self.inventory,self.stage),m.MISSING)
        self.assertFalse(self.stage.exists())

    def test_archive_route_is_explicitly_unsupported(self):
        self.rejects(lambda:m._prepare(self.context(),self.policy['archive_basis']['id'],self.inventory,self.stage),m.UNSUPPORTED)
        self.assertFalse(self.stage.exists())

    def test_inventory_digest_override_is_rejected(self):
        value=json.loads(self.inventory.read_text());value['expected_sha256']='0'*64
        self.inventory.write_bytes(m.canonical(value))
        self.rejects(self.prepare)

    def test_locator_inventory_extra_key_is_rejected(self):
        value=json.loads(self.inventory.read_text());value['locations']['python_tree']=str(self.runtime)
        self.inventory.write_bytes(m.canonical(value));self.rejects(self.prepare)

    def test_same_size_historical_byte_change_is_rejected(self):
        p=self.runtime/'Voice/LICENSE';p.write_bytes(b'x'*p.stat().st_size)
        self.rejects(self.prepare);self.assertFalse(self.stage.exists())

    def test_extra_or_missing_runtime_entry_is_rejected(self):
        for mutation in ('extra','missing'):
            with self.subTest(mutation=mutation):
                if mutation=='extra': file(self.runtime/'Voice/extra',b'hi')
                else: (self.runtime/'Voice/extra').unlink();(self.runtime/'Voice/LICENSE').unlink()
                self.rejects(self.prepare)

    def test_original_manifest_exact_raw_bytes_required(self):
        (self.runtime/m.MANIFEST).write_bytes(b'{"fixture_only":true}\n');self.rejects(self.prepare)

    def test_report_hash_cannot_be_replaced(self):
        (self.collector/'report.json').write_bytes(b'{"passed":true}\n');self.rejects(self.prepare)

    def test_v1_as_upstream_is_rejected(self):
        item=self.policy['overlay']['files'][0]
        (self.upstream/item['path'].removeprefix('Splash/')).write_bytes((self.runtime/item['path']).read_bytes())
        self.rejects(self.prepare)

    def test_current_helper_mutation_is_rejected(self):
        (self.source/'scripts/patch_splash_listener.py').write_bytes(b'raise SystemExit()\n')
        self.rejects(self.context)

    def test_only_exact_affected_bytecode_is_removed(self):
        name='Splash/server/__pycache__/server.cpython-313.pyc'
        p=file(self.runtime/name,b'affected stale pyc')
        file(self.runtime/'Splash/server/__pycache__/unrelated.cpython-313.pyc',b'preserved')
        self.basis['bytecode_removals']=[{'path':name,**p}];self.rebaseline()
        self.prepare()
        self.assertFalse((self.stage/'payload'/name).exists())
        self.assertEqual((self.stage/'payload/Splash/server/__pycache__/unrelated.cpython-313.pyc').read_bytes(),b'preserved')
        self.assertTrue((self.runtime/name).exists())
        m._status(self.context(),self.stage)

    def test_affected_unlisted_bytecode_is_rejected(self):
        file(self.runtime/'Splash/server/__pycache__/server.cpython-313.pyc',b'stale')
        self.rebaseline();self.rejects(self.prepare)

    def test_unrelated_cache_deletion_is_rejected(self):
        name='Splash/server/__pycache__/unrelated.cpython-313.pyc';p=file(self.runtime/name,b'keep')
        self.basis['bytecode_removals']=[{'path':name,**p}];self.rebaseline();self.rejects(self.prepare)

    def test_unreviewed_alternate_module_is_rejected(self):
        self.basis['module_inventory_review']['alternate_module_paths']=['Splash/python/modules.zip']
        self.save_policy();self.rejects(self.prepare)

    def test_component_ownership_must_be_complete_and_unique(self):
        for broken in ('missing','duplicate','no_notice'):
            original=copy.deepcopy(self.basis['components'])
            if broken=='missing':self.basis['components'][0]['files'].pop()
            elif broken=='duplicate':self.basis['components'][1]['files'].append('Splash')
            else:self.basis['components'][0]['license_paths']=[]
            self.save_policy();self.rejects(self.prepare)
            self.basis['components']=original

    def test_fresh_stage_and_app_parent_only(self):
        self.stage.mkdir();self.rejects(self.prepare);self.stage.rmdir()
        app=self.root/'Installed.APP';app.mkdir();self.stage=app/'new-stage';self.rejects(self.prepare)

    def test_input_and_source_overlap_are_rejected(self):
        for stage in (self.runtime/'stage',self.source/'stage',self.upstream/'stage'):
            self.stage=stage;self.rejects(self.prepare)

    def test_symlink_ancestor_rejected(self):
        alias=self.root/'alias';os.symlink(self.root,alias)
        self.stage=alias/'stage';self.rejects(self.prepare)

    def test_original_regular_hardlink_rejected_before_copy(self):
        os.link(self.runtime/'Voice/LICENSE',self.runtime/'Voice/shared')
        self.rejects(self.prepare)

    def test_external_dangling_cycle_and_file_traversal_links_rejected(self):
        target=self.runtime/'Voice/python/bin/python'
        for value in ('/etc/passwd','../../../../escape','missing','python','python3/leaf'):
            with self.subTest(value=value):
                target.unlink();os.symlink(value,target);self.rejects(self.prepare)

    def test_valid_framework_directory_link_is_not_traversed(self):
        file(self.runtime/'Voice/framework/Versions/A/library',b'native fixture')
        os.symlink('A',self.runtime/'Voice/framework/Versions/Current')
        os.symlink('Versions/Current/library',self.runtime/'Voice/framework/library')
        self.rebaseline();self.prepare();m._status(self.context(),self.stage)

    def test_fifo_nodes_fail_without_open(self):
        fifo=self.runtime/'Voice/fifo';os.mkfifo(fifo)
        self.rejects(self.prepare);fifo.unlink()

    def test_casefold_and_unicode_aliases_rejected(self):
        rows=copy.deepcopy(self.basis['closure'])
        voice=next(row for row in rows if row['path']=='Voice')
        rows.append({**voice,'path':'voice'})
        self.assertIn('duplicate/aliased node',self.rejects(lambda:m.validate_rows(rows,self.policy['bounds'])))
        alias=self.runtime/'voice'
        if alias.exists():
            # A case-insensitive volume cannot contain both distinct entries.
            self.assertTrue(alias.samefile(self.runtime/'Voice'))
        else:
            file(alias)
            self.assertIn('duplicate/aliased node',self.rejects(lambda:m.tree(
                self.runtime,self.context().budget,self.historical)))
            self.assertIn('duplicate/aliased node',self.rejects(self.prepare))
            alias.unlink()
        path=self.runtime/'Voice/Cafe\u0301';file(path)
        self.assertIn('non-NFC path',self.rejects(self.prepare))

    def test_case_only_directory_rename_rejected(self):
        # Also exercise a real alternate-case entry on case-insensitive volumes.
        (self.runtime/'Voice').rename(self.runtime/'voice-case-rename').rename(self.runtime/'voice')
        names={path.name for path in self.runtime.iterdir()}
        self.assertIn('voice',names);self.assertNotIn('Voice',names)
        self.assertIn('historical full closure mismatch',self.rejects(self.prepare))
        self.assertFalse(self.stage.exists())

    def test_unsafe_mode_rejected(self):
        (self.runtime/'Voice/LICENSE').chmod(0o666);self.rejects(self.prepare)

    def test_node_and_byte_bounds_apply_before_materializing(self):
        self.policy['bounds']['runtime_bytes']=10;self.save_policy();self.rejects(self.prepare)

    def test_disk_reserve_failure_never_publishes(self):
        with patch.object(m,'reserve',side_effect=m.Rejected('no space',m.MUTATION)):
            self.rejects(self.prepare,m.MUTATION)
        self.assertFalse(self.stage.exists());self.assertTrue((self.runtime/m.MANIFEST).exists())

    def test_deadline_stops_work(self):
        c=self.context();c.budget.deadline=0
        self.rejects(lambda:m._prepare(c,self.basis['id'],self.inventory,self.stage),m.MUTATION)

    def test_status_does_not_trust_rewritten_checkpoint(self):
        self.prepare();p=self.stage/'payload/Voice/LICENSE';p.write_bytes(b'changed')
        state=json.loads((self.stage/'stage-state.json').read_text())
        state['closure_sha256']=m.digest(m.canonical(m.tree(self.stage/'payload',self.context().budget)))
        (self.stage/'stage-state.json').write_bytes(m.canonical(state))
        self.rejects(lambda:m._status(self.context(),self.stage))

    def test_status_rejects_source_changes_and_partial_work(self):
        self.prepare();file(self.stage/'work/partial-pip',b'partial')
        self.rejects(lambda:m._status(self.context(),self.stage))
        (self.stage/'work/partial-pip').unlink()
        (self.source/'scripts/reconstruct_runtime_payload.py').write_bytes(b'new recipe\n')
        self.rejects(lambda:m._status(self.context(),self.stage))

    def test_status_cannot_accept_adjacent_fake_receipt_or_manifest(self):
        self.prepare();file(self.stage/'accepted-runtime.json',b'{"passed":true}\n')
        self.rejects(lambda:m._status(self.context(),self.stage))
        (self.stage/'accepted-runtime.json').unlink()
        file(self.stage/'payload'/m.MANIFEST,b'{"kind":"verified_runtime_payload"}\n')
        self.rejects(lambda:m._status(self.context(),self.stage))

    def test_status_is_read_only(self):
        self.prepare()
        before={str(p.relative_to(self.stage)):(p.lstat().st_mtime_ns,p.lstat().st_ctime_ns) for p in self.stage.rglob('*')}
        m._status(self.context(),self.stage)
        after={str(p.relative_to(self.stage)):(p.lstat().st_mtime_ns,p.lstat().st_ctime_ns) for p in self.stage.rglob('*')}
        self.assertEqual(before,after)

    def test_no_replace_publication_preserves_winner(self):
        with m.Root(self.root) as root:
            (self.root/'a').mkdir();(self.root/'b').mkdir();file(self.root/'b/winner',b'winner')
            self.rejects(lambda:m.no_replace(root.fd,'a','b'))
            self.assertEqual((self.root/'b/winner').read_bytes(),b'winner')
            self.assertTrue((self.root/'a').exists())

    def test_parent_replacement_is_detected(self):
        parent=self.root/'parent';parent.mkdir()
        with m.Root(parent) as cap:
            parent.rename(self.root/'moved');parent.mkdir()
            self.rejects(cap.check,m.MUTATION)

    def test_same_size_mutation_during_hash_is_detected(self):
        target=self.runtime/'Voice/LICENSE';original=os.read;changed=False;budget=self.context().budget
        with m.Root(self.runtime) as cap:
            def racing_read(fd,count):
                nonlocal changed
                data=original(fd,count)
                if data and not changed:
                    changed=True;target.write_bytes(b'X'*target.stat().st_size)
                return data
            with patch.object(os,'read',side_effect=racing_read):
                self.rejects(lambda:m.regular_at(cap.fd,'Voice/LICENSE',budget),m.MUTATION)

    def test_manifest_is_the_only_excluded_closure_path(self):
        self.prepare();file(self.stage/'payload/Voice/_CodeSignature/CodeResources',b'seal')
        self.rejects(lambda:m._status(self.context(),self.stage))

    def test_native_finalize_portable_is_fail_closed(self):
        with patch.object(m.sys,'platform','linux'):
            self.rejects(lambda:m.finalize(self.stage,self.root),m.UNSUPPORTED)
        self.assertFalse(self.stage.exists())

    def test_native_contract_requires_independent_source_record(self):
        self.prepare();c=self.context('native')
        self.rejects(lambda:m.verify_native_contract(c,self.basis,m.tree(self.stage/'payload',c.budget),self.root),m.MISSING)


    def native_fixture(self):
        self.prepare()
        context=self.context('native')
        rows=m.tree(self.stage/'payload',context.budget)
        evidence=self.root/'native-fixture-evidence';evidence.mkdir()
        closure=m.digest(m.canonical(rows))
        bindings={'basis_identity':m.digest(m.canonical(self.basis)), 'policy_sha256':context.policy_sha,
                  'source_identities':context.sources,'final_signed_closure_sha256':closure}
        record={'schema_version':1,'kind':'runtime_native_build_approval','basis_id':self.basis['id'],
                **bindings,'final_closure':rows,'receipts':[],
                'review_decision':'SYNTHETIC TEST ONLY, never a production approval'}
        for n,gate in enumerate(self.policy['required_native_evidence']):
            output_name=str(n)+'.output'
            output_pin=file(evidence/output_name,b'synthetic raw observation, not a native pass')
            receipt={'schema_version':1,'kind':'observed_native_runtime_gate','gate':gate,'bindings':bindings,
                'outcome':{'kind':'exited','exit_status':0},'argv':['/synthetic/test-only'],
                'environment_policy_sha256':m.digest(b'test-only'),
                'host':{'os':'macOS','os_version':'synthetic','sdk':'synthetic','architecture':'arm64','chip':'synthetic'},
                'started':'synthetic-start','ended':'synthetic-end',
                'outputs':[{'path':output_name,**output_pin}],
                'before_closure_sha256':closure,'after_closure_sha256':closure,
                'observations':{'synthetic_fixture':True}}
            name=str(n)+'.receipt.json'
            receipt_pin=file(evidence/name,m.canonical(receipt))
            record['receipts'].append({'gate':gate,'path':name,**receipt_pin})
        file(self.source/m.NATIVE_PATH,m.canonical(record))
        return context,rows,evidence,record

    def change_receipt(self,evidence,record,edit,repin=True):
        first=record['receipts'][0]
        value=json.loads((evidence/first['path']).read_text())
        edit(value)
        new_pin=file(evidence/first['path'],m.canonical(value))
        if repin:first.update(new_pin)
        file(self.source/m.NATIVE_PATH,m.canonical(record))

    def test_native_contract_is_structural_only_even_with_exact_fixture_bindings(self):
        c,rows,evidence,_=self.native_fixture()
        result=m.verify_native_contract(c,self.basis,rows,evidence)
        self.assertEqual(result['kind'],'native_contract_structurally_bound_not_accepted')
        self.assertFalse((self.stage/'accepted-runtime.json').exists())
        self.assertFalse((self.stage/'payload'/m.MANIFEST).exists())

    def test_unpinned_receipt_change_is_rejected(self):
        c,rows,evidence,record=self.native_fixture()
        self.change_receipt(evidence,record,lambda r:r.update(started='altered'),repin=False)
        self.rejects(lambda:m.verify_native_contract(c,self.basis,rows,evidence))

    def test_native_source_closure_policy_and_basis_binding_mismatches(self):
        c,rows,evidence,record=self.native_fixture()
        for key,value in [('policy_sha256','0'*64),('basis_identity','0'*64),
                          ('final_signed_closure_sha256','0'*64),('source_identities',{})]:
            with self.subTest(key=key):
                changed=copy.deepcopy(record);changed[key]=value
                file(self.source/m.NATIVE_PATH,m.canonical(changed))
                self.rejects(lambda:m.verify_native_contract(c,self.basis,rows,evidence))

    def test_receipt_wrong_binding_and_identity_cycle_rejected_even_when_repinned(self):
        c,rows,evidence,record=self.native_fixture()
        self.change_receipt(evidence,record,lambda r:r['bindings'].update(manifest_sha256='0'*64))
        self.rejects(lambda:m.verify_native_contract(c,self.basis,rows,evidence))

    def test_timeout_signal_launch_error_boolean_status_never_pass(self):
        c,rows,evidence,record=self.native_fixture()
        for outcome in ({'kind':'timeout','exit_status':0},{'kind':'signal','exit_status':0},
                        {'kind':'launch_error','exit_status':0},{'kind':'exited','exit_status':-9},
                        {'kind':'exited','exit_status':False}):
            with self.subTest(outcome=outcome):
                self.change_receipt(evidence,record,lambda r:r.update(outcome=outcome))
                self.rejects(lambda:m.verify_native_contract(c,self.basis,rows,evidence))

    def test_native_output_hashes_are_checked(self):
        c,rows,evidence,record=self.native_fixture()
        (evidence/'0.output').write_bytes(b'unreviewed output')
        self.rejects(lambda:m.verify_native_contract(c,self.basis,rows,evidence))

    def test_native_duplicate_or_missing_gate_rejected(self):
        c,rows,evidence,record=self.native_fixture()
        original=copy.deepcopy(record)
        record['receipts'][1]=copy.deepcopy(record['receipts'][0])
        file(self.source/m.NATIVE_PATH,m.canonical(record))
        self.rejects(lambda:m.verify_native_contract(c,self.basis,rows,evidence))
        original['receipts'].pop();file(self.source/m.NATIVE_PATH,m.canonical(original))
        self.rejects(lambda:m.verify_native_contract(c,self.basis,rows,evidence))

    def test_added_signature_seal_invalidates_native_closure(self):
        c,rows,evidence,record=self.native_fixture()
        file(self.stage/'payload/Voice/_CodeSignature/CodeResources',b'changed signature seal')
        changed=m.tree(self.stage/'payload',c.budget)
        self.rejects(lambda:m.verify_native_contract(c,self.basis,changed,evidence))

    def test_boolean_checkpoint_schema_is_rejected(self):
        self.prepare();path=self.stage/'stage-state.json';state=json.loads(path.read_text())
        state['schema_version']=True;path.write_bytes(m.canonical(state))
        self.rejects(lambda:m._status(self.context(),self.stage))

    def test_neural_asset_pin_is_required_independently_of_baseline(self):
        self.policy['speech_asset_pins']=[{'path':'STT/model','bytes':1,'sha256':m.digest(b'x')}]
        self.save_policy();self.rejects(self.prepare)

    def test_changed_destination_leaf_during_new_write_is_detected(self):
        output=self.root/'write';output.mkdir();original=os.fsync;changed=False
        with m.Root(output) as cap:
            def race(fd):
                nonlocal changed
                original(fd)
                if not changed:
                    changed=True
                    (output/'file').rename(output/'old')
                    file(output/'file',b'substituted')
            with patch.object(os,'fsync',side_effect=race):
                self.rejects(lambda:m.write_new(cap.fd,'file',b'expected'),m.MUTATION)


    def observe(self, approved=False):
        return m.read_collector_v2(self.collector,self.context(),self.basis['collector_bundle'] if approved else None)

    def change_artifact(self,name,change):
        value=json.loads((self.collector/name).read_text());change(value)
        file(self.collector/name,(json.dumps(value)+'\n').encode())

    def test_collector_preserves_seven_original_artifacts(self):
        before={name:(self.collector/name).read_bytes() for name in m.COLLECTOR_ARTIFACTS}
        result=self.observe(True)
        self.assertEqual(result['kind'],'unaccepted_collector_observation')
        self.assertTrue(result['eligible_for_reviewed_preparation']);self.assertFalse(result['native_accepted'])
        self.prepare()
        self.assertEqual(set(p.name for p in (self.stage/'evidence/collector').iterdir()),set(before))
        for name,raw in before.items():self.assertEqual((self.stage/'evidence/collector'/name).read_bytes(),raw)
        self.assertEqual(result['bundle'],self.basis['collector_bundle'])

    def test_each_original_artifact_pin_is_enforced(self):
        for name in m.COLLECTOR_ARTIFACTS:
            with self.subTest(name=name):
                path=self.collector/name;raw=path.read_bytes();path.write_bytes(raw+b' ')
                self.rejects(lambda:self.observe(True));path.write_bytes(raw)

    def test_partial_extra_case_alias_and_single_file_reports_reject(self):
        path=self.collector/'apple-tools.json';raw=path.read_bytes();path.unlink()
        self.assertIn('seven-artifact',self.rejects(self.observe));file(path,raw)
        extra=self.collector/'extra.json';file(extra,b'{}');self.rejects(self.observe);extra.unlink()
        report=self.collector/'report.json';raw=report.read_bytes()
        report.rename(self.collector/'report-case-rename').rename(self.collector/'REPORT.JSON')
        self.assertIn('REPORT.JSON',{path.name for path in self.collector.iterdir()})
        self.assertEqual((self.collector/'REPORT.JSON').read_bytes(),raw)
        self.assertIn('seven-artifact',self.rejects(self.observe))
        single=self.root/'old-collector.json';file(single,b'{}')
        self.rejects(lambda:m.read_collector_v2(single,self.context()))

    def test_report_symlinks_and_hardlinks_reject(self):
        path=self.collector/'report.json';raw=path.read_bytes();path.unlink()
        target=self.root/'saved-report';file(target,raw)
        os.symlink(target,path);self.rejects(self.observe);path.unlink()
        os.link(target,path);self.rejects(self.observe)

    def test_split_artifact_over_16mb_is_bounded_and_not_flattened(self):
        path=self.collector/'report.json';path.write_bytes(path.read_bytes()+b' '*(m.MAX_JSON+1))
        self.repin_collector();self.save_policy()
        result=self.observe(True)
        self.assertGreater(result['bundle']['artifacts']['report.json']['bytes'],m.MAX_JSON)
        self.assertTrue(result['eligible_for_reviewed_preparation'])
        self.assertLess(len(m.canonical(result['closure'])),m.MAX_JSON)
        self.rejects(lambda:m.strict_json(path.read_bytes()))

    def test_collector_per_file_and_aggregate_caps(self):
        self.policy['collector_v2']['artifact_bytes']['report.json']=10;self.save_policy()
        self.rejects(self.observe,m.MUTATION)
        self.policy['collector_v2']['artifact_bytes']['report.json']=120000000
        self.policy['collector_v2']['aggregate_bytes']=sum(p.stat().st_size for p in self.collector.iterdir())-1
        self.save_policy();self.rejects(self.observe,m.MUTATION)

    def test_actual_aggregate_growth_after_preflight_rejects(self):
        initial=sum(p.stat().st_size for p in self.collector.iterdir())
        self.policy['collector_v2']['aggregate_bytes']=initial+1000;self.save_policy();context=self.context()
        original=m.regular_at;injected=False
        def race(root_fd,name,*args,**kwargs):
            nonlocal injected
            if not injected and name=='collection-start.json':
                injected=True
                for target in ('report.json','apple-tools.json'):
                    path=self.collector/target;path.write_bytes(path.read_bytes()+b' '*10000)
            return original(root_fd,name,*args,**kwargs)
        with patch.object(m,'regular_at',side_effect=race):
            self.rejects(lambda:m.read_collector_v2(self.collector,context),m.MUTATION)
        self.assertTrue(injected)

    def test_artifact_directory_mutations_during_read_reject(self):
        original=m.regular_at
        for action in ('extra','missing','renamed'):
            with self.subTest(action=action):
                self.emit_collector();context=self.context();injected=False
                def race(root_fd,name,*args,**kwargs):
                    nonlocal injected
                    result=original(root_fd,name,*args,**kwargs)
                    if not injected and name=='COMPLETE.txt':
                        injected=True
                        if action=='extra':file(self.collector/'extra.json',b'{}')
                        elif action=='missing':(self.collector/'report.json').unlink()
                        else:(self.collector/'report.json').rename(self.collector/'renamed.json')
                    return result
                with patch.object(m,'regular_at',side_effect=race):self.rejects(lambda:m.read_collector_v2(self.collector,context))
                self.assertTrue(injected)
                for extra in ('extra.json','renamed.json'):
                    if (self.collector/extra).exists():(self.collector/extra).unlink()

    def test_diagnostics_decimal_locations_and_identity_separation(self):
        baseline=self.observe()
        limits=self.policy['collector_v2']
        tools=m.collector_json((self.collector/'apple-tools.json').read_bytes(),'apple-tools.json',limits)
        summary=m.collector_json((self.collector/'report.json').read_bytes(),'report.json',limits)
        self.assertEqual(str(tools[0]['result']['elapsed_seconds']),'0.125')
        self.assertEqual(str(summary['metadata']['Contents/_CodeSignature/CodeResources']['rules']['rules2']['^Resources/']['weight']),'10000.5')
        self.change_artifact('apple-tools.json',lambda x:x[0]['result'].update(elapsed_seconds=1.25))
        self.change_artifact('report.json',lambda x:x['metadata']['Contents/_CodeSignature/CodeResources']['rules']['rules2']['^Resources/'].update(weight=2.25))
        changed=self.observe();self.assertEqual(changed['closure'],baseline['closure'])
        self.assertEqual(changed['native_inventory'],baseline['native_inventory'])
        self.assertNotEqual(changed['bundle'],baseline['bundle'])
        self.assertFalse(changed['native_accepted'])
        self.rejects(lambda:m.canonical(tools))

    def test_decimal_wrong_paths_nonfinite_overflow_lexemes_reject(self):
        limits=self.policy['collector_v2']
        for raw in (b'{"elapsed_seconds":0.1}',b'{"metadata":{"Contents/Info.plist":{"selected_fields":{"weight":1.5}}}}',
                    b'{"metadata":{"Contents/_CodeSignature/CodeResources":{"rules":{"rules2":{"x":{"omit":0.5}}}}}}'):
            with self.subTest(raw=raw):self.rejects(lambda:m.collector_json(raw,'report.json',limits))
        for number in ('NaN','Infinity','-Infinity','1e9999','1e-9999','-0.1','1802.1','0.'+'0'*65+'1'):
            raw=('[{"result":{"elapsed_seconds":'+number+'}}]').encode()
            with self.subTest(number=number):self.rejects(lambda:m.collector_json(raw,'apple-tools.json',limits))
        for number in ('-0.1','1000000000.1','1e9999'):
            raw=('{"metadata":{"Contents/_CodeSignature/CodeResources":{"rules":{"rules2":{"x":{"weight":'+number+'}}}}}}').encode()
            self.rejects(lambda:m.collector_json(raw,'report.json',limits))

    def test_collector_duplicate_depth_and_oversized_integer_reject(self):
        for raw in (b'{"x":1,"x":2}',b'['*33+b']'*33,b'{"x":'+b'9'*5000+b'}',b'{"x":"\\ud800"}'):
            with self.subTest(raw=raw[:80]):self.rejects(lambda:m.collector_json(raw,'report.json',self.policy['collector_v2']))

    def test_complete_marker_does_not_admit_exit1_or_exit2(self):
        for code,status in ((1,'collected'),(2,'incomplete')):
            self.change_artifact('report.json',lambda x:x.update(collector_exit_code=code,status=status))
            file(self.collector/'COMPLETE.txt',('Collection finished; inspect report.json. Exit code: %d\nA complete report is not an admission or vendor-origin approval.\n'%code).encode())
            result=self.observe();self.assertFalse(result['eligible_for_reviewed_preparation'])
            self.assertIn('collector_did_not_complete_successfully',result['missing_conditions'])
            self.assertFalse(result['native_accepted'])
        self.repin_collector();self.save_policy();self.rejects(self.prepare);self.assertFalse(self.stage.exists())

    def test_mandatory_outer_tools_are_nonvacuous(self):
        original=(self.collector/'apple-tools.json').read_bytes()
        for events in ([],json.loads(original)[1:],json.loads(original)[:-1]):
            file(self.collector/'apple-tools.json',json.dumps(events).encode())
            result=self.observe();self.assertFalse(result['eligible_for_reviewed_preparation'])
            self.assertIn('mandatory_tool_event_coverage_incomplete',result['missing_conditions'])
        file(self.collector/'apple-tools.json',original)

    def test_native_tool_coverage_hash_and_descriptor_are_exact(self):
        file(self.runtime/'Voice/native.dylib',b'\xcf\xfa\xed\xfesynthetic tagged bytes')
        self.rebaseline();self.assertTrue(self.observe()['eligible_for_reviewed_preparation'])
        original=(self.collector/'apple-tools.json').read_bytes()
        self.change_artifact('apple-tools.json',lambda x:x.pop())
        self.assertIn('mandatory_tool_event_coverage_incomplete',self.observe()['missing_conditions'])
        for changes in ({'sha256':'0'*64},{'descriptor_bound':False},{'target':'unexpected'}):
            file(self.collector/'apple-tools.json',original)
            self.change_artifact('apple-tools.json',lambda x:x[-1].update(changes));self.rejects(self.observe)

    def test_tool_argv_cannot_claim_unrelated_success(self):
        self.change_artifact('apple-tools.json',lambda x:x[1]['result'].update(argv=['/bin/true']))
        self.assertIn('argv',self.rejects(self.observe))

    def test_tool_success_cannot_hide_error_fields(self):
        original=(self.collector/'apple-tools.json').read_bytes()
        for changes in ({'error_type':'OSError'},{'errno':5},{'cleanup_incomplete':True}):
            file(self.collector/'apple-tools.json',original)
            self.change_artifact('apple-tools.json',lambda x:x[1]['result'].update(changes))
            self.assertIn('tool_failure_or_incomplete_observation',self.observe()['missing_conditions'])

    def test_tool_replacement_decoding_and_raw_output_budget(self):
        original=(self.collector/'apple-tools.json').read_bytes()
        self.change_artifact('apple-tools.json',lambda x:x[0]['result'].update(stdout='\ufffd',stderr='',output_bytes=1))
        self.assertTrue(self.observe()['eligible_for_reviewed_preparation'])
        self.change_artifact('apple-tools.json',lambda x:x[0]['result'].update(output_bytes=0))
        self.assertIn('accounting',self.rejects(self.observe))
        file(self.collector/'apple-tools.json',original)
        self.change_artifact('apple-tools.json',lambda x:x[0]['result'].update(stdout='\U0001f600',output_bytes=1))
        self.rejects(self.observe)
        file(self.collector/'apple-tools.json',original)
        self.policy['collector_v2']['tool_output_total_bytes']=67;self.save_policy()
        self.rejects(self.observe,m.MUTATION)

    def test_failed_collector_tool_shape_remains_inspectable(self):
        def failure(tools):
            tools[1]['result']={'argv':tools[1]['result']['argv'],'returncode':None,'reason':'tool_unavailable',
                'stdout':'','stderr':'','error_type':'FileNotFoundError','errno':2}
        self.change_artifact('apple-tools.json',failure)
        self.assertIn('tool_failure_or_incomplete_observation',self.observe()['missing_conditions'])

    def test_collector_link_report_is_recomputed(self):
        self.change_artifact('runtime-inventory.json',lambda x:x['entries']['Voice/python/bin/python'].update(resolved='Splash/LICENSE'))
        self.assertIn('link resolution',self.rejects(self.observe))

    def test_collector_nested_schema_and_fixed_limits_reject(self):
        original=(self.collector/'report.json').read_bytes()
        changes=(lambda x:x['metadata']['Contents/Info.plist']['selected_fields'].update(unknown='x'),
                 lambda x:x['runtime_manifest'].update(unreviewed_override=True),
                 lambda x:x['trusted_tool_availability'].update(codesign=1),
                 lambda x:x['limits'].update(wall_seconds=True),
                 lambda x:x['limits'].update(entries=99999),
                 lambda x:x['metadata']['Contents/_CodeSignature/CodeResources']['manifest_entries']['files2'].update(unknown=True))
        for change in changes:
            file(self.collector/'report.json',original);self.change_artifact('report.json',change);self.rejects(self.observe)

    def test_prepare_phase_does_not_read_native_or_context_only_sources(self):
        native=self.source/'Resources/Runtime/dot_process.py';native.unlink()
        self.policy['source_bindings']['scripts/unrelated-builder.py']={'bytes':1,'sha256':'0'*64}
        self.save_policy();self.prepare();m._status(self.context(),self.stage)
        with self.assertRaises((m.Rejected,OSError)):self.context('native')
        self.assertEqual(set(self.context().sources),set(self.policy['phase_source_paths']['prepare']))

    def test_native_source_change_does_not_block_portable_status(self):
        self.prepare();file(self.source/'Resources/Runtime/dot_process.py',b'changed native helper')
        m._status(self.context(),self.stage);self.rejects(lambda:self.context('native'))

    def test_prepare_critical_source_and_patch_record_remain_pinned(self):
        path=self.source/'scripts/patch_splash_listener.py';path.write_bytes(path.read_bytes()+b'# changed\n')
        self.rejects(self.context)

    def test_patch_record_must_agree_with_policy_overlay(self):
        path=self.source/'Resources/Runtime/splash-managed-listener-patch.json';record=json.loads(path.read_text())
        record['files'][0]['sha256']='0'*64
        self.policy['source_bindings']['Resources/Runtime/splash-managed-listener-patch.json']=file(path,m.canonical(record))
        file(self.source/m.POLICY_PATH,m.canonical(self.policy));self.rejects(self.context)

    def test_full_policy_change_invalidates_existing_prepare_checkpoint(self):
        self.prepare()
        self.policy['source_bindings']['Resources/Runtime/dot_process.py']['sha256']='0'*64
        self.save_policy();self.rejects(lambda:m._status(self.context(),self.stage))

    def test_native_contract_requires_native_phase_context(self):
        c,rows,evidence,record=self.native_fixture()
        self.assertIn('native source phase',self.rejects(lambda:m.verify_native_contract(self.context(),self.basis,rows,evidence)))


class TemporaryRootTests(unittest.TestCase):
    def test_fixture_uses_physical_system_temporary_directory(self):
        outer = tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve())
        self.addCleanup(outer.cleanup)
        root = Path(outer.name)
        physical = root / 'physical'
        system_temp = physical / 'system-temp'
        system_temp.mkdir(parents=True)
        alias = root / 'alias'
        alias.symlink_to(physical, target_is_directory=True)
        aliased_temp = alias / 'system-temp'
        fixture = Fixture('test_prepare_is_inert_and_preserves_source')
        self.addCleanup(fixture.doCleanups)
        with patch.object(tempfile, 'tempdir', str(aliased_temp)):
            fixture.setUp()
        self.assertEqual(fixture.root.parent, system_temp)
        fixture.test_prepare_is_inert_and_preserves_source()
        with self.assertRaisesRegex(m.Rejected, 'symlink/non-directory ancestor'):
            with m.Root(aliased_temp / fixture.root.name):
                self.fail('production Root accepted a symlink ancestor')


class StrictInputTests(unittest.TestCase):
    def test_json_duplicates_floats_deep_and_nonfinite(self):
        for raw in (b'{"a":1,"a":2}',b'{"x":1.0}',b'{"x":NaN}',b'['*33+b']'*33,b'{"x":"\\ud800"}'):
            with self.subTest(raw=raw), self.assertRaises((m.Rejected,UnicodeError)):
                m.strict_json(raw)

    def test_bool_not_integer(self):
        with self.assertRaises(m.Rejected):m.integer(True,0,2)

    def test_canonical_json_is_stable_and_rejects_floats(self):
        self.assertEqual(m.canonical({'b':1,'a':'é'}),b'{"a":"\xc3\xa9","b":1}\n')
        with self.assertRaises(m.Rejected):m.canonical({'x':float('nan')})

    def test_bad_relative_names(self):
        for name in ('/absolute','../escape','a/../b','a//b','a\\b','C:thing','a\x00','a\n','./x',''):
            with self.subTest(name=name),self.assertRaises(m.Rejected):m.relative(name)

    def test_no_trust_or_platform_cli_overrides(self):
        for switch in ('--expected-sha256','--trust-current','--skip-signatures','--platform-override','--source-root','--force-replace'):
            proc=subprocess.run([sys.executable,str(ROOT/'scripts/reconstruct_runtime_payload.py'),'finalize',
                '--stage','absent','--evidence-dir','absent',switch,'x'],capture_output=True)
            self.assertEqual(proc.returncode,2)


if __name__=='__main__':
    unittest.main()
