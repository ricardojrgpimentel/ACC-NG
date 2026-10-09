#!/usr/bin/env python3
"""Export reproducible frontend fixtures using production shell code, never sysfs."""
import argparse
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from contract_cases import serialized
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
parser.add_argument('--app', type=Path, help='Also write/check the AccA-NG test resource')
args = parser.parse_args()
paths = [ROOT / 'tests/fixtures/frontend-contract.json']
if args.app:
    paths.append(args.app / 'app/src/test/resources/acc-ng/frontend-contract.json')
data = serialized()
for path in paths:
    if args.check:
        if not path.is_file() or path.read_text() != data:
            sys.exit(f'Contract fixture is stale: {path}')
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)
    print(('Checked ' if args.check else 'Wrote ') + str(path))
