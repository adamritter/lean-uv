#!/usr/bin/env python3
"""Audit kernel proofs separately from the explicit native assumption records."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
source = root / 'LeanUV/Contract.lean'
modules = [(source,'LeanUV.TCP.Contract.'),(root/'LeanUV/Machine.lean','LeanUV.TCP.Machine.'),(root/'LeanUV/AdapterContract.lean','LeanUV.TCP.Machine.'),(root/'LeanUV/ProgressContract.lean','LeanUV.TCP.Machine.')]
audit = root / 'LeanUV/ContractAudit.lean'
declared = {prefix + name for path,prefix in modules for name in re.findall(r'^theorem\s+(\w+)',path.read_text(),re.M)}
checked = set(re.findall(r'^#print axioms\s+(\S+)', audit.read_text(), re.M))
assert declared == checked, (declared, checked)
run = subprocess.run(['lake', 'env', 'lean', str(audit)], cwd=root, text=True, capture_output=True, check=True)
rows = {}
for name, _, deps in re.findall(r"'([^']+)' (does not depend on any axioms|depends on axioms: \[([^\]]*)\])", run.stdout):
    axioms = set(filter(None, (v.strip() for v in deps.split(','))))
    assert axioms <= {'propext','Quot.sound','Classical.choice'}, (name, axioms)
    rows[name] = sorted(axioms)
assert set(rows) == declared, run.stdout
print(json.dumps({'result':'PASS','lean':subprocess.check_output(['lean','--version'],text=True).strip(),
    'source_sha256':{str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path,_ in modules}, 'axioms':rows,
    'explicit_hypotheses':['NativeContract','ProgressContract','Machine.ExecutionContract','Machine.AdapterContract','Machine.ResponsiveContract','Machine.CompletionContract'],
    'native_implementation_proved':False,
    'http_correctness_assumed':False},indent=2))
