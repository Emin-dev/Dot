"""Portable adversarial contracts. Every accepted tiny basis is isolated test data.

No fixture is installed in production policy or establishes genuine native
admission. Private writer tests explicitly simulate gate results in temporary
source trees; public native finalization never accepts a portable fixture.
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
        self.assertTrue(production['native_finalizer']['supported'])
        self.assertFalse((ROOT/m.NATIVE_PATH).exists())

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


    def native_manifest_fixture(self):
        """Synthetic tiny bytes only; no real native observation or admission."""
        for names in m.NATIVE_REQUIRED_FILES.values():
            for name in names:
                if not (self.runtime/name).exists():
                    file(self.runtime/name,b'SYNTHETIC fixture bytes',0o755 if name.endswith(('python3','/splash')) else 0o644)
        self.rebaseline();self.prepare()
        c=self.context('native');rows=m.tree(self.stage/'payload',c.budget)
        components=[]
        existing={row['path'] for row in rows}
        for item in self.basis['components']:
            components.append({**item,'files':sorted((name for name in item['files'] if name in existing),key=lambda n:n.encode())})
        components.sort(key=lambda item:item['role'])
        facts={'approval_sha256':'1'*64,'prepared_identity':m.prepared_identity(c,self.basis,rows),
               'signed_identity':m.signed_identity(c,rows),'evidence_identity':'2'*64,
               'components':components,'gates':sorted(c.policy['required_native_evidence'])}
        return c,rows,facts

    def test_native_prepared_projection_keeps_original_checkpoint(self):
        self.prepare();native=self.context('native')
        with m.Root(self.stage) as cap:
            basis,state,rows=m._read_prepared_basis(native,cap)
        self.assertEqual(state['source_identities'],self.context().sources)
        self.assertNotEqual(state['source_identities'],native.sources)
        self.assertEqual(state,m.checkpoint(native,basis,rows,state['delta']))

    def test_native_basis_reader_does_not_relax_prepared_status(self):
        self.prepare();file(self.stage/'payload/Voice/python/bin/python3',b'signed fixture')
        with m.Root(self.stage) as cap:
            _,_,rows=m._read_prepared_basis(self.context('native'),cap)
        self.assertNotEqual(rows,m.tree(self.stage/'payload',self.context().budget))
        self.assertIn('prepared payload changed',self.rejects(lambda:m._status(self.context(),self.stage)))

    def test_native_basis_reader_rejects_rewritten_checkpoint(self):
        self.prepare();path=self.stage/'stage-state.json';state=m.strict_json(path.read_bytes())
        state['source_identities']=self.context('native').sources;file(path,m.canonical(state))
        with m.Root(self.stage) as cap:
            self.assertIn('checkpoint mismatch',self.rejects(lambda:m._read_prepared_basis(self.context('native'),cap)))

    def test_native_identity_domains_and_canonical_bound(self):
        c,rows,_=self.native_manifest_fixture()
        self.assertNotEqual(m.signed_identity(c,rows),m.digest(m.canonical(rows)))
        self.assertNotEqual(m.prepared_identity(c,self.basis,rows),m.signed_identity(c,rows))
        with patch.object(m,'MAX_JSON',64):
            self.rejects(lambda:m.native_canonical({'large':'x'*64}),m.MUTATION)
        self.rejects(lambda:m.signed_identity(c,list(reversed(rows))))

    def test_native_noop_delta_and_manifest_projection(self):
        c,rows,facts=self.native_manifest_fixture()
        self.assertEqual(m._validate_native_transforms(c,self.basis,rows,rows,[],[],[],facts['components']),facts['components'])
        raw=m._final_manifest_bytes(c,rows,facts)
        manifest=m.strict_json(raw)
        self.assertEqual(raw,m._final_manifest_bytes(c,rows,copy.deepcopy(facts)))
        self.assertTrue(raw.endswith(b'\n'))
        self.assertEqual(manifest['kind'],'verified_runtime_payload')
        self.assertFalse(any(row['kind']=='directory' or 'mode' in row for row in manifest['files']))
        self.assertEqual(manifest['native_admission']['source_identities'],c.sources)
        self.assertFalse((self.stage/'payload'/m.MANIFEST).exists())
        self.assertFalse((self.stage/'accepted-runtime.json').exists())

    def test_native_manifest_rejects_missing_gate_identity_and_required_file(self):
        c,rows,facts=self.native_manifest_fixture()
        for edit in (lambda f:f['gates'].pop(),lambda f:f.update(signed_identity='0'*64),
                     lambda f:f.update(approval_sha256='caller says passed'),lambda f:f.update(extra=True)):
            bad=copy.deepcopy(facts);edit(bad)
            self.rejects(lambda:m._final_manifest_bytes(c,rows,bad))
        missing=[r for r in rows if r['path']!='Splash/engine/splash']
        bad=copy.deepcopy(facts);bad['signed_identity']=m.signed_identity(c,missing)
        for item in bad['components']:item['files']=[n for n in item['files'] if n!='Splash/engine/splash']
        self.rejects(lambda:m._final_manifest_bytes(c,missing,bad))

    def test_native_manifest_rejects_wrong_overlay_even_with_signed_identity(self):
        c,rows,facts=self.native_manifest_fixture();rows=copy.deepcopy(rows)
        next(row for row in rows if row['path']=='Splash/install/launcher.py')['sha256']='0'*64
        facts['signed_identity']=m.signed_identity(c,rows)
        self.assertIn('v2 overlay',self.rejects(lambda:m._final_manifest_bytes(c,rows,facts)))

    def test_native_exact_resign_diff_rejects_missing_extra_wrong_rows(self):
        c,before,facts=self.native_manifest_fixture();after=copy.deepcopy(before)
        old=next(row for row in before if row['path']=='Voice/python/bin/python3')
        new=next(row for row in after if row['path']==old['path']);new['sha256']='3'*64
        transforms=[{'path':old['path'],'before':old,'after':new,'operation':'resign_macho','reason':'SYNTHETIC fixture signing only'}]
        def validate(changes,paths=None):
            return m._validate_native_transforms(c,self.basis,before,after,changes,[old['path']] if paths is None else paths,[],facts['components'])
        validate(transforms)
        self.rejects(lambda:validate([]));self.rejects(lambda:validate(transforms*2))
        for edit in (lambda e:e.update(before=None),lambda e:e.update(after=None),
                     lambda e:e.update(path='Splash/install/launcher.py'),lambda e:e.update(operation='install_package'),
                     lambda e:e.update(reason=''),lambda e:e.update(extra=True)):
            bad=copy.deepcopy(transforms);edit(bad[0]);self.rejects(lambda:validate(bad))
        self.rejects(lambda:validate(transforms,[]))
        new['mode']=0o700;transforms[0]['after']=new
        self.rejects(lambda:validate(transforms))

    def test_native_transform_boolean_cannot_equal_integer_row(self):
        c,before,facts=self.native_manifest_fixture();after=copy.deepcopy(before)
        old=next(row for row in before if row['path']=='Voice/python/bin/python3')
        new=next(row for row in after if row['path']==old['path']);new.update(bytes=1,sha256=m.digest(b'x'))
        entry={'path':old['path'],'before':old,'after':copy.deepcopy(new),'operation':'resign_macho','reason':'fixture'}
        entry['after']['bytes']=True
        self.assertIn('exact row mismatch',self.rejects(lambda:m._validate_native_transforms(
            c,self.basis,before,after,[entry],[old['path']],[],facts['components'])))

    def test_native_exact_seal_additions_inherit_component(self):
        c,before,facts=self.native_manifest_fixture();after=copy.deepcopy(before)
        additions=[{'path':'Voice/_CodeSignature','kind':'directory','mode':0o755},
                   {'path':'Voice/_CodeSignature/CodeResources','kind':'file','mode':0o644,'bytes':7,'sha256':m.digest(b'fixture')}]
        after+=additions;after.sort(key=lambda r:r['path'].encode())
        transforms=[{'path':r['path'],'before':None,'after':r,
                     'operation':'create_signature_directory' if r['kind']=='directory' else 'write_bundle_code_resources',
                     'reason':'SYNTHETIC fixture seal'} for r in additions]
        components=copy.deepcopy(facts['components'])
        voice=next(x for x in components if x['role']=='speech_synthesis')
        voice['files']=sorted(voice['files']+[r['path'] for r in additions],key=lambda n:n.encode())
        m._validate_native_transforms(c,self.basis,before,after,transforms,[],['Voice'],components)
        self.rejects(lambda:m._validate_native_transforms(c,self.basis,before,after,transforms,[],[],components))
        wrong=copy.deepcopy(components);next(x for x in wrong if x['role']=='speech_synthesis')['license']='different license'
        self.rejects(lambda:m._validate_native_transforms(c,self.basis,before,after,transforms,[],['Voice'],wrong))

    def test_native_unknown_added_removed_or_link_changed_paths_reject(self):
        c,before,facts=self.native_manifest_fixture()
        cases=[]
        extra={'path':'Voice/_unknown_signature','kind':'file','mode':0o644,'bytes':1,'sha256':m.digest(b'x')}
        cases.append((sorted(before+[extra],key=lambda r:r['path'].encode()),None,extra,'write_bundle_code_resources'))
        old=next(row for row in before if row['path']=='Voice/python/bin/python')
        new={**old,'target':'../bin/python3'}
        cases.append(([new if r['path']==old['path'] else r for r in before],old,new,'rewrite_macho_load_commands'))
        old=next(row for row in before if row['path']=='Voice/LICENSE')
        cases.append(([r for r in before if r['path']!=old['path']],old,None,'resign_macho'))
        for after,old,new,operation in cases:
            entry={'path':(new or old)['path'],'before':old,'after':new,'operation':operation,'reason':'unsupported fixture delta'}
            self.rejects(lambda:m._validate_native_transforms(c,self.basis,before,after,[entry],[],['Voice'],facts['components']))


    def native_envelope_fixture(self):
        c,rows,facts=self.native_manifest_fixture()
        evidence=self.root/'native-v2-evidence';evidence.mkdir()
        bindings={'basis_identity':m.digest(m.native_canonical(self.basis)), 'policy_sha256':c.policy_sha,
                  'source_identities':c.sources,'prepared_identity':m.prepared_identity(c,self.basis,rows),
                  'signed_identity':m.signed_identity(c,rows)}
        record={'schema_version':2,'kind':'runtime_native_build_approval','basis_id':self.basis['id'],
                **bindings,'final_closure':rows,'transforms':[],'final_components':facts['components'],
                'native_inventory':{'objects':[],'code_bundles':[],'launch_contexts':[],'system_roots':[],'system_targets':[]},
                'probe_contract':{'fixture_only':'not native evidence'},'receipts':[],'evidence_artifacts':[],
                'review_decision':{'scope':'personal_candidate','decision_id':'SYNTHETIC ENVELOPE TEST ONLY'}}
        for number,gate in enumerate(c.policy['required_native_evidence']):
            name=f'receipts/{number:02}.json'
            receipt={'schema_version':2,'kind':'observed_native_runtime_gate','gate':gate,
                     'bindings':{**bindings,'probe_contract_identity':m.digest(m.native_canonical(record['probe_contract']))}}
            result=file(evidence/name,m.canonical(receipt))
            record['receipts'].append({'gate':gate,'path':name,**result})
            record['evidence_artifacts'].append({'path':name,'kind':'receipt',**result})
        self.write_native_envelope(record)
        return c,rows,evidence,record

    def write_native_envelope(self,record):
        record['evidence_artifacts'].sort(key=lambda row:row['path'].encode())
        record['evidence_identity']=m.evidence_identity(record['evidence_artifacts'])
        file(self.source/m.NATIVE_PATH,m.canonical(record))

    def test_native_schema2_envelope_never_claims_acceptance(self):
        c,rows,evidence,record=self.native_envelope_fixture()
        before={p.relative_to(evidence).as_posix():p.read_bytes() for p in evidence.rglob('*') if p.is_file()}
        result=m._read_native_approval_envelope(c,self.basis,rows,rows,evidence)
        self.assertEqual(result['kind'],'native_approval_envelope_not_accepted')
        self.assertEqual(result['record'],record)
        self.assertEqual(result['artifacts'],before)
        self.assertEqual({p.relative_to(evidence).as_posix():p.read_bytes() for p in evidence.rglob('*') if p.is_file()},before)
        self.assertFalse((self.stage/'payload'/m.MANIFEST).exists())
        self.assertFalse((self.stage/'accepted-runtime.json').exists())

    def test_native_schema2_approval_cannot_pin_itself_in_policy(self):
        self.policy['source_bindings'][m.NATIVE_PATH]={'bytes':1,'sha256':'0'*64};self.save_policy()
        self.assertIn('approval cannot enter source bindings',self.rejects(lambda:self.context()))

    def test_native_schema2_binding_and_review_mutations_reject(self):
        c,rows,evidence,record=self.native_envelope_fixture()
        for edit in (lambda r:r.update(schema_version=1),lambda r:r.update(schema_version=True),
                     lambda r:r.update(prepared_identity='0'*64),lambda r:r.update(signed_identity='0'*64),
                     lambda r:r.update(source_identities={}),lambda r:r.update(basis_id='other'),
                     lambda r:r['review_decision'].update(scope='public_release'),
                     lambda r:r['review_decision'].update(decision_id=''),lambda r:r.update(extra=True)):
            bad=copy.deepcopy(record);edit(bad);file(self.source/m.NATIVE_PATH,m.canonical(bad))
            self.rejects(lambda:m._read_native_approval_envelope(c,self.basis,rows,rows,evidence))
        file(self.source/m.NATIVE_PATH,m.canonical(record))
        self.assertEqual(m._read_native_approval_envelope(c,self.basis,rows,rows,evidence)['kind'],
                         'native_approval_envelope_not_accepted')

    def test_native_schema2_receipt_gate_and_pin_require_exact_coverage(self):
        c,rows,evidence,record=self.native_envelope_fixture()
        for edit in (lambda r:r['receipts'].pop(),lambda r:r['receipts'].append(r['receipts'][0]),
                     lambda r:r['receipts'][0].update(gate=r['receipts'][1]['gate']),
                     lambda r:r['receipts'][0].update(bytes=True),lambda r:r['receipts'][0].update(sha256='0'*64)):
            bad=copy.deepcopy(record);edit(bad);file(self.source/m.NATIVE_PATH,m.canonical(bad))
            self.rejects(lambda:m._read_native_approval_envelope(c,self.basis,rows,rows,evidence))

    def test_native_artifact_exact_physical_closure_and_immutability(self):
        c,rows,evidence,record=self.native_envelope_fixture()
        file(evidence/'extra.txt',b'unapproved')
        self.rejects(lambda:m._read_native_approval_envelope(c,self.basis,rows,rows,evidence))
        (evidence/'extra.txt').unlink()
        name=record['receipts'][0]['path'];raw=(evidence/name).read_bytes()
        file(evidence/name,raw+b' ')
        self.rejects(lambda:m._read_native_approval_envelope(c,self.basis,rows,rows,evidence))
        file(evidence/name,raw)
        outside=self.root/'hardlink';os.link(evidence/name,outside)
        self.rejects(lambda:m._read_native_approval_envelope(c,self.basis,rows,rows,evidence))
        outside.unlink();(evidence/name).unlink();os.symlink('../01.json',evidence/name)
        self.rejects(lambda:m._read_native_approval_envelope(c,self.basis,rows,rows,evidence))

    def test_native_artifact_size_path_kind_and_identity_bounds(self):
        entry={'path':'result.json','kind':'canonical_facts','bytes':1,'sha256':m.digest(b'x')}
        self.assertNotEqual(m.evidence_identity([entry]),m.digest(m.canonical([entry])))
        for entries in ([entry,entry], [{**entry,'bytes':True}], [{**entry,'kind':'anything'}],
                        [{**entry,'bytes':m.MAX_JSON+1}], [{**entry,'path':'../escape'}],
                        [entry,{**entry,'path':'result.json/child'}],
                        [entry,{**entry,'path':'RESULT.JSON'}]):
            self.rejects(lambda:m._native_artifact_index(entries))
        with patch.object(m,'NATIVE_ARTIFACT_TOTAL',1):
            self.rejects(lambda:m._native_artifact_index([{**entry,'bytes':2}]),m.MUTATION)

    def test_native_approval_missing_is_explicit_and_prepare_context_rejected(self):
        c,rows,_=self.native_manifest_fixture()
        self.rejects(lambda:m._read_native_approval_envelope(c,self.basis,rows,rows,self.root),m.MISSING)
        self.rejects(lambda:m._read_native_approval_envelope(self.context(),self.basis,rows,rows,self.root))


    def native_commit_fixture(self):
        # Private writer tests deliberately simulate validated static evidence.
        self.enterContext(mock.patch.object(m,"_validate_fresh_native_static",return_value=None))
        """Exercise only private commit mechanics with explicitly synthetic facts."""
        c,rows,evidence,record=self.native_envelope_fixture()
        admission=m._read_native_approval_envelope(c,self.basis,rows,rows,evidence)
        admission['kind']='native_runtime_gates_verified'  # test-only simulated gate result
        admission['verified_static_facts']={'resolved_edges':[],'system_targets':[]}
        admission['verified_facts']={'approval_sha256':admission['approval_pin']['sha256'],
            'prepared_identity':record['prepared_identity'],'signed_identity':record['signed_identity'],
            'evidence_identity':record['evidence_identity'],'components':record['final_components'],
            'gates':sorted(c.policy['required_native_evidence'])}
        fresh={'native_objects':[],'code_bundles':[],'launch_contexts':[],'resolved_edges':[],'system_targets':[],'tool_events':[],
               'raw_artifacts':{'0000.stdout':b'SYNTHETIC STATIC OBSERVATION ONLY','0000.stderr':b''},
               'metadata_empty_before':[],'metadata_empty_after':[]}
        return c,rows,admission,fresh

    def test_native_private_commit_writes_manifest_and_acceptance_last(self):
        c,rows,admission,fresh=self.native_commit_fixture();operations=[];original=m.no_replace
        def observed(parent,source,destination,**kwargs):
            operations.append(destination)
            if destination==m.NATIVE_ACCEPTANCE:
                self.assertTrue((self.stage/'payload'/m.MANIFEST).exists())
                self.assertTrue((self.stage/m.NATIVE_FINALIZATION_DIR).is_dir())
                self.assertFalse((self.stage/m.NATIVE_ACCEPTANCE).exists())
            return original(parent,source,destination,**kwargs)
        with m.Root(self.stage) as stage,patch.object(m,'no_replace',side_effect=observed):
            result=m._commit_native_finalization(c,stage,admission,fresh)
        self.assertEqual(result['state'],'finalized');self.assertEqual(operations[-1],m.NATIVE_ACCEPTANCE)
        self.assertEqual(m.tree(self.stage/'payload',c.budget,result['manifest']),rows)
        self.assertTrue((self.stage/m.NATIVE_ACCEPTANCE).is_file())
        self.assertIn('directory entry bound',self.rejects(lambda:m._status(self.context(),self.stage)))
        self.assertEqual(m.tree(self.runtime,c.budget,self.historical),self.basis['closure'])

    def test_native_private_commit_retry_retains_marker_and_new_transcript(self):
        c,rows,admission,fresh=self.native_commit_fixture()
        with m.Root(self.stage) as stage:m._commit_native_finalization(c,stage,admission,fresh)
        marker=(self.stage/m.NATIVE_ACCEPTANCE).read_bytes()
        fresh['raw_artifacts']['0000.stdout']=b'SYNTHETIC NEW STATIC OBSERVATION'
        with m.Root(self.stage) as stage:result=m._commit_native_finalization(c,stage,admission,fresh)
        self.assertEqual(result['state'],'revalidated');self.assertEqual((self.stage/m.NATIVE_ACCEPTANCE).read_bytes(),marker)
        attempts=list((self.stage/m.NATIVE_FINALIZATION_DIR).glob('attempt-*'))
        self.assertEqual(len(attempts),2)
        self.assertEqual({(path/'fresh/0000.stdout').read_bytes() for path in attempts},
                         {b'SYNTHETIC STATIC OBSERVATION ONLY',b'SYNTHETIC NEW STATIC OBSERVATION'})

    def test_native_private_commit_rejects_unvalidated_or_unexpected_manifest(self):
        c,rows,admission,fresh=self.native_commit_fixture();admission['kind']='native_approval_envelope_not_accepted'
        with m.Root(self.stage) as stage:self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh))
        self.assertFalse((self.stage/m.NATIVE_FINALIZATION_DIR).exists())
        admission['kind']='native_runtime_gates_verified'
        file(self.stage/'payload'/m.MANIFEST,b'{"kind":"verified_runtime_payload"}\n')
        with m.Root(self.stage) as stage:self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh))
        self.assertFalse((self.stage/m.NATIVE_ACCEPTANCE).exists())

    def test_native_private_commit_failure_before_each_publication_is_unaccepted_resumable(self):
        for boundary in ('manifest','attempt','acceptance'):
            with self.subTest(boundary=boundary):
                # Each subcase needs its own isolated fixture, avoiding cleanup through a replaced path.
                isolated=Fixture(methodName='runTest');isolated.setUp()
                try:
                    c,rows,admission,fresh=isolated.native_commit_fixture();original=m.no_replace;failed=[False]
                    def interrupted(parent,source,destination,**kwargs):
                        hit=(boundary=='manifest' and destination==m.MANIFEST or
                             boundary=='attempt' and destination.startswith('attempt-') or
                             boundary=='acceptance' and destination==m.NATIVE_ACCEPTANCE)
                        if hit and not failed[0]:
                            failed[0]=True;raise m.Rejected('synthetic interrupted publication',m.MUTATION)
                        return original(parent,source,destination,**kwargs)
                    with m.Root(isolated.stage) as stage,patch.object(m,'no_replace',side_effect=interrupted):
                        isolated.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh),m.MUTATION)
                    self.assertFalse((isolated.stage/m.NATIVE_ACCEPTANCE).exists())
                    with m.Root(isolated.stage) as stage:result=m._commit_native_finalization(c,stage,admission,fresh)
                    self.assertEqual(result['state'],'finalized')
                finally:isolated.doCleanups()

    def test_native_private_commit_rejects_changed_approval_payload_and_marker(self):
        c,rows,admission,fresh=self.native_commit_fixture();path=self.source/m.NATIVE_PATH;old=path.read_bytes()
        file(path,old+b' ')
        with m.Root(self.stage) as stage:self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh))
        self.assertFalse((self.stage/m.NATIVE_ACCEPTANCE).exists());file(path,old)
        with m.Root(self.stage) as stage:m._commit_native_finalization(c,stage,admission,fresh)
        marker=self.stage/m.NATIVE_ACCEPTANCE;value=m.strict_json(marker.read_bytes());value['bindings']['signed_identity']='0'*64
        file(marker,m.canonical(value))
        with m.Root(self.stage) as stage:self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh))
        self.assertEqual(m.strict_json(marker.read_bytes())['bindings']['signed_identity'],'0'*64)

    def test_native_private_commit_detects_mutation_after_marker_rename(self):
        c,rows,admission,fresh=self.native_commit_fixture();original=m.no_replace
        def changed(parent,source,destination,**kwargs):
            original(parent,source,destination,**kwargs)
            if destination==m.NATIVE_ACCEPTANCE:file(self.stage/'payload/Voice/python/bin/python3',b'changed after marker')
        with m.Root(self.stage) as stage,patch.object(m,'no_replace',side_effect=changed):
            self.assertIn('payload changed after',self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh),m.MUTATION))
        # Visibility is not authority: changed payload invalidates the marker and retry.
        with m.Root(self.stage) as stage:self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh),m.MUTATION)

    def test_native_private_commit_rechecks_retained_evidence(self):
        c,rows,admission,fresh=self.native_commit_fixture()
        with m.Root(self.stage) as stage:m._commit_native_finalization(c,stage,admission,fresh)
        marker=m.strict_json((self.stage/m.NATIVE_ACCEPTANCE).read_bytes())
        attempt=self.stage/marker['finalization_evidence']['path'];raw=attempt.read_bytes()
        file(attempt,raw+b' ')
        with m.Root(self.stage) as stage:self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh))

    def test_native_private_commit_binds_resolved_edges_to_admitted_static_gate(self):
        c,rows,admission,fresh=self.native_commit_fixture()
        fresh['resolved_edges']=[{'changed':'synthetic edge mismatch'}]
        with m.Root(self.stage) as stage:
            self.assertIn('resolved dependencies',self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh)))
        self.assertFalse((self.stage/m.NATIVE_ACCEPTANCE).exists())

    def test_native_private_commit_unknown_state_and_raw_artifact_rejected(self):
        c,rows,admission,fresh=self.native_commit_fixture();file(self.stage/'unexpected',b'x')
        with m.Root(self.stage) as stage:self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh))
        (self.stage/'unexpected').unlink()
        fresh['raw_artifacts']['not-a-stream']=b'synthetic'
        with m.Root(self.stage) as stage:self.rejects(lambda:m._commit_native_finalization(c,stage,admission,fresh))
        self.assertFalse((self.stage/m.NATIVE_ACCEPTANCE).exists())


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



























# BEGIN NATIVE COMPOSITION TESTS
import types
import time
import struct
from unittest import mock
class BoundedProcessTests(unittest.TestCase):
    def run_child(self, program, seconds=1, cap=m._NS_OUTPUT):
        return m._native_run_bounded([sys.executable,'-I','-B','-c',program],
                                    time.monotonic()+seconds,env={},cap=cap)

    def test_raw_bytes_and_zero(self):
        result = self.run_child("import os; os.write(1,b'\\xff\\x00'); os.write(2,b'raw')")
        self.assertEqual(result['stdout'],b'\xff\x00')
        self.assertEqual(result['stderr'],b'raw')
        self.assertEqual(result['returncode'],0)
        self.assertTrue(result['cleanup']['complete'])
        self.assertIsNone(result['reason'])

    def test_post_eof_hang_uses_same_deadline(self):
        start = time.monotonic()
        result = self.run_child('import os,time; os.close(1); os.close(2); time.sleep(10)',.08)
        self.assertEqual(result['reason'],'deadline')
        self.assertLess(time.monotonic()-start,2.2)
        self.assertTrue(result['cleanup']['complete'])

    def test_flood_is_bounded(self):
        result = self.run_child("import os; os.write(1,b'x'*200000)",cap=1000)
        self.assertEqual(result['reason'],'output_limit')
        self.assertEqual(len(result['stdout'])+len(result['stderr']),1000)
        self.assertTrue(result['cleanup']['complete'])

    def test_signal_exit_not_success(self):
        result = self.run_child('import os,signal; os.kill(os.getpid(),signal.SIGTERM)')
        self.assertEqual(result['returncode'],-15)
        self.assertTrue(result['cleanup']['complete'])

    def test_spawn_failure(self):
        result = m._native_run_bounded(['/does/not/exist'],time.monotonic()+1)
        self.assertEqual(result['reason'],'spawn_failed')
        self.assertIsNone(result['returncode'])

    def test_no_poll_before_group_teardown(self):
        original_kill = m.os.killpg
        original_wait = m.subprocess.Popen.wait
        killed = set()
        def kill(pid,sig):
            if sig == m.signal.SIGKILL: killed.add(pid)
            return original_kill(pid,sig)
        def wait(child,*args,**kwargs):
            self.assertIn(child.pid,killed)
            return original_wait(child,*args,**kwargs)
        with mock.patch.object(m.os,'killpg',side_effect=kill), \
             mock.patch.object(m.subprocess.Popen,'wait',wait), \
             mock.patch.object(m.subprocess.Popen,'poll',side_effect=AssertionError('reaping poll forbidden')):
            result = self.run_child('pass')
        self.assertTrue(result['cleanup']['complete'])

    def test_observed_exit_does_not_reap(self):
        child = m.subprocess.Popen([sys.executable,'-I','-B','-c','pass'],start_new_session=True)
        try:
            deadline = time.monotonic()+2
            while not m._native_child_exited(child) and time.monotonic()<deadline:
                time.sleep(.005)
            self.assertIsNone(child.returncode)
            m.os.killpg(child.pid,m.signal.SIGKILL)
            self.assertEqual(child.wait(timeout=1),0)
        finally:
            if child.returncode is None:
                m.os.killpg(child.pid,m.signal.SIGKILL); child.wait(timeout=1)

    def test_selector_failure_never_spawns(self):
        with mock.patch.object(m.selectors,'DefaultSelector',side_effect=OSError('too many files')), \
             mock.patch.object(m.subprocess,'Popen') as popen:
            with self.assertRaises(OSError): self.run_child('pass')
        popen.assert_not_called()

    def test_owned_group_survives_leader_is_failure(self):
        original = m.os.killpg
        def kill(pid,sig):
            if sig==0: return None  # synthetic owned descendant still present
            return original(pid,sig)
        with mock.patch.object(m.os,'killpg',side_effect=kill):
            result = self.run_child('pass')
        self.assertEqual(result['reason'],'incomplete_cleanup')
        self.assertFalse(result['cleanup']['complete'])
        self.assertEqual(result['cleanup']['remaining_owned_processes'],1)
        self.assertGreaterEqual(result['cleanup']['duration_ms'],2000)


class ParserTests(unittest.TestCase):
    def test_lipo_strict(self):
        self.assertEqual(m._parse_native_lipo(b'arm64 x86_64\n',b''),['arm64','x86_64'])
        for raw in (b'arm64 arm64\n',b'arm64e\n',b'arm64',b'warning\narm64\n'):
            with self.assertRaises(m.Rejected): m._parse_native_lipo(raw,b'')

    def test_otool_minimal_and_unknown(self):
        raw = (b'/dev/fd/9:\nLoad command 0\n cmd LC_BUILD_VERSION\n cmdsize 32\n'
               b' platform 1\n minos 11.0\n sdk 14.0\n ntools 1\n tool LD\n version 1.0\n'
               b'Load command 1\n cmd LC_LOAD_DYLIB\n cmdsize 64\n'
               b' name /usr/lib/libSystem.B.dylib (offset 24)\n time stamp 2 Thu Jan 1 00:00:02 1970\n'
               b' current version 1.0.0\n compatibility version 1.0.0\n')
        result = m._parse_native_otool_loads(raw,b'','/dev/fd/9',['arm64'])
        self.assertEqual(result['minimum_os'],'11.0')
        self.assertEqual(result['load_commands'][1]['name'],'/usr/lib/libSystem.B.dylib')
        with self.assertRaises(m.Rejected):
            m._parse_native_otool_loads(raw.replace(b'LC_LOAD_DYLIB',b'LC_UNKNOWN'),b'','/dev/fd/9',['arm64'])

    def test_entitlement_duplicate_rejected(self):
        raw = b'<?xml version="1.0"?><plist version="1.0"><dict><key>x</key><true/><key>x</key><false/></dict></plist>'
        with self.assertRaises(m.Rejected): m._parse_native_entitlements(raw,b'','/dev/fd/9')

    def test_verify_exact(self):
        raw = b'/dev/fd/9: valid on disk\n/dev/fd/9: satisfies its Designated Requirement\n'
        self.assertTrue(m._parse_native_codesign_verify(b'',raw,'/dev/fd/9'))
        with self.assertRaises(m.Rejected): m._parse_native_codesign_verify(b'',raw+b'warning\n','/dev/fd/9')


def synthetic_case():
    context = types.SimpleNamespace(sources={'scripts/reconstruct_runtime_payload.py':{'bytes':4,'sha256':'a'*64}})
    rows = [{'path':'.','kind':'directory','mode':0o700},
            {'path':'engine','kind':'file','mode':0o700,'bytes':4,'sha256':m.digest(b'\xcf\xfa\xed\xfe')}]
    target = '/dev/fd/9'
    loads = (target+':\nLoad command 0\n cmd LC_BUILD_VERSION\n cmdsize 32\n'
             ' platform 1\n minos 11.0\n sdk 14.0\n ntools 1\n tool LD\n version 1.0\n'
             'Load command 1\n cmd LC_LOAD_DYLIB\n cmdsize 64\n'
             ' name /usr/lib/libSystem.B.dylib (offset 24)\n time stamp 2 Thu Jan 1 00:00:02 1970\n'
             ' current version 1.0.0\n compatibility version 1.0.0\n').encode()
    libraries = (target+':\n /usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n').encode()
    display = (f'Executable={target}\nIdentifier=synthetic.engine\nFormat=Mach-O thin (arm64)\n'
               'CodeDirectory v=20400 size=400 flags=0x2(adhoc) hashes=1+2 location=embedded\n'
               'Hash type=sha256 size=32\nHash choices=sha256\nCDHash='+ '1'*40 +'\n'
               'Signature=adhoc\nInfo.plist=not bound\nTeamIdentifier=not set\n'
               'Sealed Resources=none\nInternal requirements count=1 size=40\n').encode()
    requirement = b'designated => identifier "synthetic.engine"\n'
    signature = m._parse_native_codesign_display(requirement,display,target)
    signature['entitlements'] = {}
    obj = {**{k:rows[1][k] for k in ('path','bytes','sha256')},'architectures':['arm64'],
           **m._parse_native_otool_loads(loads,b'',target,['arm64']),'signature':signature}
    inventory = {'objects':[obj],'code_bundles':[],
                 'launch_contexts':[{'id':'engine','executable':'engine','loaded_objects':['engine']}],
                 'system_roots':['/usr/lib'],
                 'system_targets':[{'context':'engine','architecture':'arm64','target':'/usr/lib/libSystem.B.dylib',
                                    'availability':'dyld_shared_cache','file':None,'cache_uuid':'9'*32}]}
    streams = {'host_arm64':(b'1\n',b''),'lipo':(b'arm64\n',b''),
               'otool_libraries':(libraries,b''),'otool_loads':(loads,b''),
               'codesign_display':(requirement,display),'codesign_entitlements':(b'',b''),
               'codesign_verify':(b'',(target+': valid on disk\n'+target+': satisfies its Designated Requirement\n').encode())}
    artifacts,events = {},[]
    for role,(stdout,stderr) in streams.items():
        event_id = 'native-'+str(len(events)+1).zfill(6)
        tool,args = m._NS_ROLES[role]
        argv = [m._NS_TOOLS['sandbox'],'-p',m._ns_profile('/synthetic/payload'),m._NS_TOOLS[tool],*args]
        if role!='host_arm64': argv.append(target)
        pins = {}
        for name,raw in (('stdout',stdout),('stderr',stderr)):
            path = 'commands/'+event_id+'.'+name
            artifacts[path] = raw
            pins[name] = {'path':path,'kind':name,'bytes':len(raw),'sha256':m.digest(raw)}
        events.append({'id':event_id,'role':role,'payload_root':'/synthetic/payload','argv':argv,
            'source':{'path':'scripts/reconstruct_runtime_payload.py',**context.sources['scripts/reconstruct_runtime_payload.py']},
            'tool_identity':{'path':m._NS_TOOLS[tool],'bytes':1,'sha256':'b'*64,'uid':0,'mode':0o755},
            'sandbox_identity':{'path':m._NS_TOOLS['sandbox'],'bytes':1,'sha256':'b'*64,'uid':0,'mode':0o755},
            'target':m._ns_target_pin(rows,'.' if role=='host_arm64' else 'engine'),'environment':dict(m._NS_ENV),
            **pins,'outcome':{'kind':'exited','exit_status':0},'reason':None,
            'cleanup':{'remaining_owned_processes':0,'open_output_pipes':0,'complete':True,'duration_ms':0},
            'duration_ms':1,'started':'2026-10-14T00:00:00+00:00','ended':'2026-10-14T00:00:01+00:00'})
    event,path,raw = m._ns_system_event(context,inventory['system_targets'],time.monotonic(),
                                     '2026-10-14T00:00:00+00:00')
    events.append(event); artifacts[path]=raw
    return context,rows,inventory,events,artifacts


def synthetic_static_snapshot(context,rows,native_path):
    """Reusable raw fixture for composed approval tests; always synthetic."""
    _,_,inventory,events,artifacts=synthetic_case()
    row=next(row for row in rows if row['path']==native_path)
    inventory['objects'][0].update({key:row[key] for key in ('path','bytes','sha256')})
    inventory['launch_contexts'][0]['executable']=native_path
    inventory['launch_contexts'][0]['loaded_objects']=[native_path]
    for event in events:
        event['source']={'path':'scripts/reconstruct_runtime_payload.py',**context.sources['scripts/reconstruct_runtime_payload.py']}
        if event['role']!='system_targets':
            event['target']=m._ns_target_pin(rows,'.' if event['role']=='host_arm64' else native_path)
    parsed=m._parse_native_static_evidence(context,rows,inventory,events,artifacts)
    metadata=[{'path':row['path'],'nofollow':True,'supported':True,'attributes':[]} for row in rows]
    observation={**parsed['parsed_static_facts'],'tool_events':events,
                 'metadata_empty_before':metadata,'metadata_empty_after':copy.deepcopy(metadata)}
    return observation,inventory,parsed,artifacts


class ReplayTests(unittest.TestCase):
    def test_complete_synthetic_replay(self):
        case = synthetic_case()
        result = m._parse_native_static_evidence(*case)
        self.assertEqual(result['parsed_static_facts']['native_objects'],case[2]['objects'])
        self.assertEqual(result['parsed_static_facts']['resolved_edges'][0]['target'],'/usr/lib/libSystem.B.dylib')

    def test_missing_duplicate_or_mutated_raw(self):
        for mutation in ('missing','duplicate','raw','argv','empty','wrongarch','signer'):
            case = list(synthetic_case())
            if mutation=='missing': case[3].pop()
            elif mutation=='duplicate': case[3].append(copy.deepcopy(case[3][-1]))
            elif mutation=='raw': case[4][case[3][1]['stdout']['path']] = b'x86_64\n'
            elif mutation=='argv': case[3][1]['argv'][-1]='/tmp/not-held'
            elif mutation=='empty': case[3]=[]
            elif mutation=='wrongarch': case[2]['objects'][0]['architectures']=['arm64','x86_64']
            else: case[2]['objects'][0]['signature']['identifier']='other'
            with self.subTest(mutation=mutation), self.assertRaises(m.Rejected):
                m._parse_native_static_evidence(*case)

    def test_malformed_containers_raise_rejected(self):
        for mutation in ('role_list','object_list','object_path_list','bundle_list','roots_nested','loaded_nested'):
            case = list(synthetic_case())
            if mutation=='role_list': case[3][0]['role']=[]
            elif mutation=='object_list': case[2]['objects'][0]=[]
            elif mutation=='object_path_list': case[2]['objects'][0]['path']=[]
            elif mutation=='bundle_list': case[2]['code_bundles']=[[]]
            elif mutation=='roots_nested': case[2]['system_roots']=[[]]
            else: case[2]['launch_contexts'][0]['loaded_objects']=[[]]
            with self.subTest(mutation=mutation),self.assertRaises(m.Rejected):
                m._parse_native_static_evidence(*case)

    def test_aggregate_output_is_bounded(self):
        case = list(synthetic_case())
        with mock.patch.object(m,'_NS_TOTAL_OUTPUT',10):
            with self.assertRaises(m.Rejected): m._parse_native_static_evidence(*case)

    def test_profile_cannot_create_descendants(self):
        profile = m._ns_profile('/synthetic/path with spaces,雪/payload')
        self.assertIn('(deny process-fork)',profile)
        self.assertNotIn('(allow process-fork)',profile)
        self.assertIn('(deny network*)',profile)
        self.assertIn('(deny file-write*)',profile)
        self.assertNotIn('(allow process-exec (subpath',profile)

    def test_signer_authorities_are_retained_and_bound(self):
        _,_,_,events,artifacts = synthetic_case()
        display_event = next(event for event in events if event['role']=='codesign_display')
        raw = artifacts[display_event['stderr']['path']]
        raw = raw.replace(b'flags=0x2(adhoc)',b'flags=0x0')
        raw = raw.replace(b'Signature=adhoc\n',b'Authority=Example Leaf\nAuthority=Example Root\n')
        raw = raw.replace(b'TeamIdentifier=not set',b'TeamIdentifier=ABCDEFGHIJ')
        facts = m._parse_native_codesign_display(artifacts[display_event['stdout']['path']],raw,'/dev/fd/9')
        self.assertEqual(facts['authorities'],['Example Leaf','Example Root'])
        self.assertFalse(facts['ad_hoc'])

    def test_unsupported_portable_entry(self):
        with mock.patch.object(m.sys,'platform','linux'):
            with self.assertRaisesRegex(m.Rejected,'NATIVE_REQUIRED'):
                m._verify_native_static(None,None,None)

    def test_escaping_and_ambiguous_dependencies(self):
        context,rows,inventory,_,_ = synthetic_case()
        obj = inventory['objects'][0]
        for name in ('/Users/example/lib.dylib','@loader_path/../outside'):
            changed = copy.deepcopy(obj)
            changed['load_commands'][1]['name']=name
            with self.assertRaises(m.Rejected):
                m._native_resolved_edges(rows,[changed],inventory['launch_contexts'],inventory['system_roots'])

    def test_bundle_mapping_is_independent(self):
        rows = [{'path':'.','kind':'directory','mode':0o700},
                {'path':'X.app','kind':'directory','mode':0o700},
                {'path':'X.app/Contents','kind':'directory','mode':0o700},
                {'path':'X.app/Contents/_CodeSignature/CodeResources','kind':'file','bytes':1,'sha256':'a'*64}]
        result = m._ns_bundle_mapping(rows,{'X.app/Contents/MacOS/X'})
        self.assertEqual(result[0]['path'],'X.app')
        self.assertEqual(result[0]['seal_root'],'X.app/Contents')
        with self.assertRaises(m.Rejected): m._ns_bundle_mapping(rows[:-1],{'X.app/Contents/MacOS/X'})


class NativeBoundaryMockTests(unittest.TestCase):
    def bounds(self):
        return json.loads((ROOT/'packaging/runtime/reconstruction-policy.json').read_text())['bounds']

    def test_empty_xattr_nofollow_and_rejection(self):
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as directory:
            root = Path(directory)
            (root/'engine').write_bytes(b'x')
            os.symlink('engine',root/'alias')
            context = types.SimpleNamespace(bounds=self.bounds(),budget=m.Budget(self.bounds()))
            libc = types.SimpleNamespace(flistxattr=mock.Mock(return_value=0),listxattr=mock.Mock(return_value=0))
            with m.Root(root) as cap, mock.patch.object(m.sys,'platform','darwin'), \
                 mock.patch.object(m.ctypes,'CDLL',return_value=libc):
                rows = m.tree(root,context.budget)
                metadata = m._native_empty_xattrs(context,cap,rows)
                self.assertEqual({x['path'] for x in metadata},{'.','engine','alias'})
                self.assertEqual(libc.listxattr.call_args.args[-1],1)
                libc.flistxattr.return_value=12
                with self.assertRaisesRegex(m.Rejected,'UNREVIEWED_NATIVE_METADATA'):
                    m._native_empty_xattrs(context,cap,rows)
                libc.flistxattr.return_value=-1
                with self.assertRaisesRegex(m.Rejected,'UNSUPPORTED_NOFOLLOW_NATIVE_METADATA'):
                    m._native_empty_xattrs(context,cap,rows)

    def test_complete_fresh_verifier_only_at_mock_boundary(self):
        original_context,_,inventory,events,artifacts = synthetic_case()
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as directory:
            root = Path(directory)
            (root/'engine').write_bytes(b'\xcf\xfa\xed\xfe'); (root/'engine').chmod(0o700)
            context = types.SimpleNamespace(phase='native',bounds=self.bounds(),budget=m.Budget(self.bounds()),
                sources={**original_context.sources,'Resources/Runtime/dot_process.py':{'bytes':1,'sha256':'c'*64}})
            events=events[:-1]; artifacts={path:raw for path,raw in artifacts.items() if 'system-targets' not in path}
            fake = types.SimpleNamespace(events=events,artifacts=artifacts,call=mock.Mock(),close=mock.Mock(),
                output_bytes=sum(map(len,artifacts.values())),deadline=time.monotonic()+300)
            def empty(context,payload,rows,manifest_pin=None):
                return [{'path':row['path'],'nofollow':True,'supported':True,'attributes':[]} for row in rows]
            with m.Root(root) as cap, mock.patch.object(m.sys,'platform','darwin'), \
                 mock.patch.object(m,'_native_empty_xattrs',side_effect=empty), \
                 mock.patch.object(m,'_native_system_targets',return_value=inventory['system_targets']), \
                 mock.patch.object(m,'_NativeToolset',return_value=fake):
                result = m._verify_native_static(context,cap,inventory)
                self.assertEqual(result['native_objects'],inventory['objects'])
                self.assertEqual(fake.call.call_count,7)
                fake.close.assert_called_once()
                (root/m.MANIFEST).write_bytes(b'{}\n')
                with self.assertRaisesRegex(m.Rejected,'unexpected runtime manifest'):
                    m._verify_native_static(context,cap,inventory)

    def test_system_target_cache_file_missing_and_unsupported(self):
        context,rows,inventory,events,artifacts=synthetic_case()
        context.bounds=self.bounds(); context.budget=m.Budget(context.bounds)
        edges=m._parse_native_static_evidence(context,rows,inventory,events,artifacts)['parsed_static_facts']['resolved_edges']
        def inspect():
            return m._native_system_targets(context,inventory['objects'],inventory['launch_contexts'],edges,inventory['system_roots'])
        with mock.patch.object(m.sys,'platform','darwin'),mock.patch.object(m.os,'uname',return_value=types.SimpleNamespace(machine='arm64')):
            with mock.patch.object(m,'_ns_system_cache',return_value=(True,'9'*32)),mock.patch.object(m,'_ns_system_file',return_value=None):
                self.assertEqual(inspect(),inventory['system_targets'])
            with mock.patch.object(m,'_ns_system_cache',return_value=(False,None)),mock.patch.object(m,'_ns_system_file',return_value=None):
                with self.assertRaisesRegex(m.Rejected,'unresolved system dependency'): inspect()
            with mock.patch.object(m,'_ns_system_cache',side_effect=m.Rejected('unavailable',m.UNSUPPORTED)),mock.patch.object(m,'_ns_system_file',return_value=None):
                with self.assertRaisesRegex(m.Rejected,'UNSUPPORTED_DYLD_CACHE_INSPECTION'): inspect()
            file_pin={'bytes':3,'sha256':'f'*64}
            with mock.patch.object(m,'_ns_system_cache',return_value=(False,None)),mock.patch.object(m,'_ns_system_file',return_value=file_pin):
                self.assertEqual(inspect()[0]['file'],file_pin)
            with mock.patch.object(m,'_ns_system_cache',return_value=(True,'9'*32)),mock.patch.object(m,'_ns_system_file',return_value=file_pin):
                with self.assertRaisesRegex(m.Rejected,'AMBIGUOUS_SYSTEM_TARGET'): inspect()

    def test_system_target_nonexistent_and_unsafe_disk(self):
        context=types.SimpleNamespace(bounds=self.bounds(),budget=m.Budget(self.bounds()))
        with mock.patch.object(m,'Root',side_effect=FileNotFoundError):
            self.assertIsNone(m._ns_system_file(context,'/usr/lib/definitely_missing_dot_test_library.dylib'))
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as directory:
            path=Path(directory)/'fake.dylib'; path.write_bytes(b'bad')
            with self.assertRaises(m.Rejected): m._ns_system_file(context,str(path))

    def test_cache_abi_is_fixed_and_absence_fails_closed(self):
        def uuid(buffer):
            for index in range(16): buffer[index]=index+1
            return True
        library=types.SimpleNamespace(_dyld_shared_cache_contains_path=mock.Mock(return_value=True),
                                      _dyld_get_shared_cache_uuid=mock.Mock(side_effect=uuid))
        with mock.patch.object(m.sys,'platform','darwin'),mock.patch.object(m.ctypes,'CDLL',return_value=library):
            self.assertEqual(m._ns_system_cache('/usr/lib/example.dylib'),(True,bytes(range(1,17)).hex()))
            self.assertEqual(library._dyld_shared_cache_contains_path.argtypes,[m.ctypes.c_char_p])
            self.assertIs(library._dyld_shared_cache_contains_path.restype,m.ctypes.c_bool)
        with mock.patch.object(m.sys,'platform','darwin'),mock.patch.object(m.ctypes,'CDLL',return_value=object()):
            with self.assertRaisesRegex(m.Rejected,'UNSUPPORTED_DYLD_CACHE_API'):
                m._ns_system_cache('/usr/lib/example.dylib')



class NativeGateSemanticFragmentTests(unittest.TestCase):
    def setUp(self):
        self.artifacts = {}
        self.e = {'files':{}, 'source_identities':{}, 'events':{}, 'payload_root':'/fixture/runtime',
                  'source_root':'/fixture/source', 'voice_python_root':'Voice/python',
                  'signed_identity':'1'*64,'prepared_identity':'2'*64,'basis_identity':'3'*64,
                  'collector_bundle_identity':'4'*64,'transform_identity':'5'*64,
                  'historical_manifest':{'bytes':4,'sha256':'6'*64}}
        self.file('Voice/python/bin/python3', b'python')
        for path in ('Resources/Voice/bionic_helper.py','Resources/Voice/voice.sb',
                     'Resources/Runtime/dot_runtime.py','Resources/Runtime/dot_process.py',
                     'Resources/Runtime/dot_tls.py','Resources/Runtime/splash.sb','Tests/Native/tls.swift'):
            self.e['source_identities'][path] = {'bytes':len(path), 'sha256':m.digest(path.encode())}
        self.e['interpreter'] = {'path':'Voice/python/bin/python3',
            'file_pin':{k:self.e['files']['Voice/python/bin/python3'][k] for k in ('bytes','sha256')},
            'implementation':'CPython','version':'3.11.17','architecture':'arm64',
            'prefix':'Voice/python','base_prefix':'Voice/python'}
        self.e['voice_launch'] = {'helper_path':'/fixture/source/Resources/Voice/bionic_helper.py',
            'profile_path':'/fixture/source/Resources/Voice/voice.sb','output_path':'/fixture/private',
            'voice_root':'/fixture/runtime/Voice'}
        self.environment = {'PATH':'/usr/bin:/bin','HOME':'/fixture/private','TMPDIR':'/fixture/private',
            'PYTHONDONTWRITEBYTECODE':'1','HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1',
            'HF_HUB_DISABLE_TELEMETRY':'1','HF_HUB_DISABLE_IMPLICIT_TOKEN':'1'}
        self.cleanup = {'remaining_owned_processes':0,'open_output_pipes':0,'complete':True,'duration_ms':10}
        self.outcome = {'kind':'exited','exit_status':0}
        self.hello = {'protocol':1,'event':'hello','engine':'kokoro','voice':'bf_isabella',
                      'sample_rate':24000,'offline':True}
        self.request = self.request_for(1)
        self.audio = {'protocol':1,'event':'audio','id':self.request['id'],'turn':self.request['turn'],
            'file':'audio-00000000-0000-0000-0000-000000000003.wav','samples':2,'sample_rate':24000}

    def request_for(self,n):
        return {'protocol':1,'type':'speak','id':'00000000-0000-0000-0000-%012d' % (n*2),
                'turn':'00000000-0000-0000-0000-%012d' % (n*2+1),'text':'Synthetic fixture sentence.'}

    def file(self,path,raw=b'fixture'):
        self.e['files'][path] = {'path':path,'kind':'file','mode':420,'bytes':len(raw),'sha256':m.digest(raw)}
        return {key:self.e['files'][path][key] for key in ('path','bytes','sha256')}

    def artifact(self,name,raw,kind='canonical_facts'):
        self.artifacts[name] = raw
        return {'path':name,'kind':kind,'bytes':len(raw),'sha256':m.digest(raw)}

    def facts(self,name,value):
        return self.artifact(name,m.canonical(value))

    def wav(self,pcm=b'\x01\x00\xfe\xff'):
        return b'RIFF' + struct.pack('<I',36+len(pcm)) + b'WAVEfmt ' + struct.pack('<IHHIIHH',16,1,1,24000,48000,2,16) + b'data' + struct.pack('<I',len(pcm)) + pcm

    def event(self,event_id='voice',stdout=None,role='voice_helper'):
        if stdout is None: stdout = m.canonical(self.hello)+m.canonical(self.audio)
        source = {'path':'Resources/Voice/bionic_helper.py', **self.e['source_identities']['Resources/Voice/bionic_helper.py']}
        target = {k:self.e['files']['Voice/python/bin/python3'][k] for k in ('path','bytes','sha256')}
        if role == 'pip_check': argv = ['/fixture/runtime/Voice/python/bin/python3','-I','-B','-m','pip','check']
        else:
            argv = ['/usr/bin/sandbox-exec','-D','DOT_OUTPUT=/fixture/private','-D','DOT_VOICE_ROOT=/fixture/runtime/Voice',
                    '-D','DOT_VOICE_HELPER=/fixture/source/Resources/Voice/bionic_helper.py',
                    '-D','DOT_PYTHON_ROOT=/fixture/runtime/Voice/python','-f','/fixture/source/Resources/Voice/voice.sb',
                    '/fixture/runtime/Voice/python/bin/python3','-I','-B','-u',
                    '/fixture/source/Resources/Voice/bionic_helper.py','--root','/fixture/runtime/Voice','--output','/fixture/private']
        self.e['events'][event_id] = {'role':role,'argv':argv,'source':source,'target':target,'environment':copy.deepcopy(self.environment)}
        return {'id':event_id,'argv':copy.deepcopy(argv),'source':source,'target':target,
            'environment_artifact':self.facts(event_id+'.env',self.environment),
            'stdout':self.artifact(event_id+'.stdout',stdout,'stdout'),'stderr':self.artifact(event_id+'.stderr',b'','stderr'),
            'outcome':copy.deepcopy(self.outcome),'cleanup':copy.deepcopy(self.cleanup),
            'duration_ms':100,'started':'fixture-start','ended':'fixture-end'}

    def probe_event(self,event_id,raw,product_profile=False):
        event=self.event(event_id,raw)
        source_path='Tests/Native/synthetic_probe.py'
        source={'path':source_path,'bytes':7,'sha256':m.digest(b'fixture')}
        self.e['source_identities'][source_path]={k:source[k] for k in ('bytes','sha256')}
        argv=['/fixture/runtime/Voice/python/bin/python3','-I','-B','/fixture/source/'+source_path]
        event['source']=source
        if product_profile: argv=m._ng_voice_probe_argv(event,self.e,self.environment)
        event['argv']=argv
        self.e['events'][event_id].update(role='voice_probe',source=source,argv=argv)
        self.e.setdefault('probe_sources',{})['voice_probe']=source_path
        self.e.setdefault('probe_argv',{})['voice_probe']=argv
        return event

    def raw_subset(self,value,fields,product_profile=False):
        raw=m.canonical({key:value[key] for key in fields})
        self.e['facts_artifact']=self.artifact('subset.facts',raw)
        event=self.probe_event('subset-producer',raw,product_profile)
        self.e['facts_event_artifact']=self.facts('subset.event',event)
        self.e['facts_event_id']='subset-producer'

    def synthesis(self):
        self.e['voice_request'] = copy.deepcopy(self.request)
        self.e['voice_model_pins'] = [self.file('Voice/model/config.json'),self.file('Voice/model/kokoro-v1_0.pth'),
                                    self.file('Voice/model/voices/bf_isabella.pt')]
        event = self.event()
        trace = {'request':self.request,'hello':self.hello,'audio':self.audio,'output_absent_before':True,
                 'request_monotonic_ns':10,'output_created_monotonic_ns':11,'output_closed_monotonic_ns':12,
                 'initial_output_paths':[],'process_event':event}
        self.e['voice_trace_artifact'] = self.facts('voice-trace.json',trace)
        producer=self.probe_event('voice-trace-producer',m.canonical(trace))
        self.e['voice_trace_event_artifact']=self.facts('voice-trace.event',producer)
        raw = self.wav()
        return {'helper_sha256':self.e['source_identities']['Resources/Voice/bionic_helper.py']['sha256'],
            'model_pins':copy.deepcopy(self.e['voice_model_pins']),'request':copy.deepcopy(self.request),
            'hello_event':copy.deepcopy(self.hello),'audio_event':copy.deepcopy(self.audio),
            'wav_artifact':self.artifact('outputs/'+self.audio['file'],raw,'wav'),'wav_facts':m._ng_wav(raw),
            'output_created_after_request':True}

    def validate(self,gate,value):
        return m._validate_native_gate_observations(m._NATIVE_GATE_IDS[gate],value,expected=self.e,artifacts=self.artifacts)

    def test_every_gate_rejects_weak_or_unknown_observations(self):
        for gate in m._NATIVE_GATE_IDS:
            for observations in ({'passed':True},{'arbitrary':'not empty'},[],True):
                with self.subTest(gate=gate,observations=observations),self.assertRaises(m.Rejected):
                    m._validate_native_gate_observations(gate,observations,expected=self.e,artifacts=self.artifacts)

    def test_exact_gate_set_rejects_missing_duplicate_and_unknown(self):
        rows = [{'gate':gate} for gate in m._NATIVE_GATE_IDS]
        m._validate_native_gate_set(rows)
        for bad in (rows[:-1],rows+[rows[0]],rows[:-1]+[rows[0]],rows[:-1]+[{'gate':'different'}]):
            with self.assertRaises(m.Rejected): m._validate_native_gate_set(bad)

    def test_historical_requires_exact_real_mode_and_chain(self):
        value = {'mode':'reviewed_owner_historical_closure',**{k:self.e[k] for k in m._NATIVE_GATE_FIELDS[0][1:]}}
        self.validate(0,value)
        for key in value:
            bad=copy.deepcopy(value); bad[key]='0'*64 if key != 'historical_manifest' else {'bytes':True,'sha256':'6'*64}
            with self.subTest(key=key),self.assertRaises(m.Rejected): self.validate(0,bad)
        with self.assertRaises(m.Rejected): self.validate(0,{**value,'passed':True})

    def test_synthesis_recomputes_real_helper_protocol_and_wav(self):
        value=self.synthesis()
        self.validate(4,value)
        mutations = [('helper_sha256','0'*64),('output_created_after_request',False),
                     ('request',{**value['request'],'text':''}),('hello_event',{**self.hello,'engine':'stub'}),
                     ('audio_event',{**self.audio,'samples':3}),('wav_facts',{**value['wav_facts'],'frames':True}),
                     ('model_pins',value['model_pins'][:-1])]
        for key,bad_value in mutations:
            bad=copy.deepcopy(value);bad[key]=bad_value
            with self.subTest(key=key),self.assertRaises(m.Rejected): self.validate(4,bad)

    def test_synthesis_rejects_raw_mutation_even_if_claimed_facts_unchanged(self):
        value=self.synthesis();self.artifacts['voice.stdout'] = b'printed hello\n'
        with self.assertRaises(m.Rejected): self.validate(4,value)

    def test_synthesis_rejects_preexisting_output_and_bad_timeline(self):
        value=self.synthesis()
        trace=m.strict_json(self.artifacts['voice-trace.json'])
        for field,bad in (('output_absent_before',False),('initial_output_paths',['old.wav']),('output_created_monotonic_ns',9)):
            changed=copy.deepcopy(trace); changed[field]=bad
            self.e['voice_trace_artifact']=self.facts('voice-trace.json',changed)
            with self.subTest(field=field),self.assertRaises(m.Rejected):self.validate(4,value)

    def test_wav_rejects_zero_pcm_wrong_lengths_duplicate_chunks_and_nonpcm(self):
        valid=self.wav();self.assertEqual(m._ng_wav(valid)['frames'],2)
        mutations=[self.wav(b'\0\0\0\0'),valid+b'extra',b'RIFX'+valid[4:],valid[:20]+b'\3\0'+valid[22:],
                   valid[:22]+b'\2\0'+valid[24:],valid[:24]+struct.pack('<I',44100)+valid[28:],
                   valid[:40]+struct.pack('<I',8)+valid[44:]]
        duplicate=valid+b'data'+struct.pack('<I',2)+b'\1\0'
        duplicate=duplicate[:4]+struct.pack('<I',len(duplicate)-8)+duplicate[8:]
        mutations.append(duplicate)
        for i,bad in enumerate(mutations):
            with self.subTest(i=i),self.assertRaises(m.Rejected):m._ng_wav(bad)

    def test_event_rejects_argv_environment_source_outcome_and_bool_counts(self):
        event=self.event();m._ng_event(event,self.e,self.artifacts,'voice_helper')
        for field,value in [('argv',['/bin/echo','hello']),('source',{**event['source'],'sha256':'0'*64}),
                            ('target',{**event['target'],'bytes':True}),('outcome',{'kind':'exited','exit_status':False}),
                            ('cleanup',{**self.cleanup,'open_output_pipes':False}),
                            ('duration_ms',True)]:
            bad=copy.deepcopy(event);bad[field]=value
            with self.subTest(field=field),self.assertRaises(m.Rejected):m._ng_event(bad,self.e,self.artifacts,'voice_helper')
        for key,value in [('API_KEY','secret'),('PYTHONPATH','/host/packages')]:
            bad=copy.deepcopy(event);env={**self.environment,key:value};bad['environment_artifact']=self.facts('bad.env',env)
            self.e['events']['voice']['environment']=env
            with self.subTest(key=key),self.assertRaises(m.Rejected):m._ng_event(bad,self.e,self.artifacts,'voice_helper')

    def test_even_approved_arbitrary_voice_argv_is_rejected(self):
        event=self.event();event['argv']=['/usr/bin/sandbox-exec','-f','/fixture/source/Resources/Voice/voice.sb','-I','-B','-c','print(1)']
        self.e['events']['voice']['argv']=event['argv']
        with self.assertRaises(m.Rejected):m._ng_event(event,self.e,self.artifacts,'voice_helper')

    def test_artifacts_reject_external_paths_kinds_and_bool_bytes(self):
        item=self.artifact('ok',b'fixture','stdout');m._ng_artifact(item,'stdout',self.artifacts)
        for field,value in [('path','../escape'),('kind','wav'),('bytes',True),('sha256','0'*64)]:
            bad={**item,field:value}
            with self.subTest(field=field),self.assertRaises(m.Rejected):m._ng_artifact(bad,'stdout',self.artifacts)

    def test_metadata_requires_every_node_empty_no_follow_supported(self):
        rows=[{'path':p,'nofollow':True,'supported':True,'attributes':[]} for p in self.e['files']]
        m._ng_empty_metadata(rows,self.e)
        for bad in ([],rows+rows,[{**rows[0],'attributes':['com.apple.ResourceFork']}],
                    [{**rows[0],'nofollow':False}],[{**rows[0],'supported':False}]):
            with self.assertRaises(m.Rejected):m._ng_empty_metadata(bad,self.e)

    def test_distribution_lock_requires_all_92_and_contained_metadata(self):
        dist=[];origins=[]
        for n in range(92):
            name='synthetic-package-%03d'%n;root='Voice/python/lib/site-packages';path=root+'/'+name+'.dist-info'
            metadata=self.file(path+'/METADATA',('Name: '+name).encode())
            self.e['files'][path]={'path':path,'kind':'directory','mode':493}
            dist.append({'name':name,'version':'1.0','dist_info':path,'metadata':metadata})
            origins.append({'name':name,'root':root,'metadata_paths':[metadata]})
        self.e['locked_distributions']=[{'name':d['name'],'version':d['version']} for d in dist]
        self.e['bootstrap_exceptions']=[];self.e['package_origins']=origins
        self.e['files']['Voice/python']={'path':'Voice/python','kind':'directory','mode':493}
        self.e['sys_path']=['Voice/python']
        value={'interpreter':copy.deepcopy(self.e['interpreter']),'distributions':dist,'bootstrap_exceptions':[],
               'package_origins':origins,'sys_path':['Voice/python'],
               'pip_check_event':self.event('pip',b'No broken requirements found.\n','pip_check')}
        self.raw_subset(value,('interpreter','distributions','bootstrap_exceptions','package_origins','sys_path'))
        self.validate(1,value)
        for mutation in ('missing','duplicate','external','interpreter','pip'):
            bad=copy.deepcopy(value)
            if mutation=='missing':bad['distributions'].pop()
            elif mutation=='duplicate':bad['distributions'][1]=bad['distributions'][0]
            elif mutation=='external':bad['distributions'][0]['dist_info']='host/x.dist-info'
            elif mutation=='interpreter':bad['interpreter']['architecture']='x86_64'
            else:bad['pip_check_event']['argv'][-1]='list'
            with self.subTest(mutation=mutation),self.assertRaises(m.Rejected):self.validate(1,bad)
        self.e['files']['Voice/python/extra.dist-info']={'path':'Voice/python/extra.dist-info','kind':'directory','mode':493}
        with self.assertRaises(m.Rejected):self.validate(1,value)

    def test_sse_requires_nonempty_real_delta_and_final_done(self):
        raw=b'data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}\n\ndata: [DONE]\n\n'
        self.assertEqual(m._ng_sse(raw),2)
        for bad in (b'data: [DONE]\n\n',raw.replace(b'Hi',b''),raw.replace(b'[DONE]',b'broken'),raw+b'extra',
                    raw.replace(b'"index":0',b'"index":false')):
            with self.assertRaises(m.Rejected):m._ng_sse(bad)

    def test_positive_live_cancel_subsequent_eof_and_shutdown_are_distinct(self):
        cases = {name:self.request_for(i) for i,name in enumerate(('cancel','after_cancel','eof','shutdown'),1)}
        self.e['case_requests']=cases;self.e['case_event_ids']={};self.e['case_producer_event_artifacts']={}
        audio={**self.audio,'id':cases['after_cancel']['id'],'turn':cases['after_cancel']['turn']}
        wav=self.artifact('outputs/'+audio['file'],self.wav(),'wav')
        outputs=[self.hello,{'protocol':1,'event':'cancelled'},audio]
        inputs=[cases['cancel'],{'protocol':1,'type':'cancel'},cases['after_cancel']]
        shared=self.event('shared-cancel',b''.join(m.canonical(x) for x in outputs))
        values={}
        for name in cases:
            if name in ('cancel','after_cancel'):
                event=shared;used_inputs=inputs;used_outputs=outputs
                order=[('output',outputs[0]),('input',inputs[0]),('input',inputs[1]),
                       ('output',outputs[1]),('input',inputs[2]),('output',outputs[2])]
                completed=wav
            else:
                control={'event':'stdin_eof'} if name=='eof' else {'protocol':1,'type':'shutdown'}
                event=self.event(name,m.canonical(self.hello));used_inputs=[cases[name],control];used_outputs=[self.hello]
                order=[('output',self.hello),('input',cases[name]),('input',control)];completed=None
            self.e['case_event_ids'][name]=[event['id'],name+'-observer']
            facts={'case':name,'request':cases[name],'inputs':used_inputs,'outputs':used_outputs,
                   'render_started_before_control':True,'remaining_output_paths':[],'remaining_session_state':[],
                   'completed_audio':completed,'process_events':[event],
                   'timeline':[{'direction':d,'message':msg,'monotonic_ns':i+1} for i,(d,msg) in enumerate(order)]}
            ref=self.facts(name+'.facts',facts)
            producer=self.probe_event(name+'-observer',m.canonical(facts))
            self.e['case_producer_event_artifacts'][name]=self.facts(name+'.observer',producer)
            values[name]={'event_ids':[event['id'],producer['id']],'expected_ids':[event['id'],producer['id']],
                          'outcome':self.outcome,'cleanup':self.cleanup,'artifacts':[ref]}
        value={'helper_sha256':self.e['source_identities']['Resources/Voice/bionic_helper.py']['sha256'],
               'cancel_case':values['cancel'],'after_cancel_case':values['after_cancel'],
               'eof_case':values['eof'],'shutdown_case':values['shutdown'],'remaining_output_paths':[]}
        self.validate(5,value)
        bad=copy.deepcopy(value);bad['remaining_output_paths']=['unreported.wav']
        with self.assertRaises(m.Rejected):self.validate(5,bad)
        ref=value['cancel_case']['artifacts'][0]
        facts=m.strict_json(self.artifacts[ref['path']]);facts['outputs'][2]['id']=cases['cancel']['id']
        value['cancel_case']['artifacts'][0]=self.facts(ref['path'],facts)
        with self.assertRaises(m.Rejected):self.validate(5,value)

    def test_positive_import_checks_origins_profile_and_true_errno_denials(self):
        self.e['import_versions']={'kokoro':'0.9.4','misaki':'0.9.4','torch':'2.14.1','numpy':'2.4.6',
                                   'spacy':'3.8.16','en_core_web_sm':'3.8.0'}
        imports=[{'name':name,'version':version,'origin':self.file('Voice/python/site-packages/'+name+'/__init__.py')}
                 for name,version in self.e['import_versions'].items()]
        data=[{'role':role,**self.file('Voice/python/site-packages/'+role+'/data')} for role in ('espeak_data','phonemizer_data')]
        denials=[{'operation':op,'errno':13,'event_id':'deny-'+op,'target':'/fixture/forbidden'} for op in ('network','read','write')]
        self.e.update(imports=imports,package_data=data,denial_cases=denials,voice_environment=self.environment)
        value={'interpreter':self.e['interpreter'],'profile_sha256':self.e['source_identities']['Resources/Voice/voice.sb']['sha256'],
               'environment_artifact':self.facts('import.env',self.environment),
               'initial_private_closure':{'home':[],'tmpdir':[],'caches':[]},'imports':imports,'package_data':data,'denial_cases':denials}
        self.raw_subset(value,('interpreter','profile_sha256','initial_private_closure','imports','package_data','denial_cases'),product_profile=True)
        self.validate(3,value)
        for field,bad_value in [('profile_sha256','0'*64),('initial_private_closure',{'home':['cache'],'tmpdir':[],'caches':[]}),
                                ('denial_cases',[{**denials[0],'errno':60}]+denials[1:]),
                                ('imports',[{**imports[0],'version':'stub'}]+imports[1:])]:
            bad=copy.deepcopy(value);bad[field]=bad_value
            with self.subTest(field=field),self.assertRaises(m.Rejected):self.validate(3,bad)

    def test_positive_static_semantics_and_mutation_matrix(self):
        value,self.e,self.artifacts=real_static_fixture()
        self.validate(2,value)
        for mutation in ('arch','os','signer','rpath','edge','missing-edge','metadata'):
            bad=copy.deepcopy(value)
            if mutation=='arch':bad['native_objects'][0]['architectures']=['x86_64']
            elif mutation=='os':bad['native_objects'][0]['minimum_os']='99.0'
            elif mutation=='signer':bad['native_objects'][0]['signature']['team_id']='OTHER'
            elif mutation=='rpath':bad['native_objects'][0]['rpaths']=['/Users/host/lib']
            elif mutation=='edge':bad['resolved_edges'][0]['target']='/Users/host/evil.dylib'
            elif mutation=='missing-edge':bad['resolved_edges']=[]
            else:bad['metadata_empty_after'][0]['attributes']=['com.apple.ResourceFork']
            with self.subTest(mutation=mutation),self.assertRaises(m.Rejected):self.validate(2,bad)

    def test_probe_echo_prefix_and_unbound_case_facts_are_rejected(self):
        event=self.probe_event('probe',b'{}\n')
        event['argv']=['/bin/echo']+event['argv']
        self.e['events']['probe']['argv']=event['argv'];self.e['probe_argv']['voice_probe']=event['argv']
        with self.assertRaises(m.Rejected):m._ng_event(event,self.e,self.artifacts,'voice_probe')
        # The observer event's output is empty; a separate facts sidecar cannot
        # turn it into genuine listener observations, even with reviewed pins.
        event=self.probe_event('listener-producer',b'')
        self.e['events'][event['id']]['role']='splash_probe'
        self.e['probe_sources']['splash_probe']=event['source']['path']
        self.e['probe_argv']['splash_probe']=event['argv']
        self.e['case_event_ids']={'splash_listener':[event['id']]}
        self.e['case_producer_event_artifacts']={'splash_listener':self.facts('listener.event',event)}
        case={'event_ids':[event['id']],'expected_ids':[event['id']], 'outcome':self.outcome,'cleanup':self.cleanup,
              'artifacts':[self.facts('listener.facts',{'family':'AF_INET','address':'127.0.0.1'})]}
        with self.assertRaises(m.Rejected):m._ng_case(case,self.e,self.artifacts,'splash_listener')

    def test_exact_expectation_field_map_covers_all_nine_gates(self):
        self.assertEqual(set(m._NATIVE_EXPECTATION_FIELDS),set(m._NATIVE_GATE_IDS))
        for fields in m._NATIVE_EXPECTATION_FIELDS.values():self.assertEqual(len(fields),len(set(fields)))

    def test_positive_immutable_has_all_nine_closures_and_three_owner_rechecks(self):
        models=[{'role':role,'identity':str(i)*64,'file_count':1,'bytes':100} for i,role in enumerate(('target','draft','vision'),1)]
        owner={'schema_version':1,'kind':'independently_verified_complete_models',
               'owner_source':{'path':'model_owner.py','bytes':7,'sha256':m.digest(b'fixture')},'decision_id':'fixture-only',
               'models':models,'before_identity':'a'*64,'after_identity':'a'*64}
        owner_pin=self.facts('owner-model-input.json',owner)
        self.e['model_input_admission']={**owner,'receipt':owner_pin}
        m._ng_model_admission(self.e['model_input_admission'],self.e,self.artifacts)
        metadata=[{'path':p,'nofollow':True,'supported':True,'attributes':[]} for p in self.e['files']]
        value={'gate_closures':[{'gate':gate,'before_identity':'1'*64,'after_identity':'1'*64} for gate in m._NATIVE_GATE_IDS],
               'metadata_empty_before':metadata,'metadata_empty_after':metadata,
               'external_input_rechecks':[{'role':model['role'],'owner_receipt':owner_pin,
                   'before_identity':model['identity'],'after_identity':model['identity']} for model in models]}
        self.raw_subset(value,m._NATIVE_GATE_FIELDS[8]);self.validate(8,value)
        bad=copy.deepcopy(value);bad['gate_closures'][0]['after_identity']='0'*64
        with self.assertRaises(m.Rejected):self.validate(8,bad)
        bad=copy.deepcopy(value);bad['external_input_rechecks'][1]['after_identity']='f'*64
        with self.assertRaises(m.Rejected):self.validate(8,bad)

    def test_urlsession_requires_source_bound_compiler_build_provenance(self):
        source={'path':'Tests/Native/urlsession.swift','bytes':7,'sha256':m.digest(b'fixture')}
        binary={'path':'Tests/Native/urlsession','bytes':6,'sha256':m.digest(b'binary')}
        for item in (source,binary):self.e['source_identities'][item['path']]={k:item[k] for k in ('bytes','sha256')}
        build={'schema_version':1,'kind':'observed_native_urlsession_harness_build','source':source,'binary':binary,
               'compiler':{'path':'/usr/bin/swiftc','bytes':7,'sha256':m.digest(b'swiftc!'),'uid':0,'mode':493},
               'sdk':{'path':'/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk','version':'26.4','identity':'a'*64},
               'target':'arm64-apple-macos26.4','argv':['/usr/bin/swiftc','-sdk',
                   '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk','-target','arm64-apple-macos26.4',
                   '-o','/fixture/source/'+binary['path'],'/fixture/source/'+source['path']],
               'environment_artifact':self.facts('build.env',self.environment),
               'stdout':self.artifact('build.stdout',b'','stdout'),'stderr':self.artifact('build.stderr',b'','stderr'),
               'outcome':self.outcome,'cleanup':self.cleanup,'duration_ms':50,'started':'fixture-start','ended':'fixture-end',
               'source_before_sha256':source['sha256'],'source_after_sha256':source['sha256'],'binary_absent_before':True,
               'compiler_started_monotonic_ns':1,'binary_created_monotonic_ns':2,'compiler_exited_monotonic_ns':3}
        build_pin=self.facts('build.facts',build)
        producer=self.probe_event('build-observer',m.canonical(build))
        self.e['events'][producer['id']]['role']='urlsession_builder'
        self.e['probe_sources']['urlsession_builder']=producer['source']['path']
        self.e['probe_argv']['urlsession_builder']=producer['argv']
        self.e['urlsession_harness']={'source':source,'binary':binary,'build_artifact':build_pin,
                                     'build_event_artifact':self.facts('build.event',producer)}
        m._ng_urlsession_build(self.e,self.artifacts)
        original=copy.deepcopy(build)
        for field,bad_value in [('binary_absent_before',False),('source_after_sha256','f'*64),
                                ('compiler_started_monotonic_ns',3),('argv',['/bin/echo','pretend'])]:
            bad=copy.deepcopy(original);bad[field]=bad_value
            self.e['urlsession_harness']['build_artifact']=self.facts('build.facts',bad)
            with self.subTest(field=field),self.assertRaises(m.Rejected):m._ng_urlsession_build(self.e,self.artifacts)
        # Two independent source/binary pins without the compiler observation are
        # deliberately insufficient.
        self.e['urlsession_harness']={'source':source,'binary':binary}
        with self.assertRaises(m.Rejected):m._ng_urlsession_build(self.e,self.artifacts)

    def test_tls_missing_source_cannot_be_replaced_by_arbitrary_hash(self):
        self.e['probe_sources']={'urlsession_probe':'missing.swift'}
        with self.assertRaises(m.Rejected) as caught:
            m._ng_tls_cases({'positive':{},'reconnect':{},'wrong_pin':{}},self.e,self.artifacts)
        self.assertEqual(caught.exception.code,m.MISSING)

    def test_relocation_requires_all_path_classes_and_160_byte_overflow(self):
        value={key:None for key in m._NATIVE_GATE_FIELDS[7]}
        for path in ('normal','space only','space, ascii'):
            value['relative_test_path']=path
            with self.assertRaises(m.Rejected):self.validate(7,value)
        value['relative_test_path']='space, ü'
        self.e['relocation_relative_path']='space, ü';value['espeak_absolute_path_utf8_bytes']=160
        with self.assertRaises(m.Rejected):self.validate(7,value)



def native_change_fixture(rewrite=False):
    context,rows,inventory,events,artifacts = synthetic_case()
    context.bounds = NativeBoundaryMockTests().bounds()
    context.budget = m.Budget(context.bounds)
    pre = m._parse_native_static_evidence(context,rows,inventory,events,artifacts)['parsed_static_facts']
    post = copy.deepcopy(pre)
    final_rows = copy.deepcopy(rows)
    final_rows[1]['bytes']=5; final_rows[1]['sha256']='f'*64
    post['native_objects'][0]['bytes']=5; post['native_objects'][0]['sha256']='f'*64
    post['native_objects'][0]['signature']['cdhash']='2'*40
    transform = {'path':'engine','before':rows[1],'after':final_rows[1],
                 'operation':'rewrite_macho_load_commands' if rewrite else 'resign_macho','reason':'Reviewed personal signing change'}
    changes = []
    if rewrite:
        post['native_objects'][0]['load_commands'][1]['name']='/usr/lib/changed.dylib'
        post['resolved_edges'][0]['install_name']='/usr/lib/changed.dylib'
        post['resolved_edges'][0]['target']='/usr/lib/changed.dylib'
        changes = [{'path':'engine','load_command_changes':[{'index':1,
            'before':pre['native_objects'][0]['load_commands'][1],
            'after':post['native_objects'][0]['load_commands'][1],'reason':'Reviewed dylib relocation'}],
            'edge_changes':[{'context':'engine','index':1,'before':pre['resolved_edges'][0],
                             'after':post['resolved_edges'][0],'reason':'Same reviewed dylib relocation'}]}]
    return [context,rows,final_rows,[transform],pre,post,changes]


class ChangeSemanticsTests(unittest.TestCase):
    def test_signature_only_resign(self):
        result = m._validate_native_change_semantics(*native_change_fixture())
        self.assertEqual(result,{'native_paths':['engine'],'rewrite_paths':[]})

    def test_exact_rewrite_and_edge_annotations(self):
        self.assertEqual(m._validate_native_change_semantics(*native_change_fixture(True))['rewrite_paths'],['engine'])

    def test_resign_cannot_change_rpath_version_or_load_command(self):
        for field,value in (('rpaths',['@loader_path']),('minimum_os','15.0'),('architectures',['x86_64'])):
            case = native_change_fixture(); case[5]['native_objects'][0][field]=value
            with self.subTest(field=field),self.assertRaises(m.Rejected):
                m._validate_native_change_semantics(*case)
        case=native_change_fixture(); case[5]['native_objects'][0]['load_commands'][1]['name']='/usr/lib/other.dylib'
        with self.assertRaises(m.Rejected): m._validate_native_change_semantics(*case)

    def test_missing_extra_mutated_annotations_and_wrong_row_pin(self):
        for mutation in ('missing','extra','noop','edge_missing','edge_wrong','pin','reason'):
            case = native_change_fixture(True)
            if mutation=='missing': case[6]=[]
            elif mutation=='extra': case[6].append(copy.deepcopy(case[6][0]))
            elif mutation=='noop': case[6][0]['load_command_changes'][0]['before']=case[6][0]['load_command_changes'][0]['after']
            elif mutation=='edge_missing': case[6][0]['edge_changes']=[]
            elif mutation=='edge_wrong': case[6][0]['edge_changes'][0]['index']=0
            elif mutation=='pin': case[5]['native_objects'][0]['sha256']='0'*64
            else: case[6][0]['load_command_changes'][0]['reason']=''
            with self.subTest(mutation=mutation),self.assertRaises(m.Rejected):
                m._validate_native_change_semantics(*case)

    def test_native_object_addition_and_noop_transform_rejected(self):
        case=native_change_fixture(); case[5]['native_objects']=[]
        with self.assertRaises(m.Rejected): m._validate_native_change_semantics(*case)
        case=native_change_fixture(); case[2]=copy.deepcopy(case[1]); case[5]=copy.deepcopy(case[4])
        with self.assertRaises(m.Rejected): m._validate_native_change_semantics(*case)

    def test_only_code_signature_command_may_change_on_resign(self):
        case=native_change_fixture()
        case[4]['native_objects'][0]['load_commands'].append({'cmd':'LC_CODE_SIGNATURE','fields':['cmdsize 16','dataoff 100','datasize 200']})
        case[5]['native_objects'][0]['load_commands'].append({'cmd':'LC_CODE_SIGNATURE','fields':['cmdsize 16','dataoff 100','datasize 300']})
        m._validate_native_change_semantics(*case)



# END NATIVE COMPOSITION TESTS

# BEGIN COMPLETE GATE FIXTURES
class Capture(NativeGateSemanticFragmentTests):
    def setUp(self):
        super().setUp();self.captured={}
    def validate(self,gate,value):
        result=super().validate(gate,value)
        if gate not in self.captured:
            self.captured[gate]=copy.deepcopy((value,self.e,self.artifacts))
        return result


def captured_fixture(index):
    methods={0:'test_historical_requires_exact_real_mode_and_chain',
             1:'test_distribution_lock_requires_all_92_and_contained_metadata',
             2:'test_positive_static_semantics_and_mutation_matrix',
             3:'test_positive_import_checks_origins_profile_and_true_errno_denials',
             4:'test_synthesis_recomputes_real_helper_protocol_and_wav',
             5:'test_positive_live_cancel_subsequent_eof_and_shutdown_are_distinct',
             8:'test_positive_immutable_has_all_nine_closures_and_three_owner_rechecks'}
    if index==2:return real_static_fixture()
    f=_complete_types.Capture();f.setUp();getattr(f,methods[index])()
    return f.captured[index]


_STATIC_SUPPORT=None

def static_support():
    return types.SimpleNamespace(m=m,synthetic_case=synthetic_case)


def real_static_fixture():
    support=static_support()
    context,rows,inventory,events,artifacts=support.synthetic_case()
    parsed=support.m._parse_native_static_evidence(context,rows,inventory,events,artifacts)
    base=NativeGateSemanticFragmentTests();base.setUp()
    expected=copy.deepcopy(base.e)
    expected['files']={row['path']:row for row in rows}
    expected['source_identities'].update(context.sources)
    expected.update(parsed)
    expected['native_inventory']=inventory
    expected['resolved_edges']=parsed['parsed_static_facts']['resolved_edges']
    expected['payload_root']='/synthetic/payload'
    expected['pre_sign_inventory']=copy.deepcopy(inventory);expected['native_changes']=[]
    raw=m.canonical(events);name='pre-sign-tools.facts';artifacts[name]=raw
    expected['pre_sign_tool_events_artifact']={'path':name,'kind':'canonical_facts','bytes':len(raw),'sha256':m.digest(raw)}
    metadata=[{'path':row['path'],'nofollow':True,'supported':True,'attributes':[]} for row in rows]
    value={**parsed['parsed_static_facts'],'tool_events':events,
           'metadata_empty_before':metadata,'metadata_empty_after':metadata}
    return copy.deepcopy((value,expected,artifacts))


def distribution_fixture():
    fixture=NativeGateSemanticFragmentTests();fixture.setUp()
    versions={'kokoro':'0.9.4','misaki':'0.9.4','torch':'2.14.1','numpy':'2.4.6','spacy':'3.8.16','en-core-web-sm':'3.8.0'}
    versions.update({'synthetic-package-%03d'%n:'1.0' for n in range(86)})
    distributions=[];origins=[];root='Voice/python/lib/python3.11/site-packages'
    for name,version in sorted(versions.items()):
        path=root+'/'+name.replace('-','_')+'-'+version+'.dist-info'
        metadata=fixture.file(path+'/METADATA',('Name: '+name+'\nVersion: '+version+'\n').encode())
        fixture.e['files'][path]={'path':path,'kind':'directory','mode':493}
        distributions.append({'name':name,'version':version,'dist_info':path,'metadata':metadata})
        origins.append({'name':name,'root':root,'metadata_paths':[metadata]})
    fixture.e['files'][root]={'path':root,'kind':'directory','mode':493}
    fixture.e['locked_distributions']=[{'name':row['name'],'version':row['version']} for row in distributions]
    fixture.e['bootstrap_exceptions']=[];fixture.e['package_origins']=origins;fixture.e['sys_path']=[root]
    value={'interpreter':fixture.e['interpreter'],'distributions':distributions,'bootstrap_exceptions':[],
           'package_origins':origins,'sys_path':[root],
           'pip_check_event':fixture.event('pip',b'No broken requirements found.\n','pip_check')}
    fixture.raw_subset(value,('interpreter','distributions','bootstrap_exceptions','package_origins','sys_path'))
    return copy.deepcopy((value,fixture.e,fixture.artifacts))


class SplashFixture(NativeGateSemanticFragmentTests):
    def build(self):
        self.setUp()
        splash_python=self.file('Splash/python/bin/python3',b'synthetic-splash-python')
        for path in ('Splash','Splash/python','Splash/python/bin'):
            self.e['files'][path]={'path':path,'kind':'directory','mode':493}
        self.e['case_event_ids']={};self.e['case_producer_event_artifacts']={}
        self.e['probe_sources']={};self.e['probe_argv']={}
        self.e['tls_certificate_sha256']='f'*64
        # Complete owner-model receipt is a separately pinned canonical artifact.
        immutable=captured_fixture(8)
        self.e['model_input_admission']=copy.deepcopy(immutable[1]['model_input_admission'])
        ref=self.e['model_input_admission']['receipt'];self.artifacts[ref['path']]=immutable[2][ref['path']]
        pins=[self.file(path,b'synthetic-v2-source') for path in
              ('Splash/install/launcher.py','Splash/server/serve_options.py','Splash/server/server.py')]
        pins.extend({'path':path,**self.e['source_identities'][path]} for path in
                    ('Resources/Runtime/dot_runtime.py','Resources/Runtime/dot_process.py','Resources/Runtime/dot_tls.py'))
        self.e['splash_source_pins']=pins
        self.make_harness_build()
        def make_case(name,facts,role='splash_probe'):
            raw=m.canonical(facts)
            if role=='splash_probe':
                source_path='Tests/Native/synthetic_splash_observer.py'
                source={'path':source_path,'bytes':9,'sha256':m.digest(b'observer!')}
                target=splash_python
                argv=['/fixture/runtime/'+target['path'],'-I','-B','/fixture/source/'+source_path]
            else:
                source=self.e['urlsession_harness']['source'];target=self.e['urlsession_harness']['binary']
                argv=['/fixture/source/'+target['path']]
            self.e['source_identities'][source['path']]={key:source[key] for key in ('bytes','sha256')}
            self.e['probe_sources'][role]=source['path'];self.e['probe_argv'][role]=argv
            event=self.make_event(name+'-observer',role,source,target,argv,raw)
            self.e['case_event_ids'][name]=[event['id']]
            self.e['case_producer_event_artifacts'][name]=self.facts(name+'.event',event)
            return {'event_ids':[event['id']],'expected_ids':[event['id']],
                    'outcome':copy.deepcopy(self.outcome),'cleanup':copy.deepcopy(self.cleanup),
                    'artifacts':[self.facts(name+'.facts',facts)]}
        listener=make_case('splash_listener',{
            'family':'AF_INET','address':'127.0.0.1','owned_before_spawn':True,'listener_fd':10,'adopted_fd':10,
            'listener_identity_before':{'device':1,'inode':2,'port':40000},
            'listener_identity_after':{'device':1,'inode':2,'port':40000},
            'health':{'authenticated':True,'http_status':200,'response_bytes':2},
            'status':{'authenticated':True,'http_status':200,'response_bytes':20}})
        credential=make_case('splash_credential',{
            'argv_key_occurrences':0,'environment_key_occurrences':0,'file_key_occurrences':0,
            'pipe_bytes':65,'pipe_reads':1,'pipe_eof':True,'pipe_closed':True,'second_read_bytes':0,'key_remaining':False})
        stream=b'data: {"choices":[{"index":0,"delta":{"content":"Synthetic fixture"},"finish_reason":null}]}\n\ndata: [DONE]\n\n'
        inference=make_case('splash_inference',{'authenticated':True,'http_status':200,
            'stream':self.artifact('inference.stream',stream,'stdout'),'nonempty_characters':17,'done':True})
        tls={}
        for name in ('positive','reconnect','wrong_pin'):
            wrong=name=='wrong_pin'
            facts={'case':name,'harness_source':self.e['urlsession_harness']['source'],
                'peer_certificate_sha256':'f'*64,'expected_pin_sha256':('e' if wrong else 'f')*64,
                'certificate_observed':True,'failure_stage':'certificate_pin' if wrong else None,
                'application_bytes_sent':0 if wrong else 20,'application_bytes_received':0 if wrong else 50,
                'connection_index':2 if name=='reconnect' else 1}
            tls[name]=make_case('tls_'+name,facts,'urlsession_probe')
        cleanup={name:make_case('splash_'+name,{
            'case':name,'control_observed':True,'remaining_owned_descendants':0,
            'remaining_key_bytes':0,'remaining_state_paths':[]}) for name in ('eof','cancel','startup_failure')}
        value={'source_pins':pins,'profile_sha256':self.e['source_identities']['Resources/Runtime/splash.sb']['sha256'],
               'model_input_admission':copy.deepcopy(self.e['model_input_admission']),
               'listener_case':listener,'credential_case':credential,'inference_case':inference,
               'tls_cases':tls,'cleanup_cases':cleanup}
        return copy.deepcopy((value,self.e,self.artifacts))

    def make_event(self,event_id,role,source,target,argv,stdout):
        self.e['events'][event_id]={'role':role,'source':source,'target':target,'argv':argv,
                                   'environment':copy.deepcopy(self.environment)}
        return {'id':event_id,'argv':argv,'source':source,'target':target,
            'environment_artifact':self.facts(event_id+'.env',self.environment),
            'stdout':self.artifact(event_id+'.stdout',stdout,'stdout'),
            'stderr':self.artifact(event_id+'.stderr',b'','stderr'),
            'outcome':copy.deepcopy(self.outcome),'cleanup':copy.deepcopy(self.cleanup),
            'duration_ms':100,'started':'synthetic-start','ended':'synthetic-end'}

    def make_harness_build(self):
        source={'path':'Tests/Native/synthetic_urlsession.swift','bytes':7,'sha256':m.digest(b'fixture')}
        binary={'path':'Tests/Native/synthetic_urlsession','bytes':6,'sha256':m.digest(b'binary')}
        for item in (source,binary):self.e['source_identities'][item['path']]={k:item[k] for k in ('bytes','sha256')}
        build={'schema_version':1,'kind':'observed_native_urlsession_harness_build','source':source,'binary':binary,
               'compiler':{'path':'/usr/bin/swiftc','bytes':7,'sha256':m.digest(b'swiftc!'),'uid':0,'mode':493},
               'sdk':{'path':'/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk','version':'26.4','identity':'a'*64},
               'target':'arm64-apple-macos26.4','argv':['/usr/bin/swiftc','-sdk',
                   '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk','-target','arm64-apple-macos26.4',
                   '-o','/fixture/source/'+binary['path'],'/fixture/source/'+source['path']],
               'environment_artifact':self.facts('compiler.env',self.environment),
               'stdout':self.artifact('compiler.stdout',b'','stdout'),'stderr':self.artifact('compiler.stderr',b'','stderr'),
               'outcome':copy.deepcopy(self.outcome),'cleanup':copy.deepcopy(self.cleanup),
               'duration_ms':50,'started':'fixture-start','ended':'fixture-end',
               'source_before_sha256':source['sha256'],'source_after_sha256':source['sha256'],
               'binary_absent_before':True,'compiler_started_monotonic_ns':1,
               'binary_created_monotonic_ns':2,'compiler_exited_monotonic_ns':3}
        builder_path='Tests/Native/synthetic_build_observer.py'
        builder={'path':builder_path,'bytes':9,'sha256':m.digest(b'observer!')}
        self.e['source_identities'][builder_path]={k:builder[k] for k in ('bytes','sha256')}
        target={k:self.e['files']['Voice/python/bin/python3'][k] for k in ('path','bytes','sha256')}
        argv=['/fixture/runtime/'+target['path'],'-I','-B','/fixture/source/'+builder_path]
        self.e['probe_sources']['urlsession_builder']=builder_path;self.e['probe_argv']['urlsession_builder']=argv
        event=self.make_event('compiler-observer','urlsession_builder',builder,target,argv,m.canonical(build))
        self.e['urlsession_harness']={'source':source,'binary':binary,'build_artifact':self.facts('compiler.facts',build),
                                     'build_event_artifact':self.facts('compiler.event',event)}


def rewrite_synthetic_fixture(snapshot, namespace, *, payload_root=None, source_root=None, files=None, sources=None, signed_identity=None):
    """Rebuild ONLY synthetic fixture artifacts with a coherent context.

    This is test data construction, not migration or relabeling of real receipts.
    Every nested raw artifact is rebuilt before its enclosing pins are produced.
    """
    value,expected,old_artifacts=copy.deepcopy(snapshot)
    new_artifacts={};resolved={};active=set()
    new_root=payload_root or expected['payload_root']
    old_root=expected['payload_root']
    old_source=expected['source_root'];new_source=source_root or old_source
    metadata=None if files is None else [
        {'path':path,'nofollow':True,'supported':True,'attributes':[]} for path in sorted(files)]
    def rebuild_raw(raw):
        try:
            parsed=m.strict_json(raw)
        except m.Rejected:
            lines=raw.splitlines()
            if lines and raw.endswith(b'\n'):
                try: parsed_lines=[m.strict_json(line) for line in lines]
                except m.Rejected: return raw
                return b''.join(m.canonical(walk(item)) for item in parsed_lines)
            return raw
        return m.canonical(walk(parsed))
    def artifact(reference):
        old=reference['path']
        if old in resolved:
            prior=resolved[old]
            if prior['kind'] != reference['kind']:raise AssertionError('synthetic artifact kind collision')
            return copy.deepcopy(prior)
        if old in active:raise AssertionError('synthetic artifact hash cycle')
        active.add(old)
        raw=old_artifacts[old]
        if len(raw)!=reference['bytes'] or m.digest(raw)!=reference['sha256']:
            raise AssertionError('input synthetic artifact pin mismatch')
        raw=rebuild_raw(raw) if reference['kind']!='wav' else raw
        name=namespace+'/'+old
        pin={'path':name,'kind':reference['kind'],'bytes':len(raw),'sha256':m.digest(raw)}
        new_artifacts[name]=raw;resolved[old]=pin;active.remove(old)
        return copy.deepcopy(pin)
    def walk(item):
        if type(item) is dict:
            if set(item)=={'path','kind','bytes','sha256'} and item['kind'] in ('receipt','stdout','stderr','canonical_facts','wav'):
                return artifact(item)
            if set(item)=={'path','bytes','sha256'} and sources is not None and item['path'] in sources:
                return {'path':item['path'],**copy.deepcopy(sources[item['path']])}
            result={key:walk(val) for key,val in item.items()}
            if 'started' in result and 'ended' in result:
                result['started']='2026-10-14T12:00:00+00:00'
                result['ended']='2026-10-14T12:00:01+00:00'
            if sources is not None:
                if 'helper_sha256' in result:
                    result['helper_sha256']=sources['Resources/Voice/bionic_helper.py']['sha256']
                if 'profile_sha256' in result:
                    profile='Resources/Runtime/splash.sb' if 'source_pins' in result else 'Resources/Voice/voice.sb'
                    result['profile_sha256']=sources[profile]['sha256']
                if result.get('kind')=='observed_native_urlsession_harness_build':
                    result['source_before_sha256']=result['source_after_sha256']=result['source']['sha256']
            if metadata is not None:
                for key in ('metadata_empty_before','metadata_empty_after'):
                    if key in result:result[key]=copy.deepcopy(metadata)
            if signed_identity is not None and set(result)=={'gate','before_identity','after_identity'}:
                result['before_identity']=result['after_identity']=signed_identity
            return result
        if type(item) is list:return [walk(value) for value in item]
        if type(item) is str:return item.replace(old_root,new_root).replace(old_source,new_source)
        return item
    value=walk(value);expected=walk(expected)
    if files is not None:expected['files']=copy.deepcopy(files)
    if sources is not None:expected['source_identities']=copy.deepcopy(sources)
    if signed_identity is not None:expected['signed_identity']=signed_identity
    expected['payload_root']=new_root;expected['source_root']=new_source
    return value,expected,new_artifacts


def build_complete_synthetic_gates(*, source_identities=None, static_snapshot=None, payload_root=None, source_root=None):
    """Return all nine coherent gate observations/contexts and retained bytes.

    Caller may provide the exact source map of its isolated synthetic Context.
    Native gate validators are never mocked. Static raw-parser output remains a
    separate explicit fixture boundary owned by the static verifier tests.
    """
    snapshots={index:captured_fixture(index) for index in (0,1,2,3,4,5,8)}
    snapshots[1]=distribution_fixture()
    snapshots[6]=_complete_types.SplashFixture().build()
    if static_snapshot is not None:snapshots[2]=copy.deepcopy(static_snapshot)
    files={};sources={}
    for _,expected,_ in snapshots.values():
        for path,row in expected['files'].items():
            if path in files and files[path]!=row:raise AssertionError('synthetic closure conflict: '+path)
            files[path]=copy.deepcopy(row)
        for path,pin in expected['source_identities'].items():
            if path in sources and sources[path]!=pin:raise AssertionError('synthetic source conflict: '+path)
            sources[path]=copy.deepcopy(pin)
    # Complete physical directory closure is common to every gate.
    files['.']={'path':'.','kind':'directory','mode':493}
    for path in list(files):
        parts=path.split('/')[:-1]
        for count in range(1,len(parts)+1):
            name='/'.join(parts[:count]);files.setdefault(name,{'path':name,'kind':'directory','mode':493})
    owner=snapshots[6][1]['model_input_admission']['owner_source']
    sources[owner['path']]={key:owner[key] for key in ('bytes','sha256')}
    lock={'schema_version':1,'kind':'complete_voice_wheel_lock',
          'target':{'implementation':'cpython','python':'3.11.17','platform':'macos-arm64'},
          'wheels':copy.deepcopy(snapshots[1][1]['locked_distributions'])}
    lock_raw=m.canonical(lock);lock_path='packaging/voice/complete-voice-lock.json'
    sources[lock_path]={'bytes':len(lock_raw),'sha256':m.digest(lock_raw)}
    if source_identities is not None:
        missing=set(sources)-set(source_identities)
        if missing:raise AssertionError('synthetic native Context sources missing: '+str(sorted(missing)))
        sources=copy.deepcopy(source_identities)
    rows=sorted(files.values(),key=lambda row:row['path'].encode('utf-8'))
    signed=m.digest(m.canonical({'kind':'runtime_final_signed_closure_v1','closure':rows}))
    gates={};contexts={};artifacts={}
    for index,snapshot in snapshots.items():
        value,expected,raw=rewrite_synthetic_fixture(snapshot,'gate-%d'%index,payload_root=payload_root or '/fixture/runtime',source_root=source_root,
                                                     files=files,sources=sources,signed_identity=signed)
        gates[m._NATIVE_GATE_IDS[index]]=value;contexts[m._NATIVE_GATE_IDS[index]]=expected
        artifacts.update(raw)
    # Splash and immutable must share the exact same independently pinned owner
    # model artifact. Rebuild immutable before its source-producer pins are set.
    splash_model=contexts[m._NATIVE_GATE_IDS[6]]['model_input_admission']
    immutable_name=m._NATIVE_GATE_IDS[8]
    immutable_snapshot=(gates[immutable_name],contexts[immutable_name],artifacts)
    old_owner=immutable_snapshot[1]['model_input_admission']['receipt']
    new_owner=splash_model['receipt']
    # Keep owner path stable before rebuilding the immutable report graph.
    raw_owner=artifacts[new_owner['path']]
    for row in immutable_snapshot[0]['external_input_rechecks']:row['owner_receipt']=copy.deepcopy(new_owner)
    immutable_snapshot[1]['model_input_admission']=copy.deepcopy(splash_model)
    # Rather than mutate already-pinned observer stdout, regenerate only this
    # fixture's immutable subset and observer event from its updated value.
    e=immutable_snapshot[1];v=immutable_snapshot[0]
    old_event_ref=e['facts_event_artifact']
    event=m.strict_json(artifacts[old_event_ref['path']])
    facts_raw=m.canonical(v)
    def put(path,kind,raw):
        artifacts[path]=raw;return {'path':path,'kind':kind,'bytes':len(raw),'sha256':m.digest(raw)}
    e['facts_artifact']=put(e['facts_artifact']['path'],'canonical_facts',facts_raw)
    event['stdout']=put(event['stdout']['path'],'stdout',facts_raw)
    e['facts_event_artifact']=put(old_event_ref['path'],'canonical_facts',m.canonical(event))
    # Exercise the exact same signed rows at one fresh difficult relocation root.
    relative_path='Relocated path, ü/'+'x'*120
    relocated_root='/fixture/'+relative_path
    relocated={};relocated_refs=[]
    for index in (4,5,6):
        gate=m._NATIVE_GATE_IDS[index]
        snapshot=(gates[gate],contexts[gate],artifacts)
        value,expected,raw=rewrite_synthetic_fixture(snapshot,'relocated-%d'%index,payload_root=relocated_root,
                                                     files=files,sources=sources,signed_identity=signed)
        relocated[gate]=expected;artifacts.update(raw)
        report={'gate':gate,'payload_root':relocated_root,'before_identity':signed,'after_identity':signed,
                'observations':value}
        name='relocated-%d/report.facts'%index
        relocated_refs.append(put(name,'canonical_facts',m.canonical(report)))
    gate=m._NATIVE_GATE_IDS[7]
    espeak=relocated_root+'/Voice/python/lib/python3.11/site-packages/espeakng_loader/espeak-ng-data'
    gates[gate]={'relative_test_path':relative_path,'espeak_absolute_path_utf8_bytes':len(espeak.encode('utf-8')),
                 'relocated_signed_identity':signed,'empty_private_roots':{'home':[],'tmpdir':[],'caches':[]},
                 'voice_case_artifacts':relocated_refs[:2],'splash_case_artifacts':relocated_refs[2:],
                 'before_identity':signed,'after_identity':signed}
    contexts[gate]={'files':files,'source_identities':sources,'signed_identity':signed,
                   'relocation_relative_path':relative_path,'relocated_payload_root':relocated_root,
                   'relocated_espeak_path':espeak,'relocated_contract':{},'relocated_expected':relocated}
    # Remove deliberately superseded synthetic artifacts, so the returned map
    # is the exact reachable declared evidence graph rather than a scratch bag.
    used=set()
    def collect(item):
        if type(item) is dict:
            if set(item)=={'path','kind','bytes','sha256'} and item['kind'] in ('receipt','stdout','stderr','canonical_facts','wav'):
                path=item['path']
                if path in used:return
                used.add(path)
                if item['kind']!='wav':
                    try: parsed=m.strict_json(artifacts[path])
                    except m.Rejected: pass
                    else: collect(parsed)
            else:
                for val in item.values():collect(val)
        elif type(item) is list:
            for val in item:collect(val)
    collect(gates);collect(contexts)
    artifacts={path:raw for path,raw in artifacts.items() if path in used}
    return {'gates':gates,'expected_by_gate':contexts,'artifacts':artifacts,'final_rows':rows,
            'source_identities':sources,'signed_identity':signed,'voice_lock':lock,'voice_lock_raw':lock_raw,
            'model_owner_source_bytes':b'fixture'}


def build_probe_contract(fixture):
    def contract(contexts):
        result={}
        for gate,expected in contexts.items():
            values={name:copy.deepcopy(expected[name]) for name in m._NATIVE_EXPECTATION_FIELDS[gate]}
            if gate==m._NATIVE_GATE_IDS[7]:values['relocated_contract']=contract(expected['relocated_expected'])
            result[gate]={'invocations':[{'id':event_id,**copy.deepcopy(invocation)}
                         for event_id,invocation in sorted(expected.get('events',{}).items())], 'expectations':values}
        return {'schema_version':1,'kind':'runtime_native_probe_contract','gates':result}
    return contract(fixture['expected_by_gate'])


def build_native_receipt_bundle(fixture, bindings):
    """Create only synthetic schema-2 headers/bytes for the parent's envelope.

    ``bindings`` must be derived by the parent's isolated synthetic Context.
    No source-owned approval is written, and no genuine provenance is claimed.
    """
    artifacts=copy.deepcopy(fixture['artifacts']);contract=build_probe_contract(fixture)
    full_bindings={**copy.deepcopy(bindings),'probe_contract_identity':m.digest(m.canonical(contract))}
    receipts={};receipt_entries=[]
    static_events=fixture['gates'][m._NATIVE_GATE_IDS[2]]['tool_events']
    def put(path,kind,raw):
        artifacts[path]=raw;return {'path':path,'kind':kind,'bytes':len(raw),'sha256':m.digest(raw)}
    for index,gate in enumerate(m._NATIVE_GATE_IDS):
        expected=fixture['expected_by_gate'][gate];is_static=index in (0,2)
        if is_static:event=next(event for event in static_events if event['role']=='host_arm64')
        else:
            if index in (1,3,8):ref=expected['facts_event_artifact']
            elif index==4:ref=expected['voice_trace_event_artifact']
            elif index==5:ref=expected['case_producer_event_artifacts']['cancel']
            elif index==6:ref=expected['case_producer_event_artifacts']['splash_listener']
            else:ref=expected['relocated_expected'][m._NATIVE_GATE_IDS[4]]['voice_trace_event_artifact']
            event=m._ng_facts(ref,artifacts)
        environment=(put('headers/gate-%d.environment'%index,'canonical_facts',m.canonical(event['environment']))
                     if is_static else copy.deepcopy(event['environment_artifact']))
        receipt={'schema_version':2,'kind':'observed_native_runtime_gate','gate':gate,'bindings':copy.deepcopy(full_bindings),
                 'host':{'os':'macOS','architecture':'arm64','os_version':'26.4','sdk':'26.4','chip':'synthetic-arm64-host'},
                 **{field:copy.deepcopy(event[field]) for field in ('started','ended','duration_ms','outcome','cleanup','argv')},
                 'environment_artifact':environment,'probe_source':copy.deepcopy(event['source']),
                 'outputs':[copy.deepcopy(event['stdout']),copy.deepcopy(event['stderr'])],
                 'before_signed_identity':fixture['signed_identity'],'after_signed_identity':fixture['signed_identity'],
                 'observations':copy.deepcopy(fixture['gates'][gate])}
        receipts[gate]=receipt
        ref=put('receipts/gate-%d.json'%index,'receipt',m.canonical(receipt))
        receipt_entries.append({'gate':gate,**{key:ref[key] for key in ('path','bytes','sha256')}})
    declarations={};visited=set()
    def collect(value):
        if type(value) is list:
            for item in value:collect(item)
        elif type(value) is dict:
            if set(value)=={'path','kind','bytes','sha256'} and value['kind'] in ('receipt','stdout','stderr','canonical_facts','wav'):
                path=value['path'];raw=artifacts[path]
                if len(raw)!=value['bytes'] or m.digest(raw)!=value['sha256']:raise AssertionError('synthetic final artifact mismatch')
                if path in declarations and declarations[path]!=value:raise AssertionError('synthetic declaration collision')
                declarations[path]=copy.deepcopy(value)
                if path not in visited:
                    visited.add(path)
                    try:parsed=m.strict_json(raw)
                    except m.Rejected:pass
                    else:collect(parsed)
            else:
                for item in value.values():collect(item)
    collect(contract);collect(receipts)
    for entry in receipt_entries:
        collect({'path':entry['path'],'kind':'receipt','bytes':entry['bytes'],'sha256':entry['sha256']})
    entries=[declarations[path] for path in sorted(declarations,key=lambda path:path.encode('utf-8'))]
    return {'probe_contract':contract,'receipts':receipts,'receipt_entries':receipt_entries,
            'artifact_entries':entries,'artifacts':{path:artifacts[path] for path in declarations}}


class CompleteGateTests(unittest.TestCase):
    def test_complete_positive_splash_gate(self):
        value,expected,artifacts=_complete_types.SplashFixture().build()
        result=m._validate_native_gate_observations(m._NATIVE_GATE_IDS[6],value,expected=expected,artifacts=artifacts)
        self.assertEqual(result['gate'],m._NATIVE_GATE_IDS[6])
        # Raw artifact bytes contain no key/token value or secret-bearing protocol.
        self.assertFalse(any(b'"api_key"' in raw or b'PRIVATE KEY' in raw for raw in artifacts.values()))

    def test_complete_positive_relocation_and_all_nine_coherent_gates(self):
        fixture=build_complete_synthetic_gates()
        entries=[{'gate':gate} for gate in m._NATIVE_GATE_IDS]
        m._validate_native_gate_set(entries)
        results={}
        for gate in m._NATIVE_GATE_IDS:
            results[gate]=m._validate_native_gate_observations(gate,fixture['gates'][gate],
                expected=fixture['expected_by_gate'][gate],artifacts=fixture['artifacts'])
        self.assertEqual(set(results),set(m._NATIVE_GATE_IDS))
        self.assert_static_replay(fixture)
        self.assertTrue(all(value['signed_identity']==fixture['signed_identity']
                            for value in fixture['expected_by_gate'].values()))
        self.assertTrue(all(value['source_identities']==fixture['source_identities']
                            for value in fixture['expected_by_gate'].values()))
        self.assertEqual(fixture['signed_identity'],m.digest(m.canonical({
            'kind':'runtime_final_signed_closure_v1','closure':fixture['final_rows']})))
        self.assertEqual(len({ref['path'] for ref in fixture['gates'][m._NATIVE_GATE_IDS[7]]['voice_case_artifacts']}),2)

    def test_fixture_can_bind_fresh_synthetic_context_paths_and_source_pins(self):
        prior=build_complete_synthetic_gates()
        sources=copy.deepcopy(prior['source_identities'])
        sources['Resources/Voice/bionic_helper.py']={'bytes':3,'sha256':m.digest(b'new')}
        sources['Resources/Voice/voice.sb']={'bytes':7,'sha256':m.digest(b'profile')}
        fixture=build_complete_synthetic_gates(source_identities=sources,
            payload_root='/another-fixture/runtime',source_root='/another-fixture/source')
        for gate in m._NATIVE_GATE_IDS:
            m._validate_native_gate_observations(gate,fixture['gates'][gate],
                expected=fixture['expected_by_gate'][gate],artifacts=fixture['artifacts'])
        self.assert_static_replay(fixture)

    def assert_static_replay(self,fixture):
        from types import SimpleNamespace
        support=static_support();context=SimpleNamespace(sources=fixture['source_identities'])
        gate=m._NATIVE_GATE_IDS[2];expected=fixture['expected_by_gate'][gate]
        parsed=support.m._parse_native_static_evidence(context,fixture['final_rows'],expected['native_inventory'],
            fixture['gates'][gate]['tool_events'],fixture['artifacts'])
        self.assertEqual(parsed['parsed_static_facts'],expected['parsed_static_facts'])

    def test_all_nine_receipt_headers_match_actual_selected_event_bytes(self):
        fixture=build_complete_synthetic_gates()
        bindings={'basis_identity':'3'*64,'policy_sha256':'7'*64,'source_identities':fixture['source_identities'],
                  'prepared_identity':'2'*64,'signed_identity':fixture['signed_identity']}
        bundle=build_native_receipt_bundle(fixture,bindings)
        self.assertEqual(len(bundle['receipt_entries']),9)
        self.assertEqual(sum(row['kind']=='receipt' for row in bundle['artifact_entries']),9)
        # Exercise the parent's actual header validator with no stub.
        import datetime
        static=fixture['gates'][m._NATIVE_GATE_IDS[2]]['tool_events']
        for gate,receipt in bundle['receipts'].items():
            expected=fixture['expected_by_gate'][gate]
            event,is_static=m._native_receipt_event(gate,expected,static,bundle['artifacts'])
            m._validate_native_receipt_header(receipt,expected,event,is_static,bundle['artifacts'])
        self.assertEqual(set(bundle['artifacts']),{row['path'] for row in bundle['artifact_entries']})

    def test_required_splash_interpreter_resolves_contained_symlink(self):
        snapshot=_complete_types.SplashFixture().build();value,expected,artifacts=snapshot
        path='Splash/python/bin/python3'
        row=expected['files'].pop(path);row['path']='Splash/python/bin/python3.11'
        expected['files'][row['path']]=row
        expected['files'][path]={'path':path,'kind':'symlink','target':'python3.11'}
        self.assertEqual(m._ng_resolve_required_interpreter(expected['files']),row['path'])
        ref=expected['case_producer_event_artifacts']['splash_listener']
        event=m.strict_json(artifacts[ref['path']])
        event['target']={k:row[k] for k in ('path','bytes','sha256')}
        event['argv'][0]='/fixture/runtime/'+row['path']
        expected['events'][event['id']]['target']=copy.deepcopy(event['target'])
        expected['events'][event['id']]['argv']=copy.deepcopy(event['argv'])
        expected['probe_argv']['splash_probe']=copy.deepcopy(event['argv'])
        m._ng_event(event,expected,artifacts,'splash_probe')
        bad=copy.deepcopy(event);bad['target']['path']='Splash/python/bin/arbitrary'
        expected['files'][bad['target']['path']]={**row,'path':bad['target']['path']}
        bad['argv'][0]='/fixture/runtime/'+bad['target']['path']
        expected['events'][bad['id']]['target']=copy.deepcopy(bad['target'])
        expected['events'][bad['id']]['argv']=copy.deepcopy(bad['argv'])
        expected['probe_argv']['splash_probe']=copy.deepcopy(bad['argv'])
        with self.assertRaises(m.Rejected):m._ng_event(bad,expected,artifacts,'splash_probe')
        for target in ('../../../../outside','python3'):
            expected['files'][path]['target']=target
            with self.assertRaises(m.Rejected):m._ng_resolve_required_interpreter(expected['files'])


_complete_types=types.SimpleNamespace(Capture=Capture,SplashFixture=SplashFixture)
del Capture,SplashFixture

# END COMPLETE GATE FIXTURES

# BEGIN COMPOSED ADMISSION TESTS

class NativeCompositionTests(unittest.TestCase):
    def setUp(self):
        self.f=Fixture();self.f.setUp();self.addCleanup(self.f.doCleanups)

    def approval_fixture(self):
        f=self.f; initial=build_complete_synthetic_gates()
        # These are explicitly synthetic source files, never native probes.
        for name in initial['source_identities']:
            if name in (m.POLICY_PATH,'scripts/reconstruct_runtime_payload.py'): continue
            if name=='packaging/voice/complete-voice-lock.json': raw=initial['voice_lock_raw']
            elif (f.source/name).exists(): raw=(f.source/name).read_bytes()
            else: raw=('SYNTHETIC SOURCE ONLY '+name).encode()
            f.policy['source_bindings'][name]=file(f.source/name,raw)
        f.policy['phase_source_paths']['native']=sorted(set(f.policy['phase_source_paths']['prepare'])|set(initial['source_identities']))
        f.policy['overlay']['files']=[]
        rows=copy.deepcopy(initial['final_rows'])
        index={row['path']:row for row in rows}
        for directory in ('Splash','Voice','STT'):
            index.setdefault(directory,{'path':directory,'kind':'directory','mode':493})
            name=directory+'/LICENSE';raw=b'SYNTHETIC TEST NOTICE'
            index[name]={'path':name,'kind':'file','mode':420,'bytes':len(raw),'sha256':m.digest(raw)}
        rows=sorted(index.values(),key=lambda row:row['path'].encode())
        components=[]
        for directory,role in zip(('Splash','Voice','STT'),f.policy['component_roles']):
            components.append({'role':role,'license':'SYNTHETIC ONLY','license_paths':[directory+'/LICENSE'],
                'files':[row['path'] for row in rows if row['path']==directory or row['path'].startswith(directory+'/') or directory=='Voice' and row['path']=='engine']})
        components.sort(key=lambda row:row['role'])
        f.basis['closure']=rows;f.basis['components']=components
        f.policy['speech_asset_pins']=copy.deepcopy(initial['expected_by_gate'][m._NATIVE_GATE_IDS[4]]['voice_model_pins'])
        f.save_policy();context=m.Context(f.source,phase='native')
        static,inventory,parsed,static_raw=synthetic_static_snapshot(context,rows,'engine')
        static_expected=copy.deepcopy(initial['expected_by_gate'][m._NATIVE_GATE_IDS[2]])
        static_expected.update(files=index,native_inventory=inventory,**parsed,resolved_edges=static['resolved_edges'],
                               pre_sign_inventory=inventory,native_changes=[])
        # The complete gate helper constructs a fresh synthetic producer graph.
        snapshot=(static,static_expected,static_raw)
        # Its old pre-sign reference is replaced before graph traversal.
        raw=m.native_canonical(static['tool_events']);name='pre-sign-tools.fixture'
        static_raw[name]=raw
        static_expected['pre_sign_tool_events_artifact']={'path':name,'kind':'canonical_facts','bytes':len(raw),'sha256':m.digest(raw)}
        complete=build_complete_synthetic_gates(source_identities=context.sources,static_snapshot=snapshot,
                                               payload_root=str(f.stage/'payload'),source_root=str(f.source))
        rows=complete['final_rows'];index={row['path']:row for row in rows}
        self.assertEqual(rows,f.basis['closure'])
        # Recompute the root-target pin after final physical closure assembly;
        # this is raw synthetic test-data construction, never receipt relabeling.
        static,inventory,parsed,static_raw=synthetic_static_snapshot(context,rows,'engine')
        complete['gates'][m._NATIVE_GATE_IDS[2]]=static
        expected=complete['expected_by_gate'];artifacts=complete['artifacts'];artifacts.update(static_raw)
        e=expected[m._NATIVE_GATE_IDS[2]]
        e.update(native_inventory=inventory,**parsed,resolved_edges=static['resolved_edges'],pre_sign_inventory=inventory,native_changes=[])
        raw=m.native_canonical(static['tool_events']);name='pre-sign-tools.fixture'
        artifacts[name]=raw;e['pre_sign_tool_events_artifact']={'path':name,'kind':'canonical_facts','bytes':len(raw),'sha256':m.digest(raw)}
        bindings={'basis_identity':m.digest(m.native_canonical(f.basis)),'policy_sha256':context.policy_sha,
                  'source_identities':context.sources,'prepared_identity':m.prepared_identity(context,f.basis,rows),
                  'signed_identity':m.signed_identity(context,rows)}
        historical=complete['gates'][m._NATIVE_GATE_IDS[0]]
        historical.update(basis_identity=bindings['basis_identity'],collector_bundle_identity=m.digest(m.native_canonical(f.basis['collector_bundle'])),
                          historical_manifest=f.basis['historical_manifest'],prepared_identity=bindings['prepared_identity'],
                          transform_identity=m.digest(m.native_canonical([])))
        def contract(contexts,names):
            return {'schema_version':1,'kind':'runtime_native_probe_contract','gates':{
                gate:{'invocations':[{'id':name,**value} for name,value in contexts[gate].get('events',{}).items()],
                      'expectations':{key:contexts[gate][key] for key in m._NATIVE_EXPECTATION_FIELDS[gate]}} for gate in names}}
        relocation=expected[m._NATIVE_GATE_IDS[7]]
        relocation['relocated_contract']=contract(relocation['relocated_expected'],m._NATIVE_GATE_IDS[4:7])
        probe_contract=contract(expected,m._NATIVE_GATE_IDS)
        record={'schema_version':2,'kind':'runtime_native_build_approval','basis_id':f.basis['id'],**bindings,
                'final_closure':rows,'transforms':[],'final_components':components,'native_inventory':inventory,
                'probe_contract':probe_contract,'receipts':[],'evidence_artifacts':[],
                'review_decision':{'scope':'personal_candidate','decision_id':'SYNTHETIC NINE-GATE TEST ONLY'}}
        receipt_bindings={**bindings,'probe_contract_identity':m.digest(m.native_canonical(probe_contract))}
        host={'os':'macOS','os_version':'26.4','sdk':'26.4','architecture':'arm64','chip':'SYNTHETIC ONLY'}
        for gate in m._NATIVE_GATE_IDS:
            expected[gate]['signed_identity']=bindings['signed_identity']
            event,is_static=m._native_receipt_event(gate,expected[gate],static['tool_events'],artifacts)
            if is_static:
                raw=m.native_canonical(event['environment']);name='static-header.env'
                artifacts[name]=raw;environment={'path':name,'kind':'canonical_facts','bytes':len(raw),'sha256':m.digest(raw)}
            else: environment=event['environment_artifact']
            receipt={'schema_version':2,'kind':'observed_native_runtime_gate','gate':gate,'bindings':receipt_bindings,
                     'host':host,'probe_source':event['source'],'environment_artifact':environment,
                     'outputs':[event['stdout'],event['stderr']],
                     'before_signed_identity':bindings['signed_identity'],'after_signed_identity':bindings['signed_identity'],
                     'observations':complete['gates'][gate],
                     **{key:event[key] for key in ('started','ended','duration_ms','outcome','cleanup','argv')}}
            name='receipts/'+str(m._NATIVE_GATE_IDS.index(gate))+'.json';raw=m.native_canonical(receipt)
            artifacts[name]=raw;record['receipts'].append({'gate':gate,'path':name,'bytes':len(raw),'sha256':m.digest(raw)})
        referenced={}
        def collect(value):
            if type(value) is dict:
                if set(value)=={'path','kind','bytes','sha256'} and value['kind'] in m.NATIVE_ARTIFACT_LIMITS:
                    prior=referenced.get(value['path'])
                    if prior is not None:
                        self.assertEqual(value,prior);return
                    referenced[value['path']]=value
                    try: nested=m.strict_json(artifacts[value['path']])
                    except m.Rejected: pass
                    else: collect(nested)
                else:
                    for child in value.values():collect(child)
            elif type(value) is list:
                for child in value:collect(child)
        collect(probe_contract)
        for receipt in record['receipts']:collect({key:value for key,value in receipt.items() if key!='gate'}|{'kind':'receipt'})
        record['evidence_artifacts']=sorted(referenced.values(),key=lambda row:row['path'].encode())
        evidence=f.root/'complete-native-evidence';evidence.mkdir()
        for entry in record['evidence_artifacts']:file(evidence/entry['path'],artifacts[entry['path']])
        f.write_native_envelope(record)
        return context,rows,evidence,record

    def test_complete_nine_gate_approval_has_no_semantic_validator_mocks(self):
        context,rows,evidence,record=self.approval_fixture()
        result=m._read_native_approval(context,self.f.basis,rows,rows,evidence,str(self.f.stage/'payload'))
        self.assertEqual(result['kind'],'native_runtime_gates_verified')
        self.assertEqual(result['verified_facts']['gates'],sorted(m._NATIVE_GATE_IDS))
        self.assertEqual(result['verified_static_facts']['system_targets'],record['native_inventory']['system_targets'])

    def rewrite_fixture_receipt(self,evidence,record,gate,change):
        entry=next(row for row in record['receipts'] if row['gate']==gate)
        receipt=m.strict_json((evidence/entry['path']).read_bytes());change(receipt)
        raw=m.native_canonical(receipt);pin=file(evidence/entry['path'],raw)
        entry.update(pin)
        next(row for row in record['evidence_artifacts'] if row['path']==entry['path']).update(pin)
        self.f.write_native_envelope(record)

    def test_approved_weak_observation_is_not_genuine_semantics(self):
        c,rows,evidence,record=self.approval_fixture()
        self.rewrite_fixture_receipt(evidence,record,m._NATIVE_GATE_IDS[6],lambda receipt:receipt.update(observations={'passed':True}))
        with self.assertRaises(m.Rejected):m._read_native_approval(c,self.f.basis,rows,rows,evidence,str(self.f.stage/'payload'))

    def test_approved_receipt_header_cannot_change_actual_argv(self):
        c,rows,evidence,record=self.approval_fixture()
        self.rewrite_fixture_receipt(evidence,record,m._NATIVE_GATE_IDS[4],lambda receipt:receipt.update(argv=['/bin/echo','passed']))
        with self.assertRaisesRegex(m.Rejected,'concrete execution argv'):
            m._read_native_approval(c,self.f.basis,rows,rows,evidence,str(self.f.stage/'payload'))

    def test_approved_static_observation_cannot_change_edges(self):
        c,rows,evidence,record=self.approval_fixture()
        def mutate(receipt):receipt['observations']['resolved_edges'][0]['target']='/usr/lib/missing.dylib'
        self.rewrite_fixture_receipt(evidence,record,m._NATIVE_GATE_IDS[2],mutate)
        with self.assertRaises(m.Rejected):m._read_native_approval(c,self.f.basis,rows,rows,evidence,str(self.f.stage/'payload'))

    def test_fresh_reparse_rejects_mutated_raw_and_metadata(self):
        c,rows,evidence,record=self.approval_fixture()
        admission=m._read_native_approval(c,self.f.basis,rows,rows,evidence,str(self.f.stage/'payload'))
        observation,inventory,parsed,raw=synthetic_static_snapshot(c,rows,'engine')
        fresh={**observation,'raw_artifacts':raw}
        m._validate_fresh_native_static(c,rows,admission,fresh)
        for field in ('raw','metadata','edges','system_targets'):
            changed=copy.deepcopy(fresh)
            if field=='raw': changed['raw_artifacts'][changed['tool_events'][1]['stdout']['path']]=b'x86_64\n'
            elif field=='metadata':changed['metadata_empty_after'][0]['attributes']=['unapproved']
            elif field=='edges':changed['resolved_edges']=[]
            else:changed['system_targets']=[]
            with self.subTest(field=field),self.assertRaises(m.Rejected):m._validate_fresh_native_static(c,rows,admission,changed)

    def test_finalizer_rejects_concurrent_lock_before_tools(self):
        f=self.f;m._prepare(f.context(),f.basis['id'],f.inventory,f.stage)
        c=m.Context(f.source,phase='native');evidence=f.root/'unused-native-evidence';evidence.mkdir()
        with open(f.stage/'stage-state.json','rb') as locked, mock.patch.object(m.sys,'platform','darwin'), \
             mock.patch.object(m,'_verify_native_static') as native:
            m.fcntl.flock(locked,m.fcntl.LOCK_EX|m.fcntl.LOCK_NB)
            with self.assertRaisesRegex(m.Rejected,'already active'):m._finalize(c,f.stage,evidence)
            native.assert_not_called()
        self.assertFalse((f.stage/m.NATIVE_ACCEPTANCE).exists())

    def test_finalizer_missing_source_approval_never_runs_tools(self):
        f=self.f;m._prepare(f.context(),f.basis['id'],f.inventory,f.stage)
        c=m.Context(f.source,phase='native');evidence=f.root/'unused-native-evidence';evidence.mkdir()
        with mock.patch.object(m.sys,'platform','darwin'),mock.patch.object(m,'_verify_native_static') as native:
            with self.assertRaisesRegex(m.Rejected,'SOURCE_OWNED_NATIVE_BUILD_RECORD_REQUIRED'):
                m._finalize(c,f.stage,evidence)
            native.assert_not_called()
        self.assertFalse((f.stage/m.NATIVE_ACCEPTANCE).exists())

    def test_finalizer_transaction_reaches_commit_with_mocked_native_boundary(self):
        # This separate transaction fixture mocks native admission/execution only;
        # complete semantic/raw-parser success is proved by the test above.
        f=self.f;c,rows,admission,fresh=f.native_commit_fixture()
        evidence=f.root/'native-v2-evidence'
        platform=m.sys.platform;rename=m.no_replace
        def portable_atomic(*args,**kwargs):
            with mock.patch.object(m.sys,'platform',platform):return rename(*args,**kwargs)
        with mock.patch.object(m,'no_replace',side_effect=portable_atomic), mock.patch.object(m.sys,'platform','darwin'), \
             mock.patch.object(m,'_read_native_approval',return_value=admission), \
             mock.patch.object(m,'_verify_native_static',return_value=fresh) as native:
            result=m._finalize(c,f.stage,evidence)
            self.assertEqual(result['state'],'finalized');self.assertTrue(result['native_accepted'])
            self.assertEqual(native.call_count,1)
            result=m._finalize(c,f.stage,evidence)
            self.assertEqual(result['state'],'revalidated');self.assertEqual(native.call_count,2)

    def test_malformed_source_approved_expectations_use_declared_rejection(self):
        c,rows,evidence,original=self.approval_fixture()
        originals={entry['path']:(evidence/entry['path']).read_bytes() for entry in original['receipts']}
        cases=[(6,'model_input_admission',None),(6,'model_input_admission',[]),
               (4,'probe_sources',None),(4,'probe_argv',{}),(5,'case_event_ids',None),
               (3,'voice_environment',None),(7,'relocated_espeak_path',None),
               (4,'voice_launch',None),(2,'pre_sign_inventory',[])]
        for index,key,value in cases:
            record=copy.deepcopy(original)
            record['probe_contract']['gates'][m._NATIVE_GATE_IDS[index]]['expectations'][key]=value
            identity=m.digest(m.native_canonical(record['probe_contract']))
            for entry in record['receipts']:
                receipt=m.strict_json(originals[entry['path']]);receipt['bindings']['probe_contract_identity']=identity
                pin=file(evidence/entry['path'],m.native_canonical(receipt));entry.update(pin)
                next(row for row in record['evidence_artifacts'] if row['path']==entry['path']).update(pin)
            self.f.write_native_envelope(record)
            with self.subTest(gate=index,field=key,value=value),self.assertRaises(m.Rejected):
                m._read_native_approval(c,self.f.basis,rows,rows,evidence,str(self.f.stage/'payload'))

    def test_cancelled_native_capture_remains_unaccepted_and_reraises(self):
        f=self.f;c,rows,admission,fresh=f.native_commit_fixture()
        stopped=KeyboardInterrupt()
        stopped.native_static_capture={'tool_events':[],'raw_artifacts':{'commands/native-000001.stdout':b'partial raw',
                                                                         'commands/native-000001.stderr':b''}}
        with mock.patch.object(m.sys,'platform','darwin'), \
             mock.patch.object(m,'_read_native_approval',return_value=admission), \
             mock.patch.object(m,'_verify_native_static',side_effect=stopped):
            with self.assertRaises(KeyboardInterrupt):m._finalize(c,f.stage,f.root/'native-v2-evidence')
        reports=list((f.stage/m.NATIVE_FINALIZATION_DIR).glob('.attempt-*/attempt.json'))
        self.assertEqual(len(reports),1)
        self.assertEqual(m.strict_json(reports[0].read_bytes())['kind'],'runtime_native_finalization_failed')
        self.assertFalse((f.stage/m.NATIVE_ACCEPTANCE).exists())
        self.assertFalse((f.stage/'payload'/m.MANIFEST).exists())

    def test_capture_budget_failure_does_not_replace_cancellation(self):
        f=self.f;c,rows,admission,fresh=f.native_commit_fixture()
        stopped=KeyboardInterrupt();stopped.native_static_capture={'tool_events':[],'raw_artifacts':{}}
        with mock.patch.object(m.sys,'platform','darwin'), \
             mock.patch.object(m,'_read_native_approval',return_value=admission), \
             mock.patch.object(m,'_verify_native_static',side_effect=stopped), \
             mock.patch.object(m,'_retain_native_failure',side_effect=m.Rejected('operation deadline exceeded',m.MUTATION)):
            with self.assertRaises(KeyboardInterrupt):m._finalize(c,f.stage,f.root/'native-v2-evidence')
        self.assertEqual(stopped.native_capture_retention_error,'operation deadline exceeded')
        self.assertFalse((f.stage/m.NATIVE_ACCEPTANCE).exists())

    def test_manifest_resume_rejects_wrong_mode_even_with_exact_bytes(self):
        f=self.f;c,rows,admission,fresh=f.native_commit_fixture()
        with m.Root(f.stage) as root:m._commit_native_finalization(c,root,admission,fresh)
        (f.stage/'payload'/m.MANIFEST).chmod(0o755)
        with m.Root(f.stage) as root,self.assertRaisesRegex(m.Rejected,'manifest mode'):
            m._commit_native_finalization(c,root,admission,fresh)

# END COMPOSED ADMISSION TESTS

class RootAcquisitionRegressionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve())
        self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.ancestor=self.root/'owned';self.ancestor.mkdir(mode=0o700)
        self.target=self.ancestor/'payload';self.target.mkdir(mode=0o700)

    def test_unrelated_sibling_creation_during_ancestor_acquisition_is_allowed(self):
        before=self.ancestor.stat();original=m.os.open;injected=False
        def opened(name,*args,**kwargs):
            nonlocal injected
            if name=='owned' and not injected:
                injected=True;(self.ancestor/'unrelated-sibling').mkdir()
            return original(name,*args,**kwargs)
        with mock.patch.object(m.os,'open',side_effect=opened),m.Root(self.target) as capability:
            capability.check()
        self.assertTrue(injected)
        self.assertEqual(m.directory_identity(before),m.directory_identity(self.ancestor.stat()))
        self.assertNotEqual(m.identity(before),m.identity(self.ancestor.stat()))

    def test_replaced_ancestor_rejects_and_closes_every_acquired_descriptor(self):
        self.failed_acquisition('replace')

    def test_ancestor_mode_change_rejects_and_closes_every_acquired_descriptor(self):
        self.failed_acquisition('mode')

    def test_symlink_substitution_rejects_and_closes_every_acquired_descriptor(self):
        self.failed_acquisition('symlink')

    def failed_acquisition(self,operation,relative_parent=False):
        original=m.os.open;descriptors=[];injected=False
        def opened(name,*args,**kwargs):
            nonlocal injected
            if name=='owned' and not injected:
                injected=True
                if operation=='mode':self.ancestor.chmod(0o755)
                else:
                    parked=self.root/'parked';self.ancestor.rename(parked)
                    if operation=='symlink':self.ancestor.symlink_to(parked,target_is_directory=True)
                    else:self.ancestor.mkdir(mode=0o700);(self.ancestor/'payload').mkdir(mode=0o700)
            fd=original(name,*args,**kwargs);descriptors.append(fd);return fd
        with m.Root(self.root) as root:
            with mock.patch.object(m.os,'open',side_effect=opened),self.assertRaises((m.Rejected,OSError)):
                if relative_parent:
                    with m.parent_at(root.fd,'owned/payload/data'):pass
                else:m.Root(self.target)
        self.assertTrue(injected)
        for fd in descriptors:
            with self.subTest(fd=fd),self.assertRaises(OSError):os.fstat(fd)

    def test_regular_file_content_change_still_uses_full_identity(self):
        data=self.target/'data';data.write_bytes(b'before')
        original=m.os.open;injected=False
        def opened(name,*args,**kwargs):
            nonlocal injected
            if name=='data' and not injected:
                injected=True;data.write_bytes(b'changed bytes')
            return original(name,*args,**kwargs)
        with m.Root(self.target) as capability,mock.patch.object(m.os,'open',side_effect=opened):
            with self.assertRaisesRegex(m.Rejected,'filesystem mutation observed'):
                m.regular_at(capability.fd,'data',m.Budget({'portable_operation_seconds':60,'regular_file_bytes':1024}))
        self.assertTrue(injected)

    def test_held_ancestor_replacement_remains_rejected(self):
        with m.Root(self.target) as capability:
            self.ancestor.rename(self.root/'parked');self.ancestor.mkdir(mode=0o700)
            (self.ancestor/'payload').mkdir(mode=0o700)
            with self.assertRaisesRegex(m.Rejected,'replaced or moved'):capability.check()


    def test_parent_at_sibling_creation_during_acquisition_is_allowed(self):
        original=m.os.open;injected=False
        def opened(name,*args,**kwargs):
            nonlocal injected
            if name=='owned' and not injected:
                injected=True;(self.ancestor/'unrelated-sibling').mkdir()
            return original(name,*args,**kwargs)
        with m.Root(self.root) as root,mock.patch.object(m.os,'open',side_effect=opened):
            with m.parent_at(root.fd,'owned/payload/data') as (parent,name):
                self.assertEqual(name,'data');self.assertEqual(os.fstat(parent).st_ino,self.target.stat().st_ino)
        self.assertTrue(injected)

    def test_parent_at_replacement_rejects_and_closes_acquired_descriptors(self):
        self.failed_acquisition('replace',relative_parent=True)

    def test_parent_at_mode_change_rejects_and_closes_acquired_descriptors(self):
        self.failed_acquisition('mode',relative_parent=True)

    def test_parent_at_symlink_substitution_rejects_and_closes_acquired_descriptors(self):
        self.failed_acquisition('symlink',relative_parent=True)

    def test_parent_at_held_replacement_remains_rejected(self):
        with m.Root(self.root) as root,self.assertRaisesRegex(m.Rejected,'parent replaced'):
            with m.parent_at(root.fd,'owned/payload/data'):
                self.ancestor.rename(self.root/'parked');self.ancestor.mkdir(mode=0o700)
                (self.ancestor/'payload').mkdir(mode=0o700)

if __name__=='__main__':
    unittest.main()
