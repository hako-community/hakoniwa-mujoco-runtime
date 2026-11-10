# build_godot_ext.ps1 — S5: hakoniwa-godot（C++ の GDExtension）と型変換を、third_party の外で作る
#
#   powershell -ExecutionPolicy Bypass -File tools\windows\robo_sdk\build_godot_ext.ps1 [-Robo <場所>] [-Packages "..."] [-Clean] [-CollectOnly]
#
# ★ hakoniwa-godot は他者のリポジトリ。third_party の中では何も書かない・ビルドしない（上流の win-build.ps1 等は使わない）。
# 1) third_party\hakoniwa-godot と、そのサブモジュール（godot-cpp・hakoniwa-core-pro と core-cpp・pdu-registry・
#    hakoniwa-pdu-endpoint）を、コミット済みの HEAD だけ git archive で <RoboRoot>\src\ へ書き出す
# 2) 書き出したコピーを configure する（nlohmann-json は同梱のものを渡し、ネットから取らない。Boost は SDK の vcpkg）
# 3) 書き出したコピーの tools\build_all_codecs.ps1 でビルドとメッセージ addon の同期をする（ビルド木は <RoboRoot>\build\）
# 4) addon 一式（addons\hakoniwa・addons\hakoniwa_msgs）を <RoboRoot>\sdk\windows-msvc-x64\godot-addon へ集め、manifest を書く
#    （各ロボットの Godot プロジェクトへ入れるのは、ロボット側のスクリプト）
#
#   -Packages: 型変換。既定は上流の common-codecs と同じ 4 つ（humanoid・cobot・armpi のビューアが使うもの）
param(
    [string]$Robo = "", [string]$Python = "", [string]$VsDevCmd = "",
    [string]$Packages = "hako_msgs;std_msgs;geometry_msgs;sensor_msgs",
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [switch]$Clean,
    [switch]$CollectOnly     # ビルド済みのコピーから addon を集め直すだけ
)
. "$PSScriptRoot\robo_common.ps1"
Use-RoboSdkEnv
$RT = $RuntimeRepo -replace '\\', '/'
$GODOT_REPO = "$RT/third_party/hakoniwa-godot"
$JSON_ROOT = "$RT/external_library/nlohmann-json"
Assert-Path "$GODOT_REPO/third_party/godot-cpp" "hakoniwa-godot（ロボットのリポジトリで python tools\fetch_deps.py）"
$SRC = Join-Path $RoboRoot "src\$Plat\hakoniwa-godot"
$BUILD = Join-Path $RoboRoot "build\$Plat\hakoniwa-godot"
$TOOLCHAIN = Join-Path $SdkRoot "vcpkg\scripts\buildsystems\vcpkg.cmake"
$OUT = Join-Path $SdkRoot "godot-addon"
Assert-Path $TOOLCHAIN "SDK の vcpkg（先に build_sdk.ps1）"

