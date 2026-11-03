#!/usr/bin/env bash
# =============================================================================
#  ZerotzyID FeatherPanel Auto Installer  v1.0.0
#  Copyright (c) 2026 zerotzyid  -  https://github.com/zerotzyid
#
#  Script installer ini dibuat oleh zerotzyid. FeatherPanel & FeatherWings
#  adalah karya MythicalSystems (upstream); hak cipta upstream tetap milik
#  mereka dan tidak diubah oleh script ini.
# =============================================================================
set -uo pipefail

BRAND="zerotzyid"
GITHUB="https://github.com/zerotzyid"
VERSION="1.0.0"
LOG="/var/log/zerotzyid-installer.log"
PANEL_DIR="/var/www/featherpanel"
PANEL_PORT="4831"
UPSTREAM_RAW="https://raw.githubusercontent.com/MythicalLTD/FeatherPanel"
UPSTREAM_INSTALLER="https://get.featherpanel.com/installer.sh"

ROLE=""; PANEL_FQDN=""; NODE_FQDN=""; EMAIL=""; NODE_CMD=""
NO_SSL=0; AUTO=0; FORCE_WEB=0
MODE="install"; YES=0; WIPE_DOCKER=0
WIPE_CERTS=0; NO_FALLBACK=0; RL_MARK=/run/zerotzyid-ratelimit; NO_PROVISION=0; LOCATION_NAME="ZerotzyID Location"; NODE_NAME="ZerotzyID Node"
NODE_PROVISIONED=0; NODE_ID=""; LOC_ID=""; NODE_VERIFY=""
ALLOC_RANGE="25565-25600"; NO_ALLOC=0; JOIN_BLOB=""; ADD_NODE_FQDN=""
Z_UUID=""; Z_TID=""; Z_TOK=""; NODE_IP=""
TG_TOKEN="${TG_BOT_TOKEN:-}"; TG_CHAT="${TG_CHAT_ID:-}"
STEP=0; TOTAL=0; PANEL_URL=""; NODE_SSL=0; NODE_CONFIGURED=0
NGINX_FRESH=0; PUBLIC_IP=""

# ---------------------------------------------------------------- warna / UI
if [ -t 1 ]; then
	C0=$'\033[0m'; CB=$'\033[1m'; CR=$'\033[0;31m'; CG=$'\033[0;32m'
	CY=$'\033[0;33m'; CC=$'\033[0;36m'
else
	C0=""; CB=""; CR=""; CG=""; CY=""; CC=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '  %s•%s %s\n' "$CC" "$C0" "$*"; echo "[INFO] $*" >>"$LOG"; }
ok()   { printf '  %s✔%s %s\n' "$CG" "$C0" "$*"; echo "[OK] $*" >>"$LOG"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*"; echo "[WARN] $*" >>"$LOG"; }

boxline() {
	local t="$1" w=52 l r
	l=$(((w - ${#t}) / 2)); r=$((w - ${#t} - l))
	printf '  %s║%s%*s%s%*s%s║%s\n' "$CC" "$C0" "$l" "" "$t" "$r" "" "$CC" "$C0"
}
boxbar() { local s; s=$(printf '═%.0s' $(seq 1 52)); printf '  %s%s%s%s%s\n' "$CC" "$1" "$s" "$2" "$C0"; }

banner() {
	[ -t 1 ] && clear
	boxbar "╔" "╗"
	boxline "Z E R O T Z Y I D   I N S T A L L E R"
	boxline "FeatherPanel - Panel + Node Auto"
	boxbar "╠" "╣"
	boxline "v${VERSION}   github.com/zerotzyid"
	boxbar "╚" "╝"
	say "  ${CY}FeatherPanel & FeatherWings (c) MythicalSystems - upstream${C0}"
	say ""
}

tg() {
	[ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 0
	curl -fsS -m 10 --retry 1 -o /dev/null -X POST \
		"https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
		--data-urlencode "chat_id=${TG_CHAT}" \
		--data-urlencode "text=[${BRAND}] $(hostname): $*" >>"$LOG" 2>&1 || true
}

die() {
	local m="${*//\"/}"
	printf '\n  %s✘ %s%s\n' "$CR" "$m" "$C0" >&2
	echo "[FATAL] $m" >>"$LOG"
	if [ -s "$LOG" ]; then
		say "  ${CY}--- 15 baris terakhir log ($LOG) ---${C0}" >&2
		tail -n 15 "$LOG" | sed 's/^/    /' >&2
	fi
	tg "GAGAL: $m"
	echo "ZEROTZY_RESULT {\"status\":\"error\",\"message\":\"$m\"}"
	pkill -P $$ 2>/dev/null || true
	exit 1
}
trap 'die "Dibatalkan (sinyal diterima)"' INT TERM

step() {
	STEP=$((STEP + 1))
	printf '\n%s[%d/%d]%s %s%s%s\n' "$CC$CB" "$STEP" "$TOTAL" "$C0" "$CB" "$*" "$C0"
	echo "[STEP $STEP/$TOTAL] $*" >>"$LOG"
	tg "[$STEP/$TOTAL] $*"
}

# ------------------------------------------------- eksekusi anti-stuck
kill_tree() {
	local p="$1" c
	for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
	kill -TERM "$p" 2>/dev/null || true
}

retry() {
	local n="$1" i; shift
	for ((i = 1; i <= n; i++)); do
		"$@" && return 0
		sleep $((i * 3))
	done
	return 1
}

# run "label" batas_detik perintah...   (selalu ada timeout + spinner/heartbeat)
run() {
	local label="$1" limit="$2" start=$SECONDS i=0 hb=$SECONDS sp='|/-\' rc el pid
	shift 2
	echo "[RUN] $label :: $*" >>"$LOG"
	( "$@" ) >>"$LOG" 2>&1 &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		el=$((SECONDS - start))
		if [ "$el" -ge "$limit" ]; then
			[ -t 1 ] && printf '\r\033[K'
			warn "$label melewati batas ${limit}s - dihentikan"
			kill_tree "$pid"; sleep 1
			kill -KILL "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			return 124
		fi
		if [ -t 1 ]; then
			printf '\r  %s %s (%ss)\033[K' "${sp:$((i % 4)):1}" "$label" "$el"
			i=$((i + 1))
		elif [ $((SECONDS - hb)) -ge 30 ]; then
			echo "  ... $label (${el}s)"; hb=$SECONDS
		fi
		sleep 0.25
	done
	wait "$pid"; rc=$?
	[ -t 1 ] && printf '\r\033[K'
	if [ "$rc" -eq 0 ]; then ok "$label"; else warn "$label gagal (kode $rc)"; fi
	return "$rc"
}

fetch() { curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 120 -o "$2" "$1"; }

APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef
	-o Dpkg::Options::=--force-confold -o Acquire::Retries=3 -y -qq)
apt_update()  { retry 3 apt-get "${APT_OPTS[@]}" update; }
apt_install() { retry 3 apt-get "${APT_OPTS[@]}" install "$@"; }

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none

# ------------------------------------------------------------ argumen & input
usage() {
	cat <<EOF
ZerotzyID FeatherPanel Auto Installer v${VERSION}  (c) 2026 zerotzyid - ${GITHUB}

Interaktif   : sudo bash installer.sh
Mode bot     : sudo bash installer.sh --bot --role all \\
                 --panel-fqdn panel.domain.com --node-fqdn node.domain.com \\
                 --email kamu@domain.com --tg-token 123:ABC --tg-chat 123456

Opsi:
  --bot, --auto      Tanpa pertanyaan sama sekali (untuk bot/SSH otomatis)
  --role R           all (panel+node) | panel | node       (default: all)
  --panel-fqdn F     Domain panel
  --node-fqdn F      Domain node (Wings)
  --email E          Email Let's Encrypt (opsional)
  --tg-token T       Token bot Telegram untuk notifikasi (atau env TG_BOT_TOKEN)
  --tg-chat ID       Chat ID Telegram (atau env TG_CHAT_ID)
  --node-cmd "CMD"   Command 'featherwings configure ...' dari panel (opsional)
  --no-ssl           Lewati Let's Encrypt
  --force-web        Hentikan apache2 jika memakai port 80/443
  --uninstall        HAPUS TOTAL panel + node + config + SSL (bersihkan VPS)
  --reinstall        Hapus total lalu install ulang dari nol
  --add-node FQDN    (di server PANEL) buat Node baru + hasilkan kode --join untuk VPS node lain
  --join KODE        (di VPS node) pasang & hubungkan node otomatis dengan kode dari --add-node
  --alloc-range A-B  Range port allocation otomatis (default 25565-25600)
  --no-alloc         Jangan buat allocation otomatis
  --no-provision     Jangan auto-buat Location & Node di database
  --location-name N  Nama Location otomatis (default: ZerotzyID Location)
  --node-name N      Nama Node otomatis (default: ZerotzyID Node)
  --diag             Kumpulkan info diagnosa (tanpa rahasia) ke /root/zerotzyid-diag.txt
  --yes, -y          Lewati konfirmasi hapus (wajib untuk --bot)
  --no-fallback      Jangan pakai CA cadangan (ZeroSSL) saat Let's Encrypt kena rate limit
  --wipe-certs       Saat hapus: hapus juga sertifikat SSL (default: DIPERTAHANKAN)
  --wipe-docker      Saat hapus: prune semua image/volume Docker yang tak terpakai
  -h, --help         Bantuan ini

Baris terakhir selalu berisi:  ZEROTZY_RESULT {json}  (mudah di-parse bot)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--bot | --auto) AUTO=1 ;;
	--role) ROLE="${2:-}"; shift ;;
	--panel-fqdn) PANEL_FQDN="${2:-}"; shift ;;
	--node-fqdn) NODE_FQDN="${2:-}"; shift ;;
	--email) EMAIL="${2:-}"; shift ;;
	--tg-token) TG_TOKEN="${2:-}"; shift ;;
	--tg-chat) TG_CHAT="${2:-}"; shift ;;
	--node-cmd) NODE_CMD="${2:-}"; shift ;;
	--no-ssl) NO_SSL=1 ;;
	--force-web) FORCE_WEB=1 ;;
	--uninstall | --purge) MODE=uninstall ;;
	--reinstall) MODE=reinstall ;;
	--diag) MODE=diag ;;
	--no-provision) NO_PROVISION=1 ;;
	--add-node) ADD_NODE_FQDN="${2:-}"; MODE=addnode; shift ;;
	--join) JOIN_BLOB="${2:-}"; shift ;;
	--alloc-range) ALLOC_RANGE="${2:-$ALLOC_RANGE}"; shift ;;
	--no-alloc) NO_ALLOC=1 ;;
	--location-name) LOCATION_NAME="${2:-$LOCATION_NAME}"; shift ;;
	--node-name) NODE_NAME="${2:-$NODE_NAME}"; shift ;;
	--yes | -y) YES=1 ;;
	--wipe-docker) WIPE_DOCKER=1 ;;
	--wipe-certs) WIPE_CERTS=1 ;;
	--no-fallback) NO_FALLBACK=1 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "Opsi tidak dikenal: $1 (lihat --help)"; exit 1 ;;
	esac
	shift
