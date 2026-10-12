import base64, csv, hashlib, importlib.util, io, json
from pathlib import Path
import tarfile, tempfile, unittest, zipfile

spec = importlib.util.spec_from_file_location('docopt_packager', Path(__file__).resolve().parents[2]/'scripts/build_docopt_wheel.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class DocoptWheelTests(unittest.TestCase):
    def files(self): return {'docopt.py':b'# inert fixture, never executed\n','PKG-INFO':b'Metadata-Version: 1.1\nName: docopt\nVersion: 0.6.2\nLicense: MIT\n','LICENSE-MIT':b'fixture license'}
    def test_deterministic_and_complete_record(self):
        files=self.files(); a=module.wheel_bytes(files,{'fixture_only':True}); self.assertEqual(a,module.wheel_bytes(files,{'fixture_only':True}))
        with zipfile.ZipFile(io.BytesIO(a)) as z:
            rows=list(csv.reader(io.StringIO(z.read(module.DIST+'RECORD').decode())))
            self.assertEqual({r[0] for r in rows},set(z.namelist()))
            for name,checksum,size in rows:
                if name.endswith('/RECORD'): self.assertEqual((checksum,size),('','')); continue
                data=z.read(name); self.assertEqual(int(size),len(data))
                self.assertEqual(checksum,'sha256='+base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode())
            self.assertEqual(z.read('docopt.py'),files['docopt.py']); self.assertEqual(z.read(module.DIST+'METADATA'),files['PKG-INFO'])
            self.assertTrue(all(i.date_time==(1980,1,1,0,0,0) for i in z.infolist()))
    def test_unexpected_dependency_rejected(self):
        files=self.files();files['PKG-INFO']+=b'Requires-Dist: surprise\n'
        with self.assertRaises(ValueError):module.wheel_bytes(files,{})
    def test_wrong_identity_rejected(self):
        files=self.files();files['PKG-INFO']=files['PKG-INFO'].replace(b'0.6.2',b'0.6.3')
        with self.assertRaises(ValueError):module.wheel_bytes(files,{})
    def archive(self,path,duplicate=False,link=False):
        data=b'never execute';info=tarfile.TarInfo('docopt-0.6.2/docopt.py');info.size=len(data)
        with tarfile.open(path,'w:gz') as a:
            if link:info.type=tarfile.SYMTYPE;info.linkname='/outside';info.size=0
            a.addfile(info,None if link else io.BytesIO(data))
            if duplicate:a.addfile(info,io.BytesIO(data))
        return (path.stat().st_size,module.sha(path.read_bytes())),{'docopt.py':(len(data),module.sha(data))}
    def test_pinned_source_read_without_extraction(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'source.tgz';pin,files=self.archive(p)
            self.assertEqual(module.read_source(p,pin,files),{'docopt.py':b'never execute'})
            self.assertEqual(list(Path(d).iterdir()),[p])
    def test_wrong_hash_duplicate_or_link_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'source.tgz';pin,files=self.archive(p)
            with self.assertRaises(ValueError):module.read_source(p,(pin[0],'0'*64),files)
            for variant in ('duplicate','link'):
                pin,files=self.archive(p,**{variant:True})
                with self.assertRaises(ValueError):module.read_source(p,pin,files)
    def test_existing_destination_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/module.FILENAME;p.write_bytes(b'original')
            with self.assertRaises(ValueError):module.build(Path(d)/'absent',p)
            self.assertEqual(p.read_bytes(),b'original')

if __name__=='__main__':unittest.main()
