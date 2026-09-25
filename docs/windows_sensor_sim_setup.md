# Windows センサーシミュレーション: SDK構築と実行手順

2026-09-25。WindowsネイティブのArmPi/Humanoidシミュレーション向け（SENS-006 A案）。

## ローカルSDKとは

ビルド・実行に使うヘッダー、ライブラリ、Python拡張（`hakopy.pyd`）、Pythonパッケージ（`hakoniwa_pdu`など）、標準PDUのオフセット定義を1か所にまとめたものです。Windowsでは必須です。ROSやIsaac Simのインストールとは別物で、システム環境変数の恒久設定も不要です。

A案ではSensorHealthを標準`std_msgs/UInt8MultiArray`に格納します（`hakoniwa-mujoco-sensor/docs/sensor_health_transport.md`）。独自PDU型の生成は不要で、masterも本リポジトリの`tools/master_runner`から自前でビルドします。

## 前提

- 4つの所有リポジトリ（hakoniwa-armpi / hakoniwa-humanoid / hakoniwa-mujoco-runtime / hakoniwa-mujoco-sensor）を同じ親フォルダーに置く。ArmPiかHumanoidは`git clone --recursive`でthird_partyまで取得しておく。
- Visual Studio 2022 のC++開発環境（MSVC x64、Windows SDK）、CMake 3.20以上、Git。
- 64bit Python 3.12（`hakopy.pyd`はこのPythonに合わせてビルドされる）。検証にはNumPyとPillowも使う。
- ネットワーク接続（vcpkg、CMakeのFetchContent、PyPIから取得する）。

third_party（hakoniwa-core-pro、hakoniwa-pdu-registry、hakoniwa-core-cpp、hakoniwa-pdu-endpointなど）は他者のリポジトリです。以下の手順はすべて**読み取りのみ**で、third_party内でのビルド、ファイル生成、git操作は行いません。

## 1. SDKをゼロから構築する

PowerShellで実行します（`D:/work_build`は4リポジトリの親フォルダーに読み替えてください）。出力先は新規フォルダーを指定します。

```powershell
Set-Location D:/work_build/hakoniwa-mujoco-runtime
python -B tools/build_hakoniwa_sdk_windows.py `
  --godot-third-party D:/work_build/hakoniwa-humanoid/third_party/hakoniwa-godot/third_party `
  --json-root D:/work_build/hakoniwa-humanoid/third_party/nlohmann-json `
  --output D:/work_build/hakoniwa-mujoco-runtime/build/sdk
```

スクリプトが行うこと:

1. third_partyの各リポジトリ（hakoniwa-core-pro、hakoniwa-core-cpp、hakoniwa-pdu-registry、hakoniwa-pdu-endpoint）から、commit済みの内容（HEAD）だけを`git archive`で`<output>/src`へ書き出す。ローカルの未commit差分は含まれない。
2. vcpkgを`<output>/vcpkg`にcloneし、固定commit（`319504a5`）でboost-asio、boost-beast、MuJoCo 3.10.0、GLFW 3.5.1をインストールする。global integrationは使わない。
3. hakoniwa-coreをビルドする（C++20、`hako-cmd`とPythonバインディングを含む）。
   - 上流のinstall設定は、ドライブ直下の`/etc/hakoniwa`とシステムPythonのsite-packagesにも書き込む。そのため、いったんDESTDIRで仮の場所にインストールし、必要なものだけを`<output>/sdk`に集める。
   - ユーザーのPython環境は変更しない。
   - hakoniwa-core-cppの公開ヘッダー（`hako.hpp`など。自前masterが使う）も`include`に入れる。
4. hakoniwa-pdu-endpoint（C++静的ライブラリ）をビルドし、インストールする。
5. `hakoniwa-pdu==1.6.9`、`cffi==2.1.1`、`pycparser==3.0`と、書き出したhakoniwa-pdu-endpointのPythonパッケージを、`pip install --target`で`<output>/sdk/hakoniwa-core/python`へ入れる。
6. 必要なファイルがそろっていることと、独自SensorHealth生成物が含まれていないことを確認する。そのうえで`import hakopy, hakoniwa_pdu, hakoniwa_pdu_endpoint`を試す。最後に、ソースのcommit、vcpkgのcommit、全ファイルのSHA256を`sdk/sdk_manifest.json`に記録する。

完成するもの:

| パス | 用途 |
|---|---|
| `<output>/sdk/hakoniwa-core` | core SDK（`--core-sdk`/`--sdk`に指定） |
| `<output>/sdk/hakoniwa-pdu-endpoint` | PDU endpoint SDK（`--endpoint-sdk`） |
| `<output>/vcpkg/installed/x64-windows` | MuJoCo/GLFW/Boost（`--deps`。DLLは`bin`） |

Visual Studioのインストール先が既定と違う場合は`--vsdevcmd`で`VsDevCmd.bat`を指定します。既存のvcpkgを使い回す場合は`--vcpkg-root`を指定します。

## 2. 所有リポジトリのコードをビルド

```powershell
$sdk = 'D:/work_build/hakoniwa-mujoco-runtime/build/sdk'
python -B tools/build_sensor_sim_windows.py `
  --core-sdk "$sdk/sdk/hakoniwa-core" --endpoint-sdk "$sdk/sdk/hakoniwa-pdu-endpoint" `
  --deps "$sdk/vcpkg/installed/x64-windows" `
  --output D:/work_build/hakoniwa-mujoco-runtime/build/sensor_sim
```

