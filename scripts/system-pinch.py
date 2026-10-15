#!/usr/bin/env python3
"""Back up and change only the built-in trackpad's Launchpad pinch switches."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

DOMAIN = 'com.apple.AppleMultitouchTrackpad'
KEYS = ['TrackpadFourFingerPinchGesture', 'TrackpadFiveFingerPinchGesture']
BACKUP = Path.home() / 'Library/Application Support/OpenLaunch/system-pinch-backup.json'

def read(key):
    result = subprocess.run(['defaults', 'read', DOMAIN, key], capture_output=True, text=True)
    return int(result.stdout.strip()) if result.returncode == 0 else None

def write(key, value):
    args = ['defaults', 'delete', DOMAIN, key] if value is None else ['defaults', 'write', DOMAIN, key, '-int', str(value)]
    subprocess.run(args, check=True, capture_output=True)

if len(sys.argv) != 2 or sys.argv[1] not in ['disable', 'restore']:
    raise SystemExit('Usage: python3 scripts/system-pinch.py disable|restore')
with tempfile.TemporaryDirectory(prefix='openlaunch-hid-') as temp:
    helper = str(Path(temp) / 'hid-pinch')
    subprocess.run(['clang', str(Path(__file__).with_name('hid-pinch.c')), '-framework', 'IOKit', '-framework', 'CoreFoundation', '-o', helper], check=True)
    runtime_before = json.loads(subprocess.check_output([helper], text=True))
    if sys.argv[1] == 'disable':
        if not BACKUP.exists():
            BACKUP.parent.mkdir(parents=True, exist_ok=True)
            with BACKUP.open('x') as file:
                json.dump({'domain': DOMAIN, 'values': {key: read(key) for key in KEYS}, 'runtime_values': {key: runtime_before[key]['before'] for key in KEYS}}, file, indent=2)
        targets = {key: 0 for key in KEYS}
        saved = json.loads(BACKUP.read_text())
    else:
        saved = json.loads(BACKUP.read_text())
        targets = saved.get('runtime_values', {})
    if saved['domain'] != DOMAIN or set(saved['values']) != set(KEYS) or set(saved.get('runtime_values', {})) != set(KEYS):
        raise SystemExit('Unexpected backup; no changes made')
    if any(value not in [0, 2] for value in targets.values()):
        raise SystemExit('Unsupported original runtime value; no changes made')
    if sys.argv[1] == 'restore' and any(read(key) not in [0, saved['values'][key]] for key in KEYS):
        raise SystemExit('A setting changed since disable; no changes made')
    if sys.argv[1] == 'restore':
        saved['disabled_active'] = False
        BACKUP.write_text(json.dumps(saved, indent=2))
    for key in KEYS:
        write(key, 0 if sys.argv[1] == 'disable' else saved['values'][key])
    applied = json.loads(subprocess.check_output([helper, '--set', *[str(targets[key]) for key in KEYS]], text=True))
    if sys.argv[1] == 'disable':
        saved['disabled_active'] = True
        BACKUP.write_text(json.dumps(saved, indent=2))
    print(json.dumps({'action': sys.argv[1], 'backup': str(BACKUP), 'preferences': {key: read(key) for key in KEYS}, 'runtime': applied}, indent=2))
