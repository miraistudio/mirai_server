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
#   3. sshd_config 編集 (Port変更 / パスワード認証無効化)
#   4. SELinux ポート許可 (RHEL 系のみ)
#   5. firewalld / ufw で新ポートを許可
#   6. sshd 再起動 (旧ポートは検証後に閉鎖)
#   7. (任意) Docker CE + docker compose plugin インストール
#
# 使い方:
#   sudo bash setup.sh
#
# 言語切替:
#   LANG_OUT=en sudo bash setup.sh   # 英語表示を強制
#   LANG_OUT=ja sudo bash setup.sh   # 日本語表示を強制
#   未指定の場合は tty を判定し、物理コンソールなら英語、SSH (pts) なら日本語
#
set -euo pipefail

# ============================================================================
# プレースホルダ (実行前に書き換えるか、対話プロンプトで入力)
# ============================================================================
DEFAULT_NEW_USER=""             # 例: deploy / mirai など
DEFAULT_SSH_PORT="10022"        # 推奨: 10022 (1024-65535 で他サービスと被らないもの)
# ============================================================================

# ----------------------------------------------------------------------------
# 言語判定 (物理コンソール = 英語フォールバック、SSH = 日本語)
# ----------------------------------------------------------------------------
LANG_OUT="${LANG_OUT:-}"
if [[ -z "${LANG_OUT}" ]]; then
  _tty="$(tty 2>/dev/null || echo unknown)"
  if [[ "${_tty}" =~ ^/dev/(tty[0-9]+|ttyS[0-9]+|console)$ ]]; then
    LANG_OUT="en"
  else
    LANG_OUT="ja"
  fi
fi
case "${LANG_OUT}" in ja|en) ;; *) LANG_OUT="ja" ;; esac

# 翻訳ヘルパ: _t "日本語" "English"
_t() { if [[ "${LANG_OUT}" == "en" ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# ----------------------------------------------------------------------------
# 色付き出力
# ----------------------------------------------------------------------------
C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[0;33m'; C_BLU='\033[0;34m'; C_RST='\033[0m'
log()  { printf "${C_BLU}[INFO]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YLW}[WARN]${C_RST} %s\n" "$*"; }
err()  { printf "${C_RED}[ERR ]${C_RST} %s\n" "$*" >&2; }
ok()   { printf "${C_GRN}[ OK ]${C_RST} %s\n" "$*"; }

# 言語判定結果の表示
if [[ "${LANG_OUT}" == "en" ]]; then
  log "Language: English (set LANG_OUT=ja to force Japanese)"
else
  log "言語: 日本語 (LANG_OUT=en で英語に切替可能)"
fi

# ----------------------------------------------------------------------------
# 事前チェック
# ----------------------------------------------------------------------------
if [[ ${EUID} -ne 0 ]]; then
  err "$(_t "root 権限で実行してください: sudo bash $0" \
            "Run as root: sudo bash $0")"
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  err "$(_t "/etc/os-release が読めません。サポート対象外OSです。" \
            "Cannot read /etc/os-release. Unsupported OS.")"
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release

OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
case " ${OS_ID} ${OS_LIKE} " in
  *" rocky "*|*" almalinux "*|*" rhel "*|*" centos "*|*" fedora "*)
    OS_FAMILY="rhel"; PKG_MGR="dnf"; SSH_SERVICE="sshd"; SUDO_GROUP="wheel" ;;
  *" ubuntu "*|*" debian "*)
    OS_FAMILY="debian"; PKG_MGR="apt"; SSH_SERVICE="ssh"; SUDO_GROUP="sudo" ;;
  *)
    err "$(_t "サポート対象外OSです: ID=${OS_ID} ID_LIKE=${OS_LIKE}" \
              "Unsupported OS: ID=${OS_ID} ID_LIKE=${OS_LIKE}")"
    exit 1 ;;
esac
log "$(_t "検出OS: ${PRETTY_NAME:-${OS_ID}} (family=${OS_FAMILY})" \
          "Detected OS: ${PRETTY_NAME:-${OS_ID}} (family=${OS_FAMILY})")"

# ----------------------------------------------------------------------------
# 対話入力
# ----------------------------------------------------------------------------
echo
echo "$(_t "==== 初期設定の入力 ====" "==== Initial configuration ====")"

read -rp "$(_t "作成する一般ユーザー名 [${DEFAULT_NEW_USER}]: " \
              "New user name [${DEFAULT_NEW_USER}]: ")" NEW_USER
NEW_USER="${NEW_USER:-${DEFAULT_NEW_USER}}"
if [[ -z "${NEW_USER}" || "${NEW_USER}" == "changeme" ]]; then
  err "$(_t "ユーザー名を指定してください。" "Please specify a user name.")"
  exit 1
fi
if ! [[ "${NEW_USER}" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
  err "$(_t "ユーザー名の形式が不正です: ${NEW_USER}" \
            "Invalid user name format: ${NEW_USER}")"
  exit 1
fi

read -rp "$(_t "新しい SSH ポート番号 [${DEFAULT_SSH_PORT}]: " \
              "New SSH port [${DEFAULT_SSH_PORT}]: ")" SSH_PORT
SSH_PORT="${SSH_PORT:-${DEFAULT_SSH_PORT}}"
if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  err "$(_t "SSH ポート番号が不正です: ${SSH_PORT}" \
            "Invalid SSH port: ${SSH_PORT}")"
  exit 1
fi
if (( SSH_PORT == 22 )); then
  warn "$(_t "ポートが 22 のままです。変更の意味がありません。" \
             "Port is still 22 (no change).")"
fi

echo
echo "$(_t "公開鍵の登録方法を選択してください:" "Choose how to register the public key:")"
echo "$(_t "  1) ファイルパスを指定 (例: /tmp/id_ed25519.pub)" \
          "  1) Specify a file path (e.g. /tmp/id_ed25519.pub)")"
echo "$(_t "  2) ターミナルに 1 行貼り付け" \
          "  2) Paste a single line into the terminal")"
echo "$(_t "  3) サーバー上で新規作成 (ed25519, パスフレーズなし)" \
          "  3) Generate a new key on this server (ed25519, no passphrase)")"
