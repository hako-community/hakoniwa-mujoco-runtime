"""Build the Linux (Ubuntu 24.04, gcc) Hakoniwa robot SDK from scratch without touching third_party.

The Linux counterpart of build_hakoniwa_sdk_windows.py. Same policy and the same pinned versions
(VCPKG_COMMIT, VCPKG_PORTS and PIP_PACKAGES are imported from the Windows builder so the two never drift):
  * third_party is only read: each repository's committed HEAD is exported with `git archive`.
  * Every build tree, install tree and pip target lives under --output.
  * Upstream install rules that point outside the prefix (/etc/hakoniwa, Python site-packages) land under
    a DESTDIR stage and only the prefix part is copied into the SDK.
  * MuJoCo is the official Linux release pinned in external_library/mujoco.lock (sha256 checked).
  * The SDK is self-contained: RUNPATH $ORIGIN;$ORIGIN/../lib, so an old system install
    (/usr/local/hakoniwa registered in ld.so.conf) is never picked up.
Run it from tools/linux/robo_sdk/build_sdk.bash (that wrapper strips the old SDK from the environment).
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_hakoniwa_sdk_windows import VCPKG_URL, VCPKG_COMMIT, VCPKG_PORTS, PIP_PACKAGES  # noqa: E402  same pins

RUNTIME_ROOT = Path(__file__).resolve().parents[1]
MUJOCO_LOCK = RUNTIME_ROOT / 'external_library/mujoco.lock'
TRIPLET = 'x64-linux'
# GLFW: vcpkg の glfw3 は Linux では X11 一式（xcb・xorg の各ポート）をソースから作り、autoconf-archive などの道具を次々に求めて
# 壊れやすい。Linux では Ubuntu の libglfw3-dev（24.04 は 3.3.10。CMake の glfw3Config がある）を使う。
# GLFW はプラントの確認用の窓にしか使わない。Boost は Windows と同じ vcpkg のコミットで作る。
LINUX_VCPKG_PORTS = [port for port in VCPKG_PORTS if port != 'glfw3']
SYSTEM_GLFW = Path('/usr/lib/x86_64-linux-gnu/cmake/glfw3/glfw3Config.cmake')


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


def mujoco_lock():
    entries = {}
    for line in MUJOCO_LOCK.read_text(encoding='utf-8').splitlines():
        key, sep, value = line.partition('=')
        if sep and not key.lstrip().startswith('#'):
            entries[key.strip()] = value.strip()
    return (entries['version'], entries['linux_x86_64.url'], entries['linux_x86_64.sha256'],
            entries.get('linux_x86_64.strip', ''))


def mujoco_header_version(root):
    for line in (root / 'include/mujoco/mujoco.h').read_text(encoding='utf-8').splitlines():
        if line.startswith('#define mjVERSION_HEADER'):
            n = int(line.split()[2])
            return f'{n // 1000000}.{n // 1000 % 1000}.{n % 1000}'
    raise RuntimeError('mjVERSION_HEADER not found under ' + str(root))


def fetch_mujoco(dest, url, sha256, strip):
    """Download the official tar.gz, check the lock's sha256 and extract it without the top folder."""
    print('[GET]', url, flush=True)
    with urllib.request.urlopen(url, timeout=300) as r:
        data = r.read()
    actual = hashlib.sha256(data).hexdigest()
    if actual != sha256:
        raise RuntimeError(f'MuJoCo sha256 mismatch: {actual} != {sha256}')
    stage = dest.with_name(dest.name + '.extract')
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        t.extractall(stage, filter='data')
    shutil.move(str(stage / strip if strip else stage), str(dest))
    shutil.rmtree(stage, ignore_errors=True)


def staged(stage, prefix):
    """Where `cmake --install` with DESTDIR=stage put files meant for the absolute prefix."""
    return stage / Path(prefix).relative_to('/')


