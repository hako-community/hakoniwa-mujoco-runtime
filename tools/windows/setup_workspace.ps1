# setup_workspace.ps1 — 新しい Windows PC で、ロボット（armpi・humanoid・cobot）かドローンを 1 本で建てる
#
#   入口の文書: hakoniwa-mujoco-runtime\docs\START_HERE.md
#
#   cd D:\work_build                                                     # 作業場所（浅い場所。ロボットとドローンは別の作業場所）
#   git clone https://github.com/hako-community/hakoniwa-mujoco-runtime.git
#   powershell -ExecutionPolicy Bypass -File hakoniwa-mujoco-runtime\tools\windows\setup_workspace.ps1 -Robot humanoid
#   powershell -ExecutionPolicy Bypass -File hakoniwa-mujoco-runtime\tools\windows\setup_workspace.ps1 -Robot humanoid,cobot,armpi
#   powershell -ExecutionPolicy Bypass -File hakoniwa-mujoco-runtime\tools\windows\setup_workspace.ps1 -Drone            # 別の作業場所で
#   powershell -ExecutionPolicy Bypass -File hakoniwa-mujoco-runtime\tools\windows\setup_workspace.ps1 -Robot cobot -Check   # 確かめるだけ
#
#   手順（-From N で途中から。どれも、できているものは飛ばす）:
#     W1 ツール     Git・CMake・Python 3.12・Visual Studio 2022（vswhere）・Godot・長いパス
#     W2 clone      足りないリポジトリを clone（humanoid は hakoniwa-armpi・hakoniwa-godot-robot〔非公開〕も、ドローンは companion も）
#     W3 依存       各リポジトリの tools\fetch_deps.py（deps.lock の版の runtime・sensor・drone）
#     W4 箱庭コア   tools\hako_core\fetch_third_party.py（<作業場所>\third_party。ロボット・ドローン共通の最新）
#     W5 SDK        ロボット: robo_sdk\setup_robo_sdk.ps1（devai_robo。初回 約 1〜1.5 時間）
#                   ドローン: hakoniwa-mujoco-drone\tools\local_sdk\setup_windows.ps1（devai_drone。SDK・MuJoCo・venv・ビルド 約 10 分）
#     W6 ロボット   humanoid: config.local.ps1（無ければ作る）→ setup_python → hako\setup_hako -From 2
#                   cobot: make_venv → build → stage_godot_addon     armpi: make_venv → build → stage_godot_addon
#     W7 確認       check_robo_sdk・humanoid の check_env／ドローンは -Test で ctest。最後に「次に動かすコマンド」を出す
#
#   -Workspace : 作業場所（既定: このリポジトリの親）
#   -Robo      : ロボット共通 SDK の場所（既定: 環境変数 DEVAI_ROBO、無ければ <作業場所>\devai_robo）
#   -Godot     : Godot 4.7.1 mono の exe（既定: 環境変数 GODOT_EXE、無ければ D:\Godot_v4.7.1-stable_mono_win64\...）
#   -RebuildSdk: SDK の箱庭コアが lock と違うとき、今の SDK を <SDK>.old-<日時> に退避して作り直す（ロボット）
#                箱庭コアがもう lock と同じで一部だけ足りない（作りかけ）なら、退避せずに続きを作る
#   -SdkFrom N : その「続き」を setup_robo_sdk の S-N から（例 S5 の Godot addon で止まったら -From 5 -SdkFrom 5）
#   -WithNcMachine: cobot を加工機と連携する形で建てる（hakoniwa-ncmachine も clone）
#   -Test      : ドローンの ctest（drone 約 11 分・companion 約 15 分）も流す
#   -Check     : 何も作らず、W1・W3・W4・W7 の確認だけ
param(
    [string[]]$Robot = @(),     # humanoid・cobot・armpi（カンマ区切り。-File で呼ぶと 1 つの文字列で届くので分ける）
    [switch]$Drone,
    [string]$Workspace = "",
    [string]$Robo = "",
    [string]$Godot = "",
    [ValidateRange(1, 7)][int]$From = 1,
    [switch]$RebuildSdk,
    [ValidateRange(1, 5)][int]$SdkFrom = 1,
    [switch]$WithNcMachine,
    [switch]$Test,
    [switch]$Check
)
$ErrorActionPreference = "Stop"
$Robot = @($Robot | ForEach-Object { $_ -split "[,\s]+" } | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
foreach ($r in $Robot) { if ($r -notin @("humanoid", "cobot", "armpi")) { throw "-Robot は humanoid・cobot・armpi（$r は知らない）" } }
$RuntimeRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $Workspace) { $Workspace = Split-Path -Parent $RuntimeRepo }
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
if (-not $Robot -and -not $Drone) { throw "-Robot humanoid,cobot,armpi か -Drone を指定してください（docs\START_HERE.md）" }
if ($Robot -and $Drone) { throw "ロボットとドローンは別の作業場所に建てます（箱庭コア以外の SDK が別）。どちらか一方を指定してください" }
if ($Robot -and (Test-Path (Join-Path $Workspace "hakoniwa-mujoco-drone"))) { Write-Host "[注意] この作業場所にドローンもあります。ロボットとドローンは別の作業場所を勧めます" -ForegroundColor Yellow }
if ($Drone -and (Test-Path (Join-Path $Workspace "devai_robo"))) { Write-Host "[注意] この作業場所にロボットの SDK もあります。ロボットとドローンは別の作業場所を勧めます" -ForegroundColor Yellow }

