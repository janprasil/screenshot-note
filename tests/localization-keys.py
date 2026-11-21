# Fails when a L()/LF() literal is missing from any catalog.
import glob, json, re, subprocess, sys
catalogs = {p: json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', p])) for p in glob.glob('Localizations/*.lproj/Localizable.strings')}
missing = []
sources = sorted(glob.glob('Sources/**/*.swift', recursive=True))
# Prázdný seznam by kontrolu tiše vypnul.
if not sources:
    sys.exit('No Swift sources found under Sources/')
for source in sources:
    for match in re.finditer(r'\bLF?\("((?:[^"\\]|\\.)*)"', open(source, encoding='utf-8').read()):
        key = match.group(1).encode().decode('unicode_escape').encode('latin-1').decode('utf-8')
        missing += [f'{source}: {p}: {key}' for p, values in catalogs.items() if key not in values]
if missing:
    sys.exit('Missing translations:\n' + '\n'.join(missing))
