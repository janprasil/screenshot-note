#!/usr/bin/env python3
"""Fails when tests disappear from the test host or test code reaches the app sources."""
import glob, re, sys

# Stav po přidání testů aktualizací (feat/sparkle-updater): 33 testovacích funkcí, 981 kontrol, 25 PASS řádků hlavního self-testu.
FLOOR = {'functions': 33, 'checks': 981, 'passes': 25}

def read(pattern):
    return {p: open(p, encoding='utf-8').read() for p in sorted(glob.glob(pattern, recursive=True))}

tests = read('Sources/ScreenshotNoteTestHost/**/*.swift')
found = {
    'functions': sum(len(re.findall(r'^(?:@MainActor )?func \w+Tests?\(\)', s, re.M)) for s in tests.values()),
    'checks': sum(len(re.findall(r'\bassert\(|\bcheck\(', s)) for s in tests.values()),
    'passes': len(re.findall(r'print\("PASS:', tests.get('Sources/ScreenshotNoteTestHost/main.swift', ''))),
}
errors = [f'{k}: {found[k]} < {v}' for k, v in FLOOR.items() if found[k] < v]
for path, source in read('Sources/ScreenshotNote*/**/*.swift').items():
    if path.startswith('Sources/ScreenshotNoteTestHost/'):
        continue
    for marker in (r'^(?:@MainActor )?func \w+Tests?\(\)', r'"--[\w-]*self-test"', r'print\("PASS:'):
        if re.search(marker, source, re.M):
            errors.append(f'{path}: test code ({marker})')
if '--log' in sys.argv:
    log = open(sys.argv[sys.argv.index('--log') + 1], encoding='utf-8').read().splitlines()
    expected = open('tests/expected-passes.txt', encoding='utf-8').read().splitlines()
    ran = set(log)
    errors += [f'not reported: {line}' for line in expected if line and line not in ran]
    found['reported'] = sum(1 for line in log if line.startswith('PASS:') or line.endswith('self-test passed'))
print('Test inventory:', ', '.join(f'{k}={v}' for k, v in found.items()))
if errors:
    sys.exit('\n'.join(errors))
