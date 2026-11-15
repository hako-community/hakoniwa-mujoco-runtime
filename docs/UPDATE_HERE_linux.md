# 既にある環境を新しくする — Linux（Ubuntu 24.04）

[START_HERE_linux.md](START_HERE_linux.md) で建てた Linux の作業場所を、GitHub の最新に合わせるときの入口です。
新しく建てるときと同じ **`tools/linux/setup_workspace.sh`** を使います。スクリプトは「できているものは飛ばす」ので、
更新では **pull してから同じコマンドを `--from 3` で流す**だけです。箱庭コアや SDK を作り直す必要があるときは、スクリプトが止まって教えます。

> **Windows の作業場所を新しくするとき**は [UPDATE_HERE.md](UPDATE_HERE.md)。

```mermaid
flowchart LR
    A["1. 状態を確かめる<br/>git status"] --> B["2. pull<br/>ロボット → runtime"]
    B --> C["3. setup_workspace.sh<br/>（建てたときと同じオプション）--from 3"]
    C -->|止まった| D["4. 表示どおりに直す<br/>（§4 の表）"]
    D --> C
    C --> E["5. 動かして確かめる"]
```

## 1. 何が変わると、何が起きるか

更新のたびに「何が変わったか」を調べる必要はありません。§3 の手順を流せば、スクリプトが判断します。目安として:

| 変わったもの | 起きること | 時間 |
|---|---|---|
| ロボットのリポジトリ（humanoid・cobot・armpi）のコード・文書 | W6 でビルドし直す | 各 数分 |
| runtime（ロボットの `deps.lock` が上がる） | W3 で版を照合 → W6 でビルドし直す | 各 数分 |
| sensor の版（`deps.lock`） | W3 で止まる → 表示のコマンドで合わせる（§4） | 1 分 |
| **箱庭コア**（runtime の `tools/hako_core/third_party.lock`） | W4 で止まる → `third_party` を取り直し、W5 で **SDK を作り直す**（§4） | **約 15〜40 分** |
| MuJoCo・vcpkg の版（SDK の材料） | W5 で止まる → SDK を作り直す（§4） | 約 15〜40 分 |

## 2. 始める前に

- **建てたときと同じオプション**を使います。とくに `--robot`・`--robo`（SDK の場所）・`--with-ncmachine`。
  Godot の場所は `--godot <実行ファイル>` か環境変数 `GODOT_EXE`（`~/.bashrc` に `export` しておくと省けます）。SDK の場所も `DEVAI_ROBO` で同じく省けます。
- Godot・箱庭のデモ・ビルドを止めます（`pkill -f hako-realtime-master` などで残りがないか確かめる）。
- `third_party/` の下は他者のリポジトリです。pull・checkout・編集はしません（取り直しはスクリプトがします）。

## 3. 手順（ロボットの作業場所）

例は作業場所 `~/work_robot/work_git`。自分の作業場所に読み替えます。

### 3.1 状態を確かめる

```bash
cd ~/work_robot/work_git
for r in hakoniwa-humanoid hakoniwa-armpi hakoniwa-cobot hakoniwa-godot-robot hakoniwa-mujoco-runtime; do
  [[ -d "$r/.git" ]] && { echo "== $r"; git -C "$r" status --short --branch; }
done
```

- 1 行目が `## main...origin/main` なら、そのまま pull できます。
- 変更の行（` M …`）が出たら、その変更を残すか決めます。要らなければ `git -C <リポジトリ> restore .`、残すならコミットするか `git -C <リポジトリ> stash`。
  `config.local.bash`（humanoid の工場デモの設定。置いたときだけ）は git に入っていないので、出ませんし、pull でも消えません。
- runtime が `## HEAD (no branch)` なら、前に `deps.lock` の版へ checkout したままです。§3.2 の `switch main` で main に戻ります。

### 3.2 pull する

**ロボットのリポジトリを先に、runtime を後に**します（ロボットの `deps.lock` が runtime のどの版を使うかを決めているため）。
建てていないロボットのリポジトリは、下のループが飛ばします。