$Python = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
if (-not $Robo) { $Robo = if ($env:DEVAI_ROBO) { $env:DEVAI_ROBO } else { Join-Path $Workspace "devai_robo" } }
$Robo = [System.IO.Path]::GetFullPath($Robo)
if (-not $Godot) { $Godot = if ($env:GODOT_EXE) { $env:GODOT_EXE } else { "D:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe" } }
$Org = "https://github.com/hako-community"
$CoreTool = Join-Path $RuntimeRepo "tools\hako_core\fetch_third_party.py"
$RoboSdk = Join-Path $RuntimeRepo "tools\windows\robo_sdk"
$env:PYTHONIOENCODING = "utf-8"
$t0 = Get-Date
$warn = New-Object System.Collections.Generic.List[string]

function Write-W([int]$n, [string]$text) {
    Write-Host ""
    Write-Host "##### W$n $text #####" -ForegroundColor Magenta
}
function Invoke-Native([string]$Exe, [string[]]$Arguments, [string]$WorkDir = $null) {
    Write-Host "[run] $Exe $($Arguments -join ' ')" -ForegroundColor DarkGray
    if ($WorkDir) { Push-Location $WorkDir }
    try {
        & $Exe @Arguments
        if ($LASTEXITCODE -ne 0) { throw "失敗しました（終了コード $LASTEXITCODE）: $Exe $($Arguments -join ' ')" }
    } finally { if ($WorkDir) { Pop-Location } }
}
function Invoke-Ps1([string]$File, [string[]]$Arguments = @()) {
    Write-Host "[ps1] $File $($Arguments -join ' ')" -ForegroundColor DarkGray
    & powershell -NoProfile -ExecutionPolicy Bypass -File $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "失敗しました（終了コード $LASTEXITCODE）: $File" }
}
function Find-VsDevCmd {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vs = & $vswhere -latest -products * -version "[17.0,18.0)" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vs) { $p = Join-Path ($vs | Select-Object -First 1) "Common7\Tools\VsDevCmd.bat"; if (Test-Path $p) { return $p } }
    }
    return ""
}
# フォルダを退避する（同じドライブの名前の変更なので一瞬。中身は消さない）。
# Move-Item は、フォルダの名前の変更が「アクセス拒否」になると 1 つずつの移動に切り替わり、途中で止まって
# 新旧 2 か所に分かれることがある（2026-11-11 に実際に起きた）。ここでは、まずフォルダごと 1 回で変え、
# だめなら中身を 1 つずつ移しきる。それでも残ったら一覧を出して止める（もう一度実行すれば続きから移す）。
function Move-Aside([string]$Src, [string]$Dst) {
    try { [System.IO.Directory]::Move($Src, $Dst); return } catch {
        Write-Host "[退避] フォルダごとの名前の変更ができない（$($_.Exception.Message)）→ 中身を 1 つずつ移す" -ForegroundColor Yellow
    }
    $fail = New-Object System.Collections.Generic.List[string]
    function Merge-Into([string]$s, [string]$d) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
        foreach ($c in Get-ChildItem -LiteralPath $s -Force) {
            $t = Join-Path $d $c.Name
            if (-not (Test-Path -LiteralPath $t)) {
                try { if ($c.PSIsContainer) { [System.IO.Directory]::Move($c.FullName, $t) } else { [System.IO.File]::Move($c.FullName, $t) }; continue } catch {
                    if (-not $c.PSIsContainer) { $fail.Add("$($c.FullName): $($_.Exception.Message)"); continue }
                }
            }
            if ($c.PSIsContainer) { Merge-Into $c.FullName $t }     # 退避先に同じ名前のフォルダがある・フォルダごと移せない → 中へ
            else { $fail.Add("同じ名前が退避先にある: $($c.FullName)") }
        }
    }
    Merge-Into $Src $Dst
    Get-ChildItem -LiteralPath $Src -Recurse -Force -Directory | Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName -Force } }
    $mark = Join-Path $Dst "_MOVE_INCOMPLETE.txt"
    if (-not (Get-ChildItem -LiteralPath $Src -Force)) {
        Remove-Item -LiteralPath $Src -Force
        if (Test-Path -LiteralPath $mark) { Remove-Item -LiteralPath $mark -Force }
        return
    }
    Set-Content -LiteralPath $mark -Value "退避の途中: 残りは $Src。setup_workspace.ps1 をもう一度実行すると、ここへ続きを移す" -Encoding UTF8
    $fail | Select-Object -First 20 | ForEach-Object { Write-Host "  [残り] $_" -ForegroundColor Red }
    throw "退避が途中です: $Src に残りがあります（Godot・エディタ・エクスプローラーを閉じて、もう一度同じコマンドを実行すると $Dst へ続きを移します）"
}

