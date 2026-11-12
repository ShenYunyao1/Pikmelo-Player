"""Generate APK rejection cases for release-signed Android instrumentation."""
import argparse
import json
import os
from pathlib import Path
import shutil
import re
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--old', required=True)
    parser.add_argument('--new', required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--signing', default=os.environ.get('PIKMELO_SIGNING_PROPERTIES', 'D:/Develop/Signing/PikmeloPlayer/signing.properties'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    assets = root / 'android/app/src/androidTest/assets'
    assets.mkdir(parents=True, exist_ok=True)
    properties = dict(line.split('=', 1) for line in Path(args.signing).read_text().splitlines() if '=' in line)
    env = dict(os.environ, PIKMELO_TEST_STORE_PASSWORD=properties['storePassword'], PIKMELO_TEST_KEY_PASSWORD=properties['keyPassword'])
    tools = Path(args.sdk) / 'build-tools/35.0.0'
    signer = str(tools / ('apksigner.bat' if os.name == 'nt' else 'apksigner'))
    aapt = str(tools / ('aapt.exe' if os.name == 'nt' else 'aapt'))
    android = str(Path(args.sdk) / 'platforms/android-36/android.jar')
    badging = subprocess.check_output([aapt, 'dump', 'badging', args.new], text=True, encoding='utf-8')
    code, version = re.search(r"versionCode='(\d+)' versionName='([^']+)'", badging).groups()
    abi = re.search(r"native-code:\s*'([^']+)'", badging).group(1)
    (assets / 'candidate.json').write_text(json.dumps({'version': version, 'versionCode': int(code), 'abi': abi}), encoding='utf-8')

    def sign(source, target, debug=False):
        store = str(Path.home() / '.android/debug.keystore') if debug else properties['storeFile']
        alias = 'androiddebugkey' if debug else properties['keyAlias']
        passwords = dict(env)
        if debug:
            passwords['PIKMELO_TEST_STORE_PASSWORD'] = 'android'
            passwords['PIKMELO_TEST_KEY_PASSWORD'] = 'android'
        subprocess.run([signer, 'sign', '--ks', store, '--ks-key-alias', alias,
                        '--ks-pass', 'env:PIKMELO_TEST_STORE_PASSWORD', '--key-pass', 'env:PIKMELO_TEST_KEY_PASSWORD',
                        '--out', str(target), str(source)], env=passwords, check=True, capture_output=True)

    shutil.copy2(args.old, assets / 'old-version.apk')
    shutil.copy2(args.new, assets / 'valid.apk')
    sign(args.new, assets / 'wrong-signature.apk', debug=True)
    shutil.copy2(args.new, assets / 'damaged-signature.apk')
    with zipfile.ZipFile(assets / 'damaged-signature.apk', 'a') as archive:
        archive.writestr('assets/update-validation-tamper', b'changed after signing')
    with tempfile.TemporaryDirectory(prefix='pikmelo-apk-validation-') as directory:
        directory = Path(directory)
        for name, package in [('wrong-package.apk', 'top.shenyunyao.wrong_player'), ('wrong-abi.apk', 'top.shenyunyao.pikmelo_player')]:
            manifest = directory / 'AndroidManifest.xml'
            manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android"
              package="{package}" android:versionCode="{code}" android:versionName="{version}">
              <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="35" />
              <application android:hasCode="false" android:label="Update validation fixture" />
              </manifest>''', encoding='utf-8')
            unsigned = directory / name
            subprocess.run([aapt, 'package', '-f', '-M', str(manifest), '-I', android, '-F', str(unsigned)], check=True, capture_output=True)
            with zipfile.ZipFile(unsigned, 'a') as archive:
                incompatible = 'armeabi-v7a' if abi != 'armeabi-v7a' else 'x86_64'
                archive.writestr(f'lib/{incompatible}/fixture.so', b'validation fixture')
            sign(unsigned, assets / name)
    print('Prepared six APK signature, package, version and architecture cases.')


if __name__ == '__main__':
    main()
