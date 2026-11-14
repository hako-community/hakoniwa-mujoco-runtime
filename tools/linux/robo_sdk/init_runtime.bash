#!/usr/bin/env bash
# init_runtime.bash -- S2: 箱庭の実行時設定（共有メモリの場所）を作る（init_runtime.ps1 の Linux 版）
#
#   bash tools/linux/robo_sdk/init_runtime.bash [--robo <場所>] [--mmap-dir /dev/shm/hako_mmap_robo-$USER] [--force]
#
#   <ROBO_ROOT>/runtime/linux-gcc-x64/cpp_core_config.json を書く。全プロセスは HAKO_CONFIG_PATH でこれを指す。
#   共有メモリの場所は、ドローン（/dev/shm/hakoniwa-$USER）と分ける。既定 /dev/shm/hako_mmap_robo-$USER。
#   既にあるときは書き換えない（--force で上書き）。
MMAP=""; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in --robo) shift; ROBO="$1" ;; --mmap-dir) shift; MMAP="$1" ;; --force) FORCE=1 ;; *) echo "知らない引数: $1" >&2; exit 2 ;; esac
  shift
done
source "$(dirname "${BASH_SOURCE[0]}")/robo_common.bash"
cfg="${ROBO_ROOT}/runtime/${PLAT}/cpp_core_config.json"
if [[ -f "${cfg}" && "${FORCE}" != 1 ]]; then echo "[skip] 既にあります: ${cfg}"; cat "${cfg}"; exit 0; fi
MMAP="${MMAP:-/dev/shm/hako_mmap_robo-${USER:-$(id -un)}}"
[[ -w "$(dirname "${MMAP}")" ]] || die "共有メモリの場所 ${MMAP} の親に書けない（--mmap-dir で指定）"
mkdir -p "$(dirname "${cfg}")" "${MMAP}"
printf '{"shm_type":"mmap","core_mmap_path":"%s","asset_timeout_usec":600000000}\n' "${MMAP}" > "${cfg}"
okl "${cfg}"; cat "${cfg}"