echo "$(_t "  4) スキップ (パスワード認証を残す)" \
          "  4) Skip (keep password authentication)")"
read -rp "$(_t "選択 [1-4]: " "Choice [1-4]: ")" PUBKEY_CHOICE
PUBKEY_DATA=""; PUBKEY_MODE=""; PUBKEY_PATH=""
case "${PUBKEY_CHOICE}" in
  1)
    PUBKEY_MODE="file"
    read -rp "$(_t "公開鍵ファイルのパス: " "Path to public key file: ")" PUBKEY_PATH
    if [[ ! -r "${PUBKEY_PATH}" ]]; then
      err "$(_t "ファイルが読めません: ${PUBKEY_PATH}" \
                "Cannot read file: ${PUBKEY_PATH}")"
      exit 1
    fi
    PUBKEY_DATA="$(cat "${PUBKEY_PATH}")"
    ;;
  2)
    PUBKEY_MODE="paste"
    echo "$(_t "公開鍵 (ssh-ed25519/ssh-rsa/... で始まる 1 行) を貼り付けて Enter:" \
              "Paste public key (one line starting with ssh-ed25519/ssh-rsa/...) and press Enter:")"
    IFS= read -r PUBKEY_DATA
    ;;
  3)
    PUBKEY_MODE="generate"
    log "$(_t "鍵ペアは実行直前にサーバー上で生成します (画面表示後に破棄)" \
              "Key pair will be generated on the server later (destroyed after display)")"
    ;;
  4)
    PUBKEY_MODE="skip"
    warn "$(_t "公開鍵設定をスキップします。パスワード認証は維持されます。" \
               "Skipping public key. Password authentication will remain enabled.")"
    ;;
  *)
    err "$(_t "選択が不正です。" "Invalid choice.")"; exit 1 ;;
esac

if [[ "${PUBKEY_MODE}" =~ ^(file|paste)$ ]] \
   && ! [[ "${PUBKEY_DATA}" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-) ]]; then
  err "$(_t "公開鍵の形式が認識できません。" "Unrecognized public key format.")"
  exit 1
fi

read -rp "$(_t "パスワード認証を無効化しますか? [Y/n]: " \
              "Disable password authentication? [Y/n]: ")" DISABLE_PW