done

has_panel() { [ "$ROLE" = all ] || [ "$ROLE" = panel ]; }
has_node()  { [ "$ROLE" = all ] || [ "$ROLE" = node ]; }
valid_fqdn() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; }

tty_ok() { { : </dev/tty; } 2>/dev/null; }

ask() { # ask "prompt" var [default]
	local __a=""
	if [ -t 0 ]; then read -r -p "$1" __a || true
	elif tty_ok; then read -r -p "$1" __a </dev/tty || true
	else die "Tidak ada terminal untuk input. Pakai --bot dengan semua flag (lihat --help)."; fi
	printf -v "$2" '%s' "${__a:-${3:-}}"
}

gather() {
	[ -n "$ROLE" ] || ROLE="all"
	if [ "$AUTO" = 0 ] && [ "$ROLE" = all ] && [ -z "$PANEL_FQDN$NODE_FQDN" ]; then
		say "  ${CB}Pilih mode instalasi:${C0}"
		say "   ${CG}[1]${C0} Panel + Node   (satu VPS, paling cepat)"
		say "   ${CG}[2]${C0} Panel saja"
		say "   ${CG}[3]${C0} Node saja      (Wings)"
		local c=""
		while [[ ! "$c" =~ ^[123]$ ]]; do ask "  Pilihan [1]: " c 1; done
		case "$c" in 1) ROLE=all ;; 2) ROLE=panel ;; 3) ROLE=node ;; esac
		say ""
	fi
	case "$ROLE" in all | panel | node) ;; *) die "Role tidak valid: $ROLE (all|panel|node)" ;; esac

	PANEL_FQDN="${PANEL_FQDN,,}"; NODE_FQDN="${NODE_FQDN,,}"
	if has_panel; then
		while ! valid_fqdn "$PANEL_FQDN"; do
			[ "$AUTO" = 1 ] && die "FQDN panel tidak valid/kosong: '$PANEL_FQDN'"
			ask "  ${CB}FQDN Panel${C0} (mis. panel.domain.com): " PANEL_FQDN
			PANEL_FQDN="${PANEL_FQDN,,}"
		done
	fi
	if has_node; then
		while ! valid_fqdn "$NODE_FQDN"; do
			[ "$AUTO" = 1 ] && die "FQDN node tidak valid/kosong: '$NODE_FQDN'"
			ask "  ${CB}FQDN Node${C0}  (mis. node1.domain.com): " NODE_FQDN
			NODE_FQDN="${NODE_FQDN,,}"
		done
	fi
	if has_panel && has_node && [ "$PANEL_FQDN" = "$NODE_FQDN" ]; then
		die "FQDN panel dan node harus berbeda."
	fi
	if [ "$AUTO" = 0 ]; then
		if [ "$ROLE" = node ] && [ -z "$JOIN_BLOB" ]; then
			ask "  Kode join dari panel (hasil --add-node, Enter = lewati): " JOIN_BLOB
		fi
		[ -n "$EMAIL" ] || ask "  Email SSL Let's Encrypt (Enter = lewati): " EMAIL
		if [ -z "$TG_TOKEN" ]; then
			ask "  Token bot Telegram untuk notifikasi (Enter = lewati): " TG_TOKEN
			[ -z "$TG_TOKEN" ] || [ -n "$TG_CHAT" ] || ask "  Chat ID Telegram: " TG_CHAT
		fi
	fi
	if [ -n "$EMAIL" ] && [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[a-zA-Z]{2,}$ ]]; then
		warn "Email tidak valid, diabaikan."; EMAIL=""
	fi
}

# ----------------------------------------------------------------- langkah
check_dns() { # 0 ok | 1 belum ada | 2 beda IP
	local f="$1" ip
	ip=$(getent ahostsv4 "$f" 2>/dev/null | awk 'NR==1{print $1}')
	if [ -z "$ip" ]; then
		warn "DNS $f belum ada. Buat A record -> ${PUBLIC_IP:-IP server}"
		return 1
	elif [ -n "$PUBLIC_IP" ] && [ "$ip" != "$PUBLIC_IP" ]; then
		warn "DNS $f -> $ip (IP server: $PUBLIC_IP). Abaikan jika memakai proxy Cloudflare."
		return 2
	fi
	ok "DNS $f -> $ip"
}

preflight() {
	[ -r /etc/os-release ] || die "OS tidak dikenali."
	# shellcheck disable=SC1091
	. /etc/os-release
	case "${ID:-}" in debian | ubuntu) ;; *) die "Hanya mendukung Debian/Ubuntu (terdeteksi: ${ID:-?})." ;; esac
	ok "OS: ${PRETTY_NAME:-$ID}"

	exec 9>/run/zerotzyid-installer.lock
	flock -n 9 || die "Installer lain masih berjalan."

	curl -fsS -m 15 -o /dev/null https://raw.githubusercontent.com || die "Tidak bisa menjangkau GitHub (cek internet/DNS server)."
	ok "Koneksi internet OK"

	PUBLIC_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null ||
		curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)
	[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || PUBLIC_IP=""
	[ -z "$PUBLIC_IP" ] || ok "IP publik: $PUBLIC_IP"

	local free_gb; free_gb=$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')
	[ "${free_gb:-10}" -ge 5 ] || warn "Disk kosong hanya ${free_gb}GB (disarankan >= 10GB)"

	local ports="80"; has_panel && ports="80 443"
	local p o
	for p in $ports; do
		o=$(ss -ltnpH "( sport = :$p )" 2>/dev/null | head -n1 || true)
		if [ -n "$o" ] && ! grep -q nginx <<<"$o"; then
			if [ "$FORCE_WEB" = 1 ] && grep -q apache2 <<<"$o"; then
				warn "Menghentikan apache2 (port $p dipakai)"
				systemctl disable --now apache2 >>"$LOG" 2>&1 || true
			else
				die "Port $p sedang dipakai: $o  -> hentikan layanan itu atau jalankan ulang dengan --force-web (khusus apache2)."
			fi
		fi
	done
	command -v nginx >/dev/null 2>&1 || NGINX_FRESH=1
	run "Memperbaiki status dpkg" 120 dpkg --configure -a || true
}

install_base() {
	local pk=(curl ca-certificates gnupg lsb-release jq openssl procps iproute2 certbot)
	has_panel && pk+=(nginx python3-certbot-nginx)
	apt_update && apt_install "${pk[@]}"
}

