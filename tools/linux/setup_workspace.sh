#!/usr/bin/env bash
# setup_workspace.sh -- 新しい Linux PC で、ロボット（armpi・humanoid・cobot）かドローン（hakoniwa-mujoco-drone・companion）を 1 本で建てる。
#                       tools/windows/setup_workspace.ps1 の Linux 版（同じ段 W1〜W7）。
#
#   入口の文書: hakoniwa-mujoco-runtime/docs/START_HERE_linux.md
#
#   cd <作業場所>                                                         # 例 ~/work_robot/work_git（ロボットとドローンは別の作業場所）
#   git clone https://github.com/hako-community/hakoniwa-mujoco-runtime.git
#   bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --robot humanoid,cobot,armpi   # ロボット（初回 約 40 分〜1 時間）
#   bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --robot cobot --with-ncmachine # cobot を加工機と連携する形で
#   bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --drone                       # ドローン（約 5 分）
#   bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --drone --godot --wind        # ドローンの Godot と風況デモも
#   bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --robot cobot --check         # 確かめるだけ
#
#   手順（--from N で途中から。どれも、できているものは飛ばす）:
#     W1 ツール     git・cmake・g++・ninja・python3（3.12・venv）。ロボットは GLFW（libglfw3-dev）・gh・Godot・.NET 8 も見る
#                   ドローンの --godot / --wind は gh・Godot 4.7.1 mono・.NET 8 が必須
#     W2 clone      足りないリポジトリを clone（humanoid は hakoniwa-armpi・hakoniwa-godot-robot〔非公開〕も。
#                   cobot --with-ncmachine は hakoniwa-ncmachine〔非公開〕・image2sim-framework も。ドローンは companion も）
#     W3 依存       各リポジトリの tools/fetch_deps.py（deps.lock の版の runtime・sensor・drone）
#     W4 箱庭コア   tools/hako_core/fetch_third_party.py（<作業場所>/third_party。ロボット・ドローン共通の最新）
#     W5 SDK        ロボット: tools/linux/robo_sdk/setup_robo_sdk.bash（devai_robo。初回 約 30〜50 分）
#                   ドローン: hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash（devai_drone。約 5 分）
#     W6 ロボット   humanoid: setup_hako --from 2（venv・ArmPi のモデル・Godot addon）
#                   cobot: make_venv → （加工機のモデル）→ build → stage_godot_addon     armpi: make_venv → build → stage_godot_addon
#        ビューア   ドローンの --godot: hakoniwa-godot-drone の fetch_native.sh と C# ビルド、--wind: 風況デモの準備
#     W7 確認       ロボット: check_robo_sdk・humanoid の check_env／ドローン: --test で ctest。最後に「次に動かすコマンド」を出す
#
#   --workspace DIR : 作業場所（既定: このリポジトリの親）
#   --robo DIR      : ロボット共通 SDK の場所（既定: 環境変数 DEVAI_ROBO、無ければ <作業場所>/devai_robo）
#   --godot <exe>   : Godot 4.7.1 mono の実行ファイル（既定: 環境変数 GODOT_EXE・GODOT_BIN、無ければ /usr/local/bin/Godot_v4.7*mono*/）
#   --rebuild-sdk   : ロボット: SDK の箱庭コアが lock と違うとき、今の SDK を <SDK>.old-<日時> に退避して作り直す
#                     （箱庭コアがもう lock と同じで一部だけ足りない＝作りかけなら、退避せずに続きを作る）
#                     ドローン: SDK・MuJoCo・venv を作り直す（setup_linux.bash の CLEAN=1）
#   --sdk-from N    : ロボット SDK の「続き」を setup_robo_sdk の S-N から（例 S5 で止まったら --from 5 --sdk-from 5）
#   --with-ncmachine: cobot を加工機と連携する形で建てる（W6 で加工機・台車・パレットのモデルを image2sim-framework で作る）
#   --blender <exe> : モデルの GLB を作る Blender（既定: 環境変数 BLENDER_EXE、無ければ /usr/local/bin/blender-5.2*/blender・PATH）
set -euo pipefail