DISABLE_PW="${DISABLE_PW:-Y}"
if [[ "${PUBKEY_MODE}" == "skip" && "${DISABLE_PW^^}" == "Y" ]]; then
  warn "$(_t "公開鍵未設定のため、ロックアウト防止のためパスワード認証は無効化しません。" \
             "No public key set; keeping password authentication to avoid lockout.")"
  DISABLE_PW="N"
fi

read -rp "$(_t "OS パッケージを最新にアップデートしますか? [Y/n]: " \
              "Update OS packages to latest? [Y/n]: ")" DO_UPDATE
DO_UPDATE="${DO_UPDATE:-Y}"

read -rp "$(_t "Docker CE と docker compose plugin をインストールしますか? [y/N]: " \
              "Install Docker CE and docker compose plugin? [y/N]: ")" DO_DOCKER
DO_DOCKER="${DO_DOCKER:-N}"

# 設定確認
echo
echo "$(_t "==== 設定確認 ====" "==== Confirmation ====")"
PUBKEY_DESC="$(_t "なし" "none")"
case "${PUBKEY_MODE}" in
  file)     PUBKEY_DESC="$(_t "ファイル: ${PUBKEY_PATH}" "file: ${PUBKEY_PATH}")" ;;
  paste)    PUBKEY_DESC="$(_t "貼付済み" "pasted")" ;;
  generate) PUBKEY_DESC="$(_t "サーバー上で新規生成 (ed25519)" "generate on server (ed25519)")" ;;
  skip)     PUBKEY_DESC="$(_t "スキップ" "skip")" ;;
esac
if [[ "${LANG_OUT}" == "en" ]]; then
  printf "  OS         : %s\n" "${PRETTY_NAME:-${OS_ID}}"
  printf "  New user   : %s (group %s)\n" "${NEW_USER}" "${SUDO_GROUP}"
  printf "  SSH port   : %s\n" "${SSH_PORT}"
  printf "  Public key : %s\n" "${PUBKEY_DESC}"
  printf "  Password   : %s\n" "$( [[ "${DISABLE_PW^^}" == "Y" ]] && echo "disable" || echo "keep" )"
  printf "  OS update  : %s\n" "$( [[ "${DO_UPDATE^^}" == "Y" ]] && echo "yes" || echo "skip" )"
  printf "  Docker     : %s\n" "$( [[ "${DO_DOCKER^^}" == "Y" ]] && echo "install (add ${NEW_USER} to docker group)" || echo "skip" )"
else
  printf "  OS              : %s\n" "${PRETTY_NAME:-${OS_ID}}"
  printf "  新規ユーザー    : %s (グループ %s)\n" "${NEW_USER}" "${SUDO_GROUP}"
  printf "  新 SSH ポート   : %s\n" "${SSH_PORT}"
  printf "  公開鍵          : %s\n" "${PUBKEY_DESC}"
  printf "  パスワード認証  : %s\n" "$( [[ "${DISABLE_PW^^}" == "Y" ]] && echo "無効化" || echo "そのまま" )"
  printf "  OS アップデート : %s\n" "$( [[ "${DO_UPDATE^^}" == "Y" ]] && echo "実施" || echo "スキップ" )"
  printf "  Docker          : %s\n" "$( [[ "${DO_DOCKER^^}" == "Y" ]] && echo "インストール (${NEW_USER} を docker グループに追加)" || echo "スキップ" )"
fi
echo "=================="
read -rp "$(_t "実行してよろしいですか? [y/N]: " "Proceed? [y/N]: ")" CONFIRM
[[ "${CONFIRM^^}" == "Y" ]] || { warn "$(_t "中止しました。" "Aborted.")"; exit 0; }

# ----------------------------------------------------------------------------
# OS アップデート
# ----------------------------------------------------------------------------
if [[ "${DO_UPDATE^^}" == "Y" ]]; then
  log "$(_t "OS パッケージをアップデートします..." "Updating OS packages...")"
  if [[ "${PKG_MGR}" == "dnf" ]]; then
    dnf -y upgrade
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
  fi
  ok "$(_t "OS アップデート完了" "OS update done")"
fi

# ----------------------------------------------------------------------------
# 必須パッケージ
# ----------------------------------------------------------------------------
log "$(_t "必須パッケージをインストールします..." "Installing required packages...")"
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
ok "$(_t "パッケージ準備完了" "Packages ready")"