# 作るリポジトリの一覧（name・必須か・説明）
$repos = New-Object System.Collections.Generic.List[object]
foreach ($r in $Robot) {
    $repos.Add(@{ name = "hakoniwa-$r"; need = $true; deps = $true })
    if ($r -eq "humanoid") {
        $repos.Add(@{ name = "hakoniwa-armpi"; need = $true; deps = $true })                # ライン2 のアームのモデル
        $repos.Add(@{ name = "hakoniwa-godot-robot"; need = $true; deps = $false; private = $true })   # デモのコード（非公開）
    }
    if ($r -eq "cobot" -and $WithNcMachine) { $repos.Add(@{ name = "hakoniwa-ncmachine"; need = $true; deps = $false }) }
}
if ($Drone) {
    $repos.Add(@{ name = "hakoniwa-mujoco-drone"; need = $true; deps = $true })
    $repos.Add(@{ name = "hakoniwa-drone-companion"; need = $true; deps = $true })
}
$seen = @{}; $repos = @($repos | Where-Object { if ($seen[$_.name]) { $false } else { $seen[$_.name] = $true; $true } })
$kind = if ($Drone) { "ドローン" } else { "ロボット（$($Robot -join '・')）" }
Write-Host "[setup_workspace] $kind / 作業場所 $Workspace / runtime $RuntimeRepo" -ForegroundColor Cyan