install_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		fetch https://get.docker.com /tmp/get-docker.sh || return 1
		sh /tmp/get-docker.sh || return 1
	fi
	systemctl enable --now docker || true
	local t
	for t in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
	docker info >/dev/null 2>&1 || return 1
	docker compose version >/dev/null 2>&1 || apt_install docker-compose-plugin
	docker compose version >/dev/null 2>&1
}

DC=(docker compose --project-directory "$PANEL_DIR" -f "$PANEL_DIR/docker-compose.yml")

deploy_panel() {
	mkdir -p "$PANEL_DIR" && cd "$PANEL_DIR" || return 1
	local br got=0
	for br in main develop; do
		if fetch "$UPSTREAM_RAW/refs/heads/$br/docker-compose.yml" docker-compose.yml.new &&
			grep -qi featherpanel docker-compose.yml.new; then
			mv -f docker-compose.yml.new docker-compose.yml; got=1; break
		fi
	done
	[ "$got" = 1 ] || return 1
	# panel hanya didengarkan di localhost; akses publik lewat Nginx
	sed -i 's|"${FEATHERPANEL_PANEL_PORT:-4831}:80"|"127.0.0.1:${FEATHERPANEL_PANEL_PORT:-4831}:80"|' docker-compose.yml
	touch .env; chmod 600 .env
	grep -q '^DOCKER_UPDATER_TOKEN=' .env ||
		printf 'DOCKER_UPDATER_TOKEN="%s"\n' "$(openssl rand -hex 32)" >>.env
	echo docker >.install_mode
	"${DC[@]}" config -q
}

start_panel() { retry 3 "${DC[@]}" up -d --pull always --remove-orphans; }

wait_http() { # url detik
	local t=0 code
	while [ "$t" -lt "$2" ]; do
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true)
		[[ "$code" =~ ^[234] ]] && return 0
		sleep 3; t=$((t + 3))
	done
	return 1
}

# Jika nginx -t gagal karena file config LAIN yang rusak (sisa instalasi lama),
# file itu dipindah ke folder backup (bukan dihapus), lalu dites ulang.
nginx_heal() {
	local i out bad bk
	bk="/root/zerotzyid-nginx-backup-$(date +%Y%m%d-%H%M%S)"
	for i in 1 2 3 4 5 6; do
		out=$(nginx -t 2>&1) && return 0
		echo "$out"
		bad=$(grep -oE 'in /etc/nginx/(sites-enabled|conf\.d)/[^: ]+:[0-9]+' <<<"$out" | head -n1 | sed -E 's/^in //; s/:[0-9]+$//')
		{ [ -n "$bad" ] && [ -e "$bad" ] && [ "${bad##*/}" != "zerotzyid-panel" ]; } || return 1
		mkdir -p "$bk" && mv "$bad" "$bk/" || return 1
		echo "Config rusak dipindah: $bad -> $bk/"
	done
	return 1
}

setup_nginx() {
	local f=/etc/nginx/sites-available/zerotzyid-panel
	mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
	cat >/etc/nginx/conf.d/zerotzyid-ws-map.conf <<'EOF'
map $http_upgrade $zerotzy_conn_upgrade {
    default upgrade;
    ''      close;
}
EOF
	cat >"$f" <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name __FQDN__;
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $zerotzy_conn_upgrade;
        proxy_buffer_size 16k;
        proxy_buffers 8 16k;
        proxy_busy_buffers_size 32k;
        proxy_connect_timeout 15s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
	sed -i "s/__FQDN__/$PANEL_FQDN/g; s/__PORT__/$PANEL_PORT/g" "$f"
	ln -sf "$f" /etc/nginx/sites-enabled/zerotzyid-panel
	[ "$NGINX_FRESH" = 1 ] && rm -f /etc/nginx/sites-enabled/default
	nginx_heal || return 1
	systemctl enable nginx
	systemctl restart nginx
}

certbot_email_args() {
	if [ -n "$EMAIL" ]; then printf '%s\n' -m "$EMAIL"; else printf '%s\n' --register-unsafely-without-email; fi
}

cert_dir() {
	if [ -s "/etc/letsencrypt/live/$1/fullchain.pem" ]; then echo "/etc/letsencrypt/live/$1"; else echo "/etc/zerotzyid/certs/$1"; fi
}
cert_valid() { # ada & masih valid > 14 hari
	local d; d=$(cert_dir "$1")
	[ -s "$d/fullchain.pem" ] && openssl x509 -checkend 1209600 -noout -in "$d/fullchain.pem" >/dev/null 2>&1
}

cert_hint() { # output certbot -> petunjuk singkat
	local o="$1"
	case "$o" in
	*"too many certificates"* | *"rateLimited"* | *"too many failed"* | *"too many new orders"* | *"too many requests"*)
		touch "$RL_MARK"
		echo "[CERT] KENA RATE LIMIT Let's Encrypt (batas per domain induk). $(grep -oiE 'retry after [^:]*:[^:]*:[0-9]+ UTC' <<<"$o" | head -n1)" ;;
	*"Timeout during connect"* | *"Connection refused"* | *"Could not connect"* | *"Connection reset"*)
		echo "[CERT] Port 80 tidak terjangkau dari internet. Buka port 80/443 di firewall/security group penyedia VPS." ;;
	*"NXDOMAIN"* | *"no valid A records"* | *"DNS problem"*)
		echo "[CERT] DNS belum tersebar / A record belum benar. Tunggu beberapa menit lalu coba lagi." ;;
	*"Invalid response"* | *"unauthorized"* | *"404"*)
		echo "[CERT] Validasi HTTP ditolak: domain mungkin lewat proxy (Cloudflare), atau web server lain menjawab di port 80." ;;
	*) echo "[CERT] $(grep -iE 'error|problem|detail|failed' <<<"$o" | head -n 3 | tr '\n' ' ')$(tail -n 2 <<<"$o" | tr '\n' ' ')" ;;
	esac
}

# Nginx HTTPS manual (dipakai untuk sertifikat cadangan / pemakaian ulang sertifikat)
setup_nginx_tls() { # direktori sertifikat
	local d="$1" f=/etc/nginx/sites-available/zerotzyid-panel
	[ -s "$d/fullchain.pem" ] && [ -s "$d/privkey.pem" ] || return 1
	cat >"$f" <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name __FQDN__;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name __FQDN__;
    ssl_certificate __CERT__/fullchain.pem;
    ssl_certificate_key __CERT__/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $zerotzy_conn_upgrade;
        proxy_buffer_size 16k;
        proxy_buffers 8 16k;
        proxy_busy_buffers_size 32k;
        proxy_connect_timeout 15s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
	sed -i "s|__CERT__|$d|g; s/__FQDN__/$PANEL_FQDN/g; s/__PORT__/$PANEL_PORT/g" "$f"
	nginx_heal || return 1
	systemctl reload nginx
}