# ============================================================================
# 1. 一般ユーザー作成 + sudo 権限付与
# ============================================================================
if id -u "${NEW_USER}" >/dev/null 2>&1; then
  log "$(_t "ユーザー '${NEW_USER}' は既に存在します。作成をスキップします。" \
            "User '${NEW_USER}' already exists. Skipping creation.")"
else
  log "$(_t "一般ユーザー '${NEW_USER}' を作成します" \
            "Creating user '${NEW_USER}'")"
  useradd -m -s /bin/bash "${NEW_USER}"
  ok "$(_t "ユーザー作成完了" "User created")"

  log "$(_t "ユーザー '${NEW_USER}' のパスワードを設定してください (3 回まで再試行)" \
            "Set password for '${NEW_USER}' (up to 3 retries)")"
  RETRY=0
  until passwd "${NEW_USER}"; do
    RETRY=$((RETRY + 1))
    if (( RETRY >= 3 )); then
      err "$(_t "パスワード設定に 3 回失敗しました。中止します。" \
                "Password setup failed 3 times. Aborting.")"
      exit 1
    fi
    warn "$(_t "再試行します..." "Retrying...")"
  done
fi

if ! grep -hqE "^\s*%${SUDO_GROUP}\s+ALL=\(ALL" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
  warn "$(_t "/etc/sudoers に '%${SUDO_GROUP} ALL=...' が無いため /etc/sudoers.d/ に追記します" \
             "Missing '%${SUDO_GROUP} ALL=...' in sudoers; adding to /etc/sudoers.d/")"
  echo "%${SUDO_GROUP} ALL=(ALL) ALL" > "/etc/sudoers.d/99-${SUDO_GROUP}"
  chmod 440 "/etc/sudoers.d/99-${SUDO_GROUP}"
  visudo -cf "/etc/sudoers.d/99-${SUDO_GROUP}" >/dev/null
fi

log "$(_t "ユーザー '${NEW_USER}' を '${SUDO_GROUP}' グループに追加します" \
          "Adding user '${NEW_USER}' to group '${SUDO_GROUP}'")"
usermod -aG "${SUDO_GROUP}" "${NEW_USER}"
ok "$(_t "sudo 権限を付与しました" "sudo privilege granted")"

# ============================================================================
# 2. SSH 公開鍵を authorized_keys に登録
# ============================================================================
if [[ "${PUBKEY_MODE}" == "generate" ]]; then
  log "$(_t "サーバー上で ed25519 鍵ペアを生成します" \
            "Generating ed25519 key pair on this server")"
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    err "$(_t "ssh-keygen が見つかりません。openssh-client(s) をインストールしてください。" \
              "ssh-keygen not found. Install openssh-client(s).")"
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
  echo "================================================================"
  echo "$(_t " 重要: 以下の秘密鍵を 今すぐ PC 側に保存してください" \
            " IMPORTANT: Save the private key below to your PC NOW")"
  echo "$(_t "       (Enter で続行するとサーバーから削除されます)" \
            "       (It will be removed from the server when you press Enter)")"
  echo "================================================================"
  echo
  echo "----- BEGIN PRIVATE KEY (${KEY_FILE##*/}) -----"
  cat "${KEY_FILE}"
  echo "-----  END PRIVATE KEY  -----"
  echo
  echo "$(_t "  PC 側での保存手順:" "  Save steps on your PC:")"
  echo "    1) $(_t "上記 '----- BEGIN ...' から '----- END ...' までをコピー" \
                    "Copy from '----- BEGIN ...' to '----- END ...'")"
  echo "    2) $(_t "PC ターミナルで:" "On your PC terminal:")"
  echo "         umask 077"
  echo "         cat > ~/.ssh/${NEW_USER}_ed25519 <<'EOF'"
  echo "         $(_t "(貼り付け)" "(paste)")"
  echo "         EOF"
  echo "         chmod 600 ~/.ssh/${NEW_USER}_ed25519"
  echo
  echo "$(_t "  対応する公開鍵 (参考、サーバーには登録済みになります):" \
            "  Corresponding public key (already registered on server):")"
  echo "    ${PUBKEY_DATA}"
  echo
  read -rp "$(_t "秘密鍵を保存しましたか? Enter で続行 (画面表示は破棄します): " \
                "Saved the private key? Press Enter to continue (display will be cleared): ")" _ACK
  rm -rf "${KEY_TMP_DIR}"
  trap - EXIT
  ok "$(_t "鍵生成完了 (サーバー上の秘密鍵は削除済み)" \
            "Key generation done (server-side private key deleted)")"