# ---------------- W1 ツール ----------------
if ($From -le 1) {
    Write-W 1 "ツール"
    $ng = 0
    foreach ($t in @(@{ c = "git"; v = "--version" }, @{ c = "cmake"; v = "--version" })) {
        $cmd = Get-Command $t.c -ErrorAction SilentlyContinue
        if ($cmd) { Write-Host "[ok] $($t.c): $((& $t.c $t.v | Select-Object -First 1))" -ForegroundColor Green }
        else { Write-Host "[NG] $($t.c) が PATH に無い" -ForegroundColor Red; $ng++ }
    }
    if (Test-Path $Python) {
        $v = (& $Python -c "import sys, struct; print('%d.%d %d' % (sys.version_info[0], sys.version_info[1], struct.calcsize('P') * 8))").Trim()
        if ($v -eq "3.12 64") { Write-Host "[ok] Python 3.12（64 ビット）: $Python" -ForegroundColor Green }
        else { Write-Host "[NG] Python が 3.12（64 ビット）でない（$v）: $Python" -ForegroundColor Red; $ng++ }
    } else { Write-Host "[NG] Python 3.12 が無い: $Python（python.org 版を既定の場所に入れる）" -ForegroundColor Red; $ng++ }
    $vsd = Find-VsDevCmd
    if ($vsd) { Write-Host "[ok] Visual Studio 2022: $vsd" -ForegroundColor Green }
    else { Write-Host "[NG] Visual Studio 2022（C++ によるデスクトップ開発）が見つからない" -ForegroundColor Red; $ng++ }
    if (Test-Path $Godot) { Write-Host "[ok] Godot: $Godot" -ForegroundColor Green }
    else { Write-Host "[--] Godot が無い: $Godot（ビューアを使うときに要る。-Godot か環境変数 GODOT_EXE）" -ForegroundColor Yellow; $warn.Add("Godot が無い") }
    $lp = (& git config --global core.longpaths) 2>$null
    if ($lp -ne "true") { Write-Host "[--] git の core.longpaths が true でない（git config --global core.longpaths true）" -ForegroundColor Yellow; $warn.Add("core.longpaths") }
    $reg = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($reg -ne 1 -and $Workspace.Length -gt 20) { Write-Host "[--] 作業場所のパスが長め（$($Workspace.Length) 文字）で、Windows の長いパスが無効。浅い場所（例 D:\work_build）を勧めます" -ForegroundColor Yellow; $warn.Add("作業場所が長い") }
    if ($ng -gt 0) { throw "W1: 足りないツールが $ng 件あります（docs\START_HERE.md の「1. ツール」）" }
}

# ---------------- W2 clone ----------------
if ($From -le 2 -and -not $Check) {
    Write-W 2 "clone"
    foreach ($r in $repos) {
        $dir = Join-Path $Workspace $r.name
        if (Test-Path (Join-Path $dir ".git")) { Write-Host "[ok] $($r.name)（あります。触りません）" -ForegroundColor Green; continue }
        if ($r.private) { Write-Host "[注意] $($r.name) は非公開です。hako-community の権限が要ります（gh auth login など）" -ForegroundColor Yellow }
        Invoke-Native "git" @("-c", "core.longpaths=true", "clone", "$Org/$($r.name).git", $dir)
    }
}

# ---------------- W3 依存（deps.lock） ----------------
if ($From -le 3) {
    Write-W 3 "依存（各リポジトリの deps.lock）"
    foreach ($r in $repos | Where-Object { $_.deps }) {
        $fd = Join-Path $Workspace "$($r.name)\tools\fetch_deps.py"
        if (-not (Test-Path $fd)) { throw "$fd が無い（W2 の clone を先に）" }
        $a = @("-B", $fd)
        if ($Check) { $a += "--check" }
        Invoke-Native $Python $a
    }
}

# ---------------- W4 箱庭コア ----------------
if ($From -le 4) {
    Write-W 4 "箱庭コア（$Workspace\third_party。tools\hako_core\third_party.lock）"
    $a = @("-B", $CoreTool, "--dest", (Join-Path $Workspace "third_party"))
    if ($Check) { $a += "--verify-only" }
    & $Python @a
    if ($LASTEXITCODE -ne 0) {
        throw "W4: third_party の版が lock と違います。上流の最新に合わせて取り直すなら: $Python $CoreTool --refresh（今のものは退避。中身は触らない）"
    }
}

