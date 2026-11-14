#!/usr/bin/env bash
# build_master.bash -- S3: 箱庭のマスタを作る → <ROBO_ROOT>/sdk/linux-gcc-x64/master/bin（build_master.ps1 の Linux 版）
#
#   bash tools/linux/robo_sdk/build_master.bash [--robo <場所>] [--which realtime|runner]
#
#   --which realtime（既定）: tools/windows/realtime_master（ソースは Windows・Linux 共通）→ hako-realtime-master
#                            壁時計に合わせて箱庭の時間を進める（ロボットのデモ・セルはこれを使う）
#   --which runner          : tools/master_runner → hako-runtime-master（比較用）
WHICH=realtime
while [[ $# -gt 0 ]]; do
  case "$1" in --robo) shift; ROBO="$1" ;; --which) shift; WHICH="$1" ;; *) echo "知らない引数: $1" >&2; exit 2 ;; esac
  shift
done
source "$(dirname "${BASH_SOURCE[0]}")/robo_common.bash"
case "${WHICH}" in
  realtime) SRC="${RUNTIME_REPO}/tools/windows/realtime_master" ;;
  runner)   SRC="${RUNTIME_REPO}/tools/master_runner" ;;
  *) die "--which は realtime か runner" ;;
esac
BUILD="${ROBO_ROOT}/build/${PLAT}/robo_sdk/master_${WHICH}"
need "${SRC}/CMakeLists.txt" "マスタのソース"
need "${CORE_DIR}" "SDK（先に build_sdk.bash）"
step "マスタ（${WHICH}）を作る"
gen=(); command -v ninja >/dev/null && gen=(-G Ninja)
clean_run cmake -S "${SRC}" -B "${BUILD}" "${gen[@]}" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${CORE_DIR}" -DCMAKE_INSTALL_PREFIX="${SDK_ROOT}/master" \
  -DCMAKE_INSTALL_RPATH="${CORE_DIR}/lib"
clean_run cmake --build "${BUILD}" --parallel
clean_run cmake --install "${BUILD}"
okl "${WHICH} -> ${SDK_ROOT}/master/bin"
