#!/usr/bin/env bash
# build_godot_ext.bash -- S5: hakoniwa-godot（C++ の GDExtension）と型変換を、third_party の外で作る（build_godot_ext.ps1 の Linux 版）
#
#   bash tools/linux/robo_sdk/build_godot_ext.bash [--robo <場所>] [--packages "..."] [--clean] [--collect-only]
#
# ★ hakoniwa-godot は他者のリポジトリ。third_party の中では何も書かない・ビルドしない。
# 1) runtime の third_party/hakoniwa-godot と godot-cpp、作業場所の third_party/ の箱庭コア（core-pro・core-cpp・pdu-registry・
#    pdu-endpoint。tools/hako_core/third_party.lock の版）を、コミット済みの HEAD だけ git archive で <ROBO_ROOT>/src/ へ書き出す
# 2) 書き出したコピーを configure する（nlohmann-json は同梱、Boost は SDK の vcpkg）
# 3) ビルドし、書き出したコピーの tools/message_addon_tool.sh でメッセージ addon を同期する
# 4) addon 一式（addons/hakoniwa・addons/hakoniwa_msgs）を <ROBO_ROOT>/sdk/linux-gcc-x64/godot-addon へ集め、manifest を書く
#
#   --packages: 型変換。既定は Windows と同じ（humanoid・cobot・armpi のビューアが使うもの）
PACKAGES="hako_msgs;std_msgs;geometry_msgs;sensor_msgs;tf2_msgs;builtin_interfaces"; CLEAN=0; COLLECT=0; CONFIG=Release
while [[ $# -gt 0 ]]; do
  case "$1" in
    --robo) shift; ROBO="$1" ;; --packages) shift; PACKAGES="$1" ;; --clean) CLEAN=1 ;; --collect-only) COLLECT=1 ;;
    --configuration) shift; CONFIG="$1" ;;
    *) echo "知らない引数: $1" >&2; exit 2 ;;
  esac
  shift
done
source "$(dirname "${BASH_SOURCE[0]}")/robo_common.bash"
GODOT_REPO="${RUNTIME_REPO}/third_party/hakoniwa-godot"
JSON_ROOT="${RUNTIME_REPO}/external_library/nlohmann-json"
need "${GODOT_REPO}/third_party/godot-cpp/CMakeLists.txt" "hakoniwa-godot（ロボットのリポジトリで python3 tools/fetch_deps.py）"
assert_core_third_party
SRC="${ROBO_ROOT}/src/${PLAT}/hakoniwa-godot"
BUILD="${ROBO_ROOT}/build/${PLAT}/hakoniwa-godot"
TOOLCHAIN="${SDK_ROOT}/vcpkg/scripts/buildsystems/vcpkg.cmake"
OUT="${SDK_ROOT}/godot-addon"
need "${TOOLCHAIN}" "SDK の vcpkg（先に build_sdk.bash）"
if [[ "${CLEAN}" == 1 ]]; then rm -rf "${SRC}" "${BUILD}" "${OUT}"; fi
[[ -d "${SRC}" && "${COLLECT}" != 1 ]] && die "書き出し先が既にあります（--clean で作り直す。集めるだけなら --collect-only）: ${SRC}"

SUBS=(":${GODOT_REPO}"
      "third_party/godot-cpp:${GODOT_REPO}/third_party/godot-cpp"
      "third_party/hakoniwa-core-pro:${CORE_TP}/hakoniwa-core-pro"
      "third_party/hakoniwa-core-pro/hakoniwa-core-cpp:${CORE_TP}/hakoniwa-core-pro/hakoniwa-core-cpp"
      "third_party/hakoniwa-core-pro/hakoniwa-pdu-registry:${CORE_TP}/hakoniwa-core-pro/hakoniwa-pdu-registry"
      "third_party/hakoniwa-pdu-endpoint:${CORE_TP}/hakoniwa-pdu-endpoint")
declare -A COMMITS
for s in "${SUBS[@]}"; do
  rel="${s%%:*}"; repo="${s#*:}"
  COMMITS["${rel:-hakoniwa-godot}"]="$(git -C "${repo}" rev-parse HEAD)"
done

