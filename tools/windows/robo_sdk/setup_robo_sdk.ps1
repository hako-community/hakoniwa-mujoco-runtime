# setup_robo_sdk.ps1 — ロボット共通 SDK を最初から順に作る（S1〜S5 をまとめて実行。初回 約 1〜1.5 時間）
#
#   どのロボット（hakoniwa-armpi・hakoniwa-humanoid・hakoniwa-cobot）から始めても同じ。ロボットのリポジトリで
#   python tools\fetch_deps.py を済ませてから、作業場所（ロボットの親フォルダ）で:
#
#   powershell -ExecutionPolicy Bypass -File hakoniwa-mujoco-runtime\tools\windows\robo_sdk\setup_robo_sdk.ps1 [-Robo D:\work_build\devai_robo] [-From 3]
#
#   -Robo     : SDK を作る場所（既定: 環境変数 DEVAI_ROBO、無ければ <作業場所>\devai_robo）
#   -From N   : 手順 S-N から始める（途中で止まったときの再開用）
#   -MmapDir  : 共有メモリの場所（既定: Z: があれば Z:/mmap_robo、無ければ C:/hako_mmap_robo）
#   -Python   : Python 3.12（64 ビット）。既定は %LOCALAPPDATA%\Programs\Python\Python312\python.exe
#   -VsDevCmd : Visual Studio 2022 の VsDevCmd.bat。既定は vswhere で探す
#   -VcpkgCurl: 認証付きプロキシの内側の PC 向け（vcpkg の初期化とダウンロードを curl で行う。build_sdk.ps1 を参照）
#
#     S0 （最初に）箱庭コアを作業場所の third_party\ に用意・照合（tools\hako_core\fetch_third_party.py）
#
#     S1 build_sdk.ps1          SDK（箱庭コア・pdu-endpoint・vcpkg・MuJoCo 3.9.0・hakopy）
#     S2 init_runtime.ps1       実行時設定（共有メモリの場所）
#     S3 build_master.ps1       壁時計に合わせて進めるマスタ（hako-realtime-master.exe）
#     S4 build_endpoint_ffi.ps1 pdu-endpoint の C 呼び出し部品
#     S5 build_godot_ext.ps1    hakoniwa-godot の GDExtension と型変換（third_party の外で作る）
#     → 最後に check_robo_sdk.ps1 で確かめる
param(
    [string]$Robo = "", [string]$Python = "", [string]$VsDevCmd = "",
    [ValidateRange(1, 5)][int]$From = 1,
    [string]$MmapDir = "",
    [switch]$VcpkgCurl
)
. "$PSScriptRoot\robo_common.ps1"
$common = @("-Robo", $RoboRoot)
$build = $common + @("-Python", $Python, "-VsDevCmd", $VsDevCmd)
$steps = @(
    @{ name = "build_sdk.ps1";          args = $(if ($VcpkgCurl) { $build + @("-VcpkgCurl") } else { $build }) },
    @{ name = "init_runtime.ps1";       args = $(if ($MmapDir) { $common + @("-MmapDir", $MmapDir) } else { $common }) },
    @{ name = "build_master.ps1";       args = $build },
    @{ name = "build_endpoint_ffi.ps1"; args = $build },
    # -Clean: S5 が途中で止まって再開したとき、前回の書き出し（SDK の中の src・build・godot-addon だけ）を消して作り直す
    @{ name = "build_godot_ext.ps1";    args = $build + @("-Clean") }
)
Write-Host "[setup_robo_sdk] SDK: $RoboRoot / Python: $Python / VsDevCmd: $VsDevCmd"
# SDK ビルダーは中で深いフォルダを作る。長いパスが有効でない PC で SDK の場所が長いと、260 文字を超えて失敗する
#（実例: C:\Users\<ユーザー>\source\repos\work_cobot\devai_robo で 266 文字。C:\Users\<ユーザー>\devai_robo は通る）
$lp = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($RoboRoot.Length -gt 30 -and $lp -ne 1) {
    Write-Host "[警告] SDK の場所が長い（$($RoboRoot.Length) 文字）。ビルドがパスの長さで失敗することがあります。-Robo で短い場所（例 D:\devai_robo）にしてください" -ForegroundColor Yellow
}
$t0 = Get-Date
Write-Host ""
Write-Host "##### S0 箱庭コア（$CoreTp） #####" -ForegroundColor Magenta
$env:PYTHONIOENCODING = "utf-8"
& $Python -B $CoreLockTool --dest $CoreTp     # 無ければ clone、あれば照合（版が違えば止まる。--refresh は自分で）
if ($LASTEXITCODE -ne 0) { throw "S0 箱庭コアで止まりました（版が違うなら python $CoreLockTool --refresh）" }
for ($i = $From; $i -le $steps.Count; $i++) {
    $s = $steps[$i - 1]
    Write-Host ""
    Write-Host "##### S$i $($s.name) #####" -ForegroundColor Magenta
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $s.name) @($s.args)
    if ($LASTEXITCODE -ne 0) { throw "S$i $($s.name) で止まりました。直してから -From $i で再開できます" }
}
Write-Host ""
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "check_robo_sdk.ps1") -Robo $RoboRoot -Python $Python
if ($LASTEXITCODE -ne 0) { throw "check_robo_sdk.ps1 で足りないものがあります" }
Write-Host ("[done] ロボット共通 SDK ができました（{0:N0} 分）: $RoboRoot" -f ((Get-Date) - $t0).TotalMinutes) -ForegroundColor Green