DRONE=0; ROBOTS=(); GODOT=0; WIND=0; TEST=0; CHECK=0; FROM=1; REBUILD=0; SDK_FROM=1; NC=0; WS=""; ROBO_ARG=""
GODOT_EXE="${GODOT_EXE:-${GODOT_BIN:-}}"; BLENDER="${BLENDER_EXE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --drone) DRONE=1 ;;
    --robot|-Robot) shift; IFS=', ' read -r -a _r <<< "${1:?--robot に humanoid・cobot・armpi を}"; ROBOTS+=("${_r[@]}") ;;
    --godot) GODOT=1; if [[ "${2:-}" == /* ]]; then GODOT_EXE="$2"; shift; fi ;;
    --wind) WIND=1 ;;
    --test) TEST=1 ;;
    --check) CHECK=1 ;;
    --from) shift; FROM="${1:?--from に番号を}" ;;
    --rebuild-sdk) REBUILD=1 ;;
    --sdk-from) shift; SDK_FROM="${1:?--sdk-from に番号を}" ;;
    --with-ncmachine) NC=1 ;;
    --blender) shift; BLENDER="${1:?--blender に実行ファイルを}" ;;
    --robo) shift; ROBO_ARG="${1:?--robo に場所を}" ;;
    --workspace) shift; WS="${1:?--workspace に場所を}" ;;
    -h|--help) sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "知らない引数: $1（-h で一覧）" >&2; exit 2 ;;
  esac
  shift
done
for r in "${ROBOTS[@]}"; do [[ "${r}" =~ ^(humanoid|cobot|armpi)$ ]] || { echo "--robot は humanoid・cobot・armpi（${r} は知らない）" >&2; exit 2; }; done
ROBOT=0; [[ ${#ROBOTS[@]} -gt 0 ]] && ROBOT=1
[[ "${DRONE}" == 1 || "${ROBOT}" == 1 ]] || { echo "--robot humanoid,cobot,armpi か --drone を指定してください（docs/START_HERE_linux.md）" >&2; exit 2; }
[[ "${DRONE}" == 1 && "${ROBOT}" == 1 ]] && { echo "ロボットとドローンは別の作業場所に建てます（箱庭コア以外の SDK が別）。どちらか一方を指定してください" >&2; exit 2; }
[[ "${FROM}" =~ ^[1-7]$ ]] || { echo "--from は 1〜7" >&2; exit 2; }
[[ "${SDK_FROM}" =~ ^[1-5]$ ]] || { echo "--sdk-from は 1〜5" >&2; exit 2; }
HAS_COBOT=0; HAS_HUMANOID=0
for r in "${ROBOTS[@]}"; do [[ "${r}" == cobot ]] && HAS_COBOT=1; [[ "${r}" == humanoid ]] && HAS_HUMANOID=1; done
if [[ "${NC}" == 1 && "${HAS_COBOT}" != 1 ]]; then echo "--with-ncmachine は --robot cobot と一緒に使う" >&2; exit 2; fi

RUNTIME_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -n "${WS}" ]] || WS="$(dirname "${RUNTIME_REPO}")"
mkdir -p "${WS}"; WS="$(cd "${WS}" && pwd)"
ROBO="${ROBO_ARG:-${DEVAI_ROBO:-${WS}/devai_robo}}"
ORG=https://github.com/hako-community
CORE_TOOL="${RUNTIME_REPO}/tools/hako_core/fetch_third_party.py"
ROBO_SDK="${RUNTIME_REPO}/tools/linux/robo_sdk"
export DOTNET_ROOT="${DOTNET_ROOT:-${HOME}/.dotnet}"
[[ -x "${DOTNET_ROOT}/dotnet" ]] && export PATH="${DOTNET_ROOT}:${PATH}"
if [[ -z "${GODOT_EXE}" ]]; then
  GODOT_EXE="$(ls -d /usr/local/bin/Godot_v4.7*mono*/Godot_v*mono*.x86_64 "${HOME}"/Godot_v4.7*mono*/Godot_v*mono*.x86_64 2>/dev/null | sort -V | tail -1 || true)"
fi
if [[ -z "${BLENDER}" ]]; then
  BLENDER="$(ls -d /usr/local/bin/blender-5.2*/blender "${HOME}"/blender-5.2*/blender 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "${BLENDER}" ]] || BLENDER="$(command -v blender || true)"
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

# 作るリポジトリ（名前:種類）。種類 deps = deps.lock を持つ、lfs = LFS、priv = 非公開、- = そのほか。URL が違うものは名前=URL
REPOS=()
if [[ "${ROBOT}" == 1 ]]; then
  for r in "${ROBOTS[@]}"; do
    REPOS+=("hakoniwa-${r}:deps")
    if [[ "${r}" == humanoid ]]; then REPOS+=("hakoniwa-armpi:deps" "hakoniwa-godot-robot:priv"); fi    # ライン2 のアーム・デモのコード
    if [[ "${r}" == cobot && "${NC}" == 1 ]]; then
      REPOS+=("hakoniwa-ncmachine:priv" "image2sim-framework=https://github.com/buildko89/image2sim-framework.git:-")
    fi
  done
  [[ -d "${WS}/hakoniwa-mujoco-drone" ]] && warnl "この作業場所にドローンもあります。ロボットとドローンは別の作業場所を勧めます"
else
  REPOS=("hakoniwa-mujoco-drone:deps" "hakoniwa-drone-companion:deps")
  [[ "${GODOT}" == 1 ]] && REPOS+=("hakoniwa-godot-drone:-")
  [[ "${WIND}" == 1 ]] && REPOS+=("hakoniwa-simenv-4dst:lfs" "hakoniwa-godot-4dst:lfs")
  [[ -d "${WS}/devai_robo" ]] && warnl "この作業場所にロボットの SDK もあります。ロボットとドローンは別の作業場所を勧めます"
fi
# 重複を除く（順は保つ）
declare -A _seen; _u=()
for r in "${REPOS[@]}"; do n="${r%%[:=]*}"; [[ -n "${_seen[${n}]:-}" ]] && continue; _seen[${n}]=1; _u+=("${r}"); done
REPOS=("${_u[@]}")
repo_name() { local r="$1"; printf '%s' "${r%%[:=]*}"; }
repo_kind() { local r="$1"; printf '%s' "${r##*:}"; }
repo_url()  { local r="$1" n; n="$(repo_name "${r}")"; if [[ "${r}" == *=* ]]; then r="${r#*=}"; printf '%s' "${r%:*}"; else printf '%s/%s.git' "${ORG}" "${n}"; fi; }

if [[ "${ROBOT}" == 1 ]]; then KIND="ロボット（$(IFS=・; echo "${ROBOTS[*]}")）"; [[ "${NC}" == 1 ]] && KIND+="＋加工機"
else KIND="ドローン"; [[ "${GODOT}" == 1 ]] && KIND+="＋Godot"; [[ "${WIND}" == 1 ]] && KIND+="＋風況デモ"; fi
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
  if [[ "${ROBOT}" == 1 ]]; then
    # vcpkg（Boost）の初期化に要る道具と、プラントの窓の GLFW（Ubuntu の libglfw3-dev）・OpenGL・Python のヘッダ
    for c in zip unzip tar pkg-config; do command -v "$c" >/dev/null || { ngl "$c が無い（sudo apt install zip unzip tar pkg-config）"; ng=$((ng+1)); }; done
    if [[ -f /usr/lib/x86_64-linux-gnu/cmake/glfw3/glfw3Config.cmake ]]; then okl "GLFW（libglfw3-dev）: $(dpkg-query -W -f='${Version}' libglfw3-dev 2>/dev/null)"
    else ngl "GLFW が無い（sudo apt install libglfw3-dev libgl-dev）"; ng=$((ng+1)); fi
    if [[ -f /usr/include/GL/gl.h ]]; then okl "OpenGL のヘッダ（libgl-dev）"; else ngl "OpenGL のヘッダが無い（sudo apt install libgl-dev）"; ng=$((ng+1)); fi
    if [[ -f "/usr/include/python3.12/Python.h" ]]; then okl "Python のヘッダ（python3-dev）"; else ngl "Python のヘッダが無い（sudo apt install python3-dev。hakopy・C 呼び出し部品を作るのに要る）"; ng=$((ng+1)); fi
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then okl "gh: ログイン済み"
    elif [[ "${HAS_HUMANOID}" == 1 || "${NC}" == 1 ]]; then warnl "gh が無いか未ログイン（非公開の hakoniwa-godot-robot・hakoniwa-ncmachine の clone に権限が要る。gh auth login）"; fi
    if [[ -n "${GODOT_EXE}" && -x "${GODOT_EXE}" ]]; then okl "Godot: ${GODOT_EXE}（$("${GODOT_EXE}" --version 2>/dev/null | tail -1)）"
    else warnl "Godot 4.7.1 mono が無い（ビューアを使うときに要る。--godot <exe> か GODOT_EXE）"; fi
    if command -v dotnet >/dev/null && dotnet --list-sdks 2>/dev/null | grep -q '^8\.'; then okl ".NET 8 SDK: $(dotnet --list-sdks | grep '^8\.' | tail -1)（DOTNET_ROOT=${DOTNET_ROOT}）"
    else warnl ".NET 8 が無い（Godot mono のビューアに要る。dotnet-install.sh --channel 8.0 で ~/.dotnet に）"; fi
    if [[ "${NC}" == 1 ]]; then
      if [[ -n "${BLENDER}" && -x "${BLENDER}" ]]; then okl "Blender: ${BLENDER}"; else warnl "Blender 5.2 が無い（加工機のモデルは GLB なしで作る。--blender <exe>）"; fi
    fi
  fi
  if [[ "${DRONE}" == 1 && ( "${GODOT}" == 1 || "${WIND}" == 1 ) ]]; then
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
    name="$(repo_name "${r}")"; kind="$(repo_kind "${r}")"
    dir="${WS}/${name}"
    if [[ -d "${dir}/.git" ]]; then okl "${name}（あります。触りません）"
    else
      [[ "${kind}" == priv ]] && warnl "${name} は非公開です。hako-community の権限が要ります（gh auth login）"
      run git clone "$(repo_url "${r}")" "${dir}"
    fi
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
    name="$(repo_name "${r}")"; kind="$(repo_kind "${r}")"
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
  if [[ "${ROBOT}" == 1 ]]; then
    stage 5 "ロボット共通 SDK（${ROBO}）"
    core="${ROBO}/sdk/linux-gcc-x64/sdk/hakoniwa-core"
    if [[ -d "${core}" ]]; then
      if bash "${ROBO_SDK}/check_robo_sdk.bash" --robo "${ROBO}"; then
        okl "SDK はそろっている（作り直すなら --rebuild-sdk）"
      else
        lock_core="$(grep -E '^[[:space:]]*hakoniwa-core-pro[[:space:]]*\|' "${RUNTIME_REPO}/tools/hako_core/third_party.lock" | head -1 | cut -d'|' -f4 | tr -d ' ')"
        sdk_core="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sources"]["hakoniwa-core-pro"])' "${ROBO}/sdk/linux-gcc-x64/sdk/sdk_manifest.json" 2>/dev/null || true)"
        if [[ -n "${sdk_core}" && "${sdk_core}" == "${lock_core}" ]]; then
          printf '%s[続き] SDK の箱庭コアは lock と同じ。足りないところを作る（setup_robo_sdk.bash --from %s。退避しない）%s\n' "${c_yel}" "${SDK_FROM}" "${c_off}"
          run bash "${ROBO_SDK}/setup_robo_sdk.bash" --robo "${ROBO}" --from "${SDK_FROM}"
        else
          [[ "${REBUILD}" == 1 ]] || die "W5: SDK が lock と違うか、足りません。作り直すなら --rebuild-sdk（今の SDK は退避）か setup_robo_sdk.bash --from <番号>"
          old="${ROBO}.old-$(date +%Y%m%d-%H%M%S)"
          printf '%s[退避] %s → %s（戻すときは名前を戻す）%s\n' "${c_yel}" "${ROBO}" "${old}" "${c_off}"
          mv "${ROBO}" "${old}"
          run bash "${ROBO_SDK}/setup_robo_sdk.bash" --robo "${ROBO}"
        fi
      fi
    else
      run bash "${ROBO_SDK}/setup_robo_sdk.bash" --robo "${ROBO}"
    fi
  else
    stage 5 "ドローンの SDK とビルド（hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash）"
    if [[ "${REBUILD}" == 1 ]]; then printf '%s[作り直し] devai_drone の SDK・MuJoCo・venv を作り直す（CLEAN=1）%s\n' "${c_yel}" "${c_off}"; fi
    CLEAN="${REBUILD}" run bash "${WS}/hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash"
  fi
