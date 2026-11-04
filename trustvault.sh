#!/usr/bin/env bash
#
# TrustVault - two-site NAS with encrypted, append-only cross-backups
#
#   Samba        serves a shared folder to the local network
#   restic       encrypts, deduplicates and snapshots that folder, sends it to the peer
#   rest-server  receives the peer's backups in append-only mode (the peer cannot
#                delete or alter what it has already sent)
#   ZeroTier     private network between the two sites
#
# Target: Linux Mint, Debian, Ubuntu and derivatives with systemd and apt.
# Status: DRAFT. Test on a VM or spare machine before trusting it with real data.
#
# Usage: sudo ./trustvault.sh help

set -euo pipefail

PROJECT="trustvault"      # used for commands, paths, users and units
PRODUCT="TrustVault"      # display name
TV_VERSION="0.1.0-draft"

# Pinned upstream versions. Check the release pages before installing:
#   https://github.com/restic/restic/releases
#   https://github.com/restic/rest-server/releases
RESTIC_VERSION="0.18.0"
REST_SERVER_VERSION="0.13.0"

ETC_DIR="/etc/$PROJECT"
CONF_FILE="$ETC_DIR/$PROJECT.conf"
SECRETS_DIR="$ETC_DIR/secrets"
HTPASSWD_FILE="$ETC_DIR/htpasswd"
OPT_DIR="/opt/$PROJECT"
BIN_DIR="$OPT_DIR/bin"
STATE_DIR="/var/lib/$PROJECT"
LOG_FILE="/var/log/$PROJECT.log"
RECOVERY_FILE="/root/$PROJECT-RECOVERY.txt"
SAMBA_SNIPPET="/etc/samba/$PROJECT.conf"
SMB_CONF="/etc/samba/smb.conf"
UNIT_DIR="/etc/systemd/system"
SEND_USER="$PROJECT"          # runs backups (reads the share via CAP_DAC_READ_SEARCH)
RECV_USER="$PROJECT-recv"     # runs rest-server (owns the peer's encrypted data)
SHARE_GROUP="$PROJECT-share"  # Samba users of the share
MARK="# managed-by-$PROJECT"

ZT_IP_FILTER='.assignedAddresses[]? | select(test("^[0-9]+\\.")) | split("/")[0]'

CONFIG_VARS=(
  LOCAL_NAME SHARE_NAME SHARE_PATH SHARE_USERS ZT_NETWORK
  RECV_DATA RECV_PORT RECV_MAX_GB PEER_NAME
  PEER_HOST PEER_PORT REMOTE_USER
  SCHEDULE UPLOAD_LIMIT_KIB KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY HEALTHCHECK_URL
)

DRY_RUN=0

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