if ($Clean) {
    foreach ($d in $SRC, $BUILD, $OUT) { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
}
if ((Test-Path $SRC) -and -not $CollectOnly) { throw "書き出し先が既にあります（-Clean で作り直す。集めるだけなら -CollectOnly）: $SRC" }

$subs = @(
    @{ rel = "";                                                     repo = $GODOT_REPO },
    @{ rel = "third_party/godot-cpp";                                repo = "$GODOT_REPO/third_party/godot-cpp" },
    @{ rel = "third_party/hakoniwa-core-pro";                        repo = "$GODOT_REPO/third_party/hakoniwa-core-pro" },
    @{ rel = "third_party/hakoniwa-core-pro/hakoniwa-core-cpp";      repo = "$GODOT_REPO/third_party/hakoniwa-core-pro/hakoniwa-core-cpp" },
    @{ rel = "third_party/hakoniwa-core-pro/hakoniwa-pdu-registry";  repo = "$GODOT_REPO/third_party/hakoniwa-core-pro/hakoniwa-pdu-registry" },
    @{ rel = "third_party/hakoniwa-pdu-endpoint";                    repo = "$GODOT_REPO/third_party/hakoniwa-pdu-endpoint" }
)
$commits = $null
if (-not $CollectOnly) {
    # --- 1) git archive ---
    $commits = [ordered]@{}
    $tmpTar = Join-Path $env:TEMP "hako_godot_archive.tar"
    foreach ($s in $subs) {
        $dest = if ($s.rel) { Join-Path $SRC $s.rel } else { $SRC }
        New-Item -ItemType Directory -Force $dest | Out-Null
        $c = (& git -C $s.repo rev-parse HEAD).Trim()
        & git -C $s.repo archive --format=tar -o $tmpTar HEAD
        if ($LASTEXITCODE -ne 0) { throw "git archive failed: $($s.repo)" }
        & "$env:SystemRoot\System32\tar.exe" -xf $tmpTar -C $dest     # Git の GNU tar は C: をホスト名と解釈するので Windows の tar
        if ($LASTEXITCODE -ne 0) { throw "tar failed: $dest" }
        $name = if ($s.rel) { $s.rel } else { "hakoniwa-godot" }
        $commits[$name] = $c
        Write-Host "[export] $name $c"
    }
    Remove-Item $tmpTar -ErrorAction SilentlyContinue

    # --- 2) configure（json の場所をキャッシュに入れる）---
    $cfg = @(
        "-S", $SRC, "-B", $BUILD, "-G", "Visual Studio 17 2022", "-A", "x64",
        "-DHAKONIWA_GODOT_CODEC_PACKAGES=$Packages",
        "-DHAKONIWA_GODOT_BUILD_TESTS=OFF",
        "-DHAKONIWA_GODOT_BUILD_EXAMPLES=OFF",
        "-DHAKONIWA_GODOT_MINIMAL_DEP_BUILD=ON",
        "-DCMAKE_TOOLCHAIN_FILE=$($TOOLCHAIN -replace '\\','/')",
        "-DVCPKG_TARGET_TRIPLET=x64-windows",
        "-DHAKO_LOCAL_NLOHMANN_JSON_ROOT=$JSON_ROOT"
    )
    Invoke-Native "cmake" $cfg

    # --- 3) 上流のスクリプト（書き出したコピー）でビルドとメッセージ addon の同期 ---
    & (Join-Path $SRC "tools\build_all_codecs.ps1") -BuildDir $BUILD -Configuration $Configuration `
        -ToolchainFile $TOOLCHAIN -VcpkgTriplet "x64-windows" -Tests OFF -Packages $Packages
    if ($LASTEXITCODE -ne 0) { throw "build_all_codecs.ps1 failed" }
}

function Get-Sha256($path) {
    # Get-FileHash は、PowerShell 7 から呼ばれた Windows PowerShell では読み込めないことがあるので .NET で計算する
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($path)
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($fs))).Replace("-", "") } finally { $fs.Dispose(); $sha.Dispose() }
}

if (-not $commits) {    # -CollectOnly: 書き出したときの commit は元（third_party）から読み直す
    $commits = [ordered]@{}
    foreach ($s in $subs) { $commits[$(if ($s.rel) { $s.rel } else { "hakoniwa-godot" })] = (& git -C $s.repo rev-parse HEAD).Trim() }
}
# --- 4) addon を集める ---
New-Item -ItemType Directory -Force (Join-Path $OUT "addons") | Out-Null
foreach ($a in "hakoniwa", "hakoniwa_msgs") {
    $from = Join-Path $SRC "addons\$a"
    if (-not (Test-Path $from)) { throw "addon がありません: $from" }
    $to = Join-Path $OUT "addons\$a"
    if (Test-Path $to) { Remove-Item -Recurse -Force $to }
    Copy-Item -Recurse $from $to
}
$files = Get-ChildItem -Recurse -File $OUT | Where-Object { $_.Name -ne "godot_addon_manifest.json" }
$man = [ordered]@{
    built = (Get-Date).ToString("s"); configuration = $Configuration; packages = $Packages
    sources = $commits; json_root = $JSON_ROOT; toolchain = $TOOLCHAIN
    files = @($files | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($OUT.Length + 1); sha256 = (Get-Sha256 $_.FullName) } })
}
$man | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $OUT "godot_addon_manifest.json")
Write-Host "[done] addon -> $OUT ($($files.Count) files、型変換 $Packages)" -ForegroundColor Green
