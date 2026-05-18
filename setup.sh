#!/usr/bin/env bash
#
# setup.sh - みらいサーバー 初期セキュリティ設定スクリプト
#
# 対応OS:
#   - Rocky Linux 8 / 9
#   - AlmaLinux 8 / 9
#   - Debian GNU/Linux 11 / 12
#   - Ubuntu 20.04 / 22.04 / 24.04
#
# 実行内容 (Notion「みらいサーバー 資料集」準拠):
#   1. 一般ユーザー作成 + sudo 権限付与 (wheel / sudo グループ)
#   2. SSH 公開鍵を authorized_keys に登録
#   3. sshd_config 編集
#        - Port 変更
#        - PasswordAuthentication no
#        - ChallengeResponseAuthentication no
#   4. SELinux ポート許可 (RHEL 系のみ)
#   5. firewalld / ufw で新ポートを許可
#   6. sshd 再起動 (旧ポートは一旦残し、検証後に閉鎖)
#   7. (任意) Docker CE + docker compose plugin インストール
#        - Docker 公式リポジトリ追加
#        - docker サービスの自動起動
#        - 一般ユーザーを docker グループに追加
#
# 使い方:
#   sudo bash setup.sh
#
set -euo pipefail

# ============================================================================
# プレースホルダ (実行前に書き換えるか、対話プロンプトで入力)
# ============================================================================
DEFAULT_NEW_USER=""     # 例: deploy / mirai など
DEFAULT_SSH_PORT="10022"        # 推奨: 10022 (他サービスと被らない 1024-65535)
# ============================================================================

C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[0;33m'; C_BLU='\033[0;34m'; C_RST='\033[0m'
log()  { printf "${C_BLU}[INFO]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YLW}[WARN]${C_RST} %s\n" "$*"; }
err()  { printf "${C_RED}[ERR ]${C_RST} %s\n" "$*" >&2; }
ok()   { printf "${C_GRN}[ OK ]${C_RST} %s\n" "$*"; }

# ----------------------------------------------------------------------------
# 事前チェック
# ----------------------------------------------------------------------------
if [[ ${EUID} -ne 0 ]]; then
  err "root 権限で実行してください: sudo bash $0"
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  err "/etc/os-release が読めません。サポート対象外OSです。"
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release

OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
case " ${OS_ID} ${OS_LIKE} " in
  *" rocky "*|*" almalinux "*|*" rhel "*|*" centos "*|*" fedora "*)
    OS_FAMILY="rhel"
    PKG_MGR="dnf"
    SSH_SERVICE="sshd"
    SUDO_GROUP="wheel"
    ;;
  *" ubuntu "*|*" debian "*)
    OS_FAMILY="debian"
    PKG_MGR="apt"
    SSH_SERVICE="ssh"
    SUDO_GROUP="sudo"
    ;;
  *)
    err "サポート対象外OSです: ID=${OS_ID} ID_LIKE=${OS_LIKE}"
    exit 1
    ;;
esac
log "検出OS: ${PRETTY_NAME:-${OS_ID}} (family=${OS_FAMILY})"

# ----------------------------------------------------------------------------
# 対話入力
# ----------------------------------------------------------------------------
echo
echo "==== 初期設定の入力 ===="

read -rp "作成する一般ユーザー名 [${DEFAULT_NEW_USER}]: " NEW_USER
NEW_USER="${NEW_USER:-${DEFAULT_NEW_USER}}"
if [[ "${NEW_USER}" == "changeme" ]]; then
  err "プレースホルダ 'changeme' のままです。ユーザー名を指定してください。"
  exit 1