```bash
cd ~/work_robot/work_git
for r in hakoniwa-humanoid hakoniwa-armpi hakoniwa-cobot hakoniwa-godot-robot hakoniwa-ncmachine image2sim-framework; do
  [[ -d "$r/.git" ]] && { echo "== $r"; git -C "$r" pull --ff-only; }
done
git -C hakoniwa-mujoco-runtime switch main
git -C hakoniwa-mujoco-runtime pull --ff-only
```

- `--ff-only` は、手元に別のコミットがあるときに勝手にマージせず止めるためです。止まったら §4。
- **hakoniwa-mujoco-sensor は pull しません**。版は `deps.lock` が決め、W3 が照合します（違えば §4）。
- hakoniwa-godot-robot は humanoid のデモのコード（非公開）。hakoniwa-ncmachine・image2sim-framework は cobot を `--with-ncmachine` で建てたときだけあります。

### 3.3 setup_workspace を流す

建てたときと同じオプションに `--from 3` を付けます（W1 のツール・W2 の clone は済んでいるので飛ばす）。

```bash
cd ~/work_robot/work_git
bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --robot humanoid,cobot,armpi --from 3
# 例: SDK・Godot が既定の場所でないとき（環境変数で設定していなければ）
bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --robot humanoid,cobot,armpi --robo ~/devai_robo --godot /opt/Godot_v4.7.1/Godot_v4.7.1-stable_linux.x86_64 --from 3
```

| 段 | 更新のときにすること |
|---|---|
| W3 | 各ロボットの `deps.lock` と runtime・sensor の版を照合（違えば止まる） |
| W4 | `third_party` の版を runtime の `third_party.lock` と照合（違えば止まる） |
| W5 | SDK を確かめる。そろっていて版も同じなら**何もしない**（`SDK はそろっている` と出る）。違えば止まる |
| W6 | ロボットごとの準備をやり直す（venv・ビルド・Godot addon） |
| W7 | 確認と「次に動かすコマンド」 |

最後に「次に動かすコマンド」が出れば終わりです。

先に何が起きるかだけ見たいときは、`--from 3` の代わりに `--check` を付けます（何も作らず W3・W4・W7 の照合だけ）。

### 3.4 動かして確かめる

[START_HERE_linux.md](START_HERE_linux.md) §4 のとおり（W7 の最後にも出ます）。Godot を使う確認は、**画面のある PC のデスクトップの端末**で流します（SSH からは窓が出ません）。

## 4. 止まったとき

| 症状 | 対処 |
|---|---|
| pull が `Not possible to fast-forward` | 手元にコミットがある。要らなければ `git -C <リポジトリ> reset --hard origin/main`（**手元のコミットは消える**）。残すなら `git -C <リポジトリ> pull --rebase` |
| pull が `Your local changes … would be overwritten` | §3.1 の変更が残っている。`restore`・`stash`・コミットのどれかをしてから pull |
| W3 で `hakoniwa-mujoco-runtime のコミットが deps.lock と違う` | runtime の main が、ロボットの `deps.lock` より新しい（ロボット側の lock がまだ上がっていない）。表示の「lock の版にする」のコマンドを流して `--from 3`。runtime は main から外れた状態になるので、次の更新では §3.2 の `switch main` で戻る |
| W3 で `hakoniwa-mujoco-sensor のコミットが deps.lock と違う` | sensor の版が上がった。表示の「lock の版にする」のコマンド（`fetch --depth 1 …` と `checkout --detach …`）を流して `--from 3` |
| W3 で `runtime の hakoniwa-godot が runtime の記録と違う` | runtime の中の hakoniwa-godot（サブモジュール）が、pull した runtime の記録より古い。`git -C hakoniwa-mujoco-runtime submodule update --init --recursive third_party/hakoniwa-godot` で記録の版にして `--from 3` |
| W4 で `third_party の版が lock と違う` | 箱庭コアが上がった。下の「箱庭コアが上がったとき」 |
| W5 で `SDK が lock と違うか、足りません` | SDK を作り直す。下の「箱庭コアが上がったとき」の 2 から |
| W6 のビルドで止まった | 表示のログを見る。Godot・デモを止めてから `--from 6` |
| `$'\r': command not found` | bash の台本が CRLF になっている。`git config core.autocrlf false` にして、そのリポジトリで `git checkout -- .`（[START_HERE_linux.md](START_HERE_linux.md) §6） |
| ほかは | [START_HERE_linux.md](START_HERE_linux.md) §6 |

