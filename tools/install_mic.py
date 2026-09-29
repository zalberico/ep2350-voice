#!/usr/bin/env python3
"""Install only to the normal FX MIC disk; make and verify a private backup first."""
import datetime
import hashlib
import shutil
from pathlib import Path

root = Path(__file__).resolve().parent.parent
disk = Path('/Volumes/FX MIC DISK')
if not disk.is_dir() or (disk / 'INFO_UF2.TXT').exists():
    raise SystemExit('Normal FX MIC DISK is not mounted. Do not use a bootloader volume.')
files = [(root / 'firmware/fxmic/main.py', 'fxmic.py')]
files += [(root / 'packs/marker-pack' / n, n) for n in ['chirp.wav', 'cancel.wav', 'press.wav', 'release.wav', 'config.json']]
files += [(root / 'firmware/fxmic/boot_main.py', 'main.py')]
for source, _ in files:
    if not source.is_file():
        raise SystemExit(f'Missing {source.name}. Generate the patched script from your own mic first.')
backup = Path.home() / 'Library/Application Support/EP2350Voice/backups' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
shutil.copytree(disk, backup)
def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()
for source in disk.rglob('*'):
    if source.is_file() and digest(source) != digest(backup / source.relative_to(disk)):
        raise SystemExit(f'Backup verification failed: {source.name}; nothing installed.')
if shutil.disk_usage(disk).free < sum(s.stat().st_size for s, _ in files) + 32768:
    raise SystemExit(f'Not enough free space. Backup saved at {backup}; nothing installed.')
try:
    for source, name in files:
        shutil.copyfile(source, disk / name)
        if digest(source) != digest(disk / name):
            raise OSError(f'Copy verification failed: {name}')
except Exception as exc:
    raise SystemExit(f'Installation incomplete: {exc}. Do not restart until the original files are restored from {backup}.')
print(f'Installed and verified. Backup: {backup}')
print('Eject in Finder, unplug USB-C, power off, and squeeze to restart on batteries.')
