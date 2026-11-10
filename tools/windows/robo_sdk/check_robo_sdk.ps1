# check_robo_sdk.ps1 — ロボット共通 SDK がそろっているかを確かめる（数秒。何も書き換えない）
#
#   powershell -ExecutionPolicy Bypass -File tools\windows\robo_sdk\check_robo_sdk.ps1 [-Robo <場所>]
#
#   ファイルの有無と、SDK の環境で hakopy・hakoniwa_pdu・hakoniwa_pdu_endpoint（C 呼び出し部品）が import できるかを見る。
#   足りないものがあれば終了コード 1。
param([string]$Robo = "", [string]$Python = "")
$VsDevCmd = ""
. "$PSScriptRoot\robo_common.ps1"
$ng = 0
function Check([string]$What, [string]$Path) {
    if (Test-Path $Path) { Write-Host "[ok] $What" -ForegroundColor Green }
    else { Write-Host "[NG] $What が無い: $Path" -ForegroundColor Red; $script:ng++ }
}
Write-Host "SDK: $SdkRoot"
Check "箱庭コア（hako-cmd.exe）"            (Join-Path $CoreDir "bin\hako-cmd.exe")
Check "hakopy"                              (Join-Path $CoreDir "python\hakopy.pyd")
Check "pdu-endpoint"                        (Join-Path $SdkRoot "sdk\hakoniwa-pdu-endpoint\lib\hakoniwa_pdu_endpoint.lib")
Check "vcpkg（Boost・GLFW）"                (Join-Path $SdkRoot "vcpkg\installed\x64-windows\bin")
Check "MuJoCo 3.9.0"                        (Join-Path $SdkRoot "mujoco-3.9.0\include\mujoco\mujoco.h")
Check "実時間マスタ"                         (Join-Path $SdkRoot "master\bin\hako-realtime-master.exe")
Check "共有メモリの設定"                     (Join-Path $RoboRoot "runtime\$Plat\cpp_core_config.json")
Check "Godot addon（GDExtension）"          (Join-Path $SdkRoot "godot-addon\addons\hakoniwa\hakoniwa.gdextension")
$man = Join-Path $SdkRoot "godot-addon\godot_addon_manifest.json"
if (Test-Path $man) { Write-Host "     型変換: $((Get-Content $man -Raw | ConvertFrom-Json).packages)" }

# 箱庭コアの版: SDK（sdk_manifest.json）と Godot addon（godot_addon_manifest.json）が、tools\hako_core\third_party.lock と同じか
$lock = @{}
foreach ($l in Get-Content -Encoding UTF8 (Join-Path $RuntimeRepo "tools\hako_core\third_party.lock")) {
    if ($l -match '^\s*#' -or -not $l.Trim()) { continue }
    $f = $l -split '\|' | ForEach-Object { $_.Trim() }
    $lock[$f[0]] = $f[3]
}
$sdkMan = Join-Path $SdkRoot "sdk\sdk_manifest.json"
if (Test-Path $sdkMan) {
    $src = (Get-Content $sdkMan -Raw | ConvertFrom-Json).sources
    foreach ($n in "hakoniwa-core-pro", "hakoniwa-pdu-endpoint") {
        if ($src.$n -eq $lock[$n]) { Write-Host "[ok] SDK の $n = lock（$($lock[$n].Substring(0, 12))）" -ForegroundColor Green }
        else { Write-Host "[NG] SDK の $n が $($src.$n) で、lock（$($lock[$n])）と違う → SDK を作り直す（docs\hako_core_update.md）" -ForegroundColor Red; $ng++ }
    }
} else { Write-Host "[NG] sdk_manifest.json が無い: $sdkMan" -ForegroundColor Red; $ng++ }
if (Test-Path $man) {
    $gs = (Get-Content $man -Raw | ConvertFrom-Json).sources
    $gc = $gs.'third_party/hakoniwa-core-pro'
    if ($gc -eq $lock["hakoniwa-core-pro"]) { Write-Host "[ok] Godot addon の hakoniwa-core-pro = lock" -ForegroundColor Green }
    else { Write-Host "[NG] Godot addon の hakoniwa-core-pro が $gc で、lock と違う → build_godot_ext.ps1 -Clean" -ForegroundColor Red; $ng++ }
}
$pyd = Get-ChildItem (Join-Path $CoreDir "python\hakoniwa_pdu_endpoint") -Filter "_c_endpoint_ffi*.pyd" -ErrorAction SilentlyContinue
if ($pyd) { Write-Host "[ok] pdu-endpoint の C 呼び出し部品" -ForegroundColor Green } else { Write-Host "[NG] pdu-endpoint の C 呼び出し部品が無い" -ForegroundColor Red; $ng++ }

# C 呼び出し部品は動かすときにも cffi（_cffi_backend）が要るので、cffi の入った S4 のビルド用 venv で確かめる
#（ロボットのデモ・セルの venv にも cffi を入れておくこと）
$FfiPy = Join-Path $RoboRoot "build\$Plat\robo_sdk\ffi-venv\Scripts\python.exe"
if (Test-Path $FfiPy) { $Python = $FfiPy }
if ((Test-Path $Python) -and (Test-Path $CoreDir)) {
    Use-RoboSdkEnv
    & $Python -I -c "import sys; sys.path.insert(0, r'$CoreDir\python'); import hakopy, hakoniwa_pdu, hakoniwa_pdu_endpoint._c_endpoint_ffi as f; print('[ok] import hakopy・hakoniwa_pdu・_c_endpoint_ffi（python', sys.version.split()[0] + '）')"
    if ($LASTEXITCODE -ne 0) { Write-Host "[NG] SDK の Python パッケージが import できない" -ForegroundColor Red; $ng++ }
} else { Write-Host "[NG] Python 3.12 か SDK が無いので import を確かめられない: $Python" -ForegroundColor Red; $ng++ }

if ($ng -gt 0) { Write-Host "[check_robo_sdk] 足りないもの $ng 件（setup_robo_sdk.ps1 -From <番号> で作り直す）" -ForegroundColor Red; exit 1 }
Write-Host "[check_robo_sdk] すべてそろっています" -ForegroundColor Green
