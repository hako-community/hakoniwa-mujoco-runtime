"""Build the Windows Hakoniwa SDK from scratch without touching third_party.

third_party is only read: each repository's committed HEAD is exported with
`git archive` (local edits are excluded) and every build tree, install tree and
pip target lives under --output. The upstream install rules that write outside
the prefix (/etc/hakoniwa, Python site-packages) are redirected with DESTDIR.
MuJoCo is the official Windows release pinned in external_library/mujoco.lock
(sha256 checked), not a vcpkg port, so the header and DLL always match the lock.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

VCPKG_URL = 'https://github.com/microsoft/vcpkg.git'
VCPKG_COMMIT = '319504a5326aa870edde46438c5455fa76305a56'  # GLFW 3.5.1, Boost 1.92.0
VCPKG_PORTS = ['boost-asio', 'boost-beast', 'glfw3']  # MuJoCo comes from mujoco.lock, never from vcpkg
MUJOCO_LOCK = Path(__file__).resolve().parents[1] / 'external_library/mujoco.lock'
PIP_PACKAGES = ['hakoniwa-pdu==1.6.9', 'cffi==2.1.1', 'pycparser==3.0']


def quote(value):
    value = str(value)
    if any(c in value for c in ('"', '%', '\n', '\r')):
        raise ValueError('Unsupported command path: ' + value)
    return '"' + value + '"'


def run(command, **kwargs):
    print('[RUN]', ' '.join(map(str, command)), flush=True)
    return subprocess.run([str(c) for c in command], check=True, **kwargs)


def git(repo, *args):
    return run(['git', '-c', f'safe.directory={repo.as_posix()}', '-C', repo, *args],
               capture_output=True).stdout


def export(repo, dest):
    """Extract the committed HEAD of repo (read only) into dest."""
    dest.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(git(repo, 'archive', '--format=tar', 'HEAD'))) as tar:
        tar.extractall(dest, filter='data')
    return git(repo, 'rev-parse', 'HEAD').decode().strip()


def undrive(path):
    """Path as CMake places it under DESTDIR on Windows (drive letter removed)."""
    return Path(*Path(path).parts[1:])


def mujoco_lock():
    entries = {}
    for line in MUJOCO_LOCK.read_text(encoding='utf-8').splitlines():
        key, sep, value = line.partition('=')
        if sep and not key.lstrip().startswith('#'):
            entries[key.strip()] = value.strip()
    return entries['version'], entries['windows_x86_64.url'], entries['windows_x86_64.sha256']


def mujoco_header_version(root):
    """'3.9.0' from mjVERSION_HEADER (3009000) of root/include/mujoco/mujoco.h."""
    for line in (root / 'include/mujoco/mujoco.h').read_text(encoding='utf-8').splitlines():
        if line.startswith('#define mjVERSION_HEADER'):
            n = int(line.split()[2])
            return f'{n // 1000000}.{n // 1000 % 1000}.{n % 1000}'
    raise RuntimeError('mjVERSION_HEADER not found under ' + str(root))


def fetch_mujoco(dest, url, sha256):
    """Download the official zip, check the lock's sha256 and extract it (no top-level folder)."""
    print('[GET]', url, flush=True)
    with urllib.request.urlopen(url) as r:
        data = r.read()
    actual = hashlib.sha256(data).hexdigest()
    if actual != sha256:
        raise RuntimeError(f'MuJoCo sha256 mismatch: {actual} != {sha256}')
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        z.extractall(dest)


