# external_library

★★★★ **2026-09-02 に新設。** それまで `hakoniwa-mujoco-runtime` は外部依存を**自分では持たず**、
configure のときに**リポジトリの外を探しに行っていた**。

| 依存 | 以前に拾っていた場所 | 実体 |
|---|---|---|
| MuJoCo | `../../.cache/deps/mujoco_bin-src` | **ドローンの木の外**（別プロジェクト＝ヒューマノイドのキャッシュ） |
| nlohmann/json | `../nlohmann-json/single_include` | **`hakoniwa-drone-pro/thirdparty/nolman`**（PRIVATE。しかも「使わない」と決めたリポジトリ） |

★★★ どちらも消えた瞬間にこのリポジトリはビルド不能になる。
**単体でビルドでき、単体で動かなければ意味がない。**

## いまの形

| 取り込む | 形 | 版 |
|---|---|---|
| `nlohmann-json`（nlohmann/json） | **ヘッダ 1 つを同梱**（`single_include/nlohmann/json.hpp` と `LICENSE.MIT`。公式のまま無改変） | **v3.12.0（`55f93686`）**。json.hpp の SHA256 は `aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63` |
| `mujoco` | **`mujoco.lock`（版 ＋ SHA256）で取得** | 3.9.0 |
| `../third_party/hakoniwa-godot` | **git submodule**（2026-11-07 追加） | `8f5d7d1`（中に hakoniwa-core-pro `efc9d0c`・pdu-endpoint `66bdfb8`・godot-cpp `60b5a41`） |

★★★ **2026-11-07 から、共通の依存の版はこのリポジトリで決める。**
nlohmann/json と hakoniwa-godot（Windows の SDK の材料と Godot 拡張の材料）は、
ロボットのリポジトリ（armpi・humanoid・cobot）がそれぞれ持っていたものをここに集めた。
sensor とロボットは、作業場所の兄弟フォルダ `../hakoniwa-mujoco-runtime/` の下を参照する。
hakoniwa-godot は他者のリポジトリなので、**読むだけ**（編集・中でのビルドをしない。SDK は `git archive` で書き出してから建てる）。

★★ nlohmann/json は 2026-11-07 に submodule をやめて同梱にした（clone を速くするため。sensor・ロボットも
submodule で持たない）。版を上げるときは、公式リリースの `single_include/nlohmann/json.hpp` と `LICENSE.MIT` を
そのまま差し替え、上の表の版と SHA256 を書き換える。中身を手で直さない。

## ★★★★ なぜ MuJoCo だけ submodule にしないのか

submodule で取れるのは**ソース**で、`libmujoco.so` は付いてこない。
自前ビルドに戻すと「ヘッダとライブラリを別々に用意する」形になり、
★★★ **版が食い違うとビルドは通って実行時に SEGV する**という地雷の入り口へ戻る
（このリポジトリで **3.10.0-dev ヘッダ ＋ 3.9.0 ライブラリ**の事故が実際に起きている）。

★★★★ **その 3.10.0-dev は `/data/buildman/drone/sensor/mujoco` に今も在り、
2026-09-02 まで `hakoniwa-mujoco-sensor` の探索候補に残っていた。**候補から外した。

## 用意のしかた

```bash
external_library/setup.sh
```

同梱の nlohmann/json があることを確かめ、MuJoCo を lock の版で取得して SHA256 を検証する。
★ 最後に **symlink が他リポジトリを指していないこと**を断言して終わる（指していたら異常終了する）。

## ★★★ 版を上げるときは 4 リポジトリ同時に

`hakoniwa-mujoco-drone` / `hakoniwa-drone-companion` / `hakoniwa-mujoco-sensor` /
`hakoniwa-mujoco-runtime` は**同じ MuJoCo に対して組んだ成果物を混ぜる**。
片方だけ上げると**ビルドは通って実行時に SEGV する**。