# ---------------- W5 SDK ----------------
if ($From -le 5 -and -not $Check) {
    if ($Robot) {
        Write-W 5 "ロボット共通 SDK（$Robo）"
        # 前回の退避が途中で止まっていたら、まず続きを移しきる（半端な SDK に上から作らない）
        $half = Get-ChildItem -Path "$Robo.old-*" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "_MOVE_INCOMPLETE.txt") } | Select-Object -First 1
        if ($half -and (Test-Path $Robo)) {
            Write-Host "[退避] 前回の続き: $Robo → $($half.FullName)" -ForegroundColor Yellow
            Move-Aside $Robo $half.FullName
        }
        $core = Join-Path $Robo "sdk\windows-msvc-x64\sdk\hakoniwa-core"
        if (Test-Path $core) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RoboSdk "check_robo_sdk.ps1") -Robo $Robo
            $chk = $LASTEXITCODE
            # SDK の箱庭コアがもう lock と同じ（新しい箱庭コアで作りかけ・一部足りない）なら、退避せずに続きを作る
            $man = Join-Path $Robo "sdk\windows-msvc-x64\sdk\sdk_manifest.json"
            $lockCore = (Get-Content -Encoding UTF8 (Join-Path $RuntimeRepo "tools\hako_core\third_party.lock") |
                Where-Object { $_ -match '^\s*hakoniwa-core-pro\s*\|' } | Select-Object -First 1).Split('|')[3].Trim()
            $sdkCore = if (Test-Path $man) { (Get-Content $man -Raw | ConvertFrom-Json).sources.'hakoniwa-core-pro' } else { "" }
            if ($chk -ne 0 -and $sdkCore -eq $lockCore) {
                Write-Host "[続き] SDK の箱庭コアは lock と同じ。足りないところを作る（setup_robo_sdk.ps1 -From $SdkFrom。退避しない）" -ForegroundColor Yellow
                Invoke-Ps1 (Join-Path $RoboSdk "setup_robo_sdk.ps1") @("-Robo", $Robo, "-From", "$SdkFrom")
            } elseif ($chk -ne 0) {
                if (-not $RebuildSdk) { throw "W5: SDK が lock と違うか、足りません。作り直すなら -RebuildSdk（今の SDK は退避）か setup_robo_sdk.ps1 -From <番号>" }
                $old = "$Robo.old-" + (Get-Date).ToString("yyyyMMdd-HHmmss")
                Write-Host "[退避] $Robo → $old（戻すときは名前を戻す）" -ForegroundColor Yellow
                Move-Aside $Robo $old
                Invoke-Ps1 (Join-Path $RoboSdk "setup_robo_sdk.ps1") @("-Robo", $Robo)
            }
        } else {
            Invoke-Ps1 (Join-Path $RoboSdk "setup_robo_sdk.ps1") @("-Robo", $Robo)
        }
    } else {
        Write-W 5 "ドローンの SDK とビルド（hakoniwa-mujoco-drone\tools\local_sdk\setup_windows.ps1）"
        $sw = Join-Path $Workspace "hakoniwa-mujoco-drone\tools\local_sdk\setup_windows.ps1"
        if ($RebuildSdk) { $env:CLEAN = "1"; Write-Host "[作り直し] devai_drone の SDK・MuJoCo・venv を作り直す（CLEAN=1）" -ForegroundColor Yellow }
        Invoke-Ps1 $sw @()
        Remove-Item Env:CLEAN -ErrorAction SilentlyContinue
    }
}

