#!/usr/bin/env bash
# Parse KUTTL assert files and output what they check
# Usage: parse-assert.sh <assert-file.yaml>

set -eo pipefail

FILE="$1"
[[ -z "$FILE" || ! -f "$FILE" ]] && exit 0

# Parse YAML and output checks
python3 << 'PYEOF' - "$FILE"
import sys
import yaml

def flatten(d, parent_key='', sep='.'):
    """Flatten nested dict to dot notation"""
    items = []
    for k, v in d.items():
        new_key = f"{parent_key}{sep}{k}" if parent_key else k
        if isinstance(v, dict):
            items.extend(flatten(v, new_key, sep).items())
        else:
            items.append((new_key, v))
    return dict(items)

def parse_assert(filepath):
    with open(filepath) as f:
        docs = list(yaml.safe_load_all(f))

    results = []
    for doc in docs:
        if not doc:
            continue

        kind = doc.get('kind', '?')
        api_version = doc.get('apiVersion', '')

        # Handle TestAssert/TestStep (command or CEL expression checks)
        if kind in ('TestAssert', 'TestStep') and 'kuttl.dev' in api_version:
            # Handle CEL expressions (assertAll/assertAny)
            for expr_list in [doc.get('assertAll', []), doc.get('assertAny', [])]:
                for expr in expr_list:
                    cel = expr.get('celExpr', '')
                    if cel:
                        results.append({'type': 'cel', 'check': cel})

            # Handle commands
            commands = doc.get('commands', [])
            for cmd in commands:
                script = cmd.get('script', cmd.get('command', ''))
                ok_msg = None
                for line in script.split('\n'):
                    if 'echo "OK:' in line:
                        ok_msg = line.split('"')[1].replace('OK: ', '') if '"' in line else None
                        break
                if ok_msg:
                    results.append({'type': 'command', 'check': ok_msg})
                else:
                    first_line = script.strip().split('\n')[0][:60]
                    results.append({'type': 'command', 'check': first_line})
            continue

        # Handle regular resource asserts
        name = doc.get('metadata', {}).get('name', '?')
        ns = doc.get('metadata', {}).get('namespace', '')

        # Get checked fields (spec and status)
        checks = {}
        for key in ['spec', 'status']:
            if key in doc:
                flat = flatten({key: doc[key]})
                checks.update(flat)

        if checks:
            results.append({
                'type': 'resource',
                'kind': kind,
                'name': name,
                'namespace': ns,
                'checks': checks
            })

    return results

if __name__ == '__main__':
    filepath = sys.argv[1]
    results = parse_assert(filepath)

    for r in results:
        if r['type'] == 'cel':
            print(f"      CEL: {r['check']}")
        elif r['type'] == 'command':
            print(f"      Command: {r['check']}")
        else:
            ns_str = f" ({r['namespace']})" if r['namespace'] else ''
            for path, value in r['checks'].items():
                print(f"      {r['kind']}/{r['name']}{ns_str}: {path} = {value}")
PYEOF
