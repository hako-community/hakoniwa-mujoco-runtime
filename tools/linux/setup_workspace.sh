#!/usr/bin/env bash
# setup_workspace.sh -- 新しい Linux PC で、ドローン（hakoniwa-mujoco-drone・companion）を 1 本で建てる。
#                       tools/windows/setup_workspace.ps1 -Drone の Linux 版（同じ段 W1〜W7）。
#
#   入口の文書: hakoniwa-mujoco-runtime/docs/START_HERE_linux.md
#
#   mkdir -p ~/work_drone/work_git && cd ~/work_drone/work_git           # 作業場所
#   git clone https://github.com/hako-community/hakoniwa-mujoco-runtime.git
#   bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --drone                 # SDK・ビルドまで（約 5 分）
#   bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --drone --godot --wind  # Godot と風況デモも
#   bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --drone --check         # 確かめるだけ
#
#   手順（--from N で途中から。どれも、できているものは飛ばす）:
#     W1 ツール     git・cmake・g++・ninja・python3（3.12・venv）。--godot / --wind は gh・Godot 4.7.1 mono・.NET 8 も
#     W2 clone      足りないリポジトリを clone（drone・companion。--godot は hakoniwa-godot-drone、
#                   --wind は hakoniwa-simenv-4dst・hakoniwa-godot-4dst〔git-lfs〕も）
#     W3 依存       各リポジトリの tools/fetch_deps.py（deps.lock の版の runtime・sensor・drone）
#     W4 箱庭コア   tools/hako_core/fetch_third_party.py（<作業場所>/third_party。ロボット・ドローン共通の最新）
#     W5 SDK        hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash（devai_drone。SDK・MuJoCo・venv・ビルド 約 5 分）
#     W6 ビューア   --godot: hakoniwa-godot-drone の fetch_native.sh（libhakodrone.so）と C# ビルド
#                   --wind:  envdata（fetch_envdata.sh）・devai_windpj/.venv（netCDF4）・hakoniwa-godot-4dst の取り込みと C# ビルド
#     W7 確認       --test で ctest（drone 約 11 分・companion 約 15 分）。--wind なら風況デモのヘッドレス確認も。
#                   最後に「次に動かすコマンド」を出す
#
#   --workspace DIR : 作業場所（既定: このリポジトリの親）
#   --godot <exe>   : Godot 4.7.1 mono の実行ファイル（既定: 環境変数 GODOT_BIN、無ければ /usr/local/bin/Godot_v4.7*mono*/）
#   --rebuild-sdk   : SDK・MuJoCo・venv を作り直す（setup_linux.bash の CLEAN=1）
set -euo pipefail