# CA cadangan (ZeroSSL via acme.sh) jika Let's Encrypt kena rate limit
acme_fallback() { # fqdn
	local fq="$1" em="${EMAIL:-admin@$1}" d="/etc/zerotzyid/certs/$1" acme rc
	export HOME=/root; acme=/root/.acme.sh/acme.sh
	apt_install socat || true
	if [ ! -x "$acme" ]; then
		fetch https://get.acme.sh /tmp/get-acme.sh || return 1
		sh /tmp/get-acme.sh email="$em" || return 1
	fi
	"$acme" --register-account -m "$em" --server zerossl || true
	"$acme" --issue --standalone -d "$fq" --server zerossl --httpport 80 \
		--pre-hook "systemctl stop nginx 2>/dev/null || true" \
		--post-hook "systemctl start nginx 2>/dev/null || true"
	rc=$?
	[ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || { echo "[CERT] CA cadangan (ZeroSSL) juga gagal (kode $rc)"; return 1; }
	mkdir -p "$d"
	"$acme" --install-cert -d "$fq" --fullchain-file "$d/fullchain.pem" --key-file "$d/privkey.pem" \
		--reloadcmd "systemctl reload nginx 2>/dev/null || true; systemctl restart featherwings 2>/dev/null || true"
	echo "[CERT] sertifikat cadangan terpasang di $d"
}

issue_panel_cert() {
	local ea=() out rc
	rm -f "$RL_MARK"
	mapfile -t ea < <(certbot_email_args)
	if cert_valid "$PANEL_FQDN"; then
		echo "[CERT] sertifikat panel yang sudah ada dipakai ulang (tidak menerbitkan baru)"
		setup_nginx_tls "$(cert_dir "$PANEL_FQDN")" && return 0
	fi
	out=$(certbot --nginx -d "$PANEL_FQDN" --non-interactive --agree-tos --redirect "${ea[@]}" 2>&1); rc=$?
	printf '%s\n' "$out"
	[ "$rc" -eq 0 ] || cert_hint "$out"
	return "$rc"
}

issue_node_cert() {
	local ea=() out rc
	rm -f "$RL_MARK"
	mapfile -t ea < <(certbot_email_args)
	if cert_valid "$NODE_FQDN"; then
		echo "[CERT] sertifikat node yang sudah ada dipakai ulang (tidak menerbitkan baru)"
		return 0
	fi
	out=$(certbot certonly --standalone -d "$NODE_FQDN" --non-interactive --agree-tos "${ea[@]}" \
		--pre-hook "systemctl stop nginx 2>/dev/null || true" \
		--post-hook "systemctl start nginx 2>/dev/null || true" 2>&1); rc=$?
	printf '%s\n' "$out"
	[ "$rc" -eq 0 ] || cert_hint "$out"
	return "$rc"
}

install_wings() {
	fetch "$UPSTREAM_INSTALLER" /tmp/fp-upstream-installer.sh || return 1
	# setsid -w + stdin /dev/null: installer upstream tidak bisa menunggu input (anti-stuck)
	FP_WINGS_METHOD=apt FP_WINGS_CHANNEL=stable FP_SYSTEM_UPGRADE=no \
		setsid -w bash /tmp/fp-upstream-installer.sh --wings-install-only --skip-system-update </dev/null
	command -v featherwings >/dev/null 2>&1
}

configure_node() {
	local cmd=(); read -r -a cmd <<<"$NODE_CMD"
	[ "${cmd[0]:-}" = featherwings ] && [ "${cmd[1]:-}" = configure ] || return 1
	[[ "$NODE_CMD" =~ ^featherwings\ configure(\ --?[a-zA-Z-]+(\ [A-Za-z0-9:/._=+@-]+)?)*$ ]] || return 1
	"${cmd[@]}" && systemctl enable --now featherwings
}

open_firewall() {
	command -v ufw >/dev/null 2>&1 || return 0
	ufw status 2>/dev/null | grep -q "Status: active" || return 0
	has_panel && { ufw allow 80/tcp; ufw allow 443/tcp; }
	has_node && { ufw allow 80/tcp; ufw allow 8080/tcp; ufw allow 2022/tcp; }
	return 0
}


# ------------------------------------- auto Location + Node lewat database
STATE=/run/zerotzyid-prov.env
T_NODE=featherpanel_nodes; T_LOC=featherpanel_locations; T_ALLOC=featherpanel_allocations
DB_CT=""; DB_NAME=""; BE_CT=""; BE_ROOT=""; WV=""
declare -A VAL=()
declare -A COLCACHE=()
want_provision() { [ "$ROLE" = all ] && [ -z "$NODE_CMD" ] && [ "$NO_PROVISION" != 1 ]; }

mysql_x() { docker exec -i "$DB_CT" sh -c 'exec mysql -uroot -p"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" -N -B "$@"' sh "$@"; }
sqlq() { local s="$1"; s=${s//\'/}; s=${s//\"/}; s=${s//\\/}; printf "'%s'" "$s"; }
lit2json() {
	local v="$1"
	case "$v" in
	"NOW()") printf '"%s"' "$(date '+%F %T')" ;;
	"CURDATE()") printf '"%s"' "$(date +%F)" ;;
	"'"*"'") v="${v#\'}"; v="${v%\'}"; printf '"%s"' "$v" ;;
	-[0-9]* | [0-9]*) printf '%s' "$v" ;;
	*) printf '"%s"' "$v" ;;
	esac
}

# Cari container DB yang BENAR-BENAR berisi tabel node panel (bukan DB sisa proyek lain).
find_db() {
	local c r
	for c in $(docker ps --format '{{.Names}}'); do
		docker exec "$c" sh -c 'test -n "${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"' 2>/dev/null || continue
		DB_CT="$c"
		r=$(echo "SELECT table_schema,table_name FROM information_schema.columns WHERE column_name='daemon_token_id' AND table_name LIKE '%\_nodes' AND table_name NOT LIKE '%web%' AND table_name NOT LIKE '%vm%' ORDER BY (table_name='featherpanel_nodes') DESC, LENGTH(table_name) LIMIT 1;" | mysql_x 2>/dev/null | head -n1)
		if [ -n "$r" ]; then
			DB_NAME=${r%%$'\t'*}; T_NODE=${r#*$'\t'}
			T_LOC="${T_NODE%nodes}locations"; T_ALLOC="${T_NODE%nodes}allocations"
			return 0
		fi
	done
	DB_CT=""; return 1
}

# Cari container backend dengan memeriksa file `cli` + vendor (tidak bergantung pada nama container).
find_backend() {
	local c r
	for c in $(docker ps --format '{{.Names}}'); do
		r=$(docker exec "$c" sh -c 'for d in /var/www/html /var/www/html/backend /app /var/www/backend; do [ -f "$d/cli" ] && [ -f "$d/vendor/autoload.php" ] && echo "$d" && break; done' 2>/dev/null)
		if [ -n "$r" ]; then BE_CT="$c"; BE_ROOT="$r"; return 0; fi
	done
	BE_CT=""; BE_ROOT=""; return 1
}

# kolom tabel: nama<TAB>tipe<TAB>nullable<TAB>default(<<NULL>> = tanpa default)<TAB>extra
db_load_columns() {
	[ -n "${COLCACHE[$1]+x}" ] && return 0
	COLCACHE[$1]=$(echo "SELECT column_name,data_type,is_nullable,IF(column_default IS NULL,'<<NULL>>',CONCAT('=',column_default)),extra FROM information_schema.columns WHERE table_schema=$(sqlq "$DB_NAME") AND table_name=$(sqlq "$1") ORDER BY ordinal_position;" | mysql_x)
}
db_columns() { printf '%s\n' "${COLCACHE[$1]-}"; }

# Bangun baris dari kolom ASLI tabel; nilai dari VAL[kolom], kolom wajib lain diisi default aman.
build_row() { # tabel sql|json
	local t="$1" mode="$2" cols="" vals="" js="" c dt nul def extra v
	db_load_columns "$t"
	while IFS=$'\t' read -r c dt nul def extra; do
		[ -n "$c" ] || continue
		[[ "$extra" == *auto_increment* ]] && continue
		if [ -n "${VAL[$c]+x}" ]; then
			v="${VAL[$c]}"
		elif [ "$nul" = YES ] || [ "$def" != "<<NULL>>" ]; then
			continue
		else
			case "$dt" in
			int | bigint | smallint | tinyint | mediumint | decimal | float | double) v=0 ;;
			datetime | timestamp) v="NOW()" ;;
			date) v="CURDATE()" ;;
			json) v="'{}'" ;;
			*) v="''" ;;
			esac
		fi
		if [ "$mode" = json ]; then js+="\"$c\":$(lit2json "$v"),"; else cols+="\`$c\`,"; vals+="$v,"; fi
	done < <(db_columns "$t")
	if [ "$mode" = json ]; then
		[ -n "$js" ] || return 1
		printf '{%s}' "${js%,}"
	else
		[ -n "$cols" ] || return 1
		printf 'INSERT INTO `%s` (%s) VALUES (%s);' "$t" "${cols%,}" "${vals%,}"
	fi
}
build_insert() { build_row "$1" sql; }

