# env_robo.ps1 — ロボット共通 SDK（<RoboRoot>）を使うシェルにする（このプロセスだけ。グローバルは変えない）
#
#   . ..\hakoniwa-mujoco-runtime\tools\windows\robo_sdk\env_robo.ps1 [-Robo D:\work_build\devai_robo]   （先頭の「. 」で読み込む）
#   hako-cmd.exe --help
param([string]$Robo = "")
$Python = ""; $VsDevCmd = ""
. "$PSScriptRoot\robo_common.ps1"
Use-RoboSdkEnv
Write-Host "[env_robo] SDK: $SdkRoot"
