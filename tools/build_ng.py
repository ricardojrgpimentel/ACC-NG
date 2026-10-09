#!/usr/bin/env python3
"""Build deterministic ACC-NG installation artifacts without modifying sources."""
from pathlib import Path
import argparse, gzip, hashlib, io, json, tarfile, zipfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--update-metadata', action='store_true',
    help='Also update repository module.json when preparing publication.')
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[1]
props = dict(line.split('=', 1) for line in (ROOT / 'module.prop').read_text().splitlines() if '=' in line)
version, code = props['version'], props['versionCode']
name = f"acc_{version}_{code}"
OUT = ROOT / '_builds' / name
OUT.mkdir(parents=True, exist_ok=True)

def zip_bytes(entries):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path, data, mode in sorted(entries):
            info = zipfile.ZipInfo(path, date_time=(2026, 10, 9, 0, 0, 0))
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)
    return buffer.getvalue()

uninstaller = zip_bytes([
    ('META-INF/com/google/android/update-binary', (ROOT/'install/uninstall.sh').read_bytes(), 0o100755),
    ('META-INF/com/google/android/updater-script', b'#MAGISK\n', 0o100644),
])
entries = []
for path in ROOT.rglob('*'):
    rel = path.relative_to(ROOT)
    if any(p in {'.git', '_builds', '.tmp', '__pycache__', 'tests', 'tools'} for p in rel.parts): continue
    if rel.parts[0] in {'bin', '.github'} or rel.as_posix() == 'module.json' or not path.is_file(): continue
    # Legacy build/push scripts stay in Git, not in the runtime release archive.
    if rel.parts[0] in {'build.sh', 'build.bat', 'push.sh', 'push.bat'}: continue
    mode = 0o100755 if path.suffix == '.sh' or path.name == 'update-binary' else 0o100644
    entries.append((rel.as_posix(), path.read_bytes(), mode))
entries.append(('bin/acc_flashable_uninstaller.zip', uninstaller, 0o100644))
zip_path = OUT / f'{name}.zip'
zip_path.write_bytes(zip_bytes(entries))
tar_path = OUT / f'{name}.tgz'
with tar_path.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0, compresslevel=9) as gz:
    with tarfile.open(fileobj=gz, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for path, data, mode in sorted(entries):
            info = tarfile.TarInfo(f'acc-ng-{version}/{path}')
            info.size, info.mode, info.uid, info.gid, info.mtime = len(data), mode & 0o777, 0, 0, 0
            tar.addfile(info, io.BytesIO(data))
base = f'https://github.com/ricardojrgpimentel/ACC-NG/releases/download/{version}'
metadata = {'version': version, 'versionCode': int(code), 'zipUrl': f'{base}/{name}.zip',
    'tgz': f'{base}/{name}.tgz', 'tgzInstaller': f'{base}/install-tarball.sh',
    'onlineInstaller': f'{base}/install-online.sh',
    'changelog': 'https://raw.githubusercontent.com/ricardojrgpimentel/ACC-NG/main/changelog.md',
    'sha256': hashlib.sha256(tar_path.read_bytes()).hexdigest()}
(OUT/'module.json').write_text(json.dumps(metadata, indent=2) + '\n')
if args.update_metadata:
    (ROOT/'module.json').write_text(json.dumps(metadata, indent=2) + '\n')
for installer in ('install-tarball.sh', 'install-online.sh'):
    (OUT/installer).write_bytes((ROOT/installer).read_bytes())
print(tar_path)
print(zip_path)
print('tarball sha256='+metadata['sha256'])
