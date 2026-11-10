# build_master.ps1 — S3: 箱庭のマスタを作る → <RoboRoot>\sdk\windows-msvc-x64\master\bin
#
#   powershell -ExecutionPolicy Bypass -File tools\windows\robo_sdk\build_master.ps1 [-Robo <場所>] [-Which realtime|runner]
#
#   -Which realtime（既定）: tools\windows\realtime_master → hako-realtime-master.exe
#                            壁時計に合わせて箱庭の時間を進める（ロボットのデモ・セルはこれを使う）
#   -Which runner          : tools\master_runner → hako-runtime-master.exe（比較用。Windows では sleep の分解能のため実時間の 0.14 倍）
param([string]$Robo = "", [string]$Python = "", [string]$VsDevCmd = "", [ValidateSet("realtime", "runner")][string]$Which = "realtime")
. "$PSScriptRoot\robo_common.ps1"
$Src = if ($Which -eq "runner") { Join-Path $RuntimeRepo "tools\master_runner" } else { Join-Path $RuntimeRepo "tools\windows\realtime_master" }
$Build = Join-Path $RoboRoot "build\$Plat\robo_sdk\master_$Which"
$OutDir = (Join-Path $SdkRoot "master") -replace "\\", "/"
Assert-Path $Src "マスタのソース"
Assert-Path $CoreDir "SDK（先に build_sdk.ps1）"
Write-Step "マスタ（$Which）を作る"
Invoke-Native "cmake" @("-S", ($Src -replace "\\", "/"), "-B", $Build, "-G", "Visual Studio 17 2022", "-A", "x64", "-DCMAKE_PREFIX_PATH=$($CoreDir -replace '\\', '/')", "-DCMAKE_INSTALL_PREFIX=$OutDir")
Invoke-Native "cmake" @("--build", $Build, "--config", "Release")
Invoke-Native "cmake" @("--install", $Build, "--config", "Release")
Write-Host "[done] $Which -> $OutDir/bin" -ForegroundColor Green