log() {
  local msg="[$PROJECT] $*"
  printf '%s\n' "$msg" >&2
  if [[ -w $LOG_FILE || ( ! -e $LOG_FILE && -w ${LOG_FILE%/*} ) ]]; then
    printf '%s %s\n' "$(date -Is)" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  fi
}
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# Run a command, or only print it in dry-run mode. Never pass secrets as arguments.
run() {
  if (( DRY_RUN )); then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  log "+ $*"
  "$@"
}

# write_file PATH MODE OWNER GROUP  (content on stdin). Only rewrites if content changed.
write_file() {
  local path=$1 mode=$2 owner=$3 group=$4 tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if (( DRY_RUN )); then
    echo "[dry-run] write $path ($mode $owner:$group)"
    rm -f "$tmp"
    return 0
  fi
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
  else
    install -D -m "$mode" -o "$owner" -g "$group" "$tmp" "$path"
    rm -f "$tmp"
    log "wrote $path"
  fi
  chown "$owner:$group" "$path"
  chmod "$mode" "$path"
}

ask() {  # ask VAR "Prompt" [default]
  local __var=$1 __prompt=$2 __def=${3:-} __ans
  read -r -p "$__prompt${__def:+ [$__def]}: " __ans
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

ask_secret() {  # ask_secret VAR "Prompt"
  local __var=$1 __prompt=$2 __ans
  read -r -s -p "$__prompt: " __ans
  echo >&2
  printf -v "$__var" '%s' "$__ans"
}

confirm() {
  local ans
  read -r -p "$1 [y/N]: " ans
  [[ $ans =~ ^[Yy] ]]
}

gen_secret() {  # 40 random alphanumeric characters
  local s
  s=$(head -c 64 /dev/urandom | base64 -w0)
  s=${s//[^A-Za-z0-9]/}
  printf '%s' "${s:0:40}"
}

valid_name()  { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; }
valid_ztnet() { [[ $1 =~ ^[0-9a-f]{16}$ ]]; }
valid_port()  { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65534 )); }
valid_ipv4()  { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_uint()  { [[ $1 =~ ^[0-9]+$ ]]; }

require_root() { [[ $EUID -eq 0 ]] || die "This command must be run as root (use sudo)."; }

check_platform() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  local family pretty
  family=$( . /etc/os-release; echo " ${ID:-} ${ID_LIKE:-} " )
  pretty=$( . /etc/os-release; echo "${PRETTY_NAME:-unknown}" )
  if [[ $family != *" debian "* && $family != *" ubuntu "* ]]; then
    die "Unsupported distribution ($pretty). This draft supports Debian, Ubuntu and Linux Mint."
  fi
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    die "systemd is required."
  fi
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found."
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)          echo amd64 ;;
    aarch64|arm64)   echo arm64 ;;
    armv7l|armv6l)   echo arm ;;
    i686|i386)       echo 386 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

set_defaults() {
  local h
  h=$(hostname -s 2>/dev/null || echo nas)
  h=${h,,}; h=${h//[^a-z0-9-]/-}
  : "${LOCAL_NAME:=$h}"
  : "${SHARE_NAME:=nas}"
  : "${SHARE_PATH:=/srv/nas}"
  : "${SHARE_USERS:=${SUDO_USER:-}}"
  : "${ZT_NETWORK:=}"
  : "${RECV_DATA:=/srv/$PROJECT/incoming}"
  : "${RECV_PORT:=8000}"
  : "${RECV_MAX_GB:=0}"
  : "${PEER_NAME:=}"
  : "${PEER_HOST:=}"
  : "${PEER_PORT:=8000}"
  : "${REMOTE_USER:=}"
  : "${SCHEDULE:=*-*-* 01:30:00}"
  : "${UPLOAD_LIMIT_KIB:=0}"
  : "${KEEP_DAILY:=7}"
  : "${KEEP_WEEKLY:=4}"
  : "${KEEP_MONTHLY:=12}"
  : "${HEALTHCHECK_URL:=}"
}

load_config() {
  [[ -r $CONF_FILE ]] || die "No configuration at $CONF_FILE. Run: sudo $PROJECT configure"
  # shellcheck source=/dev/null
  . "$CONF_FILE"
  set_defaults
}

save_config() {
  local v
  {
    echo "# $PRODUCT configuration. You may edit this file; run '$PROJECT apply' afterwards."
    for v in "${CONFIG_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done
  } | write_file "$CONF_FILE" 0644 root root
}

validate_config() {
  valid_name "$LOCAL_NAME"   || die "LOCAL_NAME '$LOCAL_NAME' is invalid."
  valid_name "$PEER_NAME"    || die "PEER_NAME '$PEER_NAME' is invalid."
  valid_ztnet "$ZT_NETWORK"  || die "ZT_NETWORK '$ZT_NETWORK' is not a 16-character network ID."
  valid_port "$RECV_PORT"    || die "RECV_PORT must be between 1024 and 65534."
  [[ $SHARE_PATH == /* ]]    || die "SHARE_PATH must be an absolute path."
  [[ -n $SHARE_USERS ]]      || die "SHARE_USERS is empty."
  if [[ $RECV_DATA != /* || $RECV_DATA == *[[:space:]]* ]]; then
    die "RECV_DATA must be an absolute path without spaces."
  fi
  local n
  for n in RECV_MAX_GB UPLOAD_LIMIT_KIB KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY; do
    valid_uint "${!n}" || die "$n must be a whole number."
  done
  if [[ -n $PEER_HOST ]]; then
    valid_ipv4 "$PEER_HOST" || die "PEER_HOST '$PEER_HOST' is not an IPv4 address."
    valid_port "$PEER_PORT" || die "PEER_PORT must be between 1024 and 65534."
    valid_name "$REMOTE_USER" || die "REMOTE_USER '$REMOTE_USER' is invalid."
  fi
  systemd-analyze calendar "$SCHEDULE" >/dev/null 2>&1 || die "SCHEDULE '$SCHEDULE' is not a valid systemd calendar expression."
}

has_peer() { [[ -n $PEER_HOST && -n $REMOTE_USER && -s $SECRETS_DIR/peer-login ]]; }

restic_env() {  # restic_env [port]
  local port=${1:-$PEER_PORT}
  export RESTIC_REPOSITORY="rest:http://$PEER_HOST:$port/$REMOTE_USER/"
  export RESTIC_PASSWORD_FILE="$SECRETS_DIR/repo-password"
  export RESTIC_REST_USERNAME="$REMOTE_USER"
  RESTIC_REST_PASSWORD=$(<"$SECRETS_DIR/peer-login")
  export RESTIC_REST_PASSWORD
}

hc_ping() {  # hc_ping [start|fail]
  [[ -n $HEALTHCHECK_URL ]] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "${HEALTHCHECK_URL%/}${1:+/$1}" || true
}

fix_secret_perms() {
  getent group "$SEND_USER" >/dev/null 2>&1 || return 0
  run chown "root:$SEND_USER" "$SECRETS_DIR"
  run chmod 0750 "$SECRETS_DIR"
  local f
  for f in repo-password peer-login; do
    if [[ -e $SECRETS_DIR/$f ]]; then
      run chown "root:$SEND_USER" "$SECRETS_DIR/$f"
      run chmod 0640 "$SECRETS_DIR/$f"
    fi
  done
  if [[ -e $SECRETS_DIR/issued-login ]]; then
    run chown root:root "$SECRETS_DIR/issued-login"
    run chmod 0600 "$SECRETS_DIR/issued-login"
  fi
}

write_recovery_sheet() {
  local pw repo
  pw=$(<"$SECRETS_DIR/repo-password")
  if [[ -n $PEER_HOST ]]; then
    repo="rest:http://$PEER_HOST:$PEER_PORT/$REMOTE_USER/"
  else
    repo="rest:http://<peer ZeroTier IP>:<port>/<your login on the peer>/  (not paired yet)"
  fi
  write_file "$RECOVERY_FILE" 0600 root root <<EOF
$PRODUCT RECOVERY SHEET
Machine: $LOCAL_NAME            Written: $(date '+%Y-%m-%d %H:%M')

KEEP THIS OFF THIS COMPUTER: print it, or store it in a password manager,
then delete this file. Without the repository password nobody (including
you) can decrypt the backups stored on your peer.

  Repository password : $pw
  Backup location     : $repo
  Login on the peer   : ${REMOTE_USER:-<not paired yet>}  (your peer can issue a new password if you lose it)
  ZeroTier network    : $ZT_NETWORK

Restoring on any Linux computer with restic installed and joined to the
ZeroTier network:

  export RESTIC_REPOSITORY='$repo'
  export RESTIC_REST_USERNAME='${REMOTE_USER:-<login>}'
  export RESTIC_REST_PASSWORD='<login password from your peer>'
  restic snapshots                                  # asks for the repository password
  restic restore latest --target /path/to/restore
EOF
}

# --------------------------------------------------------------------------
# ZeroTier
# --------------------------------------------------------------------------

zt_json()    { zerotier-cli -j listnetworks 2>/dev/null || echo '[]'; }
zt_field()   { zt_json | jq -r --arg n "$ZT_NETWORK" "first(.[] | select(.nwid == \$n) | $1) // empty"; }
zt_node_id() { zerotier-cli info 2>/dev/null | awk '{print $3}'; }
iface_ip()   { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'; }

zt_account_notice() {
  cat <<EOF

  ==========================================================================
   ZEROTIER ACCOUNT REQUIRED (created outside $PRODUCT)
  ==========================================================================
  The two machines reach each other through a private ZeroTier network.
  $PRODUCT installs the ZeroTier software, but it cannot create the account or
  the network for you. Before continuing, ONE of the two of you must:

    1. Create an account at https://my.zerotier.com
       (ZeroTier offers a free plan; check their site for current terms).
    2. Click "Create A Network" and copy its 16-character Network ID.
    3. Send that same Network ID to the other person. Both machines use it.

  After 'apply' has run on each machine, the network owner opens the network
  on my.zerotier.com and ticks "Auth" next to each machine's node ID under
  "Members". Backups cannot start until both machines are authorized.

EOF
}

# ZeroTier needs the TUN device. Proxmox LXC containers don't have it by default.
check_tun() {
  [[ -c /dev/net/tun ]] && return 0
  local virt
  virt=$(systemd-detect-virt --container 2>/dev/null || true)
  if [[ $virt == lxc* ]]; then
    log "ERROR: /dev/net/tun is missing, so ZeroTier cannot create its network adapter."
    cat >&2 <<EOF

  This machine is an LXC container. On the Proxmox HOST, give it the TUN device:

      pct stop <CTID>
      pct set <CTID> -dev0 /dev/net/tun
      pct start <CTID>

  (On Proxmox older than 8.1, add these lines to /etc/pve/lxc/<CTID>.conf instead:
      lxc.cgroup2.devices.allow: c 10:200 rwm
      lxc.mount.entry: /dev/net dev/net none bind,create=dir )

  Then run '$PROJECT apply' again.
EOF
    exit 1
  fi
  die "/dev/net/tun is missing, so ZeroTier cannot create its network adapter. Load the 'tun' kernel module (sudo modprobe tun) and run apply again."
}

# One-line explanation of why this machine has no ZeroTier IPv4 address.
zt_diagnose() {
  local st
  st=$(zt_field '.status')
  case $st in
    "") echo "not joined to network $ZT_NETWORK (run: sudo $PROJECT apply)" ;;
    ACCESS_DENIED|REQUESTING_CONFIGURATION)
        echo "waiting for authorization: tick 'Auth' for node $(zt_node_id) in ZeroTier Central" ;;
    NOT_FOUND) echo "network $ZT_NETWORK does not exist; check the network ID" ;;
    OK) echo "connected but no IPv4 address: turn on IPv4 Auto-Assign for the network in ZeroTier Central, or assign this member an IP" ;;
    *)  echo "ZeroTier network status is $st (see: sudo journalctl -u zerotier-one)" ;;
  esac
}

ensure_zerotier() {
  check_tun
  if ! command -v zerotier-cli >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      echo "[dry-run] install ZeroTier with the official installer (https://install.zerotier.com)"
      return 0
    fi
    log "Installing ZeroTier with the official installer (https://install.zerotier.com) ..."
    curl -fsSL https://install.zerotier.com | bash || die "ZeroTier installation failed."
  fi
  run systemctl enable --now zerotier-one
  (( DRY_RUN )) && return 0
  local i
  for (( i = 0; i < 15; i++ )); do
    if zerotier-cli info >/dev/null 2>&1; then break; fi
    sleep 1
  done
  if [[ -z $(zt_field '.nwid') ]]; then
    run zerotier-cli join "$ZT_NETWORK"
    for (( i = 0; i < 10; i++ )); do
      [[ -n $(zt_field '.nwid') ]] && return 0
      sleep 1
    done
    die "ZeroTier accepted the join but then dropped network $ZT_NETWORK. Check: sudo journalctl -u zerotier-one -n 40"
  fi
}

# --------------------------------------------------------------------------
# Installation pieces
# --------------------------------------------------------------------------

ensure_packages() {
  local missing=() p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} )); then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

ensure_system_user() {
  if ! id "$1" >/dev/null 2>&1; then
    run useradd --system --user-group --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin "$1"
  fi
}

# fetch_verified BASE_URL FILE DIR: download FILE and check it against the release's SHA256SUMS
fetch_verified() {
  local base=$1 file=$2 dir=$3 line
  curl -fsSL --retry 3 -o "$dir/$file" "$base/$file" || die "Download failed: $base/$file"
  curl -fsSL --retry 3 -o "$dir/SHA256SUMS" "$base/SHA256SUMS" || die "Download failed: $base/SHA256SUMS"
  line=$(awk -v f="$file" '$2 == f || $2 == "*" f' "$dir/SHA256SUMS")
  [[ -n $line ]] || die "No checksum for $file in SHA256SUMS."
  (cd "$dir" && sha256sum -c --status - <<<"$line") || die "Checksum mismatch for $file."
  log "verified checksum of $file"
}

install_restic() {
  local arch=$1 marker="$BIN_DIR/.restic-version" tmp file base
  if [[ -x $BIN_DIR/restic && $(cat "$marker" 2>/dev/null) == "$RESTIC_VERSION" ]]; then return 0; fi
  if (( DRY_RUN )); then echo "[dry-run] download and install restic $RESTIC_VERSION ($arch)"; return 0; fi
  tmp=$(mktemp -d)
  file="restic_${RESTIC_VERSION}_linux_${arch}.bz2"
  base="https://github.com/restic/restic/releases/download/v$RESTIC_VERSION"
  fetch_verified "$base" "$file" "$tmp"
  bunzip2 -c "$tmp/$file" >"$tmp/restic"
  install -D -m 0755 "$tmp/restic" "$BIN_DIR/restic"
  echo "$RESTIC_VERSION" >"$marker"
  rm -rf "$tmp"
  log "installed restic $RESTIC_VERSION"
}

install_rest_server() {
  local arch=$1 marker="$BIN_DIR/.rest-server-version" tmp file base dir
  if [[ -x $BIN_DIR/rest-server && $(cat "$marker" 2>/dev/null) == "$REST_SERVER_VERSION" ]]; then return 0; fi
  if (( DRY_RUN )); then echo "[dry-run] download and install rest-server $REST_SERVER_VERSION ($arch)"; return 0; fi
  tmp=$(mktemp -d)
  dir="rest-server_${REST_SERVER_VERSION}_linux_${arch}"
  file="$dir.tar.gz"
  base="https://github.com/restic/rest-server/releases/download/v$REST_SERVER_VERSION"
  fetch_verified "$base" "$file" "$tmp"
  tar -xzf "$tmp/$file" -C "$tmp"
  [[ -f $tmp/$dir/rest-server ]] || die "rest-server binary not found in $file."
  install -D -m 0755 "$tmp/$dir/rest-server" "$BIN_DIR/rest-server"
  echo "$REST_SERVER_VERSION" >"$marker"
  rm -rf "$tmp"
  log "installed rest-server $REST_SERVER_VERSION"
}

install_self() {
  local self
  self=$(readlink -f "${BASH_SOURCE[0]}")
  if [[ $self != "$BIN_DIR/$PROJECT" ]]; then
    run install -D -m 0755 "$self" "$BIN_DIR/$PROJECT"
  fi
  run ln -sfn "$BIN_DIR/$PROJECT" "/usr/local/sbin/$PROJECT"
}

write_htpasswd() {
  (( DRY_RUN )) && { echo "[dry-run] write $HTPASSWD_FILE for login '$PEER_NAME'"; return 0; }
  local tmp
  tmp=$(mktemp)
  htpasswd -B -i -c "$tmp" "$PEER_NAME" <"$SECRETS_DIR/issued-login" 2>/dev/null \
    || die "Could not create the htpasswd file."
  install -m 0640 -o root -g "$RECV_USER" "$tmp" "$HTPASSWD_FILE"
  rm -f "$tmp"
}

lan_ips() {  # IPv4 addresses on local network interfaces (skips ZeroTier, Docker, VMs)
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '$2 !~ /^(zt|docker|br-|veth|virbr|lxc|tun|tap)/ {split($4, a, "/"); print a[1]}'
}

samba_has_password() {  # samba_has_password USER
  local list
  list=$(pdbedit -L 2>/dev/null | cut -d: -f1 || true)
  grep -qx "$1" <<<"$list"
}

print_share_info() {
  local host ips ip u users
  host=$(hostname -s 2>/dev/null || hostname)
  mapfile -t ips < <(lan_ips)
  read -r -a users <<<"$SHARE_USERS"

  cat <<EOF
--------------------------------------------------------------------------
  CONNECTING TO THE SHARE FROM THIS LOCAL NETWORK
--------------------------------------------------------------------------
  Computer name : $host
  IP address    : ${ips[*]:-<none found>}
  Share name    : $SHARE_NAME
  Folder        : $SHARE_PATH

  Windows (File Explorer address bar, or Map network drive):
      \\\\$host\\$SHARE_NAME
EOF
  for ip in "${ips[@]}"; do printf '      \\\\%s\\%s\n' "$ip" "$SHARE_NAME"; done
  cat <<EOF
  macOS (Finder > Go > Connect to Server) or Linux (file manager address bar):
      smb://$host.local/$SHARE_NAME
EOF
  for ip in "${ips[@]}"; do printf '      smb://%s/%s\n' "$ip" "$SHARE_NAME"; done
  cat <<EOF
  If the name doesn't work, use the IP address. For a permanent address,
  reserve this IP for this computer in your router's DHCP settings.

  Username : one of the users below (some systems ask for "$host\\username")
  Password : that user's SAMBA password, which is separate from the login password
EOF
  for u in "${users[@]}"; do
    if ! id "$u" >/dev/null 2>&1; then
      printf '      %-16s Linux user does not exist; create it, then run apply again\n' "$u"
    elif samba_has_password "$u"; then
      printf '      %-16s Samba password set (change: sudo %s share-password %s)\n' "$u" "$PROJECT" "$u"
    else
      printf '      %-16s NO Samba password yet: sudo %s share-password %s\n' "$u" "$PROJECT" "$u"
    fi
  done
  echo "--------------------------------------------------------------------------"
}

set_samba_password() {  # set_samba_password USER
  local u=$1
  id "$u" >/dev/null 2>&1 || die "Linux user '$u' does not exist."
  echo "Setting the Samba (network share) password for '$u'."
  echo "This is what '$u' types when connecting to the share. It can differ from the login password."
  smbpasswd -a "$u" || die "Could not set the Samba password for '$u'."
  smbpasswd -e "$u" >/dev/null 2>&1 || true
}

configure_samba() {
  local u users
  read -r -a users <<<"$SHARE_USERS"

  if grep -qiE "^[[:space:]]*\[$SHARE_NAME\]" "$SMB_CONF"; then
    die "A share named [$SHARE_NAME] already exists in $SMB_CONF. Choose another SHARE_NAME."
  fi

  getent group "$SHARE_GROUP" >/dev/null 2>&1 || run groupadd --system "$SHARE_GROUP"
  for u in "${users[@]}"; do
    if ! id "$u" >/dev/null 2>&1; then
      warn "Linux user '$u' does not exist; skipping. Create it, then run apply again."
      continue
    fi
    run usermod -aG "$SHARE_GROUP" "$u"
    if ! samba_has_password "$u"; then
      warn "No Samba password for '$u' yet; '$u' can't connect to the share until one is set."
    fi
  done

  if [[ ! -d $SHARE_PATH ]]; then
    run install -d -m 2770 -o root -g "$SHARE_GROUP" "$SHARE_PATH"
  else
    log "Share folder $SHARE_PATH already exists; its ownership and permissions are left unchanged."
  fi

  write_file "$SAMBA_SNIPPET" 0644 root root <<EOF
$MARK
# Generated by '$PROJECT apply'. Edit $CONF_FILE instead of this file.
[$SHARE_NAME]
   path = $SHARE_PATH
   browseable = yes
   read only = no
   valid users = @$SHARE_GROUP
   force group = $SHARE_GROUP
   create mask = 0660
   directory mask = 2770
EOF

  if ! grep -qxF "include = $SAMBA_SNIPPET" "$SMB_CONF"; then
    run cp -a "$SMB_CONF" "$SMB_CONF.$PROJECT-bak.$(date +%Y%m%d%H%M%S)"
    if (( ! DRY_RUN )); then
      printf '\n%s\ninclude = %s\n' "$MARK" "$SAMBA_SNIPPET" >>"$SMB_CONF"
      log "added include line to $SMB_CONF"
    fi
  fi

  if (( ! DRY_RUN )); then
    testparm -s >/dev/null 2>&1 \
      || die "Samba configuration test failed (run 'testparm' to see why). A backup of smb.conf is in /etc/samba/."
  fi
  run systemctl enable --now smbd
  run systemctl reload smbd
}

firewall_apply() {
  local iface=$1 p zone
  local ports=("$RECV_PORT" "$((RECV_PORT + 1))")
  if command -v ufw >/dev/null 2>&1 && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then
    for p in "${ports[@]}"; do
      run ufw allow in on "$iface" to any port "$p" proto tcp comment "$PROJECT"
    done
    printf 'ufw %s\n' "$iface" | write_file "$STATE_DIR/firewall" 0644 root root
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    zone=$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || firewall-cmd --get-default-zone)
    for p in "${ports[@]}"; do
      run firewall-cmd --permanent --zone="$zone" --add-port="$p/tcp"
    done
    run firewall-cmd --reload
    printf 'firewalld %s\n' "$zone" | write_file "$STATE_DIR/firewall" 0644 root root
  else
    warn "No active ufw or firewalld found. The receiver listens only on the ZeroTier address,"
    warn "but you may want firewall rules allowing TCP ${ports[*]} on $iface only."
  fi
}

firewall_remove() {
  [[ -r $STATE_DIR/firewall ]] || return 0
  local kind where p
  read -r kind where <"$STATE_DIR/firewall"
  for p in "$RECV_PORT" "$((RECV_PORT + 1))"; do
    case $kind in
      ufw)       run ufw delete allow in on "$where" to any port "$p" proto tcp || true ;;
      firewalld) run firewall-cmd --permanent --zone="$where" --remove-port="$p/tcp" || true ;;
    esac
  done
  if [[ $kind == firewalld ]]; then run firewall-cmd --reload || true; fi
}

write_units() {
  write_file "$UNIT_DIR/$PROJECT-receiver.service" 0644 root root <<EOF
[Unit]
Description=$PRODUCT receiver: append-only restic REST server for the paired peer
After=network-online.target zerotier-one.service
Wants=network-online.target zerotier-one.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$RECV_USER
Group=$RECV_USER
ExecStart=$BIN_DIR/$PROJECT run-receiver
Restart=on-failure
RestartSec=30
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$RECV_DATA
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF

  local svc
  for svc in backup check; do
    write_file "$UNIT_DIR/$PROJECT-$svc.service" 0644 root root <<EOF
[Unit]
Description=$PRODUCT $svc of the encrypted repository on the peer
After=network-online.target zerotier-one.service
Wants=network-online.target

[Service]
Type=oneshot
User=$SEND_USER
Group=$SEND_USER
ExecStart=$BIN_DIR/$PROJECT run-$svc
SuccessExitStatus=3
# Lets restic read every file in the share without running as root.
AmbientCapabilities=CAP_DAC_READ_SEARCH
CapabilityBoundingSet=CAP_DAC_READ_SEARCH
CacheDirectory=$PROJECT
Environment=RESTIC_CACHE_DIR=/var/cache/$PROJECT
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
NoNewPrivileges=yes
Nice=10
IOSchedulingClass=idle
EOF
  done

  write_file "$UNIT_DIR/$PROJECT-backup.timer" 0644 root root <<EOF
[Unit]
Description=$PRODUCT scheduled backup

[Timer]
OnCalendar=$SCHEDULE
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  write_file "$UNIT_DIR/$PROJECT-check.timer" 0644 root root <<EOF
[Unit]
Description=$PRODUCT weekly integrity check

[Timer]
OnCalendar=Sun *-*-* 05:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

init_repo() {
  restic_env
  if "$BIN_DIR/restic" --no-cache cat config >/dev/null 2>&1; then
    log "Repository on the peer is ready."
    return 0
  fi
  if (( DRY_RUN )); then echo "[dry-run] initialize repository at $RESTIC_REPOSITORY"; return 0; fi
  log "Initializing the encrypted repository on the peer ($PEER_HOST) ..."
  if ! "$BIN_DIR/restic" --no-cache init; then
    warn "Could not initialize the repository. Check that the peer has run apply, that both"
    warn "nodes are authorized in ZeroTier, and that the login details are correct."
    return 1
  fi
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

prompt_peer() {
  local pw
  while :; do ask PEER_HOST "Peer's ZeroTier IP address" "$PEER_HOST"; valid_ipv4 "$PEER_HOST" && break; echo "  Not a valid IPv4 address."; done
  while :; do ask PEER_PORT "Peer's backup port" "$PEER_PORT"; valid_port "$PEER_PORT" && break; echo "  Use a port between 1024 and 65534."; done
  while :; do ask REMOTE_USER "Login name your peer created for you" "$REMOTE_USER"; valid_name "$REMOTE_USER" && break; echo "  Invalid name."; done
  while :; do ask_secret pw "Password your peer gave you"; [[ -n $pw ]] && break; done
  printf '%s' "$pw" | write_file "$SECRETS_DIR/peer-login" 0600 root root
}

cmd_configure() {
  require_root
  check_platform
  if (( DRY_RUN )); then die "--dry-run is only supported for apply and uninstall."; fi
  if [[ -r $CONF_FILE ]]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
  fi
  set_defaults

  echo "=== $PRODUCT setup ==="
  echo "Press Enter to keep the value shown in [brackets]."
  echo
  while :; do ask LOCAL_NAME "Name for this machine (lowercase letters, digits, dashes)" "$LOCAL_NAME"; valid_name "$LOCAL_NAME" && break; echo "  Invalid name."; done

  echo; echo "-- Network share (Samba) --"
  cat <<EOF
  This machine will share one folder with computers on your local network.
  People connect to it with:
    - this computer's name or local IP address (shown at the end of 'apply')
    - the share name you choose below
    - a Linux user name on this computer, and
    - a separate SAMBA password for that user. It is not the user's login
      password unless you choose the same one. You'll be offered the chance
      to set it at the end of 'apply', or later with: sudo $PROJECT share-password USER
EOF
  while :; do ask SHARE_NAME "Share name as seen on the network" "$SHARE_NAME"; [[ $SHARE_NAME =~ ^[A-Za-z0-9_-]{1,32}$ ]] && break; echo "  Use letters, digits, - or _."; done
  while :; do ask SHARE_PATH "Folder to share and back up" "$SHARE_PATH"; [[ $SHARE_PATH == /* ]] && break; echo "  Use an absolute path."; done
  while :; do ask SHARE_USERS "Linux user names allowed to use the share (space-separated; must already exist)" "$SHARE_USERS"; [[ -n $SHARE_USERS ]] && break; done

  echo; echo "-- ZeroTier --"
  zt_account_notice
  if ! confirm "Do you have the ZeroTier network ID ready?"; then
    echo "Run '$(basename "$0") configure' again once you have it. Nothing has been changed."
    exit 0
  fi
  while :; do ask ZT_NETWORK "ZeroTier network ID (16 hex characters)" "$ZT_NETWORK"; ZT_NETWORK=${ZT_NETWORK,,}; valid_ztnet "$ZT_NETWORK" && break; echo "  Invalid network ID."; done

  echo; echo "-- Receiving your peer's backups --"
  while :; do ask RECV_DATA "Folder for the peer's encrypted backups" "$RECV_DATA"; [[ $RECV_DATA == /* && $RECV_DATA != *[[:space:]]* ]] && break; echo "  Use an absolute path without spaces."; done
  while :; do ask RECV_PORT "Receiver port (the next port up is used for maintenance windows)" "$RECV_PORT"; valid_port "$RECV_PORT" && break; echo "  Use a port between 1024 and 65534."; done
  while :; do ask RECV_MAX_GB "Maximum space your peer may use, in GB (0 = no limit)" "$RECV_MAX_GB"; valid_uint "$RECV_MAX_GB" && break; done
  while :; do ask PEER_NAME "Login name to create for your peer" "${PEER_NAME:-peer}"; valid_name "$PEER_NAME" && break; echo "  Invalid name."; done

  echo; echo "-- Sending your backups to the peer --"
  while :; do ask SCHEDULE "Backup schedule (systemd OnCalendar format)" "$SCHEDULE"; systemd-analyze calendar "$SCHEDULE" >/dev/null 2>&1 && break; echo "  Not a valid schedule, e.g. '*-*-* 01:30:00' or 'daily'."; done
  while :; do ask UPLOAD_LIMIT_KIB "Upload limit in KiB/s (0 = unlimited)" "$UPLOAD_LIMIT_KIB"; valid_uint "$UPLOAD_LIMIT_KIB" && break; done
  ask HEALTHCHECK_URL "Optional monitoring ping URL (e.g. from healthchecks.io), blank for none" "$HEALTHCHECK_URL"

  run install -d -m 0755 "$ETC_DIR"
  if [[ ! -d $SECRETS_DIR ]]; then run install -d -m 0700 "$SECRETS_DIR"; fi

  echo
  if confirm "Do you already have your peer's connection details?"; then prompt_peer; fi

  save_config

  local new_key=0
  if [[ ! -s $SECRETS_DIR/repo-password ]]; then
    gen_secret | write_file "$SECRETS_DIR/repo-password" 0600 root root
    new_key=1
  fi
  if [[ ! -s $SECRETS_DIR/issued-login ]]; then
    gen_secret | write_file "$SECRETS_DIR/issued-login" 0600 root root
  fi
  fix_secret_perms
  write_recovery_sheet

  if (( new_key )); then
    echo
    echo "A new encryption key was generated. Your recovery sheet is below and in $RECOVERY_FILE."
    echo "==========================================================================="
    cat "$RECOVERY_FILE"
    echo "==========================================================================="
    echo "If this computer is lost and this sheet is lost with it, the backups are unrecoverable."
    local ans
    while :; do
      read -r -p "Type SAVED once you have stored it somewhere other than this computer: " ans
      [[ $ans == SAVED ]] && break
    done
  fi

  echo
  echo "Configuration saved to $CONF_FILE."
  echo "Next: sudo $(basename "$0") apply"
}

cmd_apply() {
  require_root
  check_platform
  load_config
  validate_config
  [[ -s $SECRETS_DIR/repo-password && -s $SECRETS_DIR/issued-login ]] \
    || die "Secrets are missing. Run: sudo $PROJECT configure"

  local arch iface="" ip="" node="" i
  arch=$(detect_arch)
  log "Applying $PRODUCT $TV_VERSION (dry-run=$DRY_RUN)"

  ensure_packages samba samba-common-bin jq curl ca-certificates bzip2 tar apache2-utils iproute2
  ensure_system_user "$SEND_USER"
  ensure_system_user "$RECV_USER"
  run install -d -m 0755 "$OPT_DIR" "$BIN_DIR" "$STATE_DIR"

  install_restic "$arch"
  install_rest_server "$arch"
  install_self

  fix_secret_perms
  write_htpasswd
  run install -d -m 0750 -o "$RECV_USER" -g "$RECV_USER" "$RECV_DATA"

  ensure_zerotier
  if (( ! DRY_RUN )); then
    node=$(zt_node_id)
    for (( i = 0; i < 15; i++ )); do
      iface=$(zt_field '.portDeviceName')
      [[ -n $iface ]] && break
      sleep 2
    done
    ip=$(zt_field "$ZT_IP_FILTER")
  fi
  if [[ -n $iface ]]; then
    printf '%s\n' "$iface" | write_file "$STATE_DIR/zt-iface" 0644 root root
    firewall_apply "$iface"
  elif (( ! DRY_RUN )); then
    warn "The ZeroTier interface is not up yet. Authorize node ${node:-?} in your ZeroTier"
    warn "network, then run '$PROJECT apply' again."
  fi

  configure_samba

  write_units
  run systemctl daemon-reload
  run systemctl enable "$PROJECT-receiver.service"
  run systemctl restart "$PROJECT-receiver.service"

  local peer_ok=0
  if has_peer; then
    if init_repo; then peer_ok=1; fi
  fi
  if (( peer_ok )); then
    run systemctl enable --now "$PROJECT-backup.timer" "$PROJECT-check.timer"
  else
    run systemctl disable --now "$PROJECT-backup.timer" "$PROJECT-check.timer" 2>/dev/null || true
  fi

  echo
  echo "=== $PRODUCT applied ==="
  echo "ZeroTier node ID : ${node:-unknown} (must be authorized in network $ZT_NETWORK)"
  echo "ZeroTier address : ${ip:-none ($(zt_diagnose))}"
  if (( peer_ok )); then
    echo "Backups          : enabled, schedule '$SCHEDULE' -> $PEER_HOST"
  else
    echo "Backups          : NOT enabled yet (peer not set or unreachable)"
    echo
    echo "To pair:  1. sudo $PROJECT pairing-info   (send the result to your peer)"
    echo "          2. sudo $PROJECT set-peer       (enter the details your peer sends you)"
  fi
  if [[ -z $ip ]] && (( ! DRY_RUN )); then
    echo
    echo "ZeroTier: $(zt_diagnose)."
    echo "Once this machine has a ZeroTier address, run 'sudo $PROJECT apply' again."
  fi

  (( DRY_RUN )) && return 0
  local users u
  read -r -a users <<<"$SHARE_USERS"
  if [[ -t 0 ]]; then
    for u in "${users[@]}"; do
      if id "$u" >/dev/null 2>&1 && ! samba_has_password "$u"; then
        echo
        if confirm "User '$u' has no Samba password, so can't use the share yet. Set it now?"; then
          set_samba_password "$u"
        fi
      fi
    done
  fi
  echo
  print_share_info
}

cmd_share_info() {
  require_root
  load_config
  print_share_info
}

cmd_share_password() {
  require_root
  load_config
  local u=${1:-} users
  if [[ -z $u ]]; then
    read -r -a users <<<"$SHARE_USERS"
    if (( ${#users[@]} == 1 )); then u=${users[0]}; else die "Give the user name: sudo $PROJECT share-password USER"; fi
  fi
  if [[ " $SHARE_USERS " != *" $u "* ]]; then
    warn "'$u' is not in SHARE_USERS, so it won't be allowed on the share. Add it in $CONF_FILE and run apply."
  fi
  set_samba_password "$u"
}

cmd_set_peer() {
  require_root
  load_config
  prompt_peer
  save_config
  fix_secret_perms
  write_recovery_sheet
  log "Peer details saved. The recovery sheet at $RECOVERY_FILE now includes the backup location."
  if confirm "Run apply now to initialize the repository and enable scheduled backups?"; then
    cmd_apply
  fi
}

cmd_pairing_info() {
  require_root
  load_config
  local ip="" node=""
  if command -v zerotier-cli >/dev/null 2>&1; then
    ip=$(zt_field "$ZT_IP_FILTER")
    node=$(zt_node_id)
  fi
  cat <<EOF
Send these details to your peer. Share the password privately (in person, by
phone, or through a password manager), not in plain email or chat.

  Address  : ${ip:-<none: $(zt_diagnose)>}
  Port     : $RECV_PORT
  Username : $PEER_NAME
  Password : $(<"$SECRETS_DIR/issued-login")

Your peer enters them with:  sudo $PROJECT set-peer

This machine's ZeroTier node ID: ${node:-unknown}
EOF
}

cmd_status() {
  require_root
  load_config
  local ip="" node="" st=""
  echo "== $PRODUCT $TV_VERSION on $LOCAL_NAME =="
  if command -v zerotier-cli >/dev/null 2>&1; then
    node=$(zt_node_id); st=$(zt_field '.status'); ip=$(zt_field "$ZT_IP_FILTER")
    echo "ZeroTier    : node ${node:-?}, network $ZT_NETWORK ${st:-not joined}, address ${ip:-none ($(zt_diagnose))}"
  else
    echo "ZeroTier    : not installed"
  fi
  echo "Receiver    : $(systemctl is-active "$PROJECT-receiver.service" 2>/dev/null || true), port $RECV_PORT, data in $RECV_DATA"
  if systemctl is-active --quiet "$PROJECT-maint.service"; then
    echo "Maintenance : window OPEN on port $((RECV_PORT + 1))"
  fi
  echo "Last backup : $(systemctl show -p Result --value "$PROJECT-backup.service" 2>/dev/null || true)" \
       "at $(systemctl show -p ExecMainExitTimestamp --value "$PROJECT-backup.service" 2>/dev/null || true)"
  echo
  systemctl list-timers --all --no-pager "$PROJECT-*" 2>/dev/null || true
  echo
  df -h "$SHARE_PATH" "$RECV_DATA" 2>/dev/null || true
  if has_peer; then
    echo
    echo "Latest snapshot on the peer:"
    ( restic_env; "$BIN_DIR/restic" --no-cache snapshots --latest 1 --compact ) \
      || warn "Could not reach the repository on the peer."
  fi
}

cmd_backup_now() {
  require_root
  run systemctl start --no-block "$PROJECT-backup.service"
  echo "Backup started. Follow it with: journalctl -fu $PROJECT-backup.service"
}

cmd_restic() {
  load_config
  has_peer || die "No peer configured (or secrets not readable: run as root)."
  restic_env
  exec "$BIN_DIR/restic" "$@"
}

cmd_prune() {
  require_root
  load_config
  has_peer || die "No peer configured."
  restic_env "$((PEER_PORT + 1))"
  log "Removing old snapshots on the peer. This only works while the peer has a maintenance window open."
  run "$BIN_DIR/restic" forget --prune --host "$LOCAL_NAME" \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"
}

cmd_maintenance_window() {
  require_root
  load_config
  local minutes=${1:-60}
  if ! valid_uint "$minutes" || (( minutes < 1 || minutes > 1440 )); then
    die "Give the window length in minutes (1-1440)."
  fi
  if systemctl is-active --quiet "$PROJECT-maint.service"; then
    die "A maintenance window is already open. Close it with: sudo systemctl stop $PROJECT-maint"
  fi
  run systemd-run --unit="$PROJECT-maint" --collect \
    -p User="$RECV_USER" -p Group="$RECV_USER" -p RuntimeMaxSec="$((minutes * 60))" \
    -p ProtectSystem=strict -p ProtectHome=read-only -p ReadWritePaths="$RECV_DATA" \
    -p PrivateTmp=yes -p NoNewPrivileges=yes \
    "$BIN_DIR/$PROJECT" run-receiver maintenance
  echo "Maintenance window open for $minutes minutes on port $((RECV_PORT + 1))."
  echo "During this window your peer can DELETE data in its repository here."
  echo "Your peer can now run:  sudo $PROJECT prune"
  echo "Close it early with:    sudo systemctl stop $PROJECT-maint"
}

cmd_uninstall() {
  require_root
  local purge=0 u
  if [[ ${1:-} == --purge ]]; then purge=1; fi
  if [[ -r $CONF_FILE ]]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
  fi
  set_defaults

  echo "This removes $PROJECT's services, binaries, firewall rules and Samba share definition."
  (( purge )) && echo "--purge also removes $ETC_DIR (configuration and KEYS), $STATE_DIR and the $PROJECT users."
  confirm "Continue?" || exit 0

  for u in backup.timer check.timer backup.service check.service receiver.service maint.service; do
    run systemctl disable --now "$PROJECT-$u" 2>/dev/null || true
    run rm -f "$UNIT_DIR/$PROJECT-$u"
  done
  run systemctl daemon-reload
  firewall_remove

  if [[ -f $SMB_CONF ]] && grep -qxF "$MARK" "$SMB_CONF"; then
    run cp -a "$SMB_CONF" "$SMB_CONF.$PROJECT-bak.$(date +%Y%m%d%H%M%S)"
    run sed -i "/^$MARK\$/{N;d}" "$SMB_CONF"
  fi
  run rm -f "$SAMBA_SNIPPET"
  if systemctl is-active --quiet smbd; then run systemctl reload smbd; fi

  run rm -rf "$OPT_DIR"
  run rm -f "/usr/local/sbin/$PROJECT"

  if (( purge )); then
    run rm -rf "$ETC_DIR" "$STATE_DIR" "/var/cache/$PROJECT"
    run userdel "$SEND_USER" 2>/dev/null || true
    run userdel "$RECV_USER" 2>/dev/null || true
    run groupdel "$SHARE_GROUP" 2>/dev/null || true
  fi

  echo
  echo "Left in place on purpose:"
  echo "  - the shared folder $SHARE_PATH and its files"
  echo "  - your peer's encrypted backups in $RECV_DATA (delete them yourself if no longer needed)"
  echo "  - ZeroTier membership (leave with: sudo zerotier-cli leave $ZT_NETWORK)"
  echo "  - the recovery sheet $RECOVERY_FILE"
  if (( ! purge )); then
    echo "  - configuration and keys in $ETC_DIR (remove with: uninstall --purge)"
  fi
}

# --- Internal commands run by systemd -------------------------------------

cmd_run_receiver() {
  load_config
  local mode=${1:-} iface ip="" port i
  local args=(--path "$RECV_DATA" --htpasswd-file "$HTPASSWD_FILE" --private-repos)
  iface=$(cat "$STATE_DIR/zt-iface" 2>/dev/null || true)
  [[ -n $iface ]] || die "ZeroTier interface unknown. Run 'sudo $PROJECT apply'."
  for (( i = 0; i < 60; i++ )); do
    ip=$(iface_ip "$iface")
    [[ -n $ip ]] && break
    sleep 2
  done
  [[ -n $ip ]] || die "No IPv4 address on $iface. Is this node authorized in ZeroTier?"
  port=$RECV_PORT
  if [[ $mode == maintenance ]]; then
    port=$((RECV_PORT + 1))
  else
    args+=(--append-only)
  fi
  if (( RECV_MAX_GB > 0 )); then
    args+=(--max-size "$((RECV_MAX_GB * 1024 * 1024 * 1024))")
  fi
  args+=(--listen "$ip:$port")
  log "rest-server listening on $ip:$port ($([[ $mode == maintenance ]] && echo "maintenance, deletions allowed" || echo append-only))"
  exec "$BIN_DIR/rest-server" "${args[@]}"
}

cmd_run_backup() {
  load_config
  has_peer || die "No peer configured."
  restic_env
  local rc=0
  local args=(backup "$SHARE_PATH" --exclude-caches --tag "$PROJECT" --host "$LOCAL_NAME")
  if (( UPLOAD_LIMIT_KIB > 0 )); then args+=(--limit-upload "$UPLOAD_LIMIT_KIB"); fi
  hc_ping start
  "$BIN_DIR/restic" "${args[@]}" || rc=$?
  case $rc in
    0) hc_ping ""; log "Backup completed." ;;
    3) hc_ping ""; warn "Backup completed, but some files could not be read (see log above)." ;;
    *) hc_ping fail; log "ERROR: Backup failed with exit code $rc." ;;
  esac
  return "$rc"
}

cmd_run_check() {
  load_config
  has_peer || die "No peer configured."
  restic_env
  "$BIN_DIR/restic" check --read-data-subset=5%
}

usage() {
  cat <<EOF
$PRODUCT $TV_VERSION - paired NAS with encrypted, append-only cross-backups

Before you start: one of you needs a ZeroTier account and network
(https://my.zerotier.com). $PRODUCT cannot create these for you.

Setup (on each machine):
  configure                 Interactive setup; writes $CONF_FILE and generates keys
  apply [--dry-run]         Install and configure everything; safe to re-run
  pairing-info              Show the details to send to your peer
  set-peer                  Enter the details your peer sent you

Network share:
  share-info                How to connect: computer name, IP address, share name, users
  share-password [USER]     Set or change a user's Samba (share) password

Daily use:
  status                    Overview of ZeroTier, services, timers, disks, last snapshot
  backup-now                Start a backup immediately
  restic ARGS...            Run restic against your repository on the peer, e.g.
                              $PROJECT restic snapshots
                              $PROJECT restic restore latest --target /tmp/restore

Maintenance:
  maintenance-window [MIN]  Let your peer prune its backups here for MIN minutes (default 60)
  prune                     Remove old snapshots on the peer (peer must open a window first)
  uninstall [--purge]       Remove $PROJECT (data and backups are never deleted)
EOF
}

main() {
  local args=() a
  for a in "$@"; do
    case $a in
      --dry-run) DRY_RUN=1 ;;
      *) args+=("$a") ;;
    esac
  done
  set -- "${args[@]}"
  local cmd=${1:-help}
  shift || true
  case $cmd in
    configure)          cmd_configure ;;
    apply)              cmd_apply ;;
    set-peer)           cmd_set_peer ;;
    pairing-info)       cmd_pairing_info ;;
    status)             cmd_status ;;
    share-info)         cmd_share_info ;;
    share-password)     cmd_share_password "$@" ;;
    backup-now)         cmd_backup_now ;;
    restic)             cmd_restic "$@" ;;
    prune)              cmd_prune ;;
    maintenance-window) cmd_maintenance_window "$@" ;;
    uninstall)          cmd_uninstall "$@" ;;
    run-receiver)       cmd_run_receiver "$@" ;;
    run-backup)         cmd_run_backup ;;
    run-check)          cmd_run_check ;;
    help|-h|--help)     usage ;;
    *) usage; exit 1 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