def cmake_build(src, build, stage, defs, log):
    gen = ['-G', 'Ninja'] if shutil.which('ninja') else []
    with open(log, 'w', encoding='utf-8', errors='replace') as lf:
        for c in (['cmake', '-S', src, '-B', build, *gen, *defs],
                  ['cmake', '--build', build, '--parallel'],
                  ['cmake', '--install', build]):
            print('[RUN]', ' '.join(map(str, c)), f'(log: {log})', flush=True)
            env = dict(os.environ, DESTDIR=str(stage)) if c[1] == '--install' else None
            r = subprocess.run([str(x) for x in c], stdout=lf, stderr=subprocess.STDOUT, env=env)
            if r.returncode != 0:
                tail = Path(log).read_text(encoding='utf-8', errors='replace').splitlines()[-30:]
                print('\n'.join(tail), flush=True)
                raise SystemExit(f'build failed (rc={r.returncode}); see {log}')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--core-third-party', type=Path, default=RUNTIME_ROOT.parent / 'third_party',
                   help='folder containing hakoniwa-core-pro (with submodules) and hakoniwa-pdu-endpoint (read only)')
    p.add_argument('--json-root', type=Path, default=RUNTIME_ROOT / 'external_library/nlohmann-json')
    p.add_argument('--output', type=Path, required=True, help='New directory for sources, builds and the SDK')
    p.add_argument('--vcpkg-root', type=Path, help='Existing vcpkg to reuse; default clones the pinned one')
    a = p.parse_args()
    if sys.version_info[:2] != (3, 12) or sys.maxsize < 2**32:
        p.error('Run with 64-bit Python 3.12 (hakopy is built for this interpreter)')
    tp, json_root = a.core_third_party.resolve(strict=True), a.json_root.resolve(strict=True)
    out = a.output.resolve()
    if out.exists() or 'third_party' in out.parts:
        p.error('output must be a NEW directory outside third_party')
    if not SYSTEM_GLFW.is_file():
        p.error(f'GLFW が無い: {SYSTEM_GLFW}（sudo apt install libglfw3-dev）')
    out.mkdir(parents=True)
    src, build, stage, logs = out / 'src', out / 'build', out / 'stage', out / 'logs'
    logs.mkdir()
    sdk_core, sdk_ep = out / 'sdk/hakoniwa-core', out / 'sdk/hakoniwa-pdu-endpoint'

    # 1. Sources: committed HEADs only.
    core_repo = tp / 'hakoniwa-core-pro'
    commits = {'hakoniwa-core-pro': export(core_repo, src / 'hakoniwa-core-pro')}
    for sub in ('hakoniwa-core-cpp', 'hakoniwa-pdu-registry'):
        placeholder = src / 'hakoniwa-core-pro' / sub
        if placeholder.exists():
            placeholder.rmdir()
        commits[sub] = export(core_repo / sub, placeholder)
    commits['hakoniwa-pdu-endpoint'] = export(tp / 'hakoniwa-pdu-endpoint', src / 'hakoniwa-pdu-endpoint')
    core_src, ep_src = src / 'hakoniwa-core-pro', src / 'hakoniwa-pdu-endpoint'

    # 2. vcpkg (workspace-local, no global integration). Binary cache: ~/.cache/vcpkg/archives.
    vcpkg = a.vcpkg_root.resolve(strict=True) if a.vcpkg_root else out / 'vcpkg'
    if not a.vcpkg_root:
        run(['git', 'clone', '--filter=blob:none', VCPKG_URL, vcpkg])
        run(['git', '-C', vcpkg, 'checkout', '--quiet', VCPKG_COMMIT])
        run(['sh', vcpkg / 'bootstrap-vcpkg.sh', '-disableMetrics'])
    run([vcpkg / 'vcpkg', 'install', *[f'{port}:{TRIPLET}' for port in LINUX_VCPKG_PORTS], '--disable-metrics'])
    toolchain = vcpkg / 'scripts/buildsystems/vcpkg.cmake'

    # 2b. MuJoCo (official release of the locked version).
    mj_version, mj_url, mj_sha256, mj_strip = mujoco_lock()
    mujoco = out / f'mujoco-{mj_version}'
    fetch_mujoco(mujoco, mj_url, mj_sha256, mj_strip)
    if mujoco_header_version(mujoco) != mj_version:
        raise RuntimeError(f'MuJoCo under {mujoco} is not {mj_version}')
    if not (mujoco / f'lib/libmujoco.so.{mj_version}').is_file():
        raise RuntimeError('MuJoCo file missing: ' + str(mujoco / f'lib/libmujoco.so.{mj_version}'))

    # 3. Core: hako libraries, hako-cmd, hakopy.so, PDU headers and offsets.
    python = Path(sys.executable).as_posix()
    core_build, core_stage = build / 'hakoniwa-core', stage / 'hakoniwa-core'
    cmake_build(core_src, core_build, core_stage, [
        '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={sdk_core.as_posix()}',
        '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
        '-DCMAKE_INSTALL_RPATH=$ORIGIN;$ORIGIN/../lib',
        f'-DHAKO_LOCAL_NLOHMANN_JSON_ROOT={json_root.as_posix()}',
        f'-DFETCHCONTENT_SOURCE_DIR_JSON={json_root.as_posix()}',
        f'-Dnlohmann_json_SOURCE_DIR={json_root.as_posix()}',
        f'-DHAKO_CLIENT_OPTION_FILEPATH={(core_src / "cmake-options/default-cmake-options.cmake").as_posix()}',
        f'-DPython_EXECUTABLE={python}', f'-DHAKO_PYTHON_EXECUTABLE={python}',
        '-DHAKO_CORE_PRO_BUILD_COMMAND=ON', '-DHAKO_CORE_PRO_BUILD_EXAMPLES=OFF',
        '-DHAKO_CORE_PRO_BUILD_PYTHON_BINDINGS=ON', '-DHAKO_ENABLE_GTEST=OFF'], logs / 'core.log')
    shutil.copytree(staged(core_stage, sdk_core), sdk_core)
    # hako.hpp / hako_master.hpp etc. (used by the owned master) are not in the upstream install rules.
    shutil.copytree(core_src / 'hakoniwa-core-cpp/src/include', sdk_core / 'include', dirs_exist_ok=True)
    for cfg in (core_stage / 'etc/hakoniwa/cpp_core_config.json', sdk_core / 'etc/hakoniwa/cpp_core_config.json'):
        if cfg.is_file() and not (sdk_core / 'etc/hakoniwa/cpp_core_config.json').is_file():
            (sdk_core / 'etc/hakoniwa').mkdir(parents=True, exist_ok=True)
            shutil.copy2(cfg, sdk_core / 'etc/hakoniwa')
    (sdk_core / 'python').mkdir(exist_ok=True)
    for f in [f for f in core_build.rglob('hakopy*.so') if f.is_file()]:
        shutil.copy2(f, sdk_core / 'python')
    if not (sdk_core / 'bin/hako-cmd').is_file():
        (sdk_core / 'bin').mkdir(exist_ok=True)
        shutil.copy2(next(f for f in core_build.rglob('hako-cmd') if f.is_file()), sdk_core / 'bin')

    # 4. PDU endpoint (static C++ library, PIC so the cffi module can link it; Boost from vcpkg).
    ep_build, ep_stage = build / 'hakoniwa-pdu-endpoint', stage / 'hakoniwa-pdu-endpoint'
    cmake_build(ep_src, ep_build, ep_stage, [
        '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={sdk_ep.as_posix()}',
        '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
        f'-DCMAKE_TOOLCHAIN_FILE={toolchain.as_posix()}', f'-DVCPKG_TARGET_TRIPLET={TRIPLET}',
        f'-DHAKO_LOCAL_NLOHMANN_JSON_ROOT={json_root.as_posix()}',
        '-DHAKO_PDU_ENDPOINT_ENABLE_HAKONIWA_CORE=ON',
        f'-DHAKO_PDU_ENDPOINT_HAKONIWA_CORE_ROOT={sdk_core.as_posix()}',
        '-DHAKO_PDU_ENDPOINT_BUILD_TOOLS=OFF', '-DHAKO_PDU_ENDPOINT_BUILD_TESTS=OFF',
        '-DHAKO_PDU_ENDPOINT_BUILD_BENCHMARKS=OFF', '-DHAKO_PDU_ENDPOINT_BUILD_EXAMPLES=OFF'], logs / 'endpoint.log')
    shutil.copytree(staged(ep_stage, sdk_ep), sdk_ep)

    # 5. Python packages into the SDK only (never the user's site-packages).
    env = dict(os.environ, PIP_DISABLE_PIP_VERSION_CHECK='1', PYTHONDONTWRITEBYTECODE='1')
    env.pop('PYTHONPATH', None)
    pip_py = out / 'build/pip-venv/bin/python'     # Ubuntu's python3 refuses `pip install` (PEP 668); use a venv's pip
    if not pip_py.is_file():
        run([sys.executable, '-m', 'venv', pip_py.parent.parent])
    run([pip_py, '-m', 'pip', 'install', '--no-deps', '--no-compile',
         '--target', sdk_core / 'python', *PIP_PACKAGES, ep_src], env=env)

    # 6. Check and record provenance.
    for required in ['lib/cmake/hakoniwa-core/hakoniwa-coreConfig.cmake', 'bin/hako-cmd',
                     'include/hakoniwa/pdu/std_msgs/pdu_cpptype_UInt8MultiArray.hpp',
                     'python/hakoniwa_pdu/pdu_msgs/std_msgs/pdu_conv_UInt8MultiArray.py',
                     'share/hakoniwa/offset/std_msgs/UInt8MultiArray.offset']:
        if not (sdk_core / required).is_file():
            raise RuntimeError('SDK file missing: ' + required)
    if not list((sdk_core / 'python').glob('hakopy*.so')):
        raise RuntimeError('SDK file missing: python/hakopy*.so')
    if not (sdk_ep / 'lib/cmake/hakoniwa_pdu_endpoint/hakoniwa_pdu_endpointConfig.cmake').is_file():
        raise RuntimeError('PDU endpoint package config missing')
    # The SDK's own libraries must resolve inside the SDK without LD_LIBRARY_PATH.
    lenv = {k: v for k, v in os.environ.items() if k != 'LD_LIBRARY_PATH'}
    bad = []
    for t in [sdk_core / 'bin/hako-cmd', *sorted((sdk_core / 'lib').glob('lib*.so')),
              *sorted((sdk_core / 'python').glob('hakopy*.so'))]:
        for line in subprocess.run(['ldd', str(t)], capture_output=True, text=True, env=lenv).stdout.splitlines():
            name, _, where = line.strip().partition(' => ')
            if name.split('.so')[0] in ('libassets', 'libconductor', 'libshakoc', 'libhako'):
                loc = where.split(' (')[0]
                if loc == 'not found' or not Path(loc).resolve().is_relative_to(out):
                    bad.append(f'{t.name}: {name} -> {loc}')
    if bad:
        raise RuntimeError('SDK libraries resolve outside the SDK: ' + '; '.join(bad))
    run([sys.executable, '-B', '-c', 'import hakopy, hakoniwa_pdu, hakoniwa_pdu_endpoint'],
        env=dict(env, PYTHONPATH=str(sdk_core / 'python')))
    vcpkg_commit = git(vcpkg, 'rev-parse', 'HEAD').decode().strip()
    shutil.rmtree(stage)
    manifest = {
        'platform': 'linux-gcc-x64',
        'sources': commits, 'vcpkg': {'commit': vcpkg_commit, 'ports': LINUX_VCPKG_PORTS,
                                      'installed': str(vcpkg / f'installed/{TRIPLET}')},
        'system': {'glfw3': subprocess.run(['dpkg-query', '-W', '-f=${Version}', 'libglfw3-dev'],
                                           capture_output=True, text=True).stdout.strip()},
        'mujoco': {'version': mj_version, 'url': mj_url, 'sha256': mj_sha256, 'root': str(mujoco)},
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