兄弟配置のruntime/sensorを明示的に参照します。healthコーデックのテスト、master、ArmPi、Humanoid、センサーパイプラインのテストをビルドし、CTestを実行します。submoduleの更新やPDU生成は行いません。JSONヘッダーは既定でHumanoidのthird_partyを読むだけです。別の場所を使う場合は`--json-include`を指定します。

## 3. 動作検証（実PDU送受信）

```powershell
$b = 'D:/work_build/hakoniwa-mujoco-runtime/build/sensor_sim'
$common = @(
  '--sdk', "$sdk/sdk/hakoniwa-core",
  '--master', "$b/master/hako-runtime-master.exe",
  '--sensor-repo', 'D:/work_build/hakoniwa-mujoco-sensor',
  '--dll-dir', "$sdk/vcpkg/installed/x64-windows/bin"
)
Set-Location D:/work_build/hakoniwa-armpi
python -B tools/run_sensor_health_check_windows.py @common --plant "$b/armpi/armpi_sim.exe" --output "$b/reports/armpi"

Set-Location D:/work_build/hakoniwa-humanoid
python -B tools/run_sensor_checks_windows.py @common --plant "$b/humanoid/humanoid_sim.exe" --output "$b/reports/humanoid"
```

- Humanoidのカメラを検証する場合は`--camera-regression`を追加します。
- AB/resetを検証する場合は、次を追加します。
  `--reset-linkage --manifest config/assets/humanoid-hakoniwa-asset-ab.json --profile config/profiles/linkage_fault_injection_20260925.json`
- 出力先は、実行ごとに新しいフォルダーを指定してください。

ランナーは、プロセス内のPATHとPYTHONPATH、共有メモリの配置、停止ファイルを設定します。成功するとレポートが`ok: true`になり、masterの終了コードは0です。

## 補足: このPCの既存SDKを使う場合

`devai_build/sdk/windows-msvc-x64`にある既存SDKには、旧来の独自SensorHealth生成物と上流の`hako-master.exe`が含まれています。そのまま使わず、次のコマンドで除外したコピーを作ってください。

```powershell
python -B D:/work_build/hakoniwa-mujoco-sensor/tools/prepare_clean_sdk.py --source D:/work_build/devai_build/sdk/windows-msvc-x64/hakoniwa-core --output <新規フォルダー>
```

## よくある設定漏れ

- `hakopy`の読み込みに失敗する: 64bitのPython 3.12で実行しているか確認する。
- MuJoCo/GLFWのDLLが読み込めない: `--dll-dir`にvcpkgの`installed/x64-windows/bin`を指定する。
- codecが見つからない: `--sensor-repo`にstandaloneのhakoniwa-mujoco-sensorを指定する。
- 出力先がすでに存在する: 新しいフォルダーを指定する。

旧custom SensorHealth方式とは通信互換がありません。送信側、受信側、PDU設定を同時に更新してください。
