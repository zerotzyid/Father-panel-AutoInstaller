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
  --yes, -y          Lewati konfirmasi hapus (wajib untuk --bot)
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
	--yes | -y) YES=1 ;;
	--wipe-docker) WIPE_DOCKER=1 ;;
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
	nginx -t || return 1
	systemctl enable nginx
	systemctl restart nginx
}

certbot_email_args() {
	if [ -n "$EMAIL" ]; then printf '%s\n' -m "$EMAIL"; else printf '%s\n' --register-unsafely-without-email; fi
}

issue_panel_cert() {
	local ea=(); mapfile -t ea < <(certbot_email_args)
	certbot --nginx -d "$PANEL_FQDN" --non-interactive --agree-tos --redirect "${ea[@]}"
}

issue_node_cert() {
	local ea=(); mapfile -t ea < <(certbot_email_args)
	certbot certonly --standalone -d "$NODE_FQDN" --non-interactive --agree-tos "${ea[@]}" \
		--pre-hook "systemctl stop nginx 2>/dev/null || true" \
		--post-hook "systemctl start nginx 2>/dev/null || true"
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
	if command -v certbot >/dev/null 2>&1; then
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
	say "   - Config Nginx panel + sertifikat SSL (panel/node)"
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
			say "           SSL : /etc/letsencrypt/live/${NODE_FQDN}/fullchain.pem"
			say "                 /etc/letsencrypt/live/${NODE_FQDN}/privkey.pem"
		fi
		if [ "$NODE_CONFIGURED" = 1 ]; then
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
	echo "ZEROTZY_RESULT {\"status\":\"ok\",\"role\":\"$ROLE\",\"panel_url\":\"${PANEL_URL}\",\"node_fqdn\":\"${NODE_FQDN}\",\"node_ssl\":$NODE_SSL,\"node_configured\":$NODE_CONFIGURED,\"seconds\":$SECONDS}"
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
			warn "SSL gagal, panel tetap jalan via HTTP. Coba lagi: certbot --nginx -d $PANEL_FQDN"
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
			warn "SSL node gagal. Coba lagi: certbot certonly --standalone -d $NODE_FQDN"
		fi
	fi
	run "Membuka port firewall (jika ufw aktif)" 60 open_firewall || true
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
