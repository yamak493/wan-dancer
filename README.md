# Wan-Dancer on RunPod

[Wan-Dancer](https://humanaigc.github.io/wan-dancer-project/) 用の RunPod テンプレート
ブートストラップ。ポッドを起動するだけで ComfyUI + Wan-Dancer 14B のモデル一式が
そろい、すぐに「参照画像 + 音楽 → ダンス動画」を生成できる状態になります。

Wan-Dancer は Wan 2.2 ベースの music-to-dance モデルで、**global**（全体の振り付け）と
**local**（手足・頭の細かい動き）の 2 つのエキスパートを組み合わせる構成です。
本テンプレートは ComfyUI の**ネイティブ** Wan ノードで動かします。

---

## 1. RunPod テンプレート設定

添付いただいた設定をベースに、**1 箇所だけ変更が必要**です。

| 項目 | 値 |
|---|---|
| Template type | Pods |
| Compute type | NVIDIA GPU |
| Container image | `runpod/comfyui:latest` |
| Container start command | 下記 |
| **Container disk** | **80 GB**（添付の設定どおりでOK） |
| Persistent storage (Volume disk) | **0 GB のままでOK** |
| Persistent storage mount path | `/workspace` |
| Expose HTTP ports | `8188` |

### Container start command

```bash
bash -c "git clone https://github.com/yamak493/wan-dancer.git /tmp/setup && bash /tmp/setup/setup.sh"
```

（現在ご設定の内容のままで動きます。）

### 使用頻度が低い前提の設計（毎回ダウンロード）

永続ボリュームは使わず、**起動ごとに Hugging Face から並列ダウンロード**します。
使う機会が少ないなら、待機中のストレージ課金を払うよりこの方が合理的です。

高速化は 2 段構えです。

1. **ファイル内の並列化** — Hugging Face のチャンク分割マルチコネクション転送。
   どれが有効かは `huggingface_hub` のバージョンで変わります:
   - **1.x** → **Xet**（`hf_xet`）。`HF_XET_HIGH_PERFORMANCE=1` で並列数とバッファを引き上げ
   - **0.x** → **hf_transfer**（Rust 実装のマルチコネクション DL）

   インストール済みバージョンを検出して**正しい方だけ**を有効化します。
   ここは要注意で、`huggingface_hub` 1.x では `HF_HUB_ENABLE_HF_TRANSFER` は
   **廃止されており、設定しても無視されます**（1.x で残っていたら警告して除去します）。
2. **ファイル間の並列化** — スレッドプールで既定 4 本同時。約 16 GB のエキスパート 2 本が
   直列に並ばず同時に飛びます。`WD_DOWNLOAD_CONCURRENCY` で変更可。

並列時は個別のプログレスバーがログ上で混ざって読めなくなるため抑止し、代わりに
**集約進捗**を 15 秒ごとに 1 行出します（実際にディスクに着いたバイト数を数えるので、
転送中の部分ファイルも反映されます）:

```
[download] progress 12.4 GiB of ~45.2 GiB (231 MiB/s avg, ~2 min left)
```

体感目安: 回線の良い RunPod リージョンで **5〜15 分**程度。終了時に実測スループットを出します。

**キャッシュしたい場合**は Volume disk を 100 GB にして `/workspace` にマウントすれば、
自動検出してそちらを使います（2 回目以降の起動は 1〜2 分）。スクリプトは
どちらのモードでも動きます。

### 進行状況の確認

**ポート 8188 をブラウザで開いてください。** セットアップ中は進捗ページが、完了後は
ComfyUI が、同じポートに出ます（RunPod の **Connect → HTTP Service (8188)**）。

ComfyUI は全ステージ終了後にしか起動しないため、そのままだとダウンロード中の
5〜15 分間ポートが死んだままになります。そこを進捗ページが埋めます。

```
Wan-Dancer setup                       port 8188 · phase setup · elapsed 3m 34s

  Setting up…
  Models are downloading. ComfyUI starts automatically when this finishes.

  STAGES                              MODEL DOWNLOAD
  ✓ System dependencies      24s        27%
  ✓ Storage layout            1s        12.4 GiB of 45.2 GiB · 231 MiB/s · ~2m 28s left
  ✓ ComfyUI                  18s        [███████░░░░░░░░░░░░░░░░]
  ✓ Custom nodes             11s
  ⟳ Model download        2m 40s        ⟳ wan2.2_dancer_14b_global_fp8…   16.2 GiB
  · Workflows                           ⟳ wan2.2_dancer_14b_local_fp8…    16.2 GiB
                                        ✓ wan_2.1_vae.safetensors          0.24 GiB
  LOG (last 200 lines)
  [download] progress 12.4 GiB of ~45.2 GiB (231 MiB/s avg, ~2 min left)
```

5 秒ごとに自動更新（meta refresh のみ、JavaScript なし）。ステージ一覧、ダウンロード
進捗と ETA、ファイル単位の状態、最後に**ログ末尾 200 行**が出ます。準備完了の判定
結果（どのモデルが欠けているか）もここに出るので、失敗時の原因もブラウザだけで分かります。

準備ができると ComfyUI にポートを明け渡します。数秒後にリロードしてください。

他の確認経路:

| 経路 | 用途 |
|---|---|
| `http://<pod>:8188/` | 進捗ページ（上記） |
| `http://<pod>:8188/status.json` | 生の状態。`curl` やスクリプト向け |
| `http://<pod>:8188/log` | ログ全文（プレーンテキスト） |
| RunPod の **Logs** タブ | 同じ内容がコンテナログにも流れます |
| `/var/log/wan-dancer/setup.log` | ログファイル。**ComfyUI 起動後の出力も同じファイルに続きます** |

RunPod の Logs ペインはバッファが有限で Pod 再起動で履歴が消えるため、ログファイルにも
残すようにしています。

進捗ページが不要なら `WD_STATUS_PAGE=0`、または `setup.sh --no-status` で無効化できます。
ポートが既に埋まっている場合は警告を 1 行出して**起動処理はそのまま続行**します。

### ⚠️ ターミナル（シェル）について

RunPod の Container start command は**イメージの CMD を置き換えます**
（[RunPod ドキュメント](https://docs.runpod.io/pods/templates/manage-templates)）。
公式イメージで web terminal や JupyterLab を起動しているのはイメージ側の
`/start.sh` なので、**それらは起動しません**。つまりセットアップ中にシェルへ入れない
可能性があります。

これを踏まえて、進捗ページがログ末尾を表示する設計にしてあります（「今何をしているか」
「なぜ失敗したか」はシェル無しで分かります）。イメージ側のサービス一式に任せたい場合は
`WD_USE_IMAGE_ENTRYPOINT=1` を設定してください（ComfyUI の起動もイメージ側に委ねられます）。

### GPU

14B を 149 フレーム一括で回すため VRAM を大量に使います。**48 GB 以上（A6000 /
L40S / A100 / H100）推奨**。24 GB クラスでも `--lowvram` に自動で落として動きますが、
オフロードが入るため大幅に遅くなります。

---

## 2. 起動後の使い方

1. RunPod の **Connect → HTTP Service (8188)** から ComfyUI を開く。
2. 左の **Workflows** サイドバーに Wan-Dancer のワークフローが入っています。
   （無い場合は **Browse Templates** から "Wan Dancer" を選択。）
3. 入力ファイルを置く。`/workspace/wan-dancer/input/` に入れたものが
   LoadImage / LoadAudio のドロップダウンに出ます。
   - 参照画像: キャラクターの**全身**が写ったもの（バストアップより全身が有利。
     モデルは見えていない手足を動かせません）
   - 音楽: ビートが明確な wav / mp3。**生成コストは尺に比例**するので先に短く切る
4. **Run**。出力は `/workspace/wan-dancer/output/`（永続）に保存されます。

---

## 3. 中身

```
setup.sh                     エントリポイント。6 ステージを実行して ComfyUI を exec
config/models.tsv            モデルマニフェスト（ここを編集すれば構成が変わります）
config/custom_nodes.txt      入れるカスタムノード一覧
scripts/lib.sh               ログ / リトライ / symlink / 状態マーカー
scripts/paths.sh             ComfyUI 位置検出、モデル保存先の決定
scripts/01_system_deps.sh    ffmpeg, git-lfs, aria2, huggingface_hub[hf_transfer]
scripts/02_storage.sh        models/* を永続ボリュームへ symlink
scripts/03_comfyui.sh        ComfyUI を最新へ更新 + torch/torchaudio 検証
scripts/04_custom_nodes.sh   ComfyUI-Manager / KJNodes / VideoHelperSuite
scripts/05_models.sh         モデル取得（stage 5）
scripts/download.py          マニフェスト駆動ダウンローダ
scripts/06_workflows.sh      ワークフロー JSON を配置
scripts/healthcheck.sh       準備完了チェック（単体実行可）
scripts/wd_status.py         状態ファイル（アトミック書き込み + 再帰マージ）
scripts/status.sh            状態ファイルの bash ラッパ
scripts/status_server.py     進捗ページ（標準ライブラリのみ・JS なし）
scripts/90_start.sh          ComfyUI をフォアグラウンドで起動
```

### 設計上のポイント

**冪等性。** 全ステージが再実行可能です。サイズが HuggingFace 側のメタデータと
一致するファイルは再ダウンロードしません。完了したステージは
`/workspace/wan-dancer/.state/` のマーカーでスキップされます。

**パス変更への耐性。** `config/models.tsv` のパスのうち、**正しくある必要があるのは
ファイル名（basename）だけ**です。上流リポジトリでファイルが `split_files/` を
出入りしても、`download.py` が HuggingFace API でリポジトリ内の実パスを
basename から引き直します。

**フォアグラウンド常駐。** RunPod の start command はイメージの CMD を**置き換える**ため、
ComfyUI を起動するものが他にありません。`setup.sh` は最後に `exec` で
`90_start.sh` に渡し、そのまま常駐します（返ると Pod が停止します）。

**コア / 非コアの区別。** コアモデルの取得失敗は exit 1 ですが、ComfyUI は起動します
（ブラウザから原因を確認して再試行できるように）。LoRA など非コアの失敗は警告のみ。

---

## 4. 運用

### 再実行・部分実行

```bash
# モデルだけ再取得（差分のみ）
bash /tmp/setup/setup.sh --models-only

# セットアップのみ、ComfyUI は起動しない
bash /tmp/setup/setup.sh --no-start

# 状態マーカーを無視して全ステージやり直し
bash /tmp/setup/setup.sh --force

# 進捗ページを立てずに実行
bash /tmp/setup/setup.sh --no-status
```

### 準備状況の確認

```bash
COMFY_DIR=/ComfyUI WD_REPO_DIR=/tmp/setup bash /tmp/setup/scripts/healthcheck.sh
```

各モデルファイルの有無・サイズと、**この ComfyUI ビルドが Wan-Dancer ノードを
実際に持っているか**をノードレジストリから確認して表示します。

### 設定の上書き

`.env.example` を `.env` としてコピーするか、`/workspace/wan-dancer/.env` に置きます
（永続ボリューム側が後に読まれます）。RunPod テンプレートの環境変数でも同じ
`WD_*` キーが使えます。主なもの:

| 変数 | 既定 | 説明 |
|---|---|---|
| `HF_TOKEN` | – | モデルが gated 化した場合に必要 |
| `WD_MODEL_GROUPS` | `core,speed` | 取得するマニフェストグループ |
| `WD_DOWNLOAD_CONCURRENCY` | `4` | 同時ダウンロードするファイル数 |
| `WD_UPGRADE_HF_HUB` | `0` | `1` で `huggingface_hub` を最新化（下記注意） |
| `WD_TEXT_ENCODER` | `fp8` | `fp16` で UMT5 を fp16 に |
| `WD_VRAM_MODE` | `auto` | `highvram` / `normalvram` / `lowvram` |
| `WD_UPDATE_COMFYUI` | `1` | 起動時に ComfyUI を git pull |
| `WD_COMFY_PORT` | `8188` | ComfyUI と進捗ページのポート |
| `WD_STATUS_PAGE` | `1` | `0` で進捗ページを無効化 |
| `WD_LOG_FILE` | `/var/log/wan-dancer/setup.log` | ログファイルの出力先 |
| `WD_STATUS_DIR` | `/tmp/wan-dancer` | 状態ファイルの置き場 |
| `WD_USE_IMAGE_ENTRYPOINT` | `0` | `1` でイメージ標準の起動スクリプトに委譲 |

---

## 5. トラブルシューティング

**Wan-Dancer ノードが出てこない** — ベースイメージの ComfyUI が古い可能性があります。
`healthcheck.sh` の "ComfyUI node support" を確認してください。`WD_UPDATE_COMFYUI=1`
（既定）で更新を試みますが、イメージが git チェックアウトでない場合は更新できません。
その場合はより新しいベースイメージを指定してください。

**ダウンロードが遅い** — 起動ログ冒頭の `transfer backend:` 行を確認してください。
`Xet NOT installed` / `hf_transfer NOT installed` と出ている場合は並列転送が効かず
素の HTTPS に落ちています（ステージ 1 が該当パッケージの導入を試みます）。
`WD_DOWNLOAD_CONCURRENCY` を 6〜8 に上げるのも有効ですが、回線が飽和していると
逆効果です。集約進捗行の MiB/s を見て判断してください。

**`huggingface_hub` を上げたい** — 既定では**上げません**。イメージの
`transformers` が 1.0 未満にピン留めしていることがあり、ダウンローダの高速化と
引き換えにそれを壊すのは損です。`WD_UPGRADE_HF_HUB=1` で明示的に有効化できます。

**`no space left on device`** — Container disk / Volume disk の残量を確認。
`WD_TEXT_ENCODER=fp8`（既定）と `WD_DOWNLOAD_OPTIONAL=0`（既定）のままにし、
`WD_MODEL_GROUPS=core` にすると LoRA 分 1.2 GB を節約できます。

**サンプリング中に OOM** — `WD_VRAM_MODE=lowvram` を設定し、ワークフローの
フレーム数・解像度を下げてください。

**進捗ページが出ない** — 起動ログに `not starting progress page` があれば、そのポートを
既に何かが掴んでいます（イメージが独自に ComfyUI を起動している等）。その場合も
セットアップ自体は続行するので、RunPod の Logs タブで進捗を確認してください。

**進捗ページのまま ComfyUI に切り替わらない** — ログの `port <N> is free` を確認して
ください。`still in use` が出ている場合、進捗ページ以外の何かがポートを保持しています。

**Pod が即停止する** — start command の最後がフォアグラウンド常駐になっている必要が
あります。`setup.sh` をそのまま最後に呼ぶ形（上記のコマンド）を崩さないでください。

---

## 出典

- [Wan-Dancer プロジェクトページ](https://humanaigc.github.io/wan-dancer-project/)
- [Wan-AI/Wan-Dancer-14B (HuggingFace)](https://huggingface.co/Wan-AI/Wan-Dancer-14B)
- [Comfy-Org/Wan-Dancer (ComfyUI 用ウェイト)](https://huggingface.co/Comfy-Org/Wan-Dancer)
- [ComfyUI 公式チュートリアル: Wan Dancer](https://docs.comfy.org/tutorials/video/wan/wan-dancer)
- [Comfy-Org/Wan_2.1_ComfyUI_repackaged](https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged)
- [Comfy-Org/Wan_2.2_ComfyUI_Repackaged](https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged)
- [Kijai/WanVideo_comfy](https://huggingface.co/Kijai/WanVideo_comfy)
