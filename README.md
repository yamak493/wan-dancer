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
| Container disk | 40 GB |
| **Persistent storage (Volume disk)** | **100 GB** ← **0 GB から変更してください** |
| Persistent storage mount path | `/workspace` |
| Expose HTTP ports | `8188` |

### Container start command

```bash
bash -c "git clone https://github.com/yamak493/wan-dancer.git /tmp/setup && bash /tmp/setup/setup.sh"
```

（現在ご設定の内容のままで動きます。）

### ⚠️ Volume disk 0 GB は必ず変更してください

これが「いつでも生成できる状態」の要です。

- RunPod の **Container disk は Pod を停止すると消去されます**。
- Volume disk = 0 GB のままだと、モデル約 **45 GB** が container disk に落ちるため、
  **停止 → 起動のたびに 45 GB を再ダウンロード**することになります（毎回 15〜40 分）。
- Volume disk を 100 GB にすると `/workspace` が永続化され、モデルはそこに保存されます。
  2 回目以降の起動は**約 1〜2 分**で生成可能になります。

`setup.sh` は永続ボリュームの有無を自動判定します。未接続の場合も動作はしますが、
ログに大きな警告を出します。

容量の目安（Volume disk 100 GB 推奨）:

| 用途 | サイズ |
|---|---|
| dancer global / local エキスパート (fp8) | 約 16 GB × 2 |
| UMT5-XXL text encoder (fp8_scaled) | 約 6.7 GB |
| CLIP Vision H | 約 1.2 GB |
| Wan 2.1 VAE | 約 250 MB |
| wav2vec2 audio encoder (fp16) | 約 630 MB |
| LightX2V lightning LoRA | 約 1.2 GB |
| HF キャッシュ + 出力動画 | 余裕分 |

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
| `WD_TEXT_ENCODER` | `fp8` | `fp16` で UMT5 を fp16 に |
| `WD_VRAM_MODE` | `auto` | `highvram` / `normalvram` / `lowvram` |
| `WD_UPDATE_COMFYUI` | `1` | 起動時に ComfyUI を git pull |
| `WD_COMFY_PORT` | `8188` | ComfyUI のポート |
| `WD_USE_IMAGE_ENTRYPOINT` | `0` | `1` でイメージ標準の起動スクリプトに委譲 |

---

## 5. トラブルシューティング

**Wan-Dancer ノードが出てこない** — ベースイメージの ComfyUI が古い可能性があります。
`healthcheck.sh` の "ComfyUI node support" を確認してください。`WD_UPDATE_COMFYUI=1`
（既定）で更新を試みますが、イメージが git チェックアウトでない場合は更新できません。
その場合はより新しいベースイメージを指定してください。

**起動のたびにダウンロードが走る** — Volume disk が 0 GB です。上記セクション 1 を参照。

**`no space left on device`** — Container disk / Volume disk の残量を確認。
`WD_TEXT_ENCODER=fp8`（既定）と `WD_DOWNLOAD_OPTIONAL=0`（既定）のままにし、
`WD_MODEL_GROUPS=core` にすると LoRA 分 1.2 GB を節約できます。

**サンプリング中に OOM** — `WD_VRAM_MODE=lowvram` を設定し、ワークフローの
フレーム数・解像度を下げてください。

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
