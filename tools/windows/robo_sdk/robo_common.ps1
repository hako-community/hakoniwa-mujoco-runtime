# robo_common.ps1 — ロボット共通 SDK のスクリプトが最初に読む（. "$PSScriptRoot\robo_common.ps1"）
#
#   呼ぶ側の param で受けた $Robo・$Python・$VsDevCmd（空なら既定）を解決し、共通の変数と関数を用意する。
#     $RuntimeRepo : このリポジトリ（hakoniwa-mujoco-runtime）
#     $RoboRoot    : SDK を作る場所（-Robo ＞ 環境変数 DEVAI_ROBO ＞ <作業場所>\devai_robo）
#     $Plat        : windows-msvc-x64
#     $SdkRoot     : <RoboRoot>\sdk\windows-msvc-x64
#     $CoreDir     : <SdkRoot>\sdk\hakoniwa-core
#     $CoreTp      : <作業場所>\third_party（箱庭コア。tools\hako_core\third_party.lock の版。ロボット・ドローン共通で上流の最新）
#   グローバルな環境変数・システムには何も書かない。
$ErrorActionPreference = "Stop"
$RuntimeRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$Workspace = Split-Path -Parent $RuntimeRepo
$Plat = "windows-msvc-x64"

if (-not $Robo) { $Robo = if ($env:DEVAI_ROBO) { $env:DEVAI_ROBO } else { Join-Path $Workspace "devai_robo" } }
$RoboRoot = [System.IO.Path]::GetFullPath($Robo)
$SdkRoot = Join-Path $RoboRoot "sdk\$Plat"
$CoreDir = Join-Path $SdkRoot "sdk\hakoniwa-core"
$CoreTp = Join-Path $Workspace "third_party"
$CoreLockTool = Join-Path $RuntimeRepo "tools\hako_core\fetch_third_party.py"

if (-not $Python) { $Python = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" }    # ストアのエイリアス（python3）は使わない
if (-not $VsDevCmd) {
    # Visual Studio 2022（Community・Professional・Enterprise・Build Tools のどれでも）を vswhere で探す
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vs = & $vswhere -latest -products * -version "[17.0,18.0)" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vs) { $VsDevCmd = Join-Path ($vs | Select-Object -First 1) "Common7\Tools\VsDevCmd.bat" }
    }
    if (-not $VsDevCmd) { $VsDevCmd = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat" }
}

function Assert-Path([string]$Path, [string]$What) {
    if (-not (Test-Path $Path)) { throw "$What が見つかりません: $Path（手順書: hakoniwa-mujoco-runtime\docs\windows_robot_setup.md）" }
}

function Invoke-Native([string]$Exe, [string[]]$Arguments, [string]$WorkDir = $null) {
    # ネイティブのコマンドを実行し、失敗したら止める
    Write-Host "[run] $Exe $($Arguments -join ' ')" -ForegroundColor DarkGray
    if ($WorkDir) { Push-Location $WorkDir }
    try {
        & $Exe @Arguments
        if ($LASTEXITCODE -ne 0) { throw "失敗しました（終了コード $LASTEXITCODE）: $Exe" }
    } finally {
        if ($WorkDir) { Pop-Location }
    }
}

function Assert-CoreThirdParty {
    # 作業場所の third_party（箱庭コア）が tools\hako_core\third_party.lock と同じ版かを確かめる（書き換えない）
    $env:PYTHONIOENCODING = "utf-8"
    & $Python -B $CoreLockTool --dest $CoreTp --verify-only
    if ($LASTEXITCODE -ne 0) {
        throw "箱庭コア（$CoreTp）が lock と違うか、ありません。python $CoreLockTool（版が違うときは --refresh）"
    }
}

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Use-RoboSdkEnv {
    # このプロセスだけ SDK を使う環境にする。ユーザ環境変数に古い箱庭 SDK（hakoCore-win・hakoApps-win）が残っていても、
    # そちらの hakopy.pyd などを読まないように上書き・消去する
    $env:HAKO_SDK_ROOT = $CoreDir
    $env:HAKO_CONFIG_PATH = Join-Path $RoboRoot "runtime\$Plat\cpp_core_config.json"
    $env:HAKO_BINARY_PATH = Join-Path $CoreDir "share\hakoniwa\offset"
    $env:PYTHONPATH = Join-Path $CoreDir "python"              # 置き換え（先頭に足すのではない）
    foreach ($v in "HAKO_CORE_DLL_PATH", "HAKO_CORE_INC_PATH", "HAKO_CORE_LIB_PATH", "HAKO_DRONE_DLL_PATH", "HAKO_DRONE_INC_PATH", "HAKO_DRONE_LIB_PATH") {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
    $keep = ($env:PATH -split ";") | Where-Object { $_ -and ($_ -notmatch "hakoCore-win") -and ($_ -notmatch "hakoApps-win") }
    # MuJoCo は SDK の公式 3.9.0。vcpkg より先に置く（古い vcpkg に mujoco.dll が残っていてもこちらを読む）
    $env:PATH = (@((Join-Path $CoreDir "bin"), (Join-Path $SdkRoot "mujoco-3.9.0\bin"), (Join-Path $SdkRoot "vcpkg\installed\x64-windows\bin")) + $keep) -join ";"
    if ((Test-Path (Join-Path $RoboRoot "vcpkg_curl.txt")) -and -not $env:X_VCPKG_ASSET_SOURCES) {
        # build_sdk.ps1 -VcpkgCurl で作った SDK: vcpkg のダウンロードを curl で行う（認証付きプロキシ向け）
        $env:X_VCPKG_ASSET_SOURCES = "x-script,$env:SystemRoot\System32\curl.exe -sSL --fail --retry 3 -o {dst} {url}"
    }
    if (Test-Path $env:HAKO_CONFIG_PATH) {
        $env:HAKO_MMAP_DIR = (Get-Content $env:HAKO_CONFIG_PATH -Raw | ConvertFrom-Json).core_mmap_path
        New-Item -ItemType Directory -Force $env:HAKO_MMAP_DIR | Out-Null
    }
}
