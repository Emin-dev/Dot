import hashlib, importlib.util, json
from pathlib import Path
import tempfile, unittest, zipfile

spec=importlib.util.spec_from_file_location('voice_install_plan',Path(__file__).resolve().parents[2]/'scripts/prepare_voice_install.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

def sha(data):return hashlib.sha256(data).hexdigest()
def write(path,value):path.write_text(json.dumps(value));return path

class VoiceInstallPlanTests(unittest.TestCase):
    def fixture(self,root):
        metadata=b'Metadata-Version: 2.1\nName: fixture\nVersion: 1.0\n'
        wheel=root/'fixture-1.0-py3-none-any.whl'
        with zipfile.ZipFile(wheel,'w') as z:
            z.writestr('fixture.py',b'# inert test fixture\n');z.writestr('fixture-1.0.dist-info/METADATA',metadata)
        entry={'name':'fixture','version':'1.0','filename':wheel.name,'bytes':wheel.stat().st_size,
            'sha256':module.digest(wheel),'metadata_sha256':sha(metadata),'requires_dist':[]}
        report=write(root/'inspection.json',{'kind':'wheel','crc_status':'ALL_MEMBERS_VERIFIED',
            'record_status':'ALL_REQUIRED_MEMBER_HASHES_AND_SIZES_VERIFIED',
            'verified_archive':{'sha256':entry['sha256'],'size':entry['bytes']},'fixture_only':True})
        entry['inspection_report_sha256']=module.digest(report)
        lock={'schema_version':1,'kind':'complete_voice_wheel_lock','target':{'implementation':'cpython','python':'3.11.17','platform':'macos-arm64'},
            'python_archive_sha256':module.PYTHON_ARCHIVE_SHA,'unresolved':[],'wheels':[entry],'fixture_only':True}
        lockpath=write(root/'lock.json',lock)
        audit={'kind':'voice_closure_audit','passed':True,'catalog_sha256':module.digest(lockpath),'unresolved':[],'checks':1,'fixture_only':True}
        auditpath=write(root/'audit.json',audit)
        inventory={'wheels':{wheel.name:{'path':str(wheel),'sha256':entry['sha256'],'inspection_passed':True,'inspection_report':str(report)}}}
        invpath=write(root/'inventory.json',inventory)
        python=root/'python';(python/'bin').mkdir(parents=True);executable=python/'bin/python3.11';executable.write_bytes(b'inert interpreter fixture, never run');executable.chmod(0o700)
        base={'kind':'verified_standalone_python_tree','source_archive_sha256':module.PYTHON_ARCHIVE_SHA,'source_archive_bytes':27105320,
              'files':[{'kind':'file','path':'bin/python3.11','bytes':executable.stat().st_size,'sha256':module.digest(executable)}],'fixture_only':True}
        basepath=write(root/'python-tree.json',base)
        return [lockpath,auditpath,invpath,python,basepath,module.digest(executable),root/'prepared'],lock,audit,inventory
    def test_plan_is_offline_hash_locked_and_does_not_execute(self):
        with tempfile.TemporaryDirectory() as d:
            args,_,_,_=self.fixture(Path(d));plan=module.prepare(*args)
            self.assertEqual(plan['kind'],'offline_voice_install_plan_not_executed')
            for flag in ['-I','-B','--isolated','--no-index','--no-deps','--no-compile','--only-binary=:all:','--require-hashes']:
                self.assertIn(flag,plan['argv'])
            self.assertEqual(plan['argv'][:2],['/usr/bin/sandbox-exec','-p'])
            self.assertIn('(deny network*)',plan['argv'][2]);self.assertIn('(deny file-write*)',plan['argv'][2])
            self.assertEqual(plan['environment']['PIP_CONFIG_FILE'],'/dev/null')
            self.assertEqual(plan['argv'][plan['argv'].index('--prefix')+1],str(args[3]))
            self.assertFalse(plan['immutable_runtime_manifest_may_be_created'])
            self.assertTrue((args[-1]/'wheels/fixture-1.0-py3-none-any.whl').is_file())
            self.assertIn('--hash=sha256:',(args[-1]/'requirements.txt').read_text())
    def test_unresolved_lock_rejected_before_output(self):
        with tempfile.TemporaryDirectory() as d:
            args,lock,_,_=self.fixture(Path(d));lock['unresolved']=['missing'];write(args[0],lock)
            with self.assertRaises(ValueError):module.prepare(*args)
            self.assertFalse(args[-1].exists())
    def test_corrupt_archive_rejected_before_output(self):
        with tempfile.TemporaryDirectory() as d:
            args,_,_,inv=self.fixture(Path(d));p=Path(next(iter(inv['wheels'].values()))['path']);p.write_bytes(b'bad')
            with self.assertRaises(ValueError):module.prepare(*args)
            self.assertFalse(args[-1].exists())
    def test_changed_audit_or_inspection_rejected(self):
        for target in ('audit','inspection'):
            with self.subTest(target=target),tempfile.TemporaryDirectory() as d:
                args,_,audit,inv=self.fixture(Path(d))
                if target=='audit':audit['catalog_sha256']='0'*64;write(args[1],audit)
                else:Path(next(iter(inv['wheels'].values()))['inspection_report']).write_text('{}')
                with self.assertRaises(ValueError):module.prepare(*args)
                self.assertFalse(args[-1].exists())
    def test_unmanifested_python_file_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            args,_,_,_=self.fixture(Path(d));(args[3]/'extra.py').write_text('# untracked')
            with self.assertRaises(ValueError):module.prepare(*args)
            self.assertFalse(args[-1].exists())
    def test_external_python_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);args,_,_,_=self.fixture(root);p=args[3]/'bin/python3.11';p.unlink();outside=root/'outside';outside.write_bytes(b'outside');p.symlink_to(outside)
            with self.assertRaises(ValueError):module.prepare(*args)
            self.assertFalse(args[-1].exists())
    def test_existing_destination_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            args,_,_,_=self.fixture(Path(d));args[-1].mkdir();keep=args[-1]/'keep';keep.write_text('original')
            with self.assertRaises(ValueError):module.prepare(*args)
            self.assertEqual(keep.read_text(),'original')
    def test_inventory_extra_entry_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            args,_,_,inv=self.fixture(Path(d));inv['wheels']['extra.whl']={};write(args[2],inv)
            with self.assertRaises(ValueError):module.prepare(*args)
            self.assertFalse(args[-1].exists())

    def test_nonregular_inspection_report_rejected_without_reading(self):
        import os
        with tempfile.TemporaryDirectory() as d:
            args,_,_,inv=self.fixture(Path(d));report=Path(next(iter(inv['wheels'].values()))['inspection_report'])
            report.unlink();os.mkfifo(report)
            with self.assertRaises(ValueError):module.prepare(*args)
            self.assertFalse(args[-1].exists())

    def test_sandbox_path_escaping_and_control_rejection(self):
        self.assertEqual(module.sandbox_literal('/a"b\\c'), '"/a\\"b\\\\c"')
        with self.assertRaises(ValueError):module.sandbox_literal('/a\nb')

    def test_evidence_changes_do_not_relabel_validated_snapshot(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as d:
            args,_,_,_=self.fixture(Path(d));paths=[args[0],args[1],args[4]]
            original=[p.read_bytes() for p in paths];verify=module.verify_python_tree
            def change_after_validation(root,manifest):
                verify(root,manifest)
                for path in paths:path.write_text('{"changed":true}')
            with patch.object(module,'verify_python_tree',side_effect=change_after_validation):plan=module.prepare(*args)
            for name,data in zip(['voice-lock.json','closure-audit.json','python-tree.json'],original):
                self.assertEqual((args[-1]/name).read_bytes(),data)
            self.assertEqual(plan['catalog_sha256'],sha(original[0]))
            self.assertEqual(plan['python_tree_manifest_sha256'],sha(original[2]))

    def test_python_directory_nodes_are_bounded(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as d:
            args,_,_,_=self.fixture(Path(d));(args[3]/'empty').mkdir()
            with patch.object(module,'MAX_TREE_NODES',2),self.assertRaisesRegex(ValueError,'total node bound'):
                module.prepare(*args)
            self.assertFalse(args[-1].exists())

if __name__=='__main__':unittest.main()
