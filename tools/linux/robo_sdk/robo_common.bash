# robo_common.bash -- ロボット共通 SDK（Linux）のスクリプトが最初に読む（source "$(dirname "${BASH_SOURCE[0]}")/robo_common.bash"）
#
#   tools/windows/robo_sdk/robo_common.ps1 の Linux 版。呼ぶ側が先に ROBO・PYTHON を決めていればそれを使う。
#     RUNTIME_REPO : このリポジトリ（hakoniwa-mujoco-runtime）
#     WS           : 作業場所（runtime の親）
#     ROBO_ROOT    : SDK を作る場所（ROBO ＞ 環境変数 DEVAI_ROBO ＞ <作業場所>/devai_robo）
#     PLAT         : linux-gcc-x64
#     SDK_ROOT     : <ROBO_ROOT>/sdk/linux-gcc-x64
#     CORE_DIR     : <SDK_ROOT>/sdk/hakoniwa-core
#     CORE_TP      : <作業場所>/third_party（箱庭コア。tools/hako_core/third_party.lock の版）
#   グローバルな環境（~/.bashrc・/etc）には何も書かない。
set -euo pipefail
ROBO_SDK_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_REPO="$(cd "${ROBO_SDK_TOOLS}/../../.." && pwd)"
WS="$(dirname "${RUNTIME_REPO}")"
PLAT=linux-gcc-x64
ROBO="${ROBO:-${DEVAI_ROBO:-${WS}/devai_robo}}"
mkdir -p "$(dirname "${ROBO}")"
ROBO_ROOT="$(cd "$(dirname "${ROBO}")" && pwd)/$(basename "${ROBO}")"
SDK_ROOT="${ROBO_ROOT}/sdk/${PLAT}"
CORE_DIR="${SDK_ROOT}/sdk/hakoniwa-core"
EP_DIR="${SDK_ROOT}/sdk/hakoniwa-pdu-endpoint"
CORE_TP="${WS}/third_party"
CORE_LOCK_TOOL="${RUNTIME_REPO}/tools/hako_core/fetch_third_party.py"
PYTHON="${PYTHON:-/usr/bin/python3}"     # Ubuntu 24.04 の python3（3.12）
MJ_VER="$(grep -E '^version[[:space:]]*=' "${RUNTIME_REPO}/external_library/mujoco.lock" | cut -d= -f2 | tr -d ' ')"
VCPKG_INST="${SDK_ROOT}/vcpkg/installed/x64-linux"

c_mag=$'\e[35m'; c_grn=$'\e[32m'; c_red=$'\e[31m'; c_yel=$'\e[33m'; c_cyan=$'\e[36m'; c_gry=$'\e[90m'; c_off=$'\e[0m'
step()  { printf '\n%s=== %s ===%s\n' "${c_cyan}" "$*" "${c_off}"; }
okl()   { printf '%s[ok] %s%s\n' "${c_grn}" "$*" "${c_off}"; }
ngl()   { printf '%s[NG] %s%s\n' "${c_red}" "$*" "${c_off}"; }
run()   { printf '%s[run] %s%s\n' "${c_gry}" "$*" "${c_off}"; "$@"; }
die()   { printf '%s[robo_sdk] ✕ %s%s\n' "${c_red}" "$*" "${c_off}" >&2; exit 1; }
need()  { [[ -e "$1" ]] || die "$2 が見つかりません: $1（手順書: hakoniwa-mujoco-runtime/docs/START_HERE_linux.md）"; }

# 旧 SDK（/usr/local/hakoniwa・HAKO_* の環境変数）を外した環境で実行する（このプロセスだけ）
_strip_hako() { printf '%s' "$1" | tr ':' '\n' | grep -v -e '^$' -e '/usr/local/hakoniwa' | paste -sd: || true; }
clean_run() {
  env -u LD_LIBRARY_PATH -u HAKO_BINARY_PATH -u HAKO_CONFIG_PATH -u PYTHONPATH -u PYTHONHOME \
      PATH="$(_strip_hako "${PATH}")" "$@"
}

assert_core_third_party() {
  clean_run "${PYTHON}" -B "${CORE_LOCK_TOOL}" --dest "${CORE_TP}" --verify-only \
    || die "箱庭コア（${CORE_TP}）が lock と違うか、ありません。python3 ${CORE_LOCK_TOOL}（版が違うときは --refresh）"
}

# このシェルだけ SDK を使う環境にする（env_robo.bash・ロボット側の台本から）
use_robo_sdk_env() {
  export HAKO_SDK_ROOT="${CORE_DIR}"
  export HAKO_CONFIG_PATH="${ROBO_ROOT}/runtime/${PLAT}/cpp_core_config.json"
  export HAKO_BINARY_PATH="${CORE_DIR}/share/hakoniwa/offset"
  export PYTHONPATH="${CORE_DIR}/python"          # 置き換え（先頭に足すのではない）
  unset HAKO_CORE_DLL_PATH HAKO_CORE_INC_PATH HAKO_CORE_LIB_PATH HAKO_DRONE_DLL_PATH HAKO_DRONE_INC_PATH HAKO_DRONE_LIB_PATH PYTHONHOME || true
  local ld; ld="$(_strip_hako "${LD_LIBRARY_PATH:-}")"
  # MuJoCo は SDK の公式版。SDK の lib を先に置く（LD_LIBRARY_PATH は RUNPATH より強いので旧 SDK は外す）
  export LD_LIBRARY_PATH="${CORE_DIR}/lib:${SDK_ROOT}/mujoco-${MJ_VER}/lib:${VCPKG_INST}/lib${ld:+:${ld}}"
  export PATH="${CORE_DIR}/bin:${SDK_ROOT}/master/bin:$(_strip_hako "${PATH}")"
  if [[ -f "${HAKO_CONFIG_PATH}" ]]; then
    HAKO_MMAP_DIR="$("${PYTHON}" -c 'import json,sys;print(json.load(open(sys.argv[1]))["core_mmap_path"])' "${HAKO_CONFIG_PATH}")"
    export HAKO_MMAP_DIR
    mkdir -p "${HAKO_MMAP_DIR}"
  fi
}