fi
if ! [[ "${NEW_USER}" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
  err "ユーザー名の形式が不正です: ${NEW_USER}"
  exit 1
fi

read -rp "新しい SSH ポート番号 [${DEFAULT_SSH_PORT}]: " SSH_PORT
SSH_PORT="${SSH_PORT:-${DEFAULT_SSH_PORT}}"
if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  err "SSH ポート番号が不正です: ${SSH_PORT}"
  exit 1
fi
if (( SSH_PORT == 22 )); then
  warn "ポートが 22 のままです。デフォルトポート変更の意味がありません。"
fi

echo
echo "公開鍵の登録方法を選択してください:"
echo "  1) ファイルパスを指定 (例: /tmp/id_ed25519.pub)"
echo "  2) ターミナルに 1 行貼り付け"
echo "  3) サーバー上で新規作成 (ed25519, パスフレーズなし)"
echo "  4) スキップ (パスワード認証を残す)"
read -rp "選択 [1-4]: " PUBKEY_CHOICE
PUBKEY_DATA=""
PUBKEY_MODE=""
PUBKEY_PATH=""
case "${PUBKEY_CHOICE}" in
  1)
    PUBKEY_MODE="file"
    read -rp "公開鍵ファイルのパス: " PUBKEY_PATH
    if [[ ! -r "${PUBKEY_PATH}" ]]; then
      err "ファイルが読めません: ${PUBKEY_PATH}"
      exit 1
    fi
    PUBKEY_DATA="$(cat "${PUBKEY_PATH}")"
    ;;
  2)
    PUBKEY_MODE="paste"
    echo "公開鍵 (ssh-ed25519/ssh-rsa/... で始まる 1 行) を貼り付けて Enter:"
    IFS= read -r PUBKEY_DATA
    ;;
  3)
    PUBKEY_MODE="generate"
    log "鍵ペアは実行直前にサーバー上で生成します (秘密鍵は画面表示後に破棄)"
    ;;
  4)
    PUBKEY_MODE="skip"
    warn "公開鍵設定をスキップします。パスワード認証は維持されます。"
    ;;
  *)
    err "選択が不正です。"
    exit 1
    ;;
esac

if [[ "${PUBKEY_MODE}" =~ ^(file|paste)$ ]] \
   && ! [[ "${PUBKEY_DATA}" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-) ]]; then
  err "公開鍵の形式が認識できません: $(printf %.40s "${PUBKEY_DATA}")..."
  exit 1
fi

read -rp "パスワード認証を無効化しますか? [Y/n]: " DISABLE_PW
DISABLE_PW="${DISABLE_PW:-Y}"
if [[ "${PUBKEY_MODE}" == "skip" && "${DISABLE_PW^^}" == "Y" ]]; then
  warn "公開鍵未設定のため、ロックアウト防止のためパスワード認証は無効化しません。"
  DISABLE_PW="N"
fi

read -rp "OS パッケージを最新にアップデートしますか? [Y/n]: " DO_UPDATE
DO_UPDATE="${DO_UPDATE:-Y}"

read -rp "Docker CE と docker compose plugin をインストールしますか? [y/N]: " DO_DOCKER
DO_DOCKER="${DO_DOCKER:-N}"

echo
echo "==== 設定確認 ===="
printf "  OS              : %s\n" "${PRETTY_NAME:-${OS_ID}}"
printf "  新規ユーザー    : %s (グループ %s)\n" "${NEW_USER}" "${SUDO_GROUP}"
printf "  新 SSH ポート   : %s\n" "${SSH_PORT}"
PUBKEY_DESC="なし"
case "${PUBKEY_MODE}" in
  file)     PUBKEY_DESC="ファイル: ${PUBKEY_PATH}" ;;
  paste)    PUBKEY_DESC="貼付済み" ;;
  generate) PUBKEY_DESC="サーバー上で新規生成 (ed25519)" ;;
  skip)     PUBKEY_DESC="スキップ" ;;
esac
printf "  公開鍵          : %s\n" "${PUBKEY_DESC}"
printf "  パスワード認証  : %s\n" "$( [[ "${DISABLE_PW^^}" == "Y" ]] && echo "無効化" || echo "そのまま" )"
printf "  OS アップデート : %s\n" "$( [[ "${DO_UPDATE^^}" == "Y" ]] && echo "実施" || echo "スキップ" )"
printf "  Docker          : %s\n" "$( [[ "${DO_DOCKER^^}" == "Y" ]] && echo "インストール (${NEW_USER} を docker グループに追加)" || echo "スキップ" )"
echo "=================="
read -rp "実行してよろしいですか? [y/N]: " CONFIRM
[[ "${CONFIRM^^}" == "Y" ]] || { warn "中止しました。"; exit 0; }