fi

if [[ -n "${PUBKEY_DATA}" ]]; then
  USER_HOME="$(getent passwd "${NEW_USER}" | cut -d: -f6)"
  if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    err "$(_t "ホームディレクトリが見つかりません: ${USER_HOME}" \
              "Home directory not found: ${USER_HOME}")"
    exit 1
  fi
  SSH_DIR="${USER_HOME}/.ssh"
  AUTH_KEYS="${SSH_DIR}/authorized_keys"

  log "$(_t "公開鍵を ${AUTH_KEYS} に登録します" \
            "Registering public key to ${AUTH_KEYS}")"
  install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "${SSH_DIR}"
  touch "${AUTH_KEYS}"; chmod 600 "${AUTH_KEYS}"; chown "${NEW_USER}:${NEW_USER}" "${AUTH_KEYS}"

  if grep -qxF "${PUBKEY_DATA}" "${AUTH_KEYS}"; then
    log "$(_t "同一の公開鍵が既に登録されています。スキップ。" \
              "Same public key already present. Skipping.")"
  else
    printf "%s\n" "${PUBKEY_DATA}" >> "${AUTH_KEYS}"
    ok "$(_t "公開鍵を登録しました" "Public key registered")"
  fi
fi

# ============================================================================
# 3. sshd_config 編集 (ドロップイン優先)
# ============================================================================
SSHD_CFG="/etc/ssh/sshd_config"
BACKUP="${SSHD_CFG}.bak.$(date +%Y%m%d_%H%M%S)"
cp -a "${SSHD_CFG}" "${BACKUP}"
log "$(_t "sshd_config をバックアップ: ${BACKUP}" \
          "sshd_config backed up to: ${BACKUP}")"

DROPIN_DIR="/etc/ssh/sshd_config.d"
USE_DROPIN="no"
if [[ -d "${DROPIN_DIR}" ]] && grep -qE "^\s*Include\s+${DROPIN_DIR}" "${SSHD_CFG}"; then
  USE_DROPIN="yes"
fi

