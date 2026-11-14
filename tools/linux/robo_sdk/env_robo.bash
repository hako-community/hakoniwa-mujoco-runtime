# env_robo.bash -- ロボット共通 SDK（<ROBO_ROOT>）を使うシェルにする（このシェルだけ。env_robo.ps1 の Linux 版）
#
#   source hakoniwa-mujoco-runtime/tools/linux/robo_sdk/env_robo.bash     （ROBO=<場所> を先に置けば別の SDK）
#   hako-cmd --help
_er_opts="$-"
source "$(dirname "${BASH_SOURCE[0]}")/robo_common.bash"
use_robo_sdk_env
[[ "${_er_opts}" == *e* ]] || set +e
[[ "${_er_opts}" == *u* ]] || set +u
set +o pipefail 2>/dev/null || true
unset _er_opts
echo "[env_robo] SDK: ${SDK_ROOT}"
echo "[env_robo] HAKO_CONFIG_PATH=${HAKO_CONFIG_PATH}  HAKO_MMAP_DIR=${HAKO_MMAP_DIR:-（設定なし）}"