# ----------------------------------------------------------------------------
# OS アップデート
# ----------------------------------------------------------------------------
if [[ "${DO_UPDATE^^}" == "Y" ]]; then
  log "OS パッケージをアップデートします..."
  if [[ "${PKG_MGR}" == "dnf" ]]; then
    dnf -y upgrade
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
  fi
  ok "OS アップデート完了"
fi

# ----------------------------------------------------------------------------
# 必須パッケージのインストール
# ----------------------------------------------------------------------------
log "必須パッケージをインストールします..."
if [[ "${PKG_MGR}" == "dnf" ]]; then
  dnf -y install sudo openssh-server firewalld policycoreutils-python-utils
  systemctl enable --now firewalld
  systemctl enable --now "${SSH_SERVICE}"
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get -y install sudo openssh-server ufw
  systemctl enable --now "${SSH_SERVICE}"
fi
ok "パッケージ準備完了"

# ============================================================================
# 1. 一般ユーザー作成 + sudo 権限付与
# ============================================================================
if id -u "${NEW_USER}" >/dev/null 2>&1; then
  log "ユーザー '${NEW_USER}' は既に存在します。作成をスキップします。"
else
  log "一般ユーザー '${NEW_USER}' を作成します"
  useradd -m -s /bin/bash "${NEW_USER}"
  ok "ユーザー作成完了"

  log "ユーザー '${NEW_USER}' のパスワードを設定してください (3 回まで再試行)"
  RETRY=0
  until passwd "${NEW_USER}"; do
    RETRY=$((RETRY + 1))
    if (( RETRY >= 3 )); then
      err "パスワード設定に 3 回失敗しました。中止します。"
      exit 1
    fi
    warn "再試行します..."
  done
fi

# sudoers の wheel/sudo グループ有効性チェック
if ! sudo -lU "${NEW_USER}" >/dev/null 2>&1; then
  : # まだグループに入れていないので無視
fi

if ! grep -hqE "^\s*%${SUDO_GROUP}\s+ALL=\(ALL" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
  warn "/etc/sudoers に '%${SUDO_GROUP} ALL=(ALL) ALL' が無いため /etc/sudoers.d/ に追記します"
  echo "%${SUDO_GROUP} ALL=(ALL) ALL" > "/etc/sudoers.d/99-${SUDO_GROUP}"
  chmod 440 "/etc/sudoers.d/99-${SUDO_GROUP}"
  visudo -cf "/etc/sudoers.d/99-${SUDO_GROUP}" >/dev/null
fi

log "ユーザー '${NEW_USER}' を '${SUDO_GROUP}' グループに追加します"
usermod -aG "${SUDO_GROUP}" "${NEW_USER}"
ok "sudo 権限を付与しました"

# ============================================================================
# 2. SSH 公開鍵を authorized_keys に登録
# ============================================================================
if [[ "${PUBKEY_MODE}" == "generate" ]]; then
  log "サーバー上で ed25519 鍵ペアを生成します"
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    err "ssh-keygen が見つかりません。openssh-client(s) をインストールしてください。"
    exit 1
  fi
  KEY_TMP_DIR="$(mktemp -d /tmp/mirai-keygen.XXXXXX)"
  chmod 700 "${KEY_TMP_DIR}"
  trap '[[ -n "${KEY_TMP_DIR:-}" && -d "${KEY_TMP_DIR}" ]] && rm -rf "${KEY_TMP_DIR}"' EXIT
  KEY_FILE="${KEY_TMP_DIR}/${NEW_USER}_ed25519"
  ssh-keygen -t ed25519 -N '' \
    -C "${NEW_USER}@$(hostname) ($(date -I))" \
    -f "${KEY_FILE}" >/dev/null
  PUBKEY_DATA="$(cat "${KEY_FILE}.pub")"

  echo
  echo "════════════════════════════════════════════════════════════════"
  echo " 重要: 以下の秘密鍵を 今すぐ PC 側に保存してください"
  echo "       (Enter で続行するとサーバーから削除されます)"
  echo "════════════════════════════════════════════════════════════════"
  echo
  echo "----- BEGIN PRIVATE KEY (${KEY_FILE##*/}) -----"
  cat "${KEY_FILE}"
  echo "-----  END PRIVATE KEY  -----"
  echo
  echo "  PC 側での保存手順:"
  echo "    1) 上記 '----- BEGIN ...' から '----- END ...' までをコピー"
  echo "    2) PC ターミナルで:"
  echo "         umask 077"
  echo "         cat > ~/.ssh/${NEW_USER}_ed25519 <<'EOF'"
  echo "         (貼り付け)"
  echo "         EOF"
  echo "         chmod 600 ~/.ssh/${NEW_USER}_ed25519"
  echo
  echo "  対応する公開鍵 (参考、サーバーには登録済みになります):"
  echo "    ${PUBKEY_DATA}"
  echo
  read -rp "秘密鍵を保存しましたか? Enter で続行 (画面表示は破棄します): " _ACK
  rm -rf "${KEY_TMP_DIR}"
  trap - EXIT
  ok "鍵生成完了 (サーバー上の秘密鍵は削除済み)"