# Buat/ubah Node lewat KODE PANEL SENDIRI (model PHP) supaya token terenkripsi dengan benar.
php_node() { # json
	local err rc
	docker exec -i "$BE_CT" sh -c 'umask 077; cat > /tmp/zt-node.json' <<<"$1" || return 1
	docker exec -i "$BE_CT" sh -c 'umask 077; cat > /tmp/zt-run.php' <<'PHPEOF' || return 1
<?php
$root = $argv[1] ?? '/var/www/html';
chdir($root);
foreach (getenv() as $k => $v) { $_ENV[$k] = $v; $_SERVER[$k] = $v; }
if (is_readable("$root/.env")) {
    foreach (file("$root/.env", FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $l) {
        if ($l[0] === '#' || strpos($l, '=') === false) { continue; }
        [$k, $v] = explode('=', $l, 2);
        $k = trim($k); $v = trim($v, " \t\"'");
        if (!isset($_ENV[$k])) { $_ENV[$k] = $v; putenv("$k=$v"); }
    }
}
require "$root/vendor/autoload.php";
$data = json_decode((string) @file_get_contents('/tmp/zt-node.json'), true);
@unlink('/tmp/zt-node.json');
if (!is_array($data)) { fwrite(STDERR, "json tidak valid\n"); exit(4); }
$mode = $data['__mode'] ?? 'create'; $nid = $data['__id'] ?? null;
unset($data['__mode'], $data['__id']);
try {
    $cls = '\\App\\Chat\\Node';
    if (!class_exists($cls)) { fwrite(STDERR, "class $cls tidak ada\n"); exit(3); }
    $r = ($mode === 'update') ? $cls::update((int) $nid, $data) : $cls::create($data);
    echo json_encode(['ok' => true, 'result' => $r]), "\n";
} catch (Throwable $e) {
    fwrite(STDERR, get_class($e) . ': ' . $e->getMessage() . "\n"); exit(2);
}
PHPEOF
	err=$(docker exec "$BE_CT" php /tmp/zt-run.php "$BE_ROOT" 2>&1 >/dev/null); rc=$?
	docker exec "$BE_CT" rm -f /tmp/zt-node.json /tmp/zt-run.php >/dev/null 2>&1
	[ "$rc" -eq 0 ] || echo "[PROV] php-model gagal (kode $rc): ${err:0:220}"
	return "$rc"
}

write_wings_config() { # uuid token_id token scheme
	local cfg=/etc/featherpanel/config.yml ssl=false
	mkdir -p /etc/featherpanel /var/lib/featherpanel/volumes
	[ -f "$cfg" ] && cp -n "$cfg" "$cfg.zerotzyid.bak"
	[ "$4" = https ] && ssl=true
	cat >"$cfg" <<EOF
debug: false
uuid: $1
token_id: $2
token: $3
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: $ssl
    cert: $(cert_dir "$NODE_FQDN")/fullchain.pem
    key: $(cert_dir "$NODE_FQDN")/privkey.pem
  upload_limit: 1024
system:
  data: /var/lib/featherpanel/volumes
  sftp:
    bind_port: 2022
allowed_mounts: []
remote: '$PANEL_URL'
EOF
	chmod 600 "$cfg"
}

wings_start_verify() { # scheme
	local act errs code
	systemctl daemon-reload; systemctl enable featherwings 2>/dev/null; systemctl restart featherwings
	sleep 12
	act=$(systemctl is-active featherwings 2>&1)
	errs=$(journalctl -u featherwings --since "-2min" --no-pager 2>/dev/null | grep -ciE 'unauthor|401|403|decrypt|invalid token|fatal|panic')
	code=$(curl -sk -m 6 -o /dev/null -w '%{http_code}' "$1://127.0.0.1:8080/" 2>/dev/null || true)
	echo "[PROV] wings=$act error_log=$errs http_lokal=$code"
	if [ "$act" = active ] && [ "${errs:-1}" = 0 ] && [ "$code" != 000 ]; then WV=ok; else WV=check; fi
}

db_prepare() {
	local i bk c
	for i in $(seq 1 60); do
		find_db && break
		sleep 5
	done
	if [ -z "$DB_CT" ]; then
		echo "[PROV] tabel node panel tidak ditemukan di container DB mana pun (menunggu 5 menit)"
		for c in $(docker ps --format '{{.Names}}'); do
			echo "[PROV] kontainer: $c | var-env DB: $(docker exec "$c" env 2>/dev/null | grep -iE 'mysql|mariadb|database|db_' | cut -d= -f1 | tr '\n' ' ')"
		done
		return 1
	fi
	find_backend || echo "[PROV] container backend (php cli) tidak ditemukan - pakai jalur SQL langsung"
	echo "[PROV] database=$DB_NAME tabel=$T_NODE db=$DB_CT backend=${BE_CT:-none}"
	bk="/root/zerotzyid-db-backup-$(date +%Y%m%d-%H%M%S).sql"
	docker exec "$DB_CT" sh -c 'exec $(command -v mysqldump || command -v mariadb-dump) -uroot -p"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" "$@"' sh "$DB_NAME" "$T_LOC" "$T_NODE" >"$bk" 2>/dev/null &&
		{ chmod 600 "$bk"; echo "[PROV] backup tabel: $bk"; } || echo "[PROV] backup dilewati"
}

# Hasil: LOC_ID NODE_ID Z_UUID Z_TID Z_TOK
db_create_node() { # fqdn scheme ip
	local fq="$1" scheme="$2" ip="$3" t_loc="$T_LOC" t_node="$T_NODE" t_alloc="$T_ALLOC"
	local sql slug stored a b p cnt json via=""
	slug=$(tr '[:upper:] ' '[:lower:]-' <<<"$LOCATION_NAME" | tr -cd 'a-z0-9-')
	LOC_ID=$(echo "SELECT id FROM \`$t_loc\` WHERE name=$(sqlq "$LOCATION_NAME") LIMIT 1;" | mysql_x "$DB_NAME" 2>/dev/null | head -n1)
	if [ -z "$LOC_ID" ]; then
		VAL=([name]="$(sqlq "$LOCATION_NAME")" [short]="$(sqlq "$slug")" [long]="$(sqlq "$LOCATION_NAME")"
			[description]="$(sqlq "Dibuat otomatis oleh zerotzyid installer")" [created_at]="NOW()" [updated_at]="NOW()")
		sql=$(build_insert "$t_loc") || { echo "[PROV] gagal membangun INSERT location"; return 1; }
		LOC_ID=$(printf 'START TRANSACTION; %s SELECT LAST_INSERT_ID(); COMMIT;' "$sql" | mysql_x "$DB_NAME") || { echo "[PROV] INSERT location ditolak DB"; return 1; }
	fi
	[[ "$LOC_ID" =~ ^[0-9]+$ ]] || { echo "[PROV] id location tidak valid: '$LOC_ID'"; return 1; }
	echo "[PROV] location id=$LOC_ID"

	Z_TID=$(openssl rand -hex 8); Z_TOK=$(openssl rand -hex 32)
	NODE_ID=$(echo "SELECT id FROM \`$t_node\` WHERE fqdn=$(sqlq "$fq") LIMIT 1;" | mysql_x "$DB_NAME" 2>/dev/null | head -n1)
	if [ -n "$NODE_ID" ]; then
		Z_UUID=$(echo "SELECT uuid FROM \`$t_node\` WHERE id=$NODE_ID;" | mysql_x "$DB_NAME" 2>/dev/null | head -n1)
		[ -n "$Z_UUID" ] || Z_UUID=$(cat /proc/sys/kernel/random/uuid)
		if [ -n "$BE_CT" ] && php_node "{\"__mode\":\"update\",\"__id\":$NODE_ID,\"daemon_token_id\":\"$Z_TID\",\"daemon_token\":\"$Z_TOK\"}"; then
			via=php-update
		else
			echo "UPDATE \`$t_node\` SET daemon_token_id=$(sqlq "$Z_TID"), daemon_token=$(sqlq "$Z_TOK") WHERE id=$NODE_ID;" | mysql_x "$DB_NAME" || { echo "[PROV] update token node gagal"; return 1; }
			via=sql-update
		fi
		echo "[PROV] node sudah ada (id=$NODE_ID), token diperbarui via $via"
	else
		Z_UUID=$(cat /proc/sys/kernel/random/uuid)
		VAL=([name]="$(sqlq "$NODE_NAME")" [description]="$(sqlq "Dibuat otomatis oleh zerotzyid installer")"
			[uuid]="$(sqlq "$Z_UUID")" [public]=1 [fqdn]="$(sqlq "$fq")" [scheme]="$(sqlq "$scheme")"
			[behind_proxy]=0 [maintenance_mode]=0 [location_id]="$LOC_ID"
			[memory]=99999999 [memory_overallocate]=-1 [disk]=99999999 [disk_overallocate]=-1
			[upload_size]=1024 [daemon_token_id]="$(sqlq "$Z_TID")" [daemon_token]="$(sqlq "$Z_TOK")"
			[daemon_base]="$(sqlq /var/lib/featherpanel/volumes)" [daemon_listen]=8080 [daemon_sftp]=2022
			[created_at]="NOW()" [updated_at]="NOW()")
		if [ -n "$BE_CT" ]; then
			json=$(build_row "$t_node" json) && php_node "$json" &&
				NODE_ID=$(echo "SELECT id FROM \`$t_node\` WHERE fqdn=$(sqlq "$fq") LIMIT 1;" | mysql_x "$DB_NAME" 2>/dev/null | head -n1)
			[ -n "$NODE_ID" ] && via=php-model
		fi
		if [ -z "$NODE_ID" ]; then
			echo "[PROV] memakai jalur SQL langsung (token disimpan apa adanya)"
			sql=$(build_insert "$t_node") || { echo "[PROV] gagal membangun INSERT node"; return 1; }
			NODE_ID=$(printf 'START TRANSACTION; %s SELECT LAST_INSERT_ID(); COMMIT;' "$sql" | mysql_x "$DB_NAME") || { echo "[PROV] INSERT node ditolak DB"; return 1; }
			via=sql
		fi
		[[ "$NODE_ID" =~ ^[0-9]+$ ]] || { echo "[PROV] id node tidak valid: '$NODE_ID'"; return 1; }
		echo "[PROV] node dibuat id=$NODE_ID via $via (memory/disk 99999999 MB, overallocate -1)"
	fi
	stored=$(echo "SELECT daemon_token FROM \`$t_node\` WHERE id=$NODE_ID;" | mysql_x "$DB_NAME" 2>/dev/null | head -n1)
	if [ "$stored" = "$Z_TOK" ]; then echo "[PROV] token tersimpan plaintext"; else echo "[PROV] token tersimpan terenkripsi oleh panel"; fi

	if [ "$NO_ALLOC" != 1 ] && [ -n "$ip" ] && [[ "$ALLOC_RANGE" =~ ^[0-9]+-[0-9]+$ ]]; then
		a=${ALLOC_RANGE%-*}; b=${ALLOC_RANGE#*-}
		cnt=$(echo "SELECT COUNT(*) FROM \`$t_alloc\` WHERE node_id=$NODE_ID;" | mysql_x "$DB_NAME" 2>/dev/null | head -n1)
		if [ "${cnt:-1}" = 0 ] && [ "$a" -le "$b" ] && [ $((b - a)) -le 500 ]; then
			db_load_columns "$t_alloc"
			sql="START TRANSACTION;"
			for ((p = a; p <= b; p++)); do
				VAL=([node_id]="$NODE_ID" [ip]="$(sqlq "$ip")" [port]="$p" [created_at]="NOW()" [updated_at]="NOW()")
				sql+=$(build_insert "$t_alloc") || { echo "[PROV] allocation dilewati (skema tak dikenal)"; sql=""; break; }
			done
			if [ -n "$sql" ] && printf '%s COMMIT;' "$sql" | mysql_x "$DB_NAME"; then
				echo "[PROV] allocation $ip:$a-$b dibuat"
			else
				echo "[PROV] allocation gagal dibuat (tambahkan manual di panel)"
			fi
		fi
	fi
	return 0
}

provision_node() { # role all: buat di DB + konfigurasi Wings lokal
	local scheme=http
	[ "$NODE_SSL" = 1 ] && scheme=https
	db_prepare || return 1
	db_create_node "$NODE_FQDN" "$scheme" "$PUBLIC_IP" || return 1
	write_wings_config "$Z_UUID" "$Z_TID" "$Z_TOK" "$scheme"
	wings_start_verify "$scheme"
	printf 'NODE_PROVISIONED=1\nNODE_ID=%s\nLOC_ID=%s\nNODE_VERIFY=%s\n' "$NODE_ID" "$LOC_ID" "$WV" >"$STATE"
}

derive_panel_url() {
	local f fq=""
	for f in /etc/nginx/sites-available/zerotzyid-panel /etc/nginx/sites-available/featherpanel; do
		[ -f "$f" ] || continue
		fq=$(grep -m1 -oP 'server_name\s+\K[^; ]+' "$f" 2>/dev/null || true)
		[ -n "$fq" ] && break
	done
	[ -n "$fq" ] || return 1
	if [ -d "/etc/letsencrypt/live/$fq" ]; then echo "https://$fq"; else echo "http://$fq"; fi
}

addnode_main() { # di server PANEL: buat node untuk VPS lain
	local scheme=https ip
	[ "$NO_SSL" = 1 ] && scheme=http
	ip=$(getent ahostsv4 "$NODE_FQDN" 2>/dev/null | awk 'NR==1{print $1}')
	db_prepare || return 1
	db_create_node "$NODE_FQDN" "$scheme" "$ip" || return 1
	umask 077
	printf 'NODE_ID=%s\nLOC_ID=%s\nZ_UUID=%s\nZ_TID=%s\nZ_TOK=%s\nZSCHEME=%s\n' "$NODE_ID" "$LOC_ID" "$Z_UUID" "$Z_TID" "$Z_TOK" "$scheme" >"$STATE"
}

join_node() { # di VPS node: pakai kode dari --add-node
	local dec uuid tid tok purl scheme sch=http
	dec=$(printf '%s' "$JOIN_BLOB" | base64 -d 2>/dev/null) || { echo "[PROV] kode join tidak valid"; return 1; }
	IFS='|' read -r uuid tid tok purl scheme <<<"$dec"
	{ [[ "$uuid" =~ ^[0-9a-f-]{36}$ ]] && [[ "$tid" =~ ^[0-9a-f]{16}$ ]] && [[ "$tok" =~ ^[0-9a-f]{64}$ ]] &&
		[[ "$purl" =~ ^https?://[a-z0-9.-]+$ ]]; } || { echo "[PROV] isi kode join tidak valid"; return 1; }
	PANEL_URL="$purl"
	[ "$NODE_SSL" = 1 ] && sch=https
	[ "$sch" = "$scheme" ] || echo "[PROV] peringatan: scheme di panel=$scheme, node=$sch (samakan di Admin > Nodes)"
	write_wings_config "$uuid" "$tid" "$tok" "$sch"
	wings_start_verify "$sch"
	printf 'NODE_PROVISIONED=1\nNODE_VERIFY=%s\n' "$WV" >"$STATE"
}

# --------------------------------------------------------------- diagnosa
diag() {
	local out=/root/zerotzyid-diag.txt be db
	be=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i backend | head -n1 || true)
	db=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'mysql|mariadb|_db' | head -n1 || true)
	{
		echo "== zerotzyid diag v$VERSION $(date '+%F %T')"
		echo "== OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
		echo "== containers"; docker ps -a --format '{{.Names}}  {{.Status}}' 2>&1
		echo "== nginx -t"; nginx -t 2>&1
		echo "== sites-enabled"; ls -la /etc/nginx/sites-enabled 2>&1
		echo "== .env (nama variabel saja)"; grep -oE '^[A-Za-z_]+=' "$PANEL_DIR/.env" 2>&1
		echo "== featherwings"; command -v featherwings; systemctl is-active featherwings 2>&1
		journalctl -u featherwings -n 25 --no-pager 2>&1 | sed -E 's/(token[^ ]*[ =:]+)[^ ]+/\1[redacted]/Ig'
		ls -la /etc/featherpanel 2>&1
		echo "== backend: $be | db: $db"
		if [ -n "$be" ]; then
			echo "== php cli help"; docker exec "$be" sh -c 'php cli help 2>&1 || php cli list 2>&1' | head -n 60
			echo "== routes nodes.php"
			docker exec "$be" sh -c 'f=$(find / -path "*routes/admin/nodes.php" 2>/dev/null | head -n1); echo "$f"; [ -n "$f" ] && head -n 80 "$f"' 2>&1
			echo "== backend log (200 baris terakhir, error saja)"
			docker logs --tail 200 "$be" 2>&1 | grep -iE 'error|exception|fatal' | tail -n 15 | sed -E 's/(token|password|secret)[^ ,"]*[ =:"]+[^ ,"]+/\1=[redacted]/Ig'
		fi
		if [ -n "$db" ]; then
			echo "== skema tabel nodes & locations (tanpa data)"
			docker exec "$db" sh -c 'mysql -uroot -p"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" -e "SELECT table_name,column_name,column_type,is_nullable,column_default FROM information_schema.columns WHERE table_name IN (\"featherpanel_nodes\",\"featherpanel_locations\") ORDER BY table_name,ordinal_position" 2>&1' | head -n 80
		fi
	} >"$out" 2>&1
	chmod 600 "$out"
}

# ------------------------------------------------------------ hapus total
purge_panel_docker() {
	if command -v docker >/dev/null 2>&1; then
		if [ -f "$PANEL_DIR/docker-compose.yml" ]; then
			"${DC[@]}" down -v --remove-orphans --timeout 30 || true
		fi
		local ids
		ids=$(docker ps -aq --filter name=featherpanel 2>/dev/null || true)
		# shellcheck disable=SC2086
		[ -z "$ids" ] || docker rm -f $ids
		ids=$(docker volume ls -q --filter name=featherpanel 2>/dev/null || true)
		# shellcheck disable=SC2086
		[ -z "$ids" ] || docker volume rm -f $ids
		ids=$(docker network ls -q --filter name=featherpanel 2>/dev/null || true)
		# shellcheck disable=SC2086
		[ -z "$ids" ] || docker network rm $ids
		ids=$(docker images -q --filter 'reference=*featherpanel*' 2>/dev/null || true)
		# shellcheck disable=SC2086
		[ -z "$ids" ] || docker rmi -f $ids
	fi
	rm -rf "$PANEL_DIR"
	return 0
}

purge_web() {
	local doms="$PANEL_FQDN $NODE_FQDN" f d
	for f in /etc/nginx/sites-available/zerotzyid-panel /etc/nginx/sites-available/featherpanel; do
		[ -f "$f" ] && doms="$doms $(grep -hoP 'server_name\s+\K[^; ]+' "$f" 2>/dev/null | tr '\n' ' ')"
	done
	rm -f /etc/nginx/sites-enabled/zerotzyid-panel /etc/nginx/sites-available/zerotzyid-panel \
		/etc/nginx/sites-enabled/featherpanel /etc/nginx/sites-available/featherpanel \
		/etc/nginx/sites-enabled/featherpanel.conf /etc/nginx/conf.d/zerotzyid-ws-map.conf
	if [ -f /etc/apache2/sites-available/featherpanel.conf ]; then
		a2dissite featherpanel >/dev/null 2>&1 || true
		rm -f /etc/apache2/sites-available/featherpanel.conf /etc/apache2/sites-enabled/featherpanel.conf
		systemctl reload apache2 2>/dev/null || true
	fi
	if command -v nginx >/dev/null 2>&1 && nginx -t 2>/dev/null; then systemctl reload nginx 2>/dev/null || true; fi
	if [ "$WIPE_CERTS" = 1 ] && command -v certbot >/dev/null 2>&1; then
		for d in $(printf '%s\n' $doms | sort -u); do
			valid_fqdn "$d" && [ -d "/etc/letsencrypt/live/$d" ] &&
				certbot delete --cert-name "$d" --non-interactive || true
		done
	fi
	return 0
}

purge_wings() {
	systemctl disable --now featherwings 2>/dev/null || true
	systemctl disable --now featherpanel-docker-updater.service 2>/dev/null || true
	rm -f /etc/systemd/system/featherpanel-docker-updater.service /etc/systemd/system/featherwings.service \
		/usr/local/bin/featherwings
	systemctl daemon-reload || true
	if dpkg -s featherwings >/dev/null 2>&1; then apt-get "${APT_OPTS[@]}" purge featherwings || true; fi
	rm -rf /etc/featherpanel /var/lib/featherpanel
	rm -f /etc/apt/sources.list.d/mythicalsystems.list /etc/apt/keyrings/mythicalsystems.gpg /tmp/fp-upstream-installer.sh
	return 0
}

purge_all() {
	exec 9>/run/zerotzyid-installer.lock
	flock -n 9 || die "Installer lain masih berjalan."
	say ""
	say "  ${CR}${CB}HAPUS TOTAL${C0} - ini akan menghapus PERMANEN:"
	say "   - Panel: container, database/volume, image, ${PANEL_DIR}"
	say "   - Config Nginx panel (sertifikat SSL dipertahankan agar tidak kena rate limit Let's Encrypt; hapus dengan --wipe-certs)"
	say "   - Wings, /etc/featherpanel, /var/lib/featherpanel (${CB}data server game${C0})"
	[ "$WIPE_DOCKER" = 1 ] && say "   - Semua image/volume Docker yang tidak terpakai (--wipe-docker)"
	say "   ${CY}Docker, Nginx, dan paket dasar tidak dihapus.${C0}"
	if [ "$YES" != 1 ]; then
		[ "$AUTO" = 1 ] && die "Mode bot butuh --yes untuk konfirmasi hapus."
		local c=""
		ask "  Ketik ${CB}HAPUS${C0} untuk lanjut: " c
		[ "$c" = HAPUS ] || die "Dibatalkan, tidak ada yang dihapus."
	fi
	tg "Mulai HAPUS TOTAL"
	say ""
	run "Menghapus stack panel (Docker)" 600 purge_panel_docker || warn "Sebagian panel gagal dihapus"
	run "Menghapus Nginx/SSL panel" 180 purge_web || warn "Sebagian config web gagal dihapus"
	run "Menghapus Wings & data node" 300 purge_wings || warn "Sebagian Wings gagal dihapus"
	if [ "$WIPE_DOCKER" = 1 ] && command -v docker >/dev/null 2>&1; then
		run "Prune Docker (image/volume tak terpakai)" 600 docker system prune -af --volumes || true
	fi
	ok "VPS bersih dari FeatherPanel"
	tg "HAPUS TOTAL selesai"
}

finish() {
	local took="$((SECONDS / 60))m $((SECONDS % 60))s"
	say ""; boxbar "╔" "╗"
	boxline "SELESAI dalam $took"
	boxbar "╚" "╝"
	has_panel && say "  ${CB}Panel${C0}  : ${CG}${PANEL_URL}${C0}"
	has_panel && say "           Buka URL di atas untuk menyelesaikan akun admin."
	if has_node; then
		say "  ${CB}Node${C0}   : ${CG}${NODE_FQDN}${C0}  (Wings terpasang)"
		if [ "$NODE_SSL" = 1 ]; then
			say "           SSL : $(cert_dir "$NODE_FQDN")/fullchain.pem"
			say "                 $(cert_dir "$NODE_FQDN")/privkey.pem"
		fi
		if [ "$NODE_PROVISIONED" = 1 ]; then
			say "           Location id=$LOC_ID & Node id=$NODE_ID dibuat otomatis (memory/disk unlimited)."
			if [ "$NODE_VERIFY" = ok ]; then
				say "           Wings aktif & tanpa error token. Cek Admin > Nodes: harus hijau/online."
			else
				say "           ${CY}Wings belum terverifikasi.${C0} Cek: journalctl -u featherwings -n 40"
				say "           lalu jalankan: bash installer.sh --diag"
			fi
		elif [ "$NODE_CONFIGURED" = 1 ]; then
			say "           Node sudah dikonfigurasi & dijalankan."
		else
			say "           Langkah akhir: di panel buat Node dengan FQDN ${NODE_FQDN},"
			say "           lalu jalankan di server ini command 'featherwings configure ...'"
			say "           dari panel, dan: ${CB}systemctl enable --now featherwings${C0}"
		fi
	fi
	say "  ${CB}Log${C0}    : $LOG"
	say ""
	say "  ${CY}(c) 2026 zerotzyid - ${GITHUB}${C0}"
	tg "SELESAI ($took). Panel: ${PANEL_URL:-n/a} | Node: ${NODE_FQDN:-n/a} | node_configured=$NODE_CONFIGURED"
	echo "ZEROTZY_RESULT {\"status\":\"ok\",\"role\":\"$ROLE\",\"panel_url\":\"${PANEL_URL}\",\"node_fqdn\":\"${NODE_FQDN}\",\"node_ssl\":$NODE_SSL,\"node_configured\":$NODE_CONFIGURED,\"node_provisioned\":$NODE_PROVISIONED,\"node_verify\":\"$NODE_VERIFY\",\"seconds\":$SECONDS}"
}

# -------------------------------------------------------------------- main
[ "$(id -u)" -eq 0 ] || { echo "Harus root. Jalankan: sudo -i, lalu ulangi."; exit 1; }
mkdir -p "$(dirname "$LOG")"; : >>"$LOG"; chmod 600 "$LOG"
echo "[START] $(date '+%F %T') v$VERSION" >>"$LOG"

banner
if [ "$AUTO" = 0 ] && [ "$MODE" = install ] && [ -z "$ROLE$PANEL_FQDN$NODE_FQDN" ]; then
	say "  ${CB}Apa yang mau dilakukan?${C0}"
	say "   ${CG}[1]${C0} Install"
	say "   ${CR}[2]${C0} Hapus total (bersihkan VPS)"
	say "   ${CY}[3]${C0} Hapus total + install ulang"
	m=""
	while [[ ! "$m" =~ ^[123]$ ]]; do ask "  Pilihan [1]: " m 1; done
	case "$m" in 2) MODE=uninstall ;; 3) MODE=reinstall ;; esac
	say ""
fi
if [ "$MODE" = addnode ]; then
	NODE_FQDN="${ADD_NODE_FQDN,,}"
	valid_fqdn "$NODE_FQDN" || die "FQDN node tidak valid: '$ADD_NODE_FQDN'"
	command -v docker >/dev/null 2>&1 || die "--add-node harus dijalankan di server PANEL (Docker tidak ditemukan)."
	PANEL_URL=$(derive_panel_url) || die "Konfigurasi panel (Nginx) tidak ditemukan. Jalankan di server panel."
	rm -f "$STATE"
	run "Membuat Location + Node di panel" 600 addnode_main || { grep '^\[PROV\]' "$LOG" | tail -n 6 | sed 's/^/    /'; die "Gagal membuat node di panel (lihat $LOG, coba --diag)"; }
	grep '^\[PROV\]' "$LOG" | tail -n 8 | sed 's/^/    /'
	# shellcheck disable=SC1090
	. "$STATE"; rm -f "$STATE"
	blob=$(printf '%s|%s|%s|%s|%s' "$Z_UUID" "$Z_TID" "$Z_TOK" "$PANEL_URL" "$ZSCHEME" | base64 -w0)
	say ""
	say "  ${CG}Node dibuat${C0} (id=$NODE_ID, location id=$LOC_ID, ${NODE_FQDN})."
	say "  Jalankan di ${CB}VPS node${C0} (DNS $NODE_FQDN harus sudah mengarah ke VPS itu):"
	say ""
	say "  sudo bash zerotzyid-installer.sh --bot --role node --node-fqdn $NODE_FQDN --join $blob"
	say ""
	say "  ${CY}Kode join berisi rahasia node - jangan dibagikan.${C0}"
	echo "ZEROTZY_RESULT {\"status\":\"ok\",\"action\":\"add-node\",\"node_id\":$NODE_ID,\"node_fqdn\":\"$NODE_FQDN\",\"join\":\"$blob\"}"
	exit 0
fi
if [ "$MODE" = diag ]; then
	run "Mengumpulkan diagnosa" 120 diag
	say "  Hasil: ${CB}/root/zerotzyid-diag.txt${C0}  (cek dulu, lalu kirim isinya)"
	echo 'ZEROTZY_RESULT {"status":"ok","action":"diag"}'
	exit 0
fi
if [ "$MODE" = uninstall ]; then
	purge_all
	say ""; say "  ${CY}(c) 2026 zerotzyid - ${GITHUB}${C0}"
	echo 'ZEROTZY_RESULT {"status":"ok","action":"uninstall"}'
	exit 0
fi
[ "$MODE" = reinstall ] && purge_all
gather

TOTAL=3
has_panel && TOTAL=$((TOTAL + 3))
has_node && TOTAL=$((TOTAL + 2))
want_provision && TOTAL=$((TOTAL + 1))
[ "$ROLE" = node ] && [ -n "$JOIN_BLOB" ] && TOTAL=$((TOTAL + 1))

say ""
say "  ${CB}Ringkasan${C0}: role=${ROLE}${PANEL_FQDN:+  panel=$PANEL_FQDN}${NODE_FQDN:+  node=$NODE_FQDN}"
if [ "$AUTO" = 0 ] && [ -t 1 ]; then
	for i in 5 4 3 2 1; do printf '\r  Mulai otomatis dalam %s detik... (Ctrl+C = batal) ' "$i"; sleep 1; done
	printf '\r\033[K'
fi
tg "Mulai instalasi role=$ROLE panel=${PANEL_FQDN:-n/a} node=${NODE_FQDN:-n/a}"

step "Pengecekan sistem"
preflight

step "Paket dasar"
run "Memasang paket dasar" 900 install_base || die "Gagal memasang paket dasar"

step "Docker"
run "Memasang & menyalakan Docker" 900 install_docker || die "Gagal memasang Docker"

if has_panel; then
	step "Deploy FeatherPanel"
	run "Mengunduh konfigurasi panel" 180 deploy_panel || die "Gagal menyiapkan docker-compose panel"
	run "Menarik image & menyalakan container" 1500 start_panel || die "docker compose up gagal"

	step "Menunggu panel siap"
	info "Menunggu panel merespons di 127.0.0.1:$PANEL_PORT (maks 7 menit)"
	if wait_http "http://127.0.0.1:$PANEL_PORT" 420; then
		ok "Panel merespons"
	else
		"${DC[@]}" ps >>"$LOG" 2>&1 || true
		"${DC[@]}" logs --tail 40 >>"$LOG" 2>&1 || true
		die "Panel tidak merespons dalam 7 menit"
	fi

	step "Nginx + SSL untuk panel"
	run "Konfigurasi Nginx reverse proxy" 120 setup_nginx || die "Konfigurasi Nginx gagal"
	if compgen -G "/root/zerotzyid-nginx-backup-*" >/dev/null; then
		warn "Ada config Nginx rusak (sisa instalasi lama) dipindah ke /root/zerotzyid-nginx-backup-*"
	fi
	PANEL_URL="http://$PANEL_FQDN"
	if [ "$NO_SSL" = 1 ]; then
		warn "SSL dilewati (--no-ssl)"
	else
		check_dns "$PANEL_FQDN"; d=$?
		if [ "$d" -eq 1 ]; then
			warn "SSL ditunda sampai DNS siap. Nanti jalankan: certbot --nginx -d $PANEL_FQDN"
		elif run "Membuat sertifikat SSL panel" 240 issue_panel_cert; then
			PANEL_URL="https://$PANEL_FQDN"
		else
			grep '^\[CERT\]' "$LOG" | tail -n 3 | sed 's/^/    /'
			if [ -f "$RL_MARK" ] && [ "$NO_FALLBACK" != 1 ]; then
				info "Let's Encrypt kena rate limit -> mencoba CA cadangan (ZeroSSL via acme.sh)"
				if run "Sertifikat cadangan ZeroSSL (panel)" 480 acme_fallback "$PANEL_FQDN" &&
					run "Mengaktifkan HTTPS di Nginx" 120 setup_nginx_tls "$(cert_dir "$PANEL_FQDN")"; then
					PANEL_URL="https://$PANEL_FQDN"
				else
					grep '^\[CERT\]' "$LOG" | tail -n 2 | sed 's/^/    /'
					warn "SSL cadangan juga gagal; panel tetap via HTTP. Jalankan installer lagi setelah batas rate limit reset."
				fi
			else
				warn "SSL gagal, panel tetap jalan via HTTP. Coba lagi: certbot --nginx -d $PANEL_FQDN"
			fi
		fi
	fi
fi

if has_node; then
	step "Memasang FeatherWings (node)"
	run "Memasang FeatherWings" 900 install_wings || die "Instalasi FeatherWings gagal (lihat $LOG)"

	step "SSL node + firewall"
	if [ "$NO_SSL" = 1 ]; then
		warn "SSL node dilewati (--no-ssl)"
	else
		check_dns "$NODE_FQDN"; d=$?
		[ "$d" -eq 2 ] && warn "Domain node harus DNS-only (bukan proxy Cloudflare)."
		if [ "$d" -eq 1 ]; then
			warn "SSL node ditunda. Nanti: certbot certonly --standalone -d $NODE_FQDN"
		elif run "Membuat sertifikat SSL node" 240 issue_node_cert; then
			NODE_SSL=1
		else
			grep '^\[CERT\]' "$LOG" | tail -n 3 | sed 's/^/    /'
			if [ -f "$RL_MARK" ] && [ "$NO_FALLBACK" != 1 ]; then
				info "Let's Encrypt kena rate limit -> mencoba CA cadangan (ZeroSSL via acme.sh)"
				if run "Sertifikat cadangan ZeroSSL (node)" 480 acme_fallback "$NODE_FQDN"; then
					NODE_SSL=1
				else
					grep '^\[CERT\]' "$LOG" | tail -n 2 | sed 's/^/    /'
					warn "SSL node cadangan juga gagal. Jalankan installer lagi setelah batas rate limit reset."
				fi
			else
				warn "SSL node gagal. Coba lagi: certbot certonly --standalone -d $NODE_FQDN"
			fi
			case "$PANEL_URL" in https://*) warn "Panel HTTPS + node HTTP: console/file manager diblokir browser (mixed content). Selesaikan SSL node." ;; esac
		fi
	fi
	run "Membuka port firewall (jika ufw aktif)" 60 open_firewall || true
	if want_provision; then
		step "Auto-create Location & Node (database)"
		rm -f "$STATE"
		if ! run "Membuat Location + Node dan mengatur Wings" 600 provision_node; then
			warn "Auto-create gagal. Detail: $LOG  |  diagnosa: bash $0 --diag"
		fi
		grep '^\[PROV\]' "$LOG" | tail -n 8 | sed 's/^/    /'
		# shellcheck disable=SC1090
		[ -f "$STATE" ] && . "$STATE"
		[ "$NODE_PROVISIONED" = 1 ] && NODE_CONFIGURED=1
	fi
	if [ "$ROLE" = node ] && [ -n "$JOIN_BLOB" ]; then
		step "Menghubungkan node ke panel (join)"
		rm -f "$STATE"
		if ! run "Membaca kode join & menjalankan Wings" 300 join_node; then
			warn "Join gagal. Detail: $LOG"
		fi
		grep '^\[PROV\]' "$LOG" | tail -n 6 | sed 's/^/    /'
		# shellcheck disable=SC1090
		[ -f "$STATE" ] && . "$STATE"
		rm -f "$STATE"
		[ "$NODE_PROVISIONED" = 1 ] && NODE_CONFIGURED=1
	fi
	if [ -n "$NODE_CMD" ]; then
		if run "Menjalankan featherwings configure" 120 configure_node; then
			NODE_CONFIGURED=1
		else
			warn "Auto-configure gagal/tidak valid; jalankan command dari panel secara manual."
		fi
	fi
fi

finish
exit 0