# ---------------- W6 ロボットごと ----------------
if ($From -le 6 -and -not $Check -and $Robot) {
    Write-W 6 "ロボットごとの準備"
    $env:DEVAI_ROBO = $Robo
    foreach ($r in $Robot) {
        $repo = Join-Path $Workspace "hakoniwa-$r"
        Write-Host ""
        Write-Host "--- $r ---" -ForegroundColor Cyan
        switch ($r) {
            "humanoid" {
                $fd = Join-Path $repo "scripts\windows\factory_demo"
                $cfg = Join-Path $fd "config.local.ps1"
                if (-not (Test-Path $cfg)) {
                    # config.example.ps1 の D:\work_build を作業場所に、SDK・Godot・VS をこの PC の値に置き換えて作る
                    $vsd = Find-VsDevCmd
                    $text = [System.IO.File]::ReadAllText((Join-Path $fd "config.example.ps1"), [System.Text.Encoding]::UTF8)
                    $text = $text.Replace("D:\work_build\devai_robo", $Robo).Replace("D:\work_build", $Workspace)
                    $text = $text -replace '(?m)^\$GodotExe = .*$', ('$GodotExe = "' + $Godot + '"')
                    if ($vsd) { $text = $text -replace '(?m)^\$VsDevCmd = .*$', ('$VsDevCmd = "' + $vsd + '"') }
                    [System.IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding($true)))
                    Write-Host "[作成] $cfg（作業場所・SDK・Godot・VS をこの PC に合わせた。画面の番号などは必要なら書き換える）" -ForegroundColor Green
                } else { Write-Host "[ok] $cfg（あります。触りません）" -ForegroundColor Green }
                $env:FACTORY_DEMO_ROBO_ROOT = $Robo
                Invoke-Ps1 (Join-Path $fd "setup_python.ps1")
                Invoke-Ps1 (Join-Path $fd "hako\setup_hako.ps1") @("-From", "2")
            }
            "cobot" {
                $w = Join-Path $repo "scripts\windows"
                $nc = if ($WithNcMachine) { @("-WithNcMachine") } else { @() }
                Invoke-Ps1 (Join-Path $w "make_venv.ps1") (@("-Robo", $Robo) + $nc)
                Invoke-Ps1 (Join-Path $w "build.ps1") (@("-Robo", $Robo) + $nc)
                Invoke-Ps1 (Join-Path $w "stage_godot_addon.ps1") @("-Robo", $Robo)
            }
            "armpi" {
                $w = Join-Path $repo "scripts\windows"
                Invoke-Ps1 (Join-Path $w "make_venv.ps1") @("-Robo", $Robo)
                Invoke-Ps1 (Join-Path $w "build.ps1") @("-Robo", $Robo)
                Invoke-Ps1 (Join-Path $w "stage_godot_addon.ps1") @("-Robo", $Robo)
            }
        }
    }
}

# ---------------- W7 確認 ----------------
Write-W 7 "確認"
$ok = $true
if ($Robot) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RoboSdk "check_robo_sdk.ps1") -Robo $Robo
    if ($LASTEXITCODE -ne 0) { $ok = $false }
    if ($Robot -contains "humanoid") {
        $env:FACTORY_DEMO_ROBO_ROOT = $Robo
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Workspace "hakoniwa-humanoid\scripts\windows\factory_demo\check_env.ps1")
        if ($LASTEXITCODE -ne 0) { $ok = $false }
    }
} else {
    if ($Test -and -not $Check) {
        Invoke-Ps1 (Join-Path $Workspace "hakoniwa-mujoco-drone\tools\local_sdk\setup_windows.ps1") @("test")
    } else { Write-Host "[--] ドローンの ctest は -Test で流す（約 25 分）" }
}

Write-Host ""
Write-Host "================ 次に動かすコマンド ================" -ForegroundColor Cyan
foreach ($r in $Robot) {
    switch ($r) {
        "humanoid" { Write-Host "humanoid（箱庭版ライブ）: $Workspace\hakoniwa-humanoid\scripts\windows\factory_demo\hako\start_hako.bat`n    Godot なしの確認: powershell -ExecutionPolicy Bypass -File $Workspace\hakoniwa-humanoid\scripts\windows\factory_demo\hako\check_hako.ps1 -Scenario rezot" }
        "cobot"    { Write-Host "cobot: powershell -ExecutionPolicy Bypass -File $Workspace\hakoniwa-cobot\scripts\windows\verify_all.ps1" }
        "armpi"    { Write-Host "armpi: powershell -ExecutionPolicy Bypass -File $Workspace\hakoniwa-armpi\scripts\windows\run_demo.ps1 -Demo motion" }
    }
}
if ($Drone) { Write-Host "drone（Origin-01 ×2 機）: powershell -ExecutionPolicy Bypass -File $Workspace\hakoniwa-mujoco-drone\tools\local_sdk\setup_windows.ps1 run" }
if ($warn.Count) { Write-Host "注意: $($warn -join ' / ')" -ForegroundColor Yellow }
$min = ((Get-Date) - $t0).TotalMinutes
if (-not $ok) { Write-Host ("[setup_workspace] 確認で足りないものがあります（{0:N0} 分）。上の [NG] を見てください" -f $min) -ForegroundColor Red; exit 1 }
Write-Host ("[setup_workspace] できました（{0:N0} 分）" -f $min) -ForegroundColor Green