DRONE=0; GODOT=0; WIND=0; TEST=0; CHECK=0; FROM=1; REBUILD=0; WS=""; GODOT_EXE="${GODOT_BIN:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --drone) DRONE=1 ;;
    --godot) GODOT=1; if [[ "${2:-}" == /* ]]; then GODOT_EXE="$2"; shift; fi ;;
    --wind) WIND=1 ;;
    --test) TEST=1 ;;
    --check) CHECK=1 ;;
    --from) shift; FROM="${1:?--from に番号を}" ;;
    --rebuild-sdk) REBUILD=1 ;;
    --workspace) shift; WS="${1:?--workspace に場所を}" ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --robot|-Robot) echo "ロボット（armpi・humanoid・cobot）の Linux 版はまだ無い（Windows の setup_workspace.ps1 -Robot）" >&2; exit 2 ;;
    *) echo "知らない引数: $1（-h で一覧）" >&2; exit 2 ;;
  esac
  shift
done
[[ "${DRONE}" == 1 ]] || { echo "--drone を指定してください（docs/START_HERE_linux.md）" >&2; exit 2; }
[[ "${FROM}" =~ ^[1-7]$ ]] || { echo "--from は 1〜7" >&2; exit 2; }

RUNTIME_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -n "${WS}" ]] || WS="$(dirname "${RUNTIME_REPO}")"
mkdir -p "${WS}"; WS="$(cd "${WS}" && pwd)"
ORG=https://github.com/hako-community
CORE_TOOL="${RUNTIME_REPO}/tools/hako_core/fetch_third_party.py"
export DOTNET_ROOT="${DOTNET_ROOT:-${HOME}/.dotnet}"
[[ -x "${DOTNET_ROOT}/dotnet" ]] && export PATH="${DOTNET_ROOT}:${PATH}"
if [[ -z "${GODOT_EXE}" ]]; then
  GODOT_EXE="$(ls -d /usr/local/bin/Godot_v4.7*mono*/Godot_v*mono*.x86_64 "${HOME}"/Godot_v4.7*mono*/Godot_v*mono*.x86_64 2>/dev/null | sort -V | tail -1 || true)"
fi
T0=$(date +%s)
WARN=()

c_mag=$'\e[35m'; c_grn=$'\e[32m'; c_red=$'\e[31m'; c_yel=$'\e[33m'; c_cyan=$'\e[36m'; c_gry=$'\e[90m'; c_off=$'\e[0m'
stage() { printf '\n%s##### W%s %s #####%s\n' "${c_mag}" "$1" "$2" "${c_off}"; }
okl()   { printf '%s[ok] %s%s\n' "${c_grn}" "$*" "${c_off}"; }
ngl()   { printf '%s[NG] %s%s\n' "${c_red}" "$*" "${c_off}"; }
warnl() { printf '%s[--] %s%s\n' "${c_yel}" "$*" "${c_off}"; WARN+=("$*"); }
run()   { printf '%s[run] %s%s\n' "${c_gry}" "$*" "${c_off}"; "$@"; }
die()   { printf '%s[setup_workspace] ✕ %s%s\n' "${c_red}" "$*" "${c_off}" >&2; exit 1; }

# 作るリポジトリ（名前・deps.lock を持つか・LFS か）
REPOS=("hakoniwa-mujoco-drone:deps" "hakoniwa-drone-companion:deps")
[[ "${GODOT}" == 1 ]] && REPOS+=("hakoniwa-godot-drone:-")
[[ "${WIND}" == 1 ]] && REPOS+=("hakoniwa-simenv-4dst:lfs" "hakoniwa-godot-4dst:lfs")
KIND="ドローン"; [[ "${GODOT}" == 1 ]] && KIND+="＋Godot"; [[ "${WIND}" == 1 ]] && KIND+="＋風況デモ"
printf '%s[setup_workspace] %s / 作業場所 %s / runtime %s%s\n' "${c_cyan}" "${KIND}" "${WS}" "${RUNTIME_REPO}" "${c_off}"

# ---------------- W1 ツール ----------------
if [[ "${FROM}" -le 1 ]]; then
  stage 1 "ツール"
  ng=0
  for c in git cmake g++ make curl; do
    if command -v "$c" >/dev/null; then okl "$c: $("$c" --version 2>&1 | head -1)"; else ngl "$c が無い"; ng=$((ng+1)); fi
  done
  if command -v ninja >/dev/null; then okl "ninja: $(ninja --version)"; else warnl "ninja が無い（無くても建つが遅い。sudo apt install ninja-build）"; fi
  if command -v python3 >/dev/null; then
    v="$(env -u PYTHONPATH python3 -c 'import sys,struct;print("%d.%d %d"%(sys.version_info[0],sys.version_info[1],struct.calcsize("P")*8))')"
    if [[ "${v}" == "3.12 64" ]]; then okl "Python 3.12（64 ビット）: $(command -v python3)"; else ngl "python3 が 3.12（64 ビット）でない（${v}）"; ng=$((ng+1)); fi
    if env -u PYTHONPATH python3 -c 'import venv, ensurepip' 2>/dev/null; then okl "python3 の venv"; else ngl "python3 の venv が使えない（sudo apt install python3-venv）"; ng=$((ng+1)); fi
  else ngl "python3 が無い"; ng=$((ng+1)); fi
  if [[ -d /usr/local/hakoniwa ]]; then
    okl "旧 SDK /usr/local/hakoniwa がある（使わない。各スクリプトがこのプロセスだけ外す）"
  fi
  if [[ "${GODOT}" == 1 || "${WIND}" == 1 ]]; then
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then okl "gh: ログイン済み"
    else ngl "gh が無いか未ログイン（sudo apt install gh → gh auth login。非公開の Release を取る）"; ng=$((ng+1)); fi
    if [[ -n "${GODOT_EXE}" && -x "${GODOT_EXE}" ]]; then okl "Godot: ${GODOT_EXE}（$("${GODOT_EXE}" --version 2>/dev/null | tail -1)）"
    else ngl "Godot 4.7.1 mono が無い（--godot <exe> か GODOT_BIN）"; ng=$((ng+1)); fi
    if command -v dotnet >/dev/null && dotnet --list-sdks 2>/dev/null | grep -q '^8\.'; then okl ".NET 8 SDK: $(dotnet --list-sdks | grep '^8\.' | tail -1)"
    else ngl ".NET 8 SDK が無い（dotnet-install.sh --channel 8.0 で ~/.dotnet に。DOTNET_ROOT）"; ng=$((ng+1)); fi
  fi
  if [[ "${WIND}" == 1 ]]; then
    if git lfs version >/dev/null 2>&1; then okl "git-lfs: $(git lfs version | cut -d' ' -f1)"; else ngl "git-lfs が無い（sudo apt install git-lfs）"; ng=$((ng+1)); fi
  fi
  [[ "${ng}" == 0 ]] || die "W1: 足りないツールが ${ng} 件あります（docs/START_HERE_linux.md の「1. ツール」）"
fi

# ---------------- W2 clone ----------------
if [[ "${FROM}" -le 2 && "${CHECK}" != 1 ]]; then
  stage 2 "clone"
  for r in "${REPOS[@]}"; do
    name="${r%%:*}"; kind="${r##*:}"
    dir="${WS}/${name}"
    if [[ -d "${dir}/.git" ]]; then okl "${name}（あります。触りません）"
    elif [[ "${kind}" == lfs ]]; then run git clone "${ORG}/${name}.git" "${dir}"
    else run git clone "${ORG}/${name}.git" "${dir}"; fi
    if [[ "${kind}" == lfs ]]; then
      # LFS の実体（地形・建物・航空写真）。git-lfs が clone の前に無かったときは指し示しだけなので取り直す
      git -C "${dir}" lfs install --local >/dev/null
      run git -C "${dir}" lfs pull
    fi
  done
fi

# ---------------- W3 依存（deps.lock） ----------------
if [[ "${FROM}" -le 3 ]]; then
  stage 3 "依存（各リポジトリの deps.lock）"
  for r in "${REPOS[@]}"; do
    name="${r%%:*}"; kind="${r##*:}"
    [[ "${kind}" == deps ]] || continue
    fd="${WS}/${name}/tools/fetch_deps.py"
    [[ -f "${fd}" ]] || die "${fd} が無い（W2 の clone を先に）"
    a=(-B "${fd}"); [[ "${CHECK}" == 1 ]] && a+=(--check)
    run env -u PYTHONPATH python3 "${a[@]}" \
      || die "W3: ${name} の deps.lock と違う。runtime を clone したあとに runtime だけ新しくなったなら、表示の「lock の版にする」を流してから --from 3"
  done
fi

# ---------------- W4 箱庭コア ----------------
if [[ "${FROM}" -le 4 ]]; then
  stage 4 "箱庭コア（${WS}/third_party。tools/hako_core/third_party.lock）"
  a=(-B "${CORE_TOOL}" --dest "${WS}/third_party"); [[ "${CHECK}" == 1 ]] && a+=(--verify-only)
  env -u PYTHONPATH python3 "${a[@]}" \
    || die "W4: third_party の版が lock と違います。上流の最新に合わせて取り直すなら: python3 ${CORE_TOOL} --refresh（今のものは退避。中身は触らない）"
fi

# ---------------- W5 SDK ----------------
if [[ "${FROM}" -le 5 && "${CHECK}" != 1 ]]; then
  stage 5 "ドローンの SDK とビルド（hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash）"
  if [[ "${REBUILD}" == 1 ]]; then printf '%s[作り直し] devai_drone の SDK・MuJoCo・venv を作り直す（CLEAN=1）%s\n' "${c_yel}" "${c_off}"; fi
  CLEAN="${REBUILD}" run bash "${WS}/hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash"
fi

# ---------------- W6 ビューア ----------------
if [[ "${FROM}" -le 6 && "${CHECK}" != 1 && ( "${GODOT}" == 1 || "${WIND}" == 1 ) ]]; then
  stage 6 "ビューア（Godot）"
  if [[ "${GODOT}" == 1 ]]; then
    printf '\n%s--- hakoniwa-godot-drone ---%s\n' "${c_cyan}" "${c_off}"
    run bash "${WS}/hakoniwa-godot-drone/tools/fetch_native.sh"
    run "${GODOT_EXE}" --headless --import --path "${WS}/hakoniwa-godot-drone" >/dev/null 2>&1 || warnl "hakoniwa-godot-drone の取り込み（--import）が 0 以外で終わった"
    run dotnet build "${WS}/hakoniwa-godot-drone/hakoniwa_1.csproj" -nologo -v q
  fi
  if [[ "${WIND}" == 1 ]]; then
    printf '\n%s--- 風況デモ（hakoniwa-simenv-4dst・hakoniwa-godot-4dst） ---%s\n' "${c_cyan}" "${c_off}"
    demo="${WS}/hakoniwa-simenv-4dst/examples/wind_flight_demo"
    run bash "${demo}/scripts/fetch_envdata.sh" --workspace "${WS}"
    vpy="${WS}/devai_windpj/.venv/bin/python"
    if [[ ! -x "${vpy}" ]]; then run env -u PYTHONPATH python3 -m venv "${WS}/devai_windpj/.venv"; fi
    run env -u PYTHONPATH "${vpy}" -m pip install -q -r "${demo}/requirements-wind.txt"
    run "${GODOT_EXE}" --headless --import --path "${WS}/hakoniwa-godot-4dst" >/dev/null 2>&1 || warnl "hakoniwa-godot-4dst の取り込み（--import）が 0 以外で終わった"
    run dotnet build "${WS}/hakoniwa-godot-4dst" -nologo -v q
  fi
fi

# ---------------- W7 確認 ----------------
stage 7 "確認"
OK=1
if [[ "${TEST}" == 1 && "${CHECK}" != 1 ]]; then
  bash "${WS}/hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash" test || OK=0
  if [[ "${WIND}" == 1 ]]; then
    GODOT_BIN="${GODOT_EXE}" bash "${WS}/hakoniwa-simenv-4dst/examples/wind_flight_demo/run_wind_flight_demo.sh" --headless || OK=0
  fi
else
  echo "[--] ドローンの ctest は --test で流す（約 25 分）"
fi

printf '\n%s================ 次に動かすコマンド ================%s\n' "${c_cyan}" "${c_off}"
echo "drone（Origin-01 ×2 機）: bash ${WS}/hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash run"
echo "    試験: bash ${WS}/hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash test"
if [[ "${GODOT}" == 1 ]]; then
  echo "Godot（オフライン・内蔵 FC）: cd ${WS}/hakoniwa-godot-drone && DOTNET_ROOT=${DOTNET_ROOT} ${GODOT_EXE} --path . res://Scenes/drone_1.tscn"
  echo "    箱庭経由: source ${WS}/hakoniwa-mujoco-drone/tools/local_sdk/env_linux.bash して同じ Godot を起動（HAKO_NATIVE_LIB_DIR が SDK の shakoc を指す）"
fi
if [[ "${WIND}" == 1 ]]; then
  echo "風況デモ: bash ${WS}/hakoniwa-simenv-4dst/examples/wind_flight_demo/run_wind_flight_demo.sh [--wind | --live | --modes]"
fi
if [[ ${#WARN[@]} -gt 0 ]]; then printf '%s注意: %s%s\n' "${c_yel}" "$(IFS=/; echo "${WARN[*]}")" "${c_off}"; fi
MIN=$(( ($(date +%s) - T0 + 30) / 60 ))
if [[ "${OK}" != 1 ]]; then printf '%s[setup_workspace] 確認で失敗があります（%s 分）。上の出力を見てください%s\n' "${c_red}" "${MIN}" "${c_off}"; exit 1; fi
printf '%s[setup_workspace] できました（%s 分）%s\n' "${c_grn}" "${MIN}" "${c_off}"
