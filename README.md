# miraiserver — Linux サーバー初期設定スクリプト

Rocky Linux / AlmaLinux / Debian GNU/Linux / Ubuntu に対応した、SSH を中心としたセキュリティ初期設定を **1 本のスクリプトで完結** させるためのツールです。

> [みらいサーバー 資料集](https://miraistudio.notion.site/1106c35ce62580d08150f6df42f8e8ca) の手順をベースに、OS 自動判定・ロックアウト防止・自動検証を加えて自動化しています。

---

## 対応 OS

| ディストリビューション | バージョン |
|---|---|
| Rocky Linux | 8 / 9 |
| AlmaLinux | 8 / 9 |
| Debian GNU/Linux | 11 / 12 |
| Ubuntu | 20.04 / 22.04 / 24.04 |

`/etc/os-release` を読んで自動で `rhel` / `debian` のどちらかのコマンドセットに分岐します。

---

## 実行内容

| # | 項目 | 詳細 |
|---|---|---|
| 1 | 一般ユーザー作成 + sudo 権限 | `useradd` → `passwd` → `wheel` (RHEL) / `sudo` (Debian) グループ追加 |
| 2 | SSH 公開鍵の登録 | `~/.ssh/authorized_keys` に追記 (パーミッション・所有権も自動設定) |
| 3 | sshd_config 編集 | Port 変更 / PasswordAuthentication no / ChallengeResponseAuthentication no |
| 4 | SELinux ポート許可 | (RHEL のみ) `semanage port -a -t ssh_port_t` |
| 5 | ファイアウォール設定 | firewalld にカスタムサービス作成 / ufw allow |
| 6 | sshd 再起動 | `sshd -t` で構文検証後に `systemctl restart` |
| 7 | **Docker CE + docker compose plugin (任意)** | 公式リポジトリ追加 → 本体インストール → docker グループに新ユーザー追加 |
| 8 | SSH 接続自動検証 | Lv1: LISTEN チェック / Lv2: SSH ハンドシェイク (`/dev/tcp`) |
| 9 | 旧ポート 22 を即時閉鎖 | 検証通過後に firewall から 22/tcp を削除 |

---

## クイックスタート

サーバーに root で SSH ログインしてから、以下のいずれかで実行します。

### 方法 A: `curl` でワンライナー実行 (最速)

```bash
# サーバー側で実行
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/miraistudio/mirai_server/main/setup.sh)"
```

> **注意**: ワンライナー実行は内容の事前確認がしづらいため、初回はまず以下のように **ダウンロードして中身を読んでから** 実行することを推奨します。

```bash
curl -fsSL -o setup.sh https://raw.githubusercontent.com/miraistudio/mirai_server/main/setup.sh
less setup.sh        # 中身を確認
sudo bash setup.sh
```

### 方法 B: `git clone` で取得 (透明性高い)

```bash
# git が無い場合は先にインストール (RHEL: dnf install -y git / Debian: apt install -y git)
git clone https://github.com/miraistudio/mirai_server.git
cd mirai_server
sudo bash setup.sh
```

### 方法 C: ローカル PC から `scp` で転送

```bash
# PC 側
scp setup.sh root@<server-ip>:/root/

# サーバー側
ssh root@<server-ip>
sudo bash /root/setup.sh
```

実行後はスクリプトが PC 側で実行すべき接続コマンドを **コピペ可能な形** で出力します。

---

## 対話プロンプト

スクリプト起動後、以下を順に聞かれます。

| # | 質問 | 既定値 | 備考 |
|---|---|---|---|
| 1 | 作成する一般ユーザー名 | - | 必須 |
| 2 | 新しい SSH ポート | `10022` | 1024–65535 |
| 3 | 公開鍵の登録方法 | - | 1: ファイル / 2: 貼付 / 3: サーバー上で新規生成 / 4: スキップ |
| 4 | パスワード認証を無効化 | `Y` | 公開鍵未登録のときは自動で N |
| 5 | OS パッケージのアップデート | `Y` | `dnf upgrade` / `apt upgrade` |
| 6 | Docker のインストール | `N` | y で Docker CE + compose plugin |
| 7 | 実行確認 | `N` | 明示的に y で開始 |

実行中に **新規ユーザーのパスワード** を `passwd` で 2 回入力します。

---

## 公開鍵の登録方式

| モード | 用途 |
|---|---|
| 1) ファイル指定 | サーバー上に既に `.pub` がある場合 |
| 2) 貼り付け | 1 行ペーストで完結 (最も手軽) |
| 3) サーバー上で新規生成 | PC に鍵が無い場合。ed25519 を生成し、画面表示後に破棄 |
| 4) スキップ | パスワード認証を継続する場合 |

> モード 3 の秘密鍵はスクリプト内で `mktemp -d` した一時領域に作られ、ユーザーが Enter を押した時点でサーバー上から完全削除されます。**画面に表示されている間に必ず PC へ保存してください**。

---

## ロックアウト防止策

