#!/usr/bin/env python3
"""Publishes Zefy Reborn to a Sileo / Cydia repo checkout (GoldenAppleGuy/repo).

    python3 tools/update_repo.py <repo checkout> [package.deb ...]

Copies the packages (default: packages/*.deb from ./build.sh) into <repo>/debs, then regenerates the
repo index from every package in debs/: Packages (+ .gz, .bz2), Release (with checksums), and the
Sileo package page in depictions/ (from tools/depiction.json). Commit and push the checkout afterwards.
"""
import bz2, glob, gzip, hashlib, io, json, os, shutil, sys, tarfile

BASE_URL = 'https://goldenappleguy.github.io/repo/'
PACKAGE = 'com.goldenappleguy.zefyreborn'
HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)

RELEASE = {
    'Origin': 'GoldenAppleGuy',
    'Label': 'GoldenAppleGuy',
    'Suite': 'stable',
    'Version': '1.0',
    'Codename': 'ios',
    'Architectures': 'iphoneos-arm iphoneos-arm64 iphoneos-arm64e',
    'Components': 'main',
    'Description': 'Jailbreak tweaks by GoldenAppleGuy',
}


def deb_control(path):
    """The control fields of a .deb (an ar archive holding control.tar.*), in order."""
    data = open(path, 'rb').read()
    assert data[:8] == b'!<arch>\n', f'{path}: not a .deb'
    offset = 8
    while offset < len(data):
        name = data[offset:offset + 16].decode().strip().rstrip('/')
        size = int(data[offset + 48:offset + 58].decode().strip())
        member = data[offset + 60:offset + 60 + size]
        offset += 60 + size + (size % 2)
        if name.startswith('control.tar'):
            with tarfile.open(fileobj=io.BytesIO(member), mode='r:*') as tar:
                for info in tar.getmembers():
                    if os.path.basename(info.name) == 'control':
                        text = tar.extractfile(info).read().decode()
                        fields = {}
                        for line in text.splitlines():
                            if line[:1] in (' ', '\t') and fields:
                                key = list(fields)[-1]
                                fields[key] += '\n' + line
                            elif ':' in line:
                                key, value = line.split(':', 1)
                                fields[key.strip()] = value.strip()
                        return fields
    raise SystemExit(f'{path}: no control file')


def version_key(version):
    return [int(part) if part.isdigit() else part for part in version.replace('-', '.').split('.')]


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    repo = os.path.abspath(sys.argv[1])
    debs = sys.argv[2:] or sorted(glob.glob(os.path.join(PROJECT, 'packages', '*.deb')))
    os.makedirs(os.path.join(repo, 'debs'), exist_ok=True)
    for deb in debs:
        shutil.copy2(deb, os.path.join(repo, 'debs', os.path.basename(deb)))
        print('added', os.path.basename(deb))

    entries, latest = [], {}
    for path in sorted(glob.glob(os.path.join(repo, 'debs', '*.deb'))):
        fields = deb_control(path)
        data = open(path, 'rb').read()
        package = fields['Package']
        fields['Filename'] = 'debs/' + os.path.basename(path)
        fields['Size'] = str(len(data))
        fields['MD5sum'] = hashlib.md5(data).hexdigest()
        fields['SHA1'] = hashlib.sha1(data).hexdigest()
        fields['SHA256'] = hashlib.sha256(data).hexdigest()
        if os.path.exists(os.path.join(repo, 'icons', package + '.png')):
            fields['Icon'] = BASE_URL + 'icons/' + package + '.png'
        fields['SileoDepiction'] = BASE_URL + 'depictions/' + package + '.json'
        entries.append('\n'.join(f'{key}: {value}' for key, value in fields.items()))
        if package not in latest or version_key(fields['Version']) > version_key(latest[package]['Version']):
            latest[package] = fields

    packages = ('\n\n'.join(entries) + '\n').encode()
    files = {'Packages': packages, 'Packages.gz': gzip.compress(packages, mtime=0), 'Packages.bz2': bz2.compress(packages)}
    for name, content in files.items():
        open(os.path.join(repo, name), 'wb').write(content)

    release = [f'{key}: {value}' for key, value in RELEASE.items()]
    for title, digest in (('MD5Sum', hashlib.md5), ('SHA256', hashlib.sha256)):
        release.append(title + ':')
        release += [f' {digest(content).hexdigest()} {len(content)} {name}' for name, content in files.items()]
    open(os.path.join(repo, 'Release'), 'w').write('\n'.join(release) + '\n')

    # Sileo package page, with the newest version filled in
    template = open(os.path.join(HERE, 'depiction.json')).read()
    os.makedirs(os.path.join(repo, 'depictions'), exist_ok=True)
    for package, fields in latest.items():
        if package != PACKAGE:
            continue  # other packages keep the pages their own projects published
        page = template.replace('%VERSION%', fields['Version'])
        json.loads(page)  # must stay valid JSON
        open(os.path.join(repo, 'depictions', package + '.json'), 'w').write(page)
    print(f'{len(entries)} packages indexed; newest: ' + ', '.join(f'{p} {f["Version"]}' for p, f in latest.items()))


if __name__ == '__main__':
    main()
