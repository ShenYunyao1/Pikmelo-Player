"""Combine Windows and Android assets before publishing a complete release."""
import hashlib
import json
from pathlib import Path
import sys


def checksum(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    directory = Path(sys.argv[1])
    manifest = json.loads((directory / 'updates.json').read_text(encoding='utf-8'))
    filename = f"Pikmelo-Player-{manifest['version']}-windows-x64.zip"
    windows = directory / filename
    manifest['artifacts'] = [item for item in manifest['artifacts'] if item['platform'] != 'windows']
    manifest['artifacts'].append({'platform': 'windows', 'abi': 'x86_64', 'name': filename,
                                  'size': windows.stat().st_size, 'sha256': checksum(windows)})
    for item in manifest['artifacts']:
        asset = directory / item['name']
        if asset.stat().st_size != item['size'] or checksum(asset) != item['sha256']:
            raise SystemExit(f"Release asset verification failed: {item['name']}")
    (directory / 'updates.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (directory / 'SHA256SUMS').write_text(''.join(f"{item['sha256']}  {item['name']}\n" for item in manifest['artifacts']), encoding='utf-8')
    print('Verified complete Windows and Android release assets.')


if __name__ == '__main__':
    main()