fi

# ---------------- W6 ロボットごと／ドローンのビューア ----------------
if [[ "${FROM}" -le 6 && "${CHECK}" != 1 && "${ROBOT}" == 1 ]]; then
  stage 6 "ロボットごとの準備"
  export DEVAI_ROBO="${ROBO}"
  [[ -n "${GODOT_EXE}" ]] && export GODOT_EXE
  for r in "${ROBOTS[@]}"; do
    repo="${WS}/hakoniwa-${r}"
    printf '\n%s--- %s ---%s\n' "${c_cyan}" "${r}" "${c_off}"
    case "${r}" in
      humanoid)
        FACTORY_DEMO_ROBO_ROOT="${ROBO}" run bash "${repo}/scripts/linux/factory_demo/hako/setup_hako.bash" --from 2 ;;
      cobot)
        nc=(); [[ "${NC}" == 1 ]] && nc=(--with-ncmachine)
        run bash "${repo}/scripts/linux/make_venv.bash" --robo "${ROBO}" "${nc[@]}"
        if [[ "${NC}" == 1 ]]; then
          # 加工機・台車・パレット・仮置き台のモデル（hakoniwa-ncmachine/machines/<id>/。git に入っていない生成物）。
          # 無いと build の単体試験 machine_plant_test が落ち、gen_cell もセルを作れない。image2sim-framework で作り、import_model.py で取り込む
          nc_dir="${WS}/hakoniwa-ncmachine"; i2s="${WS}/image2sim-framework"; vpy="${repo}/.venv/bin/python"
          [[ -n "${BLENDER}" ]] && export BLENDER_EXE="${BLENDER}"
          for m in turning_h_k2 cart_large pallet_L stand_temp; do
            if [[ -f "${nc_dir}/machines/${m}/${m}.xml" ]]; then okl "加工機のモデル ${m}（あります。触りません）"; continue; fi
            (cd "${i2s}" && run env -u PYTHONPATH "${vpy}" -B scripts/nc_machine/run_build.py "${m}")     # Blender が無ければ GLB なしで作る
            (cd "${nc_dir}" && run env -u PYTHONPATH "${vpy}" -B tools/import_model.py "${m}")
          done
        fi
        run bash "${repo}/scripts/linux/build.bash" --robo "${ROBO}" "${nc[@]}"
        run bash "${repo}/scripts/linux/stage_godot_addon.bash" --robo "${ROBO}" ;;
      armpi)
        run bash "${repo}/scripts/linux/make_venv.bash" --robo "${ROBO}"
        run bash "${repo}/scripts/linux/build.bash" --robo "${ROBO}"
        g=(); [[ -n "${GODOT_EXE}" && -x "${GODOT_EXE}" ]] && g=(--godot "${GODOT_EXE}")
        run bash "${repo}/scripts/linux/stage_godot_addon.bash" --robo "${ROBO}" "${g[@]}" ;;
    esac
  done
