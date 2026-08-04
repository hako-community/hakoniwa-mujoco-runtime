# hakoniwa-mujoco-runtime

箱庭（[Hakoniwa](https://github.com/toppers/hakoniwa)）向けの **MuJoCo バックエンド実装と
箱庭アセット基盤**。[`hakoniwa-mujoco-sensor`](https://github.com/hako-community/hakoniwa-mujoco-sensor)
が依存する**下位レイヤ**。

`hakoniwa-mujoco-robots` から「センサではないが MuJoCo を使うために必要なもの」を切り出したリポジトリ。
`hakoniwa-mujoco-robots` のメンテナンス状況に依存しないようにするため、その置き換えとして
`hakoniwa-mujoco-sensor`（センサ）と本リポ（コア）の 2 つに再編した。

```
hakoniwa-mujoco-sensor   （上位・センサ）
        │ 依存
        ▼
hakoniwa-mujoco-runtime  （本リポ・MuJoCo バックエンド + 箱庭アセット基盤）
        │ 依存
        ▼
hakoniwa-core / hakoniwa_pdu_endpoint / MuJoCo
```

**依存は一方向。** 本リポは `sensors/**` を一切参照しない（機械的に検証可能）。

**利用側の例**: [`hakoniwa-humanoid`](https://github.com/hako-community/hakoniwa-humanoid)
（31-DoF ヒューマノイドの PLANT）が本リポと sensor を submodule として link し、
MuJoCo 1kHz の物理ループを箱庭アセットとして動かしている。

---

## 提供するもの

| 分類 | ファイル | 内容 |
|---|---|---|
| 物理の型 | `include/primitive_types.hpp` | `Vector3` / `Position` / `Euler` / `Velocity` / `BodyVelocity` / `BodyAngularVelocity` |
| インタフェース | `include/physics.hpp` | `IWorld` / `IRigidBody` |
| | `include/actuator.hpp` | アクチュエータ interface |
| **MuJoCo 実装** | `include/physics/physics_impl.hpp` | `WorldImpl` / `RigidBodyImpl`（ヘッダオンリー） |
| | `include/actuator/{actuator_impl,joint_actuator_impl}.hpp` | 同上 |
| 共通 | `include/common/update_scheduler.hpp` | 周期実行スケジューラ（`hako::robots::common`） |
| | `include/common/json_utils.hpp` | JSON 読み出しヘルパ（同上） |
| 設定スキーマ | `include/config/json_config_utils.hpp` | `mjcf_binding` / `pdu_config` ブロックの読み方（`hako::robots::config`） |
| 箱庭アセット | `include/config/asset_manifest.hpp` + `src/` | asset manifest のロード |
| | `include/runtime/hakoniwa_asset_lifecycle.hpp` + `src/` | endpoint open → conductor → asset register/start |

---

## `hakoniwa-mujoco-robots` からの変更点

### 1. `mjOBJ_BODY` → `mjOBJ_XBODY`（**挙動が変わる修正**）

`RigidBodyImpl` の速度取得 3 箇所を修正した。

MuJoCo の `mj_objectVelocity` に渡す `mjOBJ_BODY` は **body の慣性主軸フレーム（`ximat`）/
慣性 COM** を意味する。`mjOBJ_XBODY` が body のレギュラーフレーム（`xmat` / `xpos`）。

| メソッド | 旧 | 新 | 実測した誤り |
|---|---|---|---|
| `GetBodyAngularVelocity()` | `mjOBJ_BODY, local=1` | `mjOBJ_XBODY, local=1` | MJCF `<gyro>`（site 座標系）と **最大 1.65 rad/s** ずれる |
| `GetBodyVelocity()` | `mjOBJ_BODY, local=1` | `mjOBJ_XBODY, local=1` | 同上 |
| `GetVelocity()` | `mjOBJ_BODY, local=0` | `mjOBJ_XBODY, local=0` | `GetPosition()`（`xpos`＝body 原点）の時間微分と **0.017 m/s** ずれる |

実測は `hakoniwa-humanoid` の H5（2026-08-02）。`base_link` は
`body_iquat = (0.6128, 0.6131, -0.3526, 0.3526)` と単位から大きく外れているため顕在化した。
修正後は MJCF `<gyro>` と **完全一致（差 0.000e+00）**、`GetVelocity()` は数値微分と 1.3e-10 で一致。

> **既存利用者への影響**: `body_iquat` が単位に近い body（ArmPi の base_link 等）では
> 差がほとんど出ないため顕在化していなかった。移行時は当該ロボットで挙動確認をすること。

### 2. `sensors/common/` → `common/` へ移設し namespace を変更

| 旧 | 新 |
|---|---|
| `sensors/common/update_scheduler.hpp`（`hako::robots::sensor::common`） | `common/update_scheduler.hpp`（`hako::robots::common`） |
| `sensors/common/json_utils.hpp`（同上） | `common/json_utils.hpp`（同上） |

いずれもセンサ固有の要素を持たない汎用ユーティリティ。`joint_actuator_impl.hpp` が
`update_scheduler` を使っており、これが唯一の「runtime → sensors」逆流だったため解消した。

**namespace を `hako::robots::common` にしたので、`namespace hako::robots::sensor` の中の
`common::X` という記述は通常の名前解決でそのまま解決される**（sensor 側のソース修正は不要）。

### 3. `config/json_config_utils.hpp` を sensor から移設

センサ設定 JSON のスキーマ（`mjcf_binding` / `pdu_config`）を規定するヘッダ。
`asset_manifest.cpp` も使うため、下位である本リポに置く。namespace は `hako::robots::config` のまま。

### 4. `src/physics/` `src/actuator/` を `include/` へ昇格

利用側（PLANT）が `#include "physics/physics_impl.hpp"` する公開ヘッダなので、
`src/` に置いたままだと include パスに `src/` を通す必要があった。`include/` へ移動して解消。
**利用側の `#include` 文は変更不要**。

### 5. 持ち込まなかったもの

サンプル群（`main_for_sample/`、`robots/tb3`、`robots/forklift`）、`controller/`、`viewer/`、
`rd_lite/`、`hakoniwa/*RigidBody`。これらはロボット固有・サンプル固有で、コア基盤ではない。

`sensors/camera/` は**センサ**なので `hakoniwa-mujoco-sensor` 側に移設した（2026-08 完了）。

---

## ビルド

```bash
cmake -S . -B build \
  -DMUJOCO_INCLUDE_DIR=<mujoco/include> \
  -DNLOHMANN_JSON_INCLUDE_DIR=<nlohmann/json.hpp のある場所> \
  -DHAKONIWA_PDU_ENDPOINT_PREFIX=<hakoniwa_pdu_endpoint の install 先>
cmake --build build
```

`libmujoco` / `hakoniwa-core` のリンクは最終実行体（PLANT）の責務。本ライブラリは
ヘッダ解決とアセット層 2 ファイルのコンパイルのみを担う。

`-DHAKO_RUNTIME_BUILD_ASSET=OFF` にすると箱庭アセット層（`hako_asset.h` / `hako_conductor.h` 依存）
を外し、MuJoCo バックエンドだけのヘッダライブラリとして使える。


---

## 由来と第三者成果物

`hakoniwa-mujoco-robots`（同一著者）から「センサーではないが MuJoCo を使うために必要なもの」を
切り出したリポジトリ。移設時の変更点は上記「`hakoniwa-mujoco-robots` からの変更点」を参照。

| 対象 | 扱い |
|---|---|
| [MuJoCo](https://github.com/google-deepmind/mujoco)（Apache-2.0） | ヘッダを include するのみ（同梱しない。リンクは最終実行体の責務） |
| [nlohmann/json](https://github.com/nlohmann/json)（MIT） | ヘッダを include するのみ（同梱しない） |
| hakoniwa-core / hakoniwa_pdu_endpoint | 実行時・リンク時依存。別途インストール |

---

## ライセンス

**[PolyForm Noncommercial License 1.0.0](./LICENSE)**（licensor: **hakoniwa community**）
— 利用は非営利目的に限ります。
商用利用については別途ご相談ください。

上表の第三者成果物はそれぞれの元ライセンスに従います（本ライセンスは上書きしません）。