fi

if [[ -n "${PUBKEY_DATA}" ]]; then
  USER_HOME="$(getent passwd "${NEW_USER}" | cut -d: -f6)"
  if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    err "ホームディレクトリが見つかりません: ${USER_HOME}"
    exit 1
  fi

  SSH_DIR="${USER_HOME}/.ssh"
  AUTH_KEYS="${SSH_DIR}/authorized_keys"

  log "公開鍵を ${AUTH_KEYS} に登録します"
  install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "${SSH_DIR}"
  touch "${AUTH_KEYS}"
  chmod 600 "${AUTH_KEYS}"
  chown "${NEW_USER}:${NEW_USER}" "${AUTH_KEYS}"

  if grep -qxF "${PUBKEY_DATA}" "${AUTH_KEYS}"; then
    log "同一の公開鍵が既に登録されています。スキップ。"
  else
    printf "%s\n" "${PUBKEY_DATA}" >> "${AUTH_KEYS}"
    ok "公開鍵を登録しました"
  fi
fi

# ============================================================================
# 3. sshd_config 編集 (ドロップイン優先)
# ============================================================================
SSHD_CFG="/etc/ssh/sshd_config"
BACKUP="${SSHD_CFG}.bak.$(date +%Y%m%d_%H%M%S)"
cp -a "${SSHD_CFG}" "${BACKUP}"
log "sshd_config をバックアップ: ${BACKUP}"

DROPIN_DIR="/etc/ssh/sshd_config.d"
USE_DROPIN="no"
if [[ -d "${DROPIN_DIR}" ]] && grep -qE "^\s*Include\s+${DROPIN_DIR}" "${SSHD_CFG}"; then
  USE_DROPIN="yes"
fi

