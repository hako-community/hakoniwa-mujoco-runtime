#!/usr/bin/env bash
# setup_robo_sdk.bash -- ロボット共通 SDK（Linux）を最初から順に作る（S1〜S5 をまとめて実行。setup_robo_sdk.ps1 の Linux 版）
#
#   bash hakoniwa-mujoco-runtime/tools/linux/robo_sdk/setup_robo_sdk.bash [--robo <作業場所>/devai_robo] [--from 3] [--mmap-dir DIR]
#
#     S0 （最初に）箱庭コアを作業場所の third_party/ に用意・照合（tools/hako_core/fetch_third_party.py）
#     S1 build_sdk.bash          SDK（箱庭コア・pdu-endpoint・vcpkg・MuJoCo・hakopy）
#     S2 init_runtime.bash       実行時設定（共有メモリの場所。既定 /dev/shm/hako_mmap_robo-$USER）
#     S3 build_master.bash       壁時計に合わせて進めるマスタ（hako-realtime-master）
#     S4 build_endpoint_ffi.bash pdu-endpoint の C 呼び出し部品
#     S5 build_godot_ext.bash    hakoniwa-godot の GDExtension と型変換（third_party の外で作る）
#     → 最後に check_robo_sdk.bash で確かめる
FROM=1; MMAP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --robo) shift; ROBO="$1" ;; --from) shift; FROM="$1" ;; --mmap-dir) shift; MMAP_ARGS=(--mmap-dir "$1") ;;
    *) echo "知らない引数: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "${FROM}" =~ ^[1-5]$ ]] || { echo "--from は 1〜5" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/robo_common.bash"
T0=$(date +%s)
echo "[setup_robo_sdk] SDK: ${ROBO_ROOT} / Python: ${PYTHON}"
printf '\n%s##### S0 箱庭コア（%s） #####%s\n' "${c_mag}" "${CORE_TP}" "${c_off}"
clean_run "${PYTHON}" -B "${CORE_LOCK_TOOL}" --dest "${CORE_TP}" \
  || die "S0 箱庭コアで止まりました（版が違うなら python3 ${CORE_LOCK_TOOL} --refresh）"
STEPS=("build_sdk.bash" "init_runtime.bash" "build_master.bash" "build_endpoint_ffi.bash" "build_godot_ext.bash")
for ((i = FROM; i <= ${#STEPS[@]}; i++)); do
  s="${STEPS[$((i - 1))]}"
  a=(--robo "${ROBO_ROOT}")
  [[ "${s}" == init_runtime.bash ]] && a+=("${MMAP_ARGS[@]}")
  [[ "${s}" == build_godot_ext.bash ]] && a+=(--clean)     # 途中で止まって再開したとき、前回の書き出しを消して作り直す
  printf '\n%s##### S%s %s #####%s\n' "${c_mag}" "${i}" "${s}" "${c_off}"
  bash "${ROBO_SDK_TOOLS}/${s}" "${a[@]}" || die "S${i} ${s} で止まりました。直してから --from ${i} で再開できます"
done
echo
bash "${ROBO_SDK_TOOLS}/check_robo_sdk.bash" --robo "${ROBO_ROOT}" || die "check_robo_sdk.bash で足りないものがあります"
printf '%s[done] ロボット共通 SDK ができました（%s 分）: %s%s\n' "${c_grn}" "$(( ($(date +%s) - T0 + 30) / 60 ))" "${ROBO_ROOT}" "${c_off}"
