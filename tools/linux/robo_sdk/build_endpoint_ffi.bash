#!/usr/bin/env bash
# build_endpoint_ffi.bash -- S4: pdu-endpoint の C 呼び出し部品（_c_endpoint_ffi*.so）を SDK に作る（build_endpoint_ffi.ps1 の Linux 版）
#
#   bash tools/linux/robo_sdk/build_endpoint_ffi.bash [--robo <場所>]
#
#   中継アセット（共有メモリ ⇔ WebSocket）が hakoniwa_pdu_endpoint.c_endpoint を使うのに要る。
#   ビルド用の小さな venv（<ROBO_ROOT>/build/linux-gcc-x64/robo_sdk/ffi-venv、cffi・setuptools）を作って
#   build_endpoint_ffi.py を実行する。ロボットのデモ用の venv には触らない。
while [[ $# -gt 0 ]]; do case "$1" in --robo) shift; ROBO="$1" ;; *) echo "知らない引数: $1" >&2; exit 2 ;; esac; shift; done
source "$(dirname "${BASH_SOURCE[0]}")/robo_common.bash"
need "${CORE_DIR}/python/hakoniwa_pdu_endpoint/build_c_endpoint_ffi.py" "SDK の hakoniwa_pdu_endpoint（先に build_sdk.bash）"
VENV="${ROBO_ROOT}/build/${PLAT}/robo_sdk/ffi-venv"
VPY="${VENV}/bin/python"
[[ -x "${VPY}" ]] || clean_run "${PYTHON}" -m venv "${VENV}"
# cffi は動かす側（ロボットの venv）と同じ版。Python 3.12 以降の cffi は setuptools が要る
clean_run "${VPY}" -m pip install --disable-pip-version-check -q cffi==2.1.1 setuptools==80.9.0
step "C 呼び出し部品を作る"
clean_run "${VPY}" "${ROBO_SDK_TOOLS}/build_endpoint_ffi.py" "${ROBO_ROOT}"
okl "C 呼び出し部品"
