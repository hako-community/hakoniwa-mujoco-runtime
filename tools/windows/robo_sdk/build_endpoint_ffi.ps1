# build_endpoint_ffi.ps1 — S4: pdu-endpoint の C 呼び出し部品（_c_endpoint_ffi.pyd）を SDK に作る
#
#   powershell -ExecutionPolicy Bypass -File tools\windows\robo_sdk\build_endpoint_ffi.ps1 [-Robo <場所>]
#
#   中継アセット（共有メモリ ⇔ WebSocket）が hakoniwa_pdu_endpoint.c_endpoint を使うのに要る。
#   SDK の pdu-endpoint（静的ライブラリ）と箱庭コアを pyd に静的リンクするので、DLL は要らない。
#   ビルド用の小さな venv（<RoboRoot>\build\windows-msvc-x64\robo_sdk\ffi-venv、cffi・setuptools）を作り、
#   VS 2022 x64 の開発者環境の中で build_endpoint_ffi.py を実行する。ロボットのデモ用の venv には触らない。
param([string]$Robo = "", [string]$Python = "", [string]$VsDevCmd = "")
. "$PSScriptRoot\robo_common.ps1"
Assert-Path $Python "Python 3.12（64 ビット）"
Assert-Path $VsDevCmd "Visual Studio 2022 の VsDevCmd.bat（-VsDevCmd で指定）"
Assert-Path (Join-Path $CoreDir "python\hakoniwa_pdu_endpoint\build_c_endpoint_ffi.py") "SDK の hakoniwa_pdu_endpoint（先に build_sdk.ps1）"
$Venv = Join-Path $RoboRoot "build\$Plat\robo_sdk\ffi-venv"
$Vpy = Join-Path $Venv "Scripts\python.exe"
$env:PYTHONPATH = ""
if (-not (Test-Path $Vpy)) { Invoke-Native $Python @("-m", "venv", $Venv) }
# cffi は動かす側（ロボットの venv）と同じ版。Python 3.12 以降の cffi は setuptools が要る
Invoke-Native $Vpy @("-m", "pip", "install", "--disable-pip-version-check", "-q", "cffi==2.1.1", "setuptools==80.9.0")
$py = Join-Path $PSScriptRoot "build_endpoint_ffi.py"
$cmd = "call `"$VsDevCmd`" -arch=x64 -host_arch=x64 >nul && set DISTUTILS_USE_SDK=1&& set MSSdk=1&& set PYTHONPATH=&& `"$Vpy`" `"$py`" `"$RoboRoot`""
Write-Step "C 呼び出し部品を作る"
& cmd.exe /d /c $cmd
if ($LASTEXITCODE -ne 0) { throw "build_endpoint_ffi.py が失敗しました（終了コード $LASTEXITCODE）" }
Write-Host "[done]" -ForegroundColor Green