### 箱庭コアが上がったとき（約 15〜40 分）

1. `third_party` を取り直す（今のものは `third_party.old-<日時>` に退避。中身は触らない）

   ```bash
   python3 hakoniwa-mujoco-runtime/tools/hako_core/fetch_third_party.py --refresh
   ```

2. SDK を作り直して、ロボットもビルドし直す（今の SDK は `devai_robo.old-<日時>` に退避）

   ```bash
   bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --robot humanoid,cobot,armpi --from 4 --rebuild-sdk
   ```

   途中で止まったら、原因を直して `--from 5 --sdk-from <止まった S の番号> --rebuild-sdk`（作りかけは退避せずに続きから作る）。

3. §3.4 で確かめる。退避した `third_party.old-*`・`devai_robo.old-*` は、新しいもので動くのを確かめてから消します
   （戻すときは、新しいほうを別名にして、退避したものの名前を戻し、`--from 6` でロボットをビルドし直す）。

## 5. ドローンの作業場所

ドローンは別の作業場所（例 `~/work_drone/work_git`）です。流れは同じで、pull するリポジトリとオプションが違います。

> 下の手順を 1 本で行うスクリプトもあります: `bash hakoniwa-mujoco-drone/tools/local_sdk/update_workspace.bash`（pull → runtime・sensor を `deps.lock` の版に → 箱庭コアが違えば取り直し・SDK だけ作り直し → ビルド → hakodrone。`--check` で見るだけ。drone の [docs/manual/13_update.md](../../hakoniwa-mujoco-drone/docs/manual/13_update.md)）。

```bash
cd ~/work_drone/work_git
for r in hakoniwa-mujoco-drone hakoniwa-drone-companion hakoniwa-godot-drone hakoniwa-simenv-4dst hakoniwa-godot-4dst; do
  [[ -d "$r/.git" ]] && { echo "== $r"; git -C "$r" pull --ff-only; }
done
git -C hakoniwa-mujoco-runtime switch main
git -C hakoniwa-mujoco-runtime pull --ff-only
bash hakoniwa-mujoco-runtime/tools/linux/setup_workspace.sh --drone --from 3                  # ビューア・風況デモも建てたなら --godot --wind も。--test で ctest（約 25 分）
```

- ドローンの W5（drone の `tools/local_sdk/setup_linux.bash`）は、SDK・MuJoCo・venv があれば飛ばし（SDK の箱庭コアが lock と違えば止まる）、
  drone・companion のビルドをやり直します。
- 箱庭コアが上がったときは、`fetch_third_party.py --refresh` のあと `--drone --from 4 --rebuild-sdk`（SDK・MuJoCo・venv を作り直す）。
- W3 で runtime が `deps.lock` と違うと出たら、ロボットと同じく表示の「lock の版にする」を流して `--from 3`（drone・companion の `deps.lock` が runtime の main より古いとき）。
- companion の `deps.lock` は drone の版も決めています。W3 で drone が違うと出たら、drone を pull し忘れていないか、表示の「lock の版にする」を見ます。

## 6. 関連

| 知りたいこと | 文書 |
|---|---|
| 新しく建てる・各段とオプションの意味・動かし方 | [START_HERE_linux.md](START_HERE_linux.md) |
| Windows の作業場所を新しくする | [UPDATE_HERE.md](UPDATE_HERE.md) |
| 箱庭コアを上流の最新に上げる（上げる側の手順） | [hako_core_update.md](hako_core_update.md) |