fi
if [[ "${FROM}" -le 6 && "${CHECK}" != 1 && "${DRONE}" == 1 && ( "${GODOT}" == 1 || "${WIND}" == 1 ) ]]; then
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
if [[ "${ROBOT}" == 1 ]]; then
  bash "${ROBO_SDK}/check_robo_sdk.bash" --robo "${ROBO}" || OK=0
  if [[ "${HAS_HUMANOID}" == 1 ]]; then
    FACTORY_DEMO_ROBO_ROOT="${ROBO}" bash "${WS}/hakoniwa-humanoid/scripts/linux/factory_demo/check_env.bash" || OK=0
  fi
elif [[ "${TEST}" == 1 && "${CHECK}" != 1 ]]; then
  bash "${WS}/hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash" test || OK=0
  if [[ "${WIND}" == 1 ]]; then
    GODOT_BIN="${GODOT_EXE}" bash "${WS}/hakoniwa-simenv-4dst/examples/wind_flight_demo/run_wind_flight_demo.sh" --headless || OK=0
  fi
else
  echo "[--] ドローンの ctest は --test で流す（約 25 分）"
fi

printf '\n%s================ 次に動かすコマンド ================%s\n' "${c_cyan}" "${c_off}"
if [[ "${ROBOT}" == 1 ]]; then
  echo "（Godot の窓を出すものは、画面のある PC のデスクトップの端末で。SSH からは Godot なしの確認だけ）"
  for r in "${ROBOTS[@]}"; do
    case "${r}" in
      humanoid)
        echo "humanoid（箱庭版ライブ）: bash ${WS}/hakoniwa-humanoid/scripts/linux/factory_demo/hako/start_hako.bash"
        echo "    Godot なしの確認: bash ${WS}/hakoniwa-humanoid/scripts/linux/factory_demo/hako/check_hako.bash --scenario rezot" ;;
      cobot)
        echo "cobot（Godot で見る）: bash ${WS}/hakoniwa-cobot/scripts/linux/demo.bash"
        echo "    自動の確かめ: bash ${WS}/hakoniwa-cobot/scripts/linux/verify_all.bash（--quick で箱庭なしだけ）"
        [[ "${NC}" == 1 ]] && echo "    NC 加工機との連携（Godot で見る）: docs/START_HERE_linux.md の §4.2" ;;
      armpi)
        echo "armpi: bash ${WS}/hakoniwa-armpi/scripts/linux/run_demo.bash --demo motion（Godot なし: --no-viewer）" ;;
    esac
  done
