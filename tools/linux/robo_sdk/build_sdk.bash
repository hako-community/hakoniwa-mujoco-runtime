#!/usr/bin/env bash
# build_sdk.bash -- S1: 箱庭のローカル SDK を <ROBO_ROOT>/sdk/linux-gcc-x64 に作る（初回 約 20〜40 分。ほとんどは vcpkg の Boost）
#
#   bash tools/linux/robo_sdk/build_sdk.bash [--robo <場所>]
#
#   tools/build_hakoniwa_sdk_linux.py を呼ぶ（build_sdk.ps1 の Linux 版）。材料（作業場所の third_party/ の hakoniwa-core-pro・
#   pdu-endpoint、同梱の nlohmann-json）は git archive で読むだけで、中には何も書かない。
#   vcpkg（Boost・GLFW。Windows と同じコミット）と MuJoCo（mujoco.lock の SHA256 で照合）も出力先の中に入る。
#   出力先に SDK が既にあるときは止まる（作り直すときは出力先を退避・削除する）。
#   2 回目からは vcpkg のバイナリキャッシュ（~/.cache/vcpkg/archives）から Boost・GLFW を戻すので速い。
while [[ $# -gt 0 ]]; do case "$1" in --robo) shift; ROBO="$1" ;; *) echo "知らない引数: $1" >&2; exit 2 ;; esac; shift; done
source "$(dirname "${BASH_SOURCE[0]}")/robo_common.bash"
JSON="${RUNTIME_REPO}/external_library/nlohmann-json"
need "${PYTHON}" "Python 3.12"
need "${JSON}/single_include/nlohmann/json.hpp" "同梱の nlohmann-json"
assert_core_third_party
[[ -d "${CORE_DIR}" ]] && die "SDK は既にあります: ${SDK_ROOT}（作り直すときは退避・削除してから）"
step "SDK を作る → ${SDK_ROOT}"
clean_run "${PYTHON}" -B "${RUNTIME_REPO}/tools/build_hakoniwa_sdk_linux.py" \
  --core-third-party "${CORE_TP}" --json-root "${JSON}" --output "${SDK_ROOT}"
okl "SDK: ${SDK_ROOT}"