サーバーを「ssh で締め出される」事故を防ぐため、以下の段階的安全策を組み込んでいます。

| 段階 | 仕組み |
|---|---|
| sshd_config 書き換え前 | `cp` で `sshd_config.bak.<timestamp>` に退避 |
| sshd 再起動前 | `sshd -t` で構文検証。NG なら自動ロールバック |
| ファイアウォール設定 | 旧 22 と 新ポートを **両方** 開いた状態で sshd 再起動 |
| sshd 再起動後 | Lv1 (LISTEN チェック) + Lv2 (`/dev/tcp` でハンドシェイク確認) |
| 検証 OK | はじめて 22/tcp を閉じる |
| 検証 NG | 22/tcp は開放のまま終了 → 元の経路で復旧可能 |

加えて、Ubuntu の `cloud-init` などが書き込む `sshd_config.d/50-cloud-init.conf` と競合しないよう、**`00-mirai-setup.conf` (先勝)** にドロップイン設定を書き出します。

---

## Docker のインストール (オプション)

| OS | リポジトリ | パッケージ |
|---|---|---|
| Rocky / Alma | `https://download.docker.com/linux/centos/docker-ce.repo` | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` |
| Debian / Ubuntu | `https://download.docker.com/linux/{debian,ubuntu}` (GPG キー検証付き) | 同上 |

- 旧版の `docker`, `podman`, `runc` 等は事前に削除
- `systemctl enable --now docker`
- `groupadd -f docker` → 新規ユーザーを `docker` グループに追加

> `docker` グループの反映には **再ログインが必要** です (スクリプト出力の最後で案内)。

---

## 出力されるコピペ用コマンド

スクリプト完了時、以下が PC のターミナルにそのまま貼り付け可能な形で表示されます。

```bash
# ----- [1] SSH 接続テスト ---------------------------------------
ssh deploy@198.51.100.10 -p 10022 -i ~/.ssh/deploy_ed25519

# ----- [2] ~/.ssh/config に追記 (推奨) --------------------------
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/config <<'SSHCONF'

Host mirai-server
    HostName 198.51.100.10
    Port 10022
    User deploy
    IdentityFile ~/.ssh/deploy_ed25519
    ServerAliveInterval 60
SSHCONF
chmod 600 ~/.ssh/config

# 追記後はこれだけで接続可能:
ssh mirai-server

# ----- [3] sudo 動作確認 ---------------------------------------
ssh mirai-server 'sudo whoami'

# ----- [4] Docker 動作確認 (再ログイン後) ----------------------
ssh mirai-server 'docker ps'
ssh mirai-server 'docker compose version'
```

---

## スクリプト外で必要な手作業

スクリプトは触らないので、手動で対応してください。

| 項目 | 対応方法 |
|---|---|
| クラウド側ファイアウォール (AWS Security Group / さくら パケットフィルタ等) | クラウド管理画面で新 SSH ポート (例: 10022) を許可 |
| PC 側の `~/.ssh/config` | 上記コピペコマンドの [2] を貼るだけ |
| Docker の動作確認 | docker グループ反映のため一度ログアウト → 再ログイン |

---

## トラブルシューティング

### sshd が新ポートで起動しない

スクリプトが Lv1 (LISTEN チェック) で失敗した場合、`port 22` は開放状態のまま終了します。サーバーに 22 番で再接続して、以下で復旧してください。

```bash
sudo cp -a /etc/ssh/sshd_config.bak.<timestamp> /etc/ssh/sshd_config
sudo systemctl restart sshd   # Debian/Ubuntu は ssh
```

### `cloud-init` の設定が優先されてしまう

`/etc/ssh/sshd_config.d/` 内の他ファイル (`50-cloud-init.conf` など) に `Port` や `PasswordAuthentication` の記述がある場合、本スクリプトは **`00-mirai-setup.conf`** (先勝) として書き出すため自動で勝ちます。それでも問題が起きる場合は競合ファイルを直接編集してください。

### 新規ユーザーで `sudo` が使えない

- `wheel` (RHEL) / `sudo` (Debian) グループに入っていない可能性 → `groups <username>` で確認
- `/etc/sudoers` に `%wheel ALL=(ALL) ALL` が無い場合、スクリプトが `/etc/sudoers.d/99-wheel` を自動作成しています

### Docker コマンドが「permission denied」

`docker` グループ追加後の **再ログイン忘れ** がほぼ全てです。

```bash
exit
ssh mirai-server
docker ps   # → 動くはず
```

---

## ファイル構成

```
.
├── setup.sh        # 本体スクリプト
├── README.md       # このファイル
└── .gitignore
```

---

## ライセンス

MIT License (お好みのライセンスに変更してください)

---

## 参考

- [みらいサーバー 資料集 (Notion)](https://miraistudio.notion.site/1106c35ce62580d08150f6df42f8e8ca)
- [Docker Engine Install Guide](https://docs.docker.com/engine/install/)
- [OpenSSH sshd_config(5)](https://man.openbsd.org/sshd_config)