else
  echo "drone（Origin-01 ×2 機）: bash ${WS}/hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash run"
  echo "    試験: bash ${WS}/hakoniwa-mujoco-drone/tools/local_sdk/setup_linux.bash test"
  if [[ "${GODOT}" == 1 ]]; then
    echo "Godot（オフライン・内蔵 FC）: cd ${WS}/hakoniwa-godot-drone && DOTNET_ROOT=${DOTNET_ROOT} ${GODOT_EXE} --path . res://Scenes/drone_1.tscn"
    echo "    箱庭経由: source ${WS}/hakoniwa-mujoco-drone/tools/local_sdk/env_linux.bash して同じ Godot を起動（HAKO_NATIVE_LIB_DIR が SDK の shakoc を指す）"
  fi
  if [[ "${WIND}" == 1 ]]; then
    echo "風況デモ: bash ${WS}/hakoniwa-simenv-4dst/examples/wind_flight_demo/run_wind_flight_demo.sh [--wind | --live | --modes]"
  fi
fi
if [[ ${#WARN[@]} -gt 0 ]]; then printf '%s注意: %s%s\n' "${c_yel}" "$(IFS=/; echo "${WARN[*]}")" "${c_off}"; fi
MIN=$(( ($(date +%s) - T0 + 30) / 60 ))
if [[ "${OK}" != 1 ]]; then printf '%s[setup_workspace] 確認で足りないもの・失敗があります（%s 分）。上の出力を見てください%s\n' "${c_red}" "${MIN}" "${c_off}"; exit 1; fi
printf '%s[setup_workspace] できました（%s 分）%s\n' "${c_grn}" "${MIN}" "${c_off}"
