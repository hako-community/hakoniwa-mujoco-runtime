#!/usr/bin/env bash
# check_robo_sdk.bash -- ロボット共通 SDK（Linux）がそろっているかを確かめる（数秒。何も書き換えない。check_robo_sdk.ps1 の Linux 版）
#
#   bash tools/linux/robo_sdk/check_robo_sdk.bash [--robo <場所>]
#   足りないものがあれば終了コード 1。
while [[ $# -gt 0 ]]; do case "$1" in --robo) shift; ROBO="$1" ;; *) echo "知らない引数: $1" >&2; exit 2 ;; esac; shift; done
source "$(dirname "${BASH_SOURCE[0]}")/robo_common.bash"
set +e
ng=0
check() { if [[ -e "$2" ]]; then okl "$1"; else ngl "$1 が無い: $2"; ng=$((ng+1)); fi; }
echo "SDK: ${SDK_ROOT}"
check "箱庭コア（hako-cmd）"          "${CORE_DIR}/bin/hako-cmd"
check "hakopy"                        "$(ls "${CORE_DIR}"/python/hakopy*.so 2>/dev/null | head -1 || echo "${CORE_DIR}/python/hakopy*.so")"
check "pdu-endpoint"                  "${EP_DIR}/lib/libhakoniwa_pdu_endpoint.a"
check "vcpkg（Boost）"               "${VCPKG_INST}/include/boost/version.hpp"
check "GLFW（Ubuntu の libglfw3-dev）"  "/usr/lib/x86_64-linux-gnu/cmake/glfw3/glfw3Config.cmake"
check "MuJoCo ${MJ_VER}"              "${SDK_ROOT}/mujoco-${MJ_VER}/include/mujoco/mujoco.h"
check "実時間マスタ"                   "${SDK_ROOT}/master/bin/hako-realtime-master"
check "共有メモリの設定"               "${ROBO_ROOT}/runtime/${PLAT}/cpp_core_config.json"
check "Godot addon（GDExtension）"    "${SDK_ROOT}/godot-addon/addons/hakoniwa/bin/libhakoniwa_godot_native.so"
check "Godot addon の箱庭コア（同梱）"  "${SDK_ROOT}/godot-addon/addons/hakoniwa/bin/libshakoc.so.1"
gman="${SDK_ROOT}/godot-addon/godot_addon_manifest.json"
sman="${SDK_ROOT}/sdk/sdk_manifest.json"
lock="${RUNTIME_REPO}/tools/hako_core/third_party.lock"
"${PYTHON}" - "${lock}" "${sman}" "${gman}" <<'PY' || ng=$((ng+1))
import json, sys
from pathlib import Path
lock_p, sman, gman = map(Path, sys.argv[1:])
lock = {}
for l in lock_p.read_text(encoding='utf-8').splitlines():
    if l.strip() and not l.lstrip().startswith('#'):
        f = [x.strip() for x in l.split('|')]
        lock[f[0]] = f[3]
G, R, O = '\033[32m', '\033[31m', '\033[0m'
bad = 0
if sman.is_file():
    src = json.loads(sman.read_text(encoding='utf-8'))['sources']
    for n in ('hakoniwa-core-pro', 'hakoniwa-pdu-endpoint'):
        if src.get(n) == lock[n]: print(f'{G}[ok] SDK の {n} = lock（{lock[n][:12]}）{O}')
        else: print(f'{R}[NG] SDK の {n} が {src.get(n)} で、lock（{lock[n]}）と違う → SDK を作り直す（docs/hako_core_update.md）{O}'); bad += 1
else:
    print(f'{R}[NG] sdk_manifest.json が無い: {sman}{O}'); bad += 1
if gman.is_file():
    g = json.loads(gman.read_text(encoding='utf-8'))
    print(f'     型変換: {g["packages"]}')
    if g['sources'].get('third_party/hakoniwa-core-pro') == lock['hakoniwa-core-pro']: print(f'{G}[ok] Godot addon の hakoniwa-core-pro = lock{O}')
    else: print(f'{R}[NG] Godot addon の hakoniwa-core-pro が lock と違う → build_godot_ext.bash --clean{O}'); bad += 1
sys.exit(1 if bad else 0)
PY
if ls "${CORE_DIR}"/python/hakoniwa_pdu_endpoint/_c_endpoint_ffi*.so >/dev/null 2>&1; then okl "pdu-endpoint の C 呼び出し部品"
else ngl "pdu-endpoint の C 呼び出し部品が無い"; ng=$((ng+1)); fi
# C 呼び出し部品は動かすときにも cffi が要るので、cffi の入った S4 のビルド用 venv で確かめる
FFI_PY="${ROBO_ROOT}/build/${PLAT}/robo_sdk/ffi-venv/bin/python"
PY="${PYTHON}"; [[ -x "${FFI_PY}" ]] && PY="${FFI_PY}"
if [[ -d "${CORE_DIR}" ]]; then
  ( use_robo_sdk_env
    "${PY}" -I -c "import sys; sys.path.insert(0, '${CORE_DIR}/python'); import hakopy, hakoniwa_pdu, hakoniwa_pdu_endpoint._c_endpoint_ffi as f; print('[ok] import hakopy・hakoniwa_pdu・_c_endpoint_ffi（python', sys.version.split()[0] + '）')" ) \
    || { ngl "SDK の Python パッケージが import できない"; ng=$((ng+1)); }
fi
if [[ ${ng} -gt 0 ]]; then printf '%s[check_robo_sdk] 足りないもの %s 件（setup_robo_sdk.bash --from <番号> で作り直す）%s\n' "${c_red}" "${ng}" "${c_off}"; exit 1; fi
printf '%s[check_robo_sdk] すべてそろっています%s\n' "${c_grn}" "${c_off}"