if [[ "${USE_DROPIN}" == "yes" ]]; then
  # ドロップインは最初に読まれた値が勝つ → 00- プレフィックスで先勝
  DROPIN_FILE="${DROPIN_DIR}/00-mirai-setup.conf"
  log "ドロップイン設定を書き出します: ${DROPIN_FILE}"
  {
    echo "# Generated by setup.sh ($(date -Iseconds))"
    echo "Port ${SSH_PORT}"
    echo "PubkeyAuthentication yes"
    if [[ "${DISABLE_PW^^}" == "Y" ]]; then
      echo "PasswordAuthentication no"
      echo "ChallengeResponseAuthentication no"
      echo "KbdInteractiveAuthentication no"
    fi
  } > "${DROPIN_FILE}"
  chmod 644 "${DROPIN_FILE}"

  # cloud-init 等の競合チェック
  for f in "${DROPIN_DIR}"/*.conf; do
    [[ "$f" == "${DROPIN_FILE}" ]] && continue
    [[ -f "$f" ]] || continue
    if grep -qE "^\s*(Port|PasswordAuthentication|ChallengeResponseAuthentication|KbdInteractiveAuthentication)\s" "$f"; then
      warn "競合するドロップインを検出: $f (00-mirai-setup.conf が先勝するので通常 OK)"
    fi
  done
else
  # 主設定ファイルを直接編集
  log "sshd_config を直接編集します"
  set_or_append() {
    local key="$1" val="$2"
    if grep -qE "^\s*#?\s*${key}\s+" "${SSHD_CFG}"; then
      sed -ri "s|^\s*#?\s*${key}\s+.*|${key} ${val}|" "${SSHD_CFG}"
    else
      echo "${key} ${val}" >> "${SSHD_CFG}"
    fi
  }
  set_or_append "Port" "${SSH_PORT}"
  set_or_append "PubkeyAuthentication" "yes"
  if [[ "${DISABLE_PW^^}" == "Y" ]]; then
    set_or_append "PasswordAuthentication" "no"
    set_or_append "ChallengeResponseAuthentication" "no"
    set_or_append "KbdInteractiveAuthentication" "no"
  fi
fi

log "sshd_config 構文チェック (sshd -t)"
if ! sshd -t; then
  err "sshd_config に構文エラー。バックアップから復元します。"
  cp -a "${BACKUP}" "${SSHD_CFG}"
  [[ "${USE_DROPIN}" == "yes" ]] && rm -f "${DROPIN_FILE}"
  exit 1
fi
ok "sshd_config OK"

# ============================================================================
# 4. SELinux (RHEL 系のみ)
# ============================================================================
if [[ "${OS_FAMILY}" == "rhel" ]] && command -v getenforce >/dev/null 2>&1; then
  if [[ "$(getenforce)" != "Disabled" ]]; then
    log "SELinux: ${SSH_PORT}/tcp を ssh_port_t に許可"
    if semanage port -l 2>/dev/null | awk '$1=="ssh_port_t" && $2=="tcp"' | grep -qw "${SSH_PORT}"; then
      log "SELinux ポート: 既に許可済み"
    else
      if ! semanage port -a -t ssh_port_t -p tcp "${SSH_PORT}" 2>/dev/null; then
        semanage port -m -t ssh_port_t -p tcp "${SSH_PORT}"
      fi
      ok "SELinux ポート許可完了"
    fi
  fi
fi

# ============================================================================
# 5. ファイアウォール: 新ポート許可 (旧ポートは検証後に閉じる)
# ============================================================================
if [[ "${OS_FAMILY}" == "rhel" ]]; then
  log "firewalld: SSH(${SSH_PORT}) カスタムサービスを作成して許可"
  SVC_NAME="ssh_${SSH_PORT}"
  SVC_FILE="/etc/firewalld/services/${SVC_NAME}.xml"
  install -d -m 755 /etc/firewalld/services
  cat > "${SVC_FILE}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>SSH(${SSH_PORT})</short>
  <description>Custom SSH on TCP/${SSH_PORT}</description>
  <port protocol="tcp" port="${SSH_PORT}"/>
</service>
EOF
  chmod 644 "${SVC_FILE}"

  firewall-cmd --reload
  firewall-cmd --permanent --zone=public --add-service="${SVC_NAME}"
  firewall-cmd --zone=public --add-service="${SVC_NAME}"
  ok "firewalld: ${SVC_NAME} を許可"
else
  log "ufw: 新 SSH ポート ${SSH_PORT}/tcp と旧 22/tcp (一時) を許可"
  ufw allow "${SSH_PORT}/tcp" comment "ssh-new"
  ufw allow 22/tcp comment "ssh-old (temporary)" || true
  if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
    warn "ufw を有効化します (既存 iptables ルールは上書きされる可能性あり)"
    ufw --force enable
  fi
  ok "ufw 設定完了"
fi

# ============================================================================
# 6. sshd 再起動
# ============================================================================
log "${SSH_SERVICE} を再起動します"
systemctl restart "${SSH_SERVICE}"
ok "${SSH_SERVICE} 再起動完了"

# ============================================================================
# 7. Docker CE + docker compose plugin (任意)
# ============================================================================
if [[ "${DO_DOCKER^^}" == "Y" ]]; then
  log "Docker CE をインストールします"

  if [[ "${OS_FAMILY}" == "rhel" ]]; then
    # 旧 docker パッケージを除去 (存在する場合のみ)
    dnf -y remove docker docker-client docker-client-latest docker-common \
                  docker-latest docker-latest-logrotate docker-logrotate \
                  docker-engine podman runc 2>/dev/null || true

    # dnf config-manager (dnf5: dnf-plugins-core, dnf4: dnf-plugins-core)
    if ! command -v dnf config-manager >/dev/null 2>&1; then
      dnf -y install dnf-plugins-core
    fi

    # Docker 公式リポジトリの追加 (Rocky/Alma は centos リポジトリを利用)
    if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
      dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
    fi
    log "Docker リポジトリ確認"
    dnf repolist | grep -q docker-ce-stable || warn "docker-ce-stable が見えません"

    # 関連 + 本体
    dnf -y install device-mapper-persistent-data lvm2
    dnf -y install docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin

  else
    # 旧パッケージ除去
    for p in docker.io docker-doc docker-compose docker-compose-v2 \
             podman-docker containerd runc; do
      apt-get -y remove "$p" 2>/dev/null || true
    done

    # 前提パッケージ
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get -y install ca-certificates curl gnupg

    # GPG キー
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
      curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
    fi

    # apt sources (codename = jammy/noble/bookworm 等)
    ARCH="$(dpkg --print-architecture)"
    CODENAME="${VERSION_CODENAME:-$(. /etc/os-release && echo "${VERSION_CODENAME}")}"
    if [[ -z "${CODENAME}" ]]; then
      err "Debian/Ubuntu の VERSION_CODENAME が取得できません"
      exit 1
    fi
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get -y install docker-ce docker-ce-cli containerd.io \
                       docker-buildx-plugin docker-compose-plugin
  fi
  ok "Docker パッケージインストール完了"

  # サービス有効化 + 起動
  log "docker サービスを有効化 + 起動"
  systemctl enable --now docker
  systemctl enable --now containerd 2>/dev/null || true

  # docker グループに新ユーザーを追加
  log "docker グループを作成し ${NEW_USER} を追加"
  groupadd -f docker
  usermod -aG docker "${NEW_USER}"
  ok "docker グループ設定完了"

  # バージョン確認
  log "バージョン確認"
  docker --version || true
  docker compose version || true
fi

# ============================================================================
# 8. SSH 接続自動検証 (Lv1: LISTEN, Lv2: SSH ハンドシェイク)
# ============================================================================
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

log "Lv1: sshd の LISTEN チェック (port ${SSH_PORT})"
LISTEN_OK="no"
for _ in 1 2 3 4 5; do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${SSH_PORT}\$"; then
    LISTEN_OK="yes"
    break
  fi
  sleep 1
done
if [[ "${LISTEN_OK}" != "yes" ]]; then
  err "sshd が port ${SSH_PORT} で LISTEN していません。port 22 は開放したままで終了します。"
  err "復旧手順:"
  err "  cp -a ${BACKUP} ${SSHD_CFG} && systemctl restart ${SSH_SERVICE}"
  exit 1
fi
ok "Lv1 OK: sshd LISTEN on ${SSH_PORT}/tcp"

log "Lv2: SSH ハンドシェイクチェック (127.0.0.1:${SSH_PORT})"
BANNER=""
{
  if exec 9<>/dev/tcp/127.0.0.1/"${SSH_PORT}"; then
    IFS= read -r -t 5 BANNER <&9 || true
    exec 9>&-
  fi
} 2>/dev/null
BANNER="${BANNER%$'\r'}"
if [[ "${BANNER}" != SSH-* ]]; then
  err "SSH ハンドシェイク失敗 (応答: ${BANNER:-(なし)}). port 22 は開放したまま終了します。"
  exit 1
fi
ok "Lv2 OK: ${BANNER}"

# ============================================================================
# 9. 旧ポート 22 を即時閉鎖
# ============================================================================
log "旧ポート 22 を閉鎖します"
if [[ "${OS_FAMILY}" == "rhel" ]]; then
  firewall-cmd --permanent --zone=public --remove-service=ssh 2>/dev/null || true
  firewall-cmd --zone=public --remove-service=ssh 2>/dev/null || true
  firewall-cmd --reload
  ok "firewalld: ssh(22) サービス削除完了"
else
  ufw --force delete allow 22/tcp || true
  ok "ufw: 22/tcp 削除完了"
fi

# ============================================================================
# 完了 — PC 側で実行するコマンドを出力
# ============================================================================
# 接続情報の組み立て
SERVER_IP="${SERVER_IP:-<server_ip>}"
SSH_HOST_ALIAS="mirai-server"

# IdentityFile パス
if [[ "${PUBKEY_MODE}" == "skip" ]]; then
  IDENTITY_PATH=""
  IDENTITY_FLAG=""
  IDENTITY_CFG_LINE=""
elif [[ "${PUBKEY_MODE}" == "generate" ]]; then
  IDENTITY_PATH="~/.ssh/${NEW_USER}_ed25519"
  IDENTITY_FLAG=" -i ${IDENTITY_PATH}"
  IDENTITY_CFG_LINE="    IdentityFile ${IDENTITY_PATH}"
else
  IDENTITY_PATH="~/.ssh/<秘密鍵ファイル名>"
  IDENTITY_FLAG=" -i ${IDENTITY_PATH}"
  IDENTITY_CFG_LINE="    IdentityFile ${IDENTITY_PATH}"
fi

echo
echo "================================================================"
ok "全工程完了"
echo "================================================================"
echo
echo "  以下のコマンドを PC のターミナルに貼り付けて実行してください。"
echo "  (heredoc / シングルクォートはそのままコピー可能です)"
echo

# ---- [1] 接続テスト ----
cat <<EOF
# ----- [1] SSH 接続テスト ---------------------------------------
ssh ${NEW_USER}@${SERVER_IP} -p ${SSH_PORT}${IDENTITY_FLAG}

EOF

# ---- [2] ~/.ssh/config に追記 ----
if [[ "${PUBKEY_MODE}" != "skip" ]]; then
cat <<EOF
# ----- [2] ~/.ssh/config に追記 (推奨) --------------------------
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/config <<'SSHCONF'

Host ${SSH_HOST_ALIAS}
    HostName ${SERVER_IP}
    Port ${SSH_PORT}
    User ${NEW_USER}
${IDENTITY_CFG_LINE}
    ServerAliveInterval 60
SSHCONF
chmod 600 ~/.ssh/config

# 追記後はこれだけで接続可能:
ssh ${SSH_HOST_ALIAS}

EOF
fi

# ---- [3] sudo 確認 ----
cat <<EOF
# ----- [3] sudo 動作確認 ---------------------------------------
ssh ${SSH_HOST_ALIAS:-${NEW_USER}@${SERVER_IP}} 'sudo whoami'
# => 'root' と表示されれば OK

EOF

# ---- [4] Docker (任意) ----
if [[ "${DO_DOCKER^^}" == "Y" ]]; then
cat <<EOF
# ----- [4] Docker 動作確認 (再ログイン後) ----------------------
# docker グループの反映には一度ログアウト→再ログインが必要です
ssh ${SSH_HOST_ALIAS:-${NEW_USER}@${SERVER_IP}} 'docker ps'
ssh ${SSH_HOST_ALIAS:-${NEW_USER}@${SERVER_IP}} 'docker compose version'

EOF
fi

# ---- [5] サーバー側情報 ----
cat <<EOF
# ----- サーバー側ファイル (参照用) -----------------------------
#   設定ファイル: $( [[ "${USE_DROPIN}" == "yes" ]] && echo "${DROPIN_FILE}" || echo "${SSHD_CFG}" )
#   バックアップ: ${BACKUP}
EOF

# ---- [6] 注意事項 ----
cat <<EOF

# ----- 手動対応が必要な項目 ------------------------------------
#   ★ クラウドFW (Security Group / パケットフィルタ等)
#       TCP ${SSH_PORT} を許可
#       TCP 22 はもう不要 (script で閉鎖済み)
EOF

if [[ "${PUBKEY_MODE}" == "generate" ]]; then
cat <<EOF
#
#   ★ サーバー上で生成した秘密鍵は破棄済みです。
#     PC 側に ${IDENTITY_PATH} として保存していない場合は再実行が必要です。
EOF
fi

echo
echo "================================================================"
echo