if [[ "${USE_DROPIN}" == "yes" ]]; then
  DROPIN_FILE="${DROPIN_DIR}/00-mirai-setup.conf"
  log "$(_t "ドロップイン設定を書き出します: ${DROPIN_FILE}" \
            "Writing drop-in config: ${DROPIN_FILE}")"
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

  for f in "${DROPIN_DIR}"/*.conf; do
    [[ "$f" == "${DROPIN_FILE}" ]] && continue
    [[ -f "$f" ]] || continue
    if grep -qE "^\s*(Port|PasswordAuthentication|ChallengeResponseAuthentication|KbdInteractiveAuthentication)\s" "$f"; then
      warn "$(_t "競合するドロップインを検出: $f (00-mirai-setup.conf が先勝するので通常 OK)" \
                 "Conflicting drop-in detected: $f (00-mirai-setup.conf wins, usually OK)")"
    fi
  done
else
  log "$(_t "sshd_config を直接編集します" "Editing sshd_config directly")"
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

log "$(_t "sshd_config 構文チェック (sshd -t)" "sshd_config syntax check (sshd -t)")"
if ! sshd -t; then
  err "$(_t "sshd_config に構文エラー。バックアップから復元します。" \
            "sshd_config syntax error. Restoring from backup.")"
  cp -a "${BACKUP}" "${SSHD_CFG}"
  [[ "${USE_DROPIN}" == "yes" ]] && rm -f "${DROPIN_FILE}"
  exit 1
fi
ok "$(_t "sshd_config OK" "sshd_config OK")"

# ============================================================================
# 4. SELinux (RHEL 系のみ)
# ============================================================================
if [[ "${OS_FAMILY}" == "rhel" ]] && command -v getenforce >/dev/null 2>&1; then
  if [[ "$(getenforce)" != "Disabled" ]]; then
    log "$(_t "SELinux: ${SSH_PORT}/tcp を ssh_port_t に許可" \
              "SELinux: allowing ${SSH_PORT}/tcp on ssh_port_t")"
    if semanage port -l 2>/dev/null | awk '$1=="ssh_port_t" && $2=="tcp"' | grep -qw "${SSH_PORT}"; then
      log "$(_t "SELinux ポート: 既に許可済み" "SELinux port: already allowed")"
    else
      if ! semanage port -a -t ssh_port_t -p tcp "${SSH_PORT}" 2>/dev/null; then
        semanage port -m -t ssh_port_t -p tcp "${SSH_PORT}"
      fi
      ok "$(_t "SELinux ポート許可完了" "SELinux port allowed")"
    fi
  fi
fi

# ============================================================================
# 5. ファイアウォール
# ============================================================================
if [[ "${OS_FAMILY}" == "rhel" ]]; then
  log "$(_t "firewalld: SSH(${SSH_PORT}) カスタムサービスを作成して許可" \
            "firewalld: creating and allowing custom SSH(${SSH_PORT}) service")"
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
  ok "$(_t "firewalld: ${SVC_NAME} を許可" "firewalld: ${SVC_NAME} allowed")"
else
  log "$(_t "ufw: 新 SSH ポート ${SSH_PORT}/tcp と旧 22/tcp (一時) を許可" \
            "ufw: allowing new SSH ${SSH_PORT}/tcp and old 22/tcp (temporary)")"
  ufw allow "${SSH_PORT}/tcp" comment "ssh-new"
  ufw allow 22/tcp comment "ssh-old (temporary)" || true
  if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
    warn "$(_t "ufw を有効化します (既存 iptables ルールは上書きされる可能性あり)" \
               "Enabling ufw (existing iptables rules may be overwritten)")"
    ufw --force enable
  fi
  ok "$(_t "ufw 設定完了" "ufw configured")"
fi

# ============================================================================
# 6. sshd 再起動
# ============================================================================
# Ubuntu 22.04+ / Debian 12+ では ssh.socket による socket activation がデフォルトで、
# port 22 を抱えたまま ssh.service と衝突し新ポート bind に時間がかかる/失敗する。
# 確実に sshd_config の Port を反映させるため socket activation を無効化する。
if [[ "${OS_FAMILY}" == "debian" ]]; then
  if systemctl list-unit-files ssh.socket >/dev/null 2>&1 \
     && systemctl cat ssh.socket >/dev/null 2>&1; then
    log "$(_t "ssh.socket (socket activation) を無効化して ssh.service 直接起動に切替" \
              "Disabling ssh.socket (socket activation) and using ssh.service directly")"
    systemctl disable --now ssh.socket 2>/dev/null || true
    systemctl enable ssh.service 2>/dev/null || true
  fi
fi

log "$(_t "${SSH_SERVICE} を再起動します" "Restarting ${SSH_SERVICE}")"
systemctl restart "${SSH_SERVICE}"
ok "$(_t "${SSH_SERVICE} 再起動完了" "${SSH_SERVICE} restarted")"

# ============================================================================
# 7. Docker (任意)
# ============================================================================
if [[ "${DO_DOCKER^^}" == "Y" ]]; then
  log "$(_t "Docker CE をインストールします" "Installing Docker CE")"
  if [[ "${OS_FAMILY}" == "rhel" ]]; then
    dnf -y remove docker docker-client docker-client-latest docker-common \
                  docker-latest docker-latest-logrotate docker-logrotate \
                  docker-engine podman runc 2>/dev/null || true
    if ! command -v dnf config-manager >/dev/null 2>&1; then
      dnf -y install dnf-plugins-core
    fi
    if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
      dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
    fi
    dnf repolist | grep -q docker-ce-stable \
      || warn "$(_t "docker-ce-stable が見えません" "docker-ce-stable repo not visible")"
    dnf -y install device-mapper-persistent-data lvm2
    dnf -y install docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin
  else
    for p in docker.io docker-doc docker-compose docker-compose-v2 \
             podman-docker containerd runc; do
      apt-get -y remove "$p" 2>/dev/null || true
    done
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get -y install ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
      curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
    fi
    ARCH="$(dpkg --print-architecture)"
    CODENAME="${VERSION_CODENAME:-$(. /etc/os-release && echo "${VERSION_CODENAME}")}"
    if [[ -z "${CODENAME}" ]]; then
      err "$(_t "Debian/Ubuntu の VERSION_CODENAME が取得できません" \
                "Cannot determine Debian/Ubuntu VERSION_CODENAME")"
      exit 1
    fi
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get -y install docker-ce docker-ce-cli containerd.io \
                       docker-buildx-plugin docker-compose-plugin
  fi
  ok "$(_t "Docker パッケージインストール完了" "Docker packages installed")"

  log "$(_t "docker サービスを有効化 + 起動" "Enabling and starting docker service")"
  systemctl enable --now docker
  systemctl enable --now containerd 2>/dev/null || true

  log "$(_t "docker グループを作成し ${NEW_USER} を追加" \
            "Creating docker group and adding ${NEW_USER}")"
  groupadd -f docker
  usermod -aG docker "${NEW_USER}"
  ok "$(_t "docker グループ設定完了" "docker group configured")"

  log "$(_t "バージョン確認" "Version check")"
  docker --version || true
  docker compose version || true
fi

# ============================================================================
# 8. SSH 接続自動検証 (Lv1: LISTEN, Lv2: SSH ハンドシェイク)
# ============================================================================
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

log "$(_t "Lv1: sshd の LISTEN チェック (port ${SSH_PORT}, 最大 30 秒待機)" \
          "Lv1: checking sshd LISTEN on port ${SSH_PORT} (up to 30s)")"
LISTEN_OK="no"
for _i in $(seq 1 30); do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${SSH_PORT}\$"; then
    LISTEN_OK="yes"
    log "$(_t "  -> ${_i} 秒後に LISTEN を確認" "  -> LISTEN detected after ${_i}s")"
    break
  fi
  sleep 1
done
if [[ "${LISTEN_OK}" != "yes" ]]; then
  err "$(_t "sshd が port ${SSH_PORT} で LISTEN していません。port 22 は開放したまま終了します。" \
            "sshd not listening on port ${SSH_PORT}. Exiting with port 22 still open.")"
  err "$(_t "復旧手順:" "Recovery steps:")"
  err "  cp -a ${BACKUP} ${SSHD_CFG} && systemctl restart ${SSH_SERVICE}"
  exit 1
fi
ok "$(_t "Lv1 OK: sshd LISTEN on ${SSH_PORT}/tcp" \
          "Lv1 OK: sshd is LISTENing on ${SSH_PORT}/tcp")"

log "$(_t "Lv2: SSH ハンドシェイクチェック (127.0.0.1:${SSH_PORT})" \
          "Lv2: SSH handshake check (127.0.0.1:${SSH_PORT})")"
BANNER=""
{
  if exec 9<>/dev/tcp/127.0.0.1/"${SSH_PORT}"; then
    IFS= read -r -t 5 BANNER <&9 || true
    exec 9>&-
  fi
} 2>/dev/null
BANNER="${BANNER%$'\r'}"
if [[ "${BANNER}" != SSH-* ]]; then
  err "$(_t "SSH ハンドシェイク失敗 (応答: ${BANNER:-(なし)}). port 22 は開放したまま終了します。" \
            "SSH handshake failed (response: ${BANNER:-(none)}). Exiting with port 22 still open.")"
  exit 1
fi
ok "$(_t "Lv2 OK: ${BANNER}" "Lv2 OK: ${BANNER}")"

# ============================================================================
# 9. 旧ポート 22 を即時閉鎖
# ============================================================================
log "$(_t "旧ポート 22 を閉鎖します" "Closing legacy port 22")"
if [[ "${OS_FAMILY}" == "rhel" ]]; then
  firewall-cmd --permanent --zone=public --remove-service=ssh 2>/dev/null || true
  firewall-cmd --zone=public --remove-service=ssh 2>/dev/null || true
  firewall-cmd --reload
  ok "$(_t "firewalld: ssh(22) サービス削除完了" "firewalld: ssh(22) service removed")"
else
  ufw --force delete allow 22/tcp || true
  ok "$(_t "ufw: 22/tcp 削除完了" "ufw: 22/tcp removed")"
fi

# ============================================================================
# 完了 — PC 側で実行するコマンドを出力
# ============================================================================
SERVER_IP="${SERVER_IP:-<server_ip>}"
SSH_HOST_ALIAS="mirai-server"

if [[ "${PUBKEY_MODE}" == "skip" ]]; then
  IDENTITY_PATH=""; IDENTITY_FLAG=""; IDENTITY_CFG_LINE=""
elif [[ "${PUBKEY_MODE}" == "generate" ]]; then
  IDENTITY_PATH="~/.ssh/${NEW_USER}_ed25519"
  IDENTITY_FLAG=" -i ${IDENTITY_PATH}"
  IDENTITY_CFG_LINE="    IdentityFile ${IDENTITY_PATH}"
else
  IDENTITY_PATH="$(_t "~/.ssh/<秘密鍵ファイル名>" "~/.ssh/<your_private_key>")"
  IDENTITY_FLAG=" -i ${IDENTITY_PATH}"
  IDENTITY_CFG_LINE="    IdentityFile ${IDENTITY_PATH}"
fi

echo
echo "================================================================"
ok "$(_t "全工程完了" "All steps completed")"
echo "================================================================"
echo
echo "$(_t "  以下のコマンドを PC のターミナルに貼り付けて実行してください。" \
          "  Paste the following commands into your PC terminal.")"
echo "$(_t "  (heredoc / シングルクォートはそのままコピー可能です)" \
          "  (heredoc and single quotes can be copied as-is)")"
echo

# [1] 接続テスト
cat <<EOF
# ----- [1] $(_t "SSH 接続テスト" "SSH connection test") --------------------
ssh ${NEW_USER}@${SERVER_IP} -p ${SSH_PORT}${IDENTITY_FLAG}

EOF

# [2] ~/.ssh/config に追記
if [[ "${PUBKEY_MODE}" != "skip" ]]; then
cat <<EOF
# ----- [2] $(_t "~/.ssh/config に追記 (推奨)" "Append to ~/.ssh/config (recommended)") --------
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

# $(_t "追記後はこれだけで接続可能:" "After this, you can simply run:")
ssh ${SSH_HOST_ALIAS}

EOF
fi

# [3] sudo 確認
cat <<EOF
# ----- [3] $(_t "sudo 動作確認" "sudo check") -----------------------------
ssh ${SSH_HOST_ALIAS:-${NEW_USER}@${SERVER_IP}} 'sudo whoami'
# => $(_t "'root' と表示されれば OK" "should print 'root'")

EOF

# [4] Docker 動作確認
if [[ "${DO_DOCKER^^}" == "Y" ]]; then
cat <<EOF
# ----- [4] $(_t "Docker 動作確認 (再ログイン後)" "Docker check (after re-login)") ----------
# $(_t "docker グループの反映には一度ログアウト→再ログインが必要です" \
       "docker group requires logout/re-login to take effect")
ssh ${SSH_HOST_ALIAS:-${NEW_USER}@${SERVER_IP}} 'docker ps'
ssh ${SSH_HOST_ALIAS:-${NEW_USER}@${SERVER_IP}} 'docker compose version'

EOF
fi

# サーバー側情報
cat <<EOF
# ----- $(_t "サーバー側ファイル (参照用)" "Server-side files (reference)") -------------
#   $(_t "設定ファイル" "Config file"): $( [[ "${USE_DROPIN}" == "yes" ]] && echo "${DROPIN_FILE}" || echo "${SSHD_CFG}" )
#   $(_t "バックアップ" "Backup"):     ${BACKUP}
EOF

# 注意事項
cat <<EOF

# ----- $(_t "手動対応が必要な項目" "Manual follow-up required") ----------------
#   $(_t "★ クラウドFW (Security Group / パケットフィルタ等)" \
         "* Cloud firewall (Security Group / packet filter, etc.)")
#       $(_t "TCP ${SSH_PORT} を許可" "Allow TCP ${SSH_PORT}")
#       $(_t "TCP 22 はもう不要 (script で閉鎖済み)" "TCP 22 no longer needed (closed by script)")
EOF

if [[ "${PUBKEY_MODE}" == "generate" ]]; then
cat <<EOF
#
#   $(_t "★ サーバー上で生成した秘密鍵は破棄済みです。" \
         "* The server-side private key has been destroyed.")
#     $(_t "PC 側に ${IDENTITY_PATH} として保存していない場合は再実行が必要です。" \
         "Re-run the script if you did not save it as ${IDENTITY_PATH} on your PC.")
EOF
fi

echo
echo "================================================================"
echo