if [[ "${COLLECT}" != 1 ]]; then
  # --- 1) git archive ---
  for s in "${SUBS[@]}"; do
    rel="${s%%:*}"; repo="${s#*:}"
    dest="${SRC}${rel:+/${rel}}"
    mkdir -p "${dest}"
    git -C "${repo}" archive --format=tar HEAD | tar -xf - -C "${dest}"
    echo "[export] ${rel:-hakoniwa-godot} ${COMMITS[${rel:-hakoniwa-godot}]}"
  done
  # --- 2) configure ---
  gen=(); command -v ninja >/dev/null && gen=(-G Ninja)
  clean_run cmake -S "${SRC}" -B "${BUILD}" "${gen[@]}" -DCMAKE_BUILD_TYPE="${CONFIG}" \
    -DHAKONIWA_GODOT_CODEC_PACKAGES="${PACKAGES}" \
    -DHAKONIWA_GODOT_BUILD_TESTS=OFF -DHAKONIWA_GODOT_BUILD_EXAMPLES=OFF -DHAKONIWA_GODOT_MINIMAL_DEP_BUILD=ON \
    -DHAKO_PDU_ENDPOINT_BUILD_BENCHMARKS=OFF -DHAKO_PDU_ENDPOINT_BUILD_TOOLS=OFF -DHAKO_PDU_ENDPOINT_BUILD_TESTS=OFF \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" -DVCPKG_TARGET_TRIPLET=x64-linux \
    -DBoost_DIR="${VCPKG_INST}/share/boost" \
    -DHAKO_LOCAL_NLOHMANN_JSON_ROOT="${JSON_ROOT}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON     -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON '-DCMAKE_INSTALL_RPATH=$ORIGIN'
  # ↑ Linux の GDExtension は箱庭コアの共有ライブラリ（libshakoc・libassets・libconductor）を使う。既定の RUNPATH はビルド木への
  #   相対パスで、ロボットの addon に写すと切れてシステムの旧 SDK（/usr/lib/x86_64-linux-gnu など）を読むことがある。
  #   $ORIGIN（同じフォルダ）にして、4) で addon の bin/ に同梱する（Windows は dll 1 つで完結している）
  # --- 3) build とメッセージ addon の同期（書き出したコピーの上流スクリプト）---
  clean_run cmake --build "${BUILD}" --parallel
  (cd "${SRC}" && bash tools/message_addon_tool.sh sync --packages "${PACKAGES}")
fi

# --- 4) addon を集める ---
mkdir -p "${OUT}/addons"
for a in hakoniwa hakoniwa_msgs; do
  [[ -d "${SRC}/addons/${a}" ]] || die "addon がありません: ${SRC}/addons/${a}"
  rm -rf "${OUT}/addons/${a}"
  cp -a "${SRC}/addons/${a}" "${OUT}/addons/${a}"
done
[[ -f "${OUT}/addons/hakoniwa/bin/libhakoniwa_godot_native.so" ]] || die "GDExtension（libhakoniwa_godot_native.so）ができていない"
# 箱庭コアの共有ライブラリ（GDExtension と同じビルド＝ lock の版）を bin/ に同梱する（実体をコピー。名前は NEEDED の .so.1）
for lib in shakoc assets conductor; do
  f="$(find "${BUILD}/third_party/hakoniwa-core-pro" -name "lib${lib}.so.1" | head -1)"
  [[ -n "${f}" ]] || die "lib${lib}.so.1 がビルド木に無い: ${BUILD}"
  cp -fL "${f}" "${OUT}/addons/hakoniwa/bin/lib${lib}.so.1"
done
bad="$(cd "${OUT}/addons/hakoniwa/bin" && env -u LD_LIBRARY_PATH ldd ./libhakoniwa_godot_native.so | grep -E 'libshakoc|libassets|libconductor' | grep -v "${OUT}/addons/hakoniwa/bin/" || true)"
[[ -z "${bad}" ]] || die "GDExtension が同梱の箱庭コアを読まない（RUNPATH を確かめる）:
${bad}"
src_json="{"; first=1
for k in "${!COMMITS[@]}"; do
  [[ ${first} == 1 ]] || src_json+=","; first=0
  src_json+="\"${k}\":\"${COMMITS[${k}]}\""
done
src_json+="}"
"${PYTHON}" - "${OUT}" "${CONFIG}" "${PACKAGES}" "${src_json}" "${JSON_ROOT}" "${TOOLCHAIN}" <<'PY'
import hashlib, json, sys, datetime
from pathlib import Path
out, conf, pk, src, jr, tc = sys.argv[1:]
out = Path(out)
files = [f for f in sorted(out.rglob('*')) if f.is_file() and f.name != 'godot_addon_manifest.json']
man = {'built': datetime.datetime.now().isoformat(timespec='seconds'), 'configuration': conf, 'packages': pk,
       'sources': json.loads(src), 'json_root': jr, 'toolchain': tc,
       'files': [{'path': f.relative_to(out).as_posix(), 'sha256': hashlib.sha256(f.read_bytes()).hexdigest()} for f in files]}
(out / 'godot_addon_manifest.json').write_text(json.dumps(man, indent=2), encoding='utf-8')
print(f'[done] addon -> {out} ({len(files)} files、型変換 {pk})')
PY
