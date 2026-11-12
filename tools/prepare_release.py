"""Verify Android artifacts and prepare the public update manifest."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--sdk', default=os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    version, build = re.search(r'^version:\s*(\S+)\+(\d+)\s*$', (root / 'pubspec.yaml').read_text(), re.M).groups()
    if args.tag.startswith('v') and args.tag != f'v{version}':
        raise SystemExit('Release tag must match pubspec.yaml.')
    fingerprint = (root / 'android/release-cert.sha256').read_text().strip().lower()
    if not re.fullmatch('[a-f0-9]{64}', fingerprint):
        raise SystemExit('Invalid pinned signing certificate.')
    build_tools = sorted((Path(args.sdk) / 'build-tools').iterdir(), key=lambda item: tuple(int(part) for part in item.name.split('.') if part.isdigit()))[-1]
    suffix = '.bat' if os.name == 'nt' else ''
    executable = '.exe' if os.name == 'nt' else ''
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    artifacts = []
    for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
        apk = root / f'build/app/outputs/flutter-apk/app-{abi}-release.apk'
        verified = subprocess.check_output([str(build_tools / f'apksigner{suffix}'), 'verify', '--print-certs', str(apk)], text=True)
        digests = re.findall(r'certificate SHA-256 digest:\s*([a-fA-F0-9]+)', verified)
        if digests != [fingerprint]:
            raise SystemExit(f'Unexpected signing certificate for {abi}.')
        badging = subprocess.check_output([str(build_tools / f'aapt{executable}'), 'dump', 'badging', str(apk)], text=True, encoding='utf-8')
        package, code, name = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging).groups()
        if (package, int(code), name) != ('top.shenyunyao.pikmelo_player', int(build), version):
            raise SystemExit(f'Unexpected package or version for {abi}.')
        if re.search(r"native-code:\s*'([^']+)'", badging).group(1) != abi:
            raise SystemExit(f'Unexpected native architecture for {abi}.')
        filename = f'Pikmelo-Player-{version}-{abi}.apk'
        shutil.copy2(apk, output / filename)
        artifacts.append({'platform': 'android', 'abi': abi, 'name': filename,
                          'size': apk.stat().st_size, 'sha256': hashlib.file_digest(apk.open('rb'), 'sha256').hexdigest()})
    manifest = {'schema': 1, 'version': version, 'versionCode': int(build),
                'packageName': package, 'signerSha256': fingerprint, 'artifacts': artifacts}
    (output / 'updates.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (output / 'SHA256SUMS').write_text(''.join(f"{item['sha256']}  {item['name']}\n" for item in artifacts), encoding='utf-8')
    print(f'Prepared {version}+{build} with {len(artifacts)} verified APKs.')


if __name__ == '__main__':
    main()
