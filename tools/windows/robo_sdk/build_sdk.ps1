# build_sdk.ps1 — S1: 箱庭のローカル SDK を <RoboRoot>\sdk\windows-msvc-x64 に作る（約 1 時間）
#
#   powershell -ExecutionPolicy Bypass -File tools\windows\robo_sdk\build_sdk.ps1 [-Robo <場所>]
#
#   tools\build_hakoniwa_sdk_windows.py を呼ぶ。材料（third_party\hakoniwa-godot の中の hakoniwa-core-pro・pdu-endpoint、
#   同梱の nlohmann-json）は git archive で読むだけで、中には何も書かない。
#   vcpkg（Boost・GLFW）と MuJoCo 3.9.0（公式版。mujoco.lock の SHA256 で照合）も出力先の中に入る。
#   出力先に SDK が既にあるときは止まる（作り直すときは出力先を自分で退避・削除する）。
#
#   -VcpkgCurl: 認証付きプロキシの内側の PC 向け。vcpkg の初期化（bootstrap-vcpkg.bat。WinHTTP を使う）はプロキシを通らないので、
#               vcpkg を <RoboRoot>\vcpkg に git で取り、vcpkg.exe と vcpkg のダウンロードを curl で行う。
#               SDK の中の vcpkg はジャンクションでつなぐ。以後の段（S5 など）も curl でダウンロードする（印のファイル vcpkg_curl.txt）。
param([string]$Robo = "", [string]$Python = "", [string]$VsDevCmd = "", [switch]$VcpkgCurl)
. "$PSScriptRoot\robo_common.ps1"
$Script = Join-Path $RuntimeRepo "tools\build_hakoniwa_sdk_windows.py"
$GodotTp = Join-Path $RuntimeRepo "third_party\hakoniwa-godot\third_party"
$Json = Join-Path $RuntimeRepo "external_library\nlohmann-json"
Assert-Path $Python "Python 3.12（64 ビット）"
Assert-Path $VsDevCmd "Visual Studio 2022 の VsDevCmd.bat（-VsDevCmd で指定）"
Assert-Path (Join-Path $GodotTp "hakoniwa-core-pro\CMakeLists.txt") "hakoniwa-godot（ロボットのリポジトリで python tools\fetch_deps.py）"
Assert-Path (Join-Path $Json "single_include\nlohmann\json.hpp") "同梱の nlohmann-json"
if (Test-Path $CoreDir) { throw "SDK は既にあります: $SdkRoot（作り直すときは退避・削除してから）" }

$extra = @()
if ($VcpkgCurl) {
    # SDK ビルダーと同じ vcpkg の版（build_hakoniwa_sdk_windows.py の VCPKG_COMMIT）を使う
    $commit = [regex]::Match((Get-Content $Script -Raw), "VCPKG_COMMIT\s*=\s*'([0-9a-f]{40})'").Groups[1].Value
    if (-not $commit) { throw "build_hakoniwa_sdk_windows.py から VCPKG_COMMIT を読めません" }
    $Vc = Join-Path $RoboRoot "vcpkg"
    Write-Step "vcpkg を curl で用意する → $Vc（$commit）"
    if (-not (Test-Path (Join-Path $Vc ".git"))) { Invoke-Native "git" @("clone", "--filter=blob:none", "https://github.com/microsoft/vcpkg.git", $Vc) }
    Invoke-Native "git" @("-C", $Vc, "checkout", "--quiet", $commit)
    if (-not (Test-Path (Join-Path $Vc "vcpkg.exe"))) {
        $tag = ((Get-Content (Join-Path $Vc "scripts\vcpkg-tool-metadata.txt")) | Where-Object { $_ -match "^VCPKG_TOOL_RELEASE_TAG=" }) -replace "^VCPKG_TOOL_RELEASE_TAG=", ""
        Invoke-Native "$env:SystemRoot\System32\curl.exe" @("-sSL", "--fail", "--retry", "3", "-o", (Join-Path $Vc "vcpkg.exe"), "https://github.com/microsoft/vcpkg-tool/releases/download/$tag/vcpkg.exe")
    }
    New-Item -ItemType Directory -Force $RoboRoot | Out-Null
    Set-Content -Encoding ascii (Join-Path $RoboRoot "vcpkg_curl.txt") "vcpkg downloads go through curl (build_sdk.ps1 -VcpkgCurl)"
    $extra = @("--vcpkg-root", $Vc)
}

Use-RoboSdkEnv     # vcpkg_curl.txt があれば X_VCPKG_ASSET_SOURCES も設定する
$env:PYTHONPATH = ""
Write-Step "SDK を作る → $SdkRoot"
Invoke-Native $Python (@("-B", $Script, "--godot-third-party", $GodotTp, "--json-root", $Json, "--output", $SdkRoot, "--vsdevcmd", $VsDevCmd) + $extra)
if ($VcpkgCurl -and -not (Test-Path (Join-Path $SdkRoot "vcpkg"))) {
    New-Item -ItemType Junction -Path (Join-Path $SdkRoot "vcpkg") -Target $Vc | Out-Null     # 管理者権限は要らない
    Write-Host "[junction] $SdkRoot\vcpkg -> $Vc"
}
Write-Host "[done] SDK: $SdkRoot" -ForegroundColor Green