def msvc(script, vsdevcmd, lines):
    body = ['@echo off', 'call ' + quote(vsdevcmd) + ' -arch=x64 -host_arch=x64',
            'if errorlevel 1 exit /b 1']
    for line in lines:
        body += [line, 'if errorlevel 1 exit /b 1']
    script.write_text('\n'.join(body) + '\n', encoding='utf-8')
    run(['cmd.exe', '/d', '/c', script])


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--godot-third-party', type=Path, required=True,
                   help='hakoniwa-godot/third_party containing hakoniwa-core-pro and hakoniwa-pdu-endpoint (read only)')
    p.add_argument('--json-root', type=Path, required=True, help='nlohmann-json checkout (read only)')
    p.add_argument('--output', type=Path, required=True, help='New directory for sources, builds and the SDK')
    p.add_argument('--vcpkg-root', type=Path, help='Existing vcpkg to reuse; default clones a pinned one')
    p.add_argument('--mujoco-root', type=Path,
                   help='Existing official MuJoCo of the mujoco.lock version to reuse; default downloads it')
    p.add_argument('--vsdevcmd', type=Path, default=Path(
        'C:/Program Files/Microsoft Visual Studio/2022/Community/Common7/Tools/VsDevCmd.bat'))
    a = p.parse_args()
    if sys.version_info[:2] != (3, 12) or sys.maxsize < 2**32:
        p.error('Run with 64-bit Python 3.12 (hakopy.pyd is built for this interpreter)')
    godot, json_root = a.godot_third_party.resolve(strict=True), a.json_root.resolve(strict=True)
    out = a.output.resolve()
    if out.exists() or 'third_party' in out.parts:
        p.error('output must be a NEW directory outside third_party')
    vsdevcmd = a.vsdevcmd.resolve(strict=True)
    out.mkdir(parents=True)
    src, build, stage = out / 'src', out / 'build', out / 'stage'
    sdk_core, sdk_ep = out / 'sdk/hakoniwa-core', out / 'sdk/hakoniwa-pdu-endpoint'

    # 1. Sources: committed HEADs only.
    core_repo = godot / 'hakoniwa-core-pro'
    commits = {'hakoniwa-core-pro': export(core_repo, src / 'hakoniwa-core-pro')}
    for sub in ('hakoniwa-core-cpp', 'hakoniwa-pdu-registry'):
        placeholder = src / 'hakoniwa-core-pro' / sub
        if placeholder.exists():
            placeholder.rmdir()  # empty gitlink directory
        commits[sub] = export(core_repo / sub, src / 'hakoniwa-core-pro' / sub)
    commits['hakoniwa-pdu-endpoint'] = export(godot / 'hakoniwa-pdu-endpoint', src / 'hakoniwa-pdu-endpoint')
    core_src, ep_src = src / 'hakoniwa-core-pro', src / 'hakoniwa-pdu-endpoint'

    # 2. vcpkg (workspace-local, no global integration).
    vcpkg = a.vcpkg_root.resolve(strict=True) if a.vcpkg_root else out / 'vcpkg'
    if not a.vcpkg_root:
        run(['git', 'clone', '--filter=blob:none', VCPKG_URL, vcpkg])
        run(['git', '-C', vcpkg, 'checkout', '--quiet', VCPKG_COMMIT])
        run(['cmd.exe', '/d', '/c', vcpkg / 'bootstrap-vcpkg.bat', '-disableMetrics'])
    run([vcpkg / 'vcpkg.exe', 'install', *[f'{port}:x64-windows' for port in VCPKG_PORTS],
         '--disable-metrics'])
    toolchain = vcpkg / 'scripts/buildsystems/vcpkg.cmake'

    # 2b. MuJoCo (official release of the locked version; header, import lib and DLL as one pair).
    mj_version, mj_url, mj_sha256 = mujoco_lock()
    mujoco = a.mujoco_root.resolve(strict=True) if a.mujoco_root else out / f'mujoco-{mj_version}'
    if not a.mujoco_root:
        fetch_mujoco(mujoco, mj_url, mj_sha256)
    if mujoco_header_version(mujoco) != mj_version:
        raise RuntimeError(f'MuJoCo under {mujoco} is not {mj_version}')
    for required in ('lib/mujoco.lib', 'bin/mujoco.dll'):
        if not (mujoco / required).is_file():
            raise RuntimeError('MuJoCo file missing: ' + str(mujoco / required))

    # 3. Core: hako libraries, hako-cmd, hakopy.pyd, PDU headers and offsets.
    python = Path(sys.executable).as_posix()
    core_build, core_stage = build / 'hakoniwa-core', stage / 'hakoniwa-core'
    msvc(out / 'build_core.cmd', vsdevcmd, [
        ' '.join(map(quote, ['cmake', '-S', core_src, '-B', core_build, '-G', 'NMake Makefiles',
                             '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={sdk_core.as_posix()}',
                             f'-DHAKO_LOCAL_NLOHMANN_JSON_ROOT={json_root.as_posix()}',
                             f'-DHAKO_CLIENT_OPTION_FILEPATH={(core_src / "cmake-options/win-cmake-options.cmake").as_posix()}',
                             f'-DPython_EXECUTABLE={python}',
                             '-DHAKO_CORE_PRO_BUILD_COMMAND=ON', '-DHAKO_CORE_PRO_BUILD_EXAMPLES=OFF',
                             '-DHAKO_CORE_PRO_BUILD_PYTHON_BINDINGS=ON', '-DHAKO_ENABLE_GTEST=OFF'])),
        'cmake --build ' + quote(core_build),
        f'set "DESTDIR={core_stage}"',
        'cmake --install ' + quote(core_build)])
    shutil.copytree(core_stage / undrive(sdk_core), sdk_core)
    # hako.hpp / hako_master.hpp etc. (used by the owned master) are not in the upstream install rules.
    shutil.copytree(core_src / 'hakoniwa-core-cpp/src/include', sdk_core / 'include', dirs_exist_ok=True)
    config = core_stage / 'etc/hakoniwa/cpp_core_config.json'
    if config.is_file():
        (sdk_core / 'etc/hakoniwa').mkdir(parents=True)
        shutil.copy2(config, sdk_core / 'etc/hakoniwa')
    (sdk_core / 'python').mkdir()
    hakopy = next(core_build.rglob('hakopy.pyd'))
    shutil.copy2(hakopy, sdk_core / 'python')
    if not (sdk_core / 'bin/hako-cmd.exe').is_file():
        (sdk_core / 'bin').mkdir(exist_ok=True)
        shutil.copy2(next(core_build.rglob('hako-cmd.exe')), sdk_core / 'bin')

    # 4. PDU endpoint (static C++ library; Boost from vcpkg).
    ep_build, ep_stage = build / 'hakoniwa-pdu-endpoint', stage / 'hakoniwa-pdu-endpoint'
    msvc(out / 'build_endpoint.cmd', vsdevcmd, [
        ' '.join(map(quote, ['cmake', '-S', ep_src, '-B', ep_build, '-G', 'NMake Makefiles',
                             '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={sdk_ep.as_posix()}',
                             f'-DCMAKE_TOOLCHAIN_FILE={toolchain.as_posix()}',
                             f'-DHAKO_LOCAL_NLOHMANN_JSON_ROOT={json_root.as_posix()}',
                             '-DHAKO_PDU_ENDPOINT_ENABLE_HAKONIWA_CORE=ON',
                             f'-DHAKO_PDU_ENDPOINT_HAKONIWA_CORE_ROOT={sdk_core.as_posix()}',
                             '-DHAKO_PDU_ENDPOINT_BUILD_TOOLS=OFF', '-DHAKO_PDU_ENDPOINT_BUILD_TESTS=OFF',
                             '-DHAKO_PDU_ENDPOINT_BUILD_BENCHMARKS=OFF', '-DHAKO_PDU_ENDPOINT_BUILD_EXAMPLES=OFF'])),
        'cmake --build ' + quote(ep_build),
        f'set "DESTDIR={ep_stage}"',
        'cmake --install ' + quote(ep_build)])
    shutil.copytree(ep_stage / undrive(sdk_ep), sdk_ep)

    # 5. Python packages into the SDK only (never the user's site-packages).
    env = dict(os.environ, PIP_DISABLE_PIP_VERSION_CHECK='1', PYTHONDONTWRITEBYTECODE='1')
    run([sys.executable, '-m', 'pip', 'install', '--no-deps', '--no-compile',
         '--target', sdk_core / 'python', *PIP_PACKAGES, ep_src], env=env)

    # 6. Check and record provenance.
    for required in ['lib/cmake/hakoniwa-core/hakoniwa-coreConfig.cmake', 'bin/hako-cmd.exe', 'python/hakopy.pyd',
                     'include/hakoniwa/pdu/std_msgs/pdu_cpptype_UInt8MultiArray.hpp',
                     'python/hakoniwa_pdu/pdu_msgs/std_msgs/pdu_conv_UInt8MultiArray.py',
                     'share/hakoniwa/offset/std_msgs/UInt8MultiArray.offset']:
        if not (sdk_core / required).is_file():
            raise RuntimeError('SDK file missing: ' + required)
    if not (sdk_ep / 'lib/cmake/hakoniwa_pdu_endpoint/hakoniwa_pdu_endpointConfig.cmake').is_file():
        raise RuntimeError('PDU endpoint package config missing')
    custom = [f.relative_to(out).as_posix() for f in (out / 'sdk').rglob('*SensorHealth*')]
    if custom:
        raise RuntimeError('Unexpected custom SensorHealth files: ' + ', '.join(custom))
    run([sys.executable, '-B', '-c', 'import hakopy, hakoniwa_pdu, hakoniwa_pdu_endpoint'],
        env=dict(env, PYTHONPATH=str(sdk_core / 'python')))
    vcpkg_commit = git(vcpkg, 'rev-parse', 'HEAD').decode().strip()
    shutil.rmtree(stage)
    manifest = {
        'sources': commits, 'vcpkg': {'commit': vcpkg_commit, 'ports': VCPKG_PORTS,
                                      'installed': str(vcpkg / 'installed/x64-windows')},
        'mujoco': {'version': mj_version, 'url': mj_url,
                   'sha256': mj_sha256 if not a.mujoco_root else None, 'root': str(mujoco)},
        'pip': PIP_PACKAGES + ['hakoniwa-pdu-endpoint (exported source)'],
        'python': sys.version, 'json_root': str(json_root),
        'sha256': {f.relative_to(out).as_posix(): hashlib.sha256(f.read_bytes()).hexdigest()
                   for f in sorted((out / 'sdk').rglob('*')) if f.is_file()},
    }
    (out / 'sdk/sdk_manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps({'sdk': str(out / 'sdk'), 'deps': manifest['vcpkg']['installed'],
                      'mujoco': str(mujoco), 'sources': commits, 'files': len(manifest['sha256'])}, indent=2))


if __name__ == '__main__':
    main()
