"""Build SENS-006 from owned sibling repositories without submodule operations."""
import argparse
from pathlib import Path
import subprocess


def quote(value):
    value = str(value)
    if any(c in value for c in ('"', '%', '\n', '\r')):
        raise ValueError('Unsupported command path: ' + value)
    return '"' + value + '"'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--workspace', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--core-sdk', type=Path, required=True)
    parser.add_argument('--endpoint-sdk', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True, help='Installed GLFW prefix (vcpkg installed/x64-windows)')
    parser.add_argument('--mujoco-root', type=Path, required=True,
                        help='Official MuJoCo release (include/, lib/, bin/) of the mujoco.lock version')
    parser.add_argument('--json-include', type=Path, help='Directory containing nlohmann/json.hpp (read only)')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--vsdevcmd', type=Path, default=Path(
        'C:/Program Files/Microsoft Visual Studio/2022/Community/Common7/Tools/VsDevCmd.bat'))
    args = parser.parse_args()
    root, core, endpoint, deps, mujoco = (x.resolve(strict=True) for x in
                                         (args.workspace, args.core_sdk, args.endpoint_sdk, args.deps,
                                          args.mujoco_root))
    output = args.output.resolve()
    if 'third_party' in output.parts or not output.is_relative_to(root):
        parser.error('output must be inside the workspace and outside third_party')
    runtime, sensor = root / 'hakoniwa-mujoco-runtime', root / 'hakoniwa-mujoco-sensor'
    json_include = (args.json_include.resolve(strict=True) if args.json_include else
                    root / 'hakoniwa-humanoid/third_party/nlohmann-json/single_include')
    common = [f'-DCMAKE_PREFIX_PATH={core};{endpoint};{deps}',
              f'-DHAKONIWA_INSTALL_PREFIX={core}', f'-DHAKONIWA_PDU_ENDPOINT_PREFIX={endpoint}',
              f'-DMJRUNTIME_DIR={runtime}', f'-DMJSENSOR_DIR={sensor}',
              f'-DMUJOCO_ROOT={mujoco}', f'-DMUJOCO_INCLUDE_DIR={mujoco}/include',
              f'-DMUJOCO_LIB={mujoco}/lib/mujoco.lib',
              f'-DNLOHMANN_JSON_INCLUDE_DIR={json_include}',
              '-DHAKO_RUNTIME_BUILD_ASSET=ON', '-DCMAKE_BUILD_TYPE=Release',
              '-DCMAKE_CXX_FLAGS=/DWIN32 /D_WINDOWS /DNOMINMAX /EHsc /utf-8']
    builds = [('codec', sensor / 'tests/sensor_health_codec'),
              ('master', runtime / 'tools/master_runner'),
              ('armpi', root / 'hakoniwa-armpi/mujoco_plant'),
              ('humanoid', root / 'hakoniwa-humanoid/mujoco_plant'),
              ('sensor-pipeline-tests', root / 'hakoniwa-humanoid/tests/sensor_pipeline')]
    lines = ['@echo off', 'set PYTHONDONTWRITEBYTECODE=1',
             'call ' + quote(args.vsdevcmd.resolve(strict=True)) + ' -arch=x64 -host_arch=x64',
             'if errorlevel 1 exit /b 1']
    for name, source in builds:
        command = ['cmake', '-S', source, '-B', output / name, '-G', 'NMake Makefiles', *common]
        lines += [' '.join(map(quote, command)), 'if errorlevel 1 exit /b 1',
                  'cmake --build ' + quote(output / name), 'if errorlevel 1 exit /b 1']
    for name in ('codec', 'armpi', 'sensor-pipeline-tests'):
        lines += ['ctest --test-dir ' + quote(output / name) + ' --output-on-failure',
                  'if errorlevel 1 exit /b 1']
    output.mkdir(parents=True, exist_ok=True)
    script = output / 'build_owned.cmd'
    script.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    subprocess.run(['cmd.exe', '/d', '/c', str(script)], check=True)


if __name__ == '__main__':
    main()
