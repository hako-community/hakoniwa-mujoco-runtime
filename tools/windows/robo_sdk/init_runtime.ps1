# init_runtime.ps1 — S2: 箱庭の実行時設定（共有メモリの場所）を作る
#
#   powershell -ExecutionPolicy Bypass -File tools\windows\robo_sdk\init_runtime.ps1 [-Robo <場所>] [-MmapDir C:/hako_mmap_robo] [-Force]
#
#   <RoboRoot>\runtime\windows-msvc-x64\cpp_core_config.json を書く。全プロセスは HAKO_CONFIG_PATH でこれを指す。
#   共有メモリの場所は、ほかの箱庭の作業（例: ドローンの Z:/mmap）と分ける。
#   -MmapDir を省くと、Z: ドライブ（RAM ディスク）があれば Z:/mmap_robo、無ければ C:/hako_mmap_robo。
#   既にあるときは書き換えない（-Force で上書き）。
param([string]$Robo = "", [string]$MmapDir = "", [switch]$Force)
$Python = ""; $VsDevCmd = ""
. "$PSScriptRoot\robo_common.ps1"
$dir = Join-Path $RoboRoot "runtime\$Plat"
$cfg = Join-Path $dir "cpp_core_config.json"
if ((Test-Path $cfg) -and -not $Force) {
    Write-Host "[skip] 既にあります: $cfg"; Get-Content $cfg; return
}
if (-not $MmapDir) { $MmapDir = if (Test-Path "Z:\") { "Z:/mmap_robo" } else { "C:/hako_mmap_robo" } }
$drive = Split-Path -Qualifier $MmapDir
if ($drive -and -not (Test-Path "$drive\")) { throw "ドライブ $drive がありません。-MmapDir で別の場所（例 C:/hako_mmap_robo）を指定する" }
New-Item -ItemType Directory -Force $dir | Out-Null
New-Item -ItemType Directory -Force $MmapDir | Out-Null
$json = [ordered]@{ shm_type = "mmap"; core_mmap_path = $MmapDir; asset_timeout_usec = 600000000 } | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($cfg, $json, (New-Object System.Text.UTF8Encoding($false)))    # BOM なし
Write-Host "[done] $cfg"; Get-Content $cfg
