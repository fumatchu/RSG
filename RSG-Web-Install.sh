#!/usr/bin/env bash
# RSG-WEB Installer -- Rocky Secure Gateway (nftables-only firewall appliance)
# Requires: Rocky Linux 10.0+, run as root
#
# Not standalone -- run via RSG-Web-Installer.sh, or directly from
# inside a full clone/release tarball of the repo (deploy_rsg_web()
# below expects api/, ui/, and installer/ alongside itself under
# SRC_BASE, as a fallback if the release tarball download fails).
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
TEXTRESET="\033[0m"
CYAN="\e[36m"
RESET="\e[0m"
SRC_BASE="/root/RSG-WebInstaller"
INSTALL_BASE="/opt/rsg-web"
LOGDIR="/var/log/rsg-web-installer"
mkdir -p "$LOGDIR"

# =============================================================
# OUTPUT HELPERS
# =============================================================
step_ok()   { echo -e "  [${GREEN}✓${TEXTRESET}] $*"; }
step_fail() { echo -e "  [${RED}✗${TEXTRESET}] $*"; }
step_info() { echo -e "  [${YELLOW}→${TEXTRESET}] $*"; }
section()   { echo ""; echo -e "${CYAN}── $* ──${TEXTRESET}"; }

# =============================================================
# STEP 1 -- ROOT + OS CHECK
# =============================================================
check_root_and_os() {
  section "System Checks"
  if [[ $EUID -eq 0 ]]; then
    step_ok "Running as root"
  else
    step_fail "Must be run as root"
    exit 1
  fi
  local OSVER_RAW OSVER_MAJOR OSVER_MINOR
  if [[ -f /etc/os-release ]]; then
    OSVER_RAW=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null)
  elif [[ -f /etc/redhat-release ]]; then
    OSVER_RAW=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)
  fi
  OSVER_MAJOR=$(echo "$OSVER_RAW" | awk -F. '{print $1}')
  OSVER_MINOR=$(echo "$OSVER_RAW" | awk -F. '{print ($2==""?0:$2)}')
  if (( OSVER_MAJOR >= 10 )); then
    step_ok "OS check passed -- Rocky Linux ${OSVER_MAJOR}.${OSVER_MINOR}"
  else
    step_fail "Rocky Linux 10.0+ required (detected: ${OSVER_MAJOR:-unknown}.${OSVER_MINOR:-x})"
    exit 1
  fi
  sleep 1
}

# =============================================================
# STEP 2 -- SELINUX
# =============================================================
check_and_enable_selinux() {
  section "SELinux"
  local status; status=$(getenforce 2>/dev/null || echo "Unknown")
  if [[ "$status" == "Enforcing" ]]; then
    step_ok "SELinux is Enforcing"
  else
    step_info "SELinux is ${status} -- enabling..."
    sed -i 's/SELINUX=disabled/SELINUX=enforcing/' /etc/selinux/config
    sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
    setenforce 1 2>/dev/null || true
    [[ "$(getenforce)" == "Enforcing" ]] && step_ok "SELinux enabled (Enforcing)" \
      || step_fail "SELinux could not be set to Enforcing -- check config manually"
  fi
  sleep 1
}

# =============================================================
# STEP 3 -- BASE PACKAGES
#
# nftables is installed explicitly and BEFORE anything under
# /etc/nftables/ or /etc/sysconfig/nftables.conf is written --
# installing it *after* those files already exist makes dnf treat them
# as local modifications and stash them in .rpmsave instead of laying
# down the package's own defaults, which is the exact trap that showed
# up during manual testing on the dev box. Package-first, config-after
# avoids it entirely.
# =============================================================
install_base_packages() {
  section "Base Packages"
  local log="$LOGDIR/base-packages.log"; : > "$log"

  step_info "EPEL + dnf plugins..."
  dnf -y install epel-release --setopt=install_weak_deps=False --color=never >>"$log" 2>&1
  dnf -y install dnf-plugins-core --setopt=install_weak_deps=False --color=never >>"$log" 2>&1 || true
  step_ok "EPEL + dnf-plugins-core installed"

  step_info "httpd + reverse proxy + TLS..."
  dnf -y install httpd mod_ssl mod_proxy_html --color=never >>"$log" 2>&1
  step_ok "httpd, mod_ssl, mod_proxy_html installed"

  step_info "Python + FastAPI runtime deps..."
  dnf -y install python3 python3-pip python3-devel python3-psutil \
    policycoreutils-python-utils openssl --color=never >>"$log" 2>&1
  step_ok "Python runtime deps installed"

  step_info "nftables (before any custom config is written -- see comment above)..."
  dnf -y install nftables --color=never >>"$log" 2>&1
  step_ok "nftables installed"

  step_info "Supporting utilities..."
  dnf -y install fail2ban chrony bind-utils net-tools wget curl rsync \
    nano htop at tuned --color=never >>"$log" 2>&1
  step_ok "Supporting utilities installed"
  sleep 1
}

# =============================================================
# STEP 4 -- PYTHON PACKAGES
# (psutil intentionally comes from dnf above, not pip)
# =============================================================
install_python_packages() {
  section "Python / FastAPI"
  local log="$LOGDIR/python.log"; : > "$log"
  cd /root || cd /tmp
  step_info "Upgrading pip..."
  python3 -m pip install --upgrade pip setuptools wheel --break-system-packages >>"$log" 2>&1
  local PACKAGES=(
    "fastapi"
    "uvicorn[standard]"
    "python-multipart"
    "python-pam"       # PAM auth against Rocky system users
    "aiofiles"
    "python-dotenv"
    "httpx"             # async HTTP client (Meraki lookups, etc.)
    "meraki"            # Meraki Dashboard API client
  )
  local all_ok=1
  for pkg in "${PACKAGES[@]}"; do
    python3 -m pip install -U "$pkg" --break-system-packages >>"$log" 2>&1
    [[ $? -eq 0 ]] && step_ok "pip install ${pkg}" \
      || { step_fail "pip install ${pkg} failed -- see ${log}"; all_ok=0; }
  done
  [[ $all_ok -eq 1 ]] && step_ok "All Python packages installed" \
    || step_fail "Some Python packages failed -- see ${log}"
  sleep 1
}

# =============================================================
# STEP 5 -- DEPLOY RSG-WEB APPLICATION
# =============================================================
deploy_rsg_web() {
  section "Deploy RSG-Web Application"
  local log="$LOGDIR/deploy.log"; : > "$log"
  local TARBALL_URL="https://github.com/fumatchu/RSG/releases/latest/download/rsg-web.tar.gz"
  local TARBALL="/tmp/rsg-web.tar.gz"
  step_info "Downloading application package from GitHub Releases..."
  wget -q -O "$TARBALL" "$TARBALL_URL" 2>>"$log"
  if [[ $? -ne 0 || ! -s "$TARBALL" ]]; then
    step_info "Release tarball not found -- installing from cloned source..."
    if [[ -d "$SRC_BASE" ]]; then
      mkdir -p "$INSTALL_BASE"
      cp -r "${SRC_BASE}/api"       "$INSTALL_BASE/" >>"$log" 2>&1
      cp -r "${SRC_BASE}/ui"        "$INSTALL_BASE/" >>"$log" 2>&1
      cp -r "${SRC_BASE}/installer" "$INSTALL_BASE/" >>"$log" 2>&1
      [[ -d "${SRC_BASE}/upgrade" ]] && cp -r "${SRC_BASE}/upgrade" "$INSTALL_BASE/" >>"$log" 2>&1
      [[ -f "${SRC_BASE}/VERSION" ]] && cp "${SRC_BASE}/VERSION" "$INSTALL_BASE/" >>"$log" 2>&1
      step_ok "Installed from source: ${SRC_BASE}"
    else
      step_fail "No source or release package available"
      return 1
    fi
  else
    local SIZE; SIZE=$(du -sh "$TARBALL" | cut -f1)
    step_ok "Downloaded rsg-web.tar.gz (${SIZE})"
    [[ -d "$INSTALL_BASE" ]] && mv "$INSTALL_BASE" "${INSTALL_BASE}.bak.$(date +%Y%m%d%H%M%S)"
    tar -xzf "$TARBALL" -C /opt/ >>"$log" 2>&1
    [[ $? -eq 0 ]] && step_ok "Extracted to ${INSTALL_BASE}" \
      || { step_fail "Extraction failed"; return 1; }
    rm -f "$TARBALL"
  fi
  # Ensure runtime dirs -- state/ holds platform_update.py's
  # update_available.json (GitHub release check state), separate from
  # data/ (operator/reference data) and logs/.
  mkdir -p "${INSTALL_BASE}/data" "${INSTALL_BASE}/logs" "${INSTALL_BASE}/state"
  # Permissions
  find "$INSTALL_BASE" -type d -exec chmod 755 {} \;
  find "${INSTALL_BASE}/api" -type f -name "*.py" -exec chmod 644 {} \;
  find "${INSTALL_BASE}/ui"  -type f -exec chmod 644 {} \;
  [[ -d "${INSTALL_BASE}/installer" ]] && find "${INSTALL_BASE}/installer" -type f -name "*.sh" -exec chmod 700 {} \;
  [[ -d "${INSTALL_BASE}/upgrade" ]]   && find "${INSTALL_BASE}/upgrade"   -type f -name "*.sh" -exec chmod 700 {} \;
  chmod 755 "${INSTALL_BASE}/data" "${INSTALL_BASE}/logs" "${INSTALL_BASE}/state"
  step_ok "Permissions set"
  sleep 1
}

# =============================================================
# STEP 6 -- KNOWN-SERVICES CATALOG
#
# api/known_services.py's catalog (name/port/protocol, sourced from
# firewalld's own service definitions) ships pre-scraped as part of the
# release tarball at data/known-services.json -- that's INSTALL_BASE
# itself, so it's already sitting there the moment extract_files()
# finishes, no scraping needed on a normal install. This step is now
# just a safety net for a tarball that's missing it for some reason
# (an old release build, a dev checkout, etc.): if firewalld's service
# definitions still happen to be on disk, scrape them as a fallback --
# this MUST run before remove_firewalld() deletes that directory for
# good, so it can't be deferred to run later on demand.
# =============================================================
scrape_known_services() {
  section "Known-Services Catalog"
  local log="$LOGDIR/known-services.log"; : > "$log"
  if [[ -s "${INSTALL_BASE}/data/known-services.json" ]]; then
    local COUNT
    COUNT=$(python3 -c "
import sys
sys.path.insert(0, '${INSTALL_BASE}/api')
import known_services
print(len(known_services.load_catalog()))
" 2>>"$log")
    step_ok "Catalog already shipped with this release -- ${COUNT:-?} known services, no scrape needed"
    sleep 1
    return 0
  fi
  if [[ ! -d /usr/lib/firewalld/services ]]; then
    step_info "No shipped catalog and no firewalld service definitions found -- skipping (Services page will start empty)"
    sleep 1
    return 0
  fi
  step_info "No shipped catalog found -- falling back to scraping firewalld's service definitions before it's removed..."
  local COUNT
  COUNT=$(python3 -c "
import sys
sys.path.insert(0, '${INSTALL_BASE}/api')
import known_services
print(known_services.scrape_and_save())
" 2>>"$log")
  if [[ -z "$COUNT" || "$COUNT" -eq 0 ]]; then
    step_fail "Captured 0 services -- check ${log}"
  else
    step_ok "Captured ${COUNT} known services into ${INSTALL_BASE}/data/known-services.json"
  fi
  sleep 1
}

# =============================================================
# STEP 7 -- REMOVE FIREWALLD, GO NFTABLES-ONLY
#
# RSG is nftables-only by design -- see nft_fw.py's docstring. Two
# services running the same netfilter-adjacent job on one box is
# exactly the kind of redundant attack surface a firewall appliance
# shouldn't ship with.
# =============================================================
remove_firewalld() {
  section "Firewalld -> nftables"
  local log="$LOGDIR/firewalld-removal.log"; : > "$log"
  if systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
    step_info "Disabling and masking firewalld..."
    systemctl disable --now firewalld >>"$log" 2>&1
    systemctl mask firewalld >>"$log" 2>&1
    step_info "Removing firewalld package..."
    dnf remove -y firewalld --color=never >>"$log" 2>&1
    step_ok "firewalld disabled, masked, and removed"
  else
    step_ok "firewalld not present -- nothing to remove"
  fi
  sleep 1
}

# =============================================================
# STEP 8 -- WRITE BASE NFTABLES RULESET
#
# This is deliberately close to the stock nftables package sample --
# no per-box customization baked in here. allowed_tcp_dports starts at
# ssh/9090/http/https (management access); allowed_udp_dports starts
# empty (nft_fw.py adds the `elements = { ... }` line the first time a
# feature needs a UDP port persisted). router.nft/nat.nft stay
# commented out until zones_apply.py's day-one topology step (below)
# decides whether this box has a 2-interface Inside/Outside setup that
# needs them.
# =============================================================
configure_nftables() {
  section "nftables Base Ruleset"
  local log="$LOGDIR/nftables.log"; : > "$log"

  mkdir -p /etc/nftables
  cat > /etc/nftables/main.nft <<'EOF'
# Sample configuration for nftables service.
# Load this by calling 'nft -f /etc/nftables/main.nft'.
# Reset only our own table, not the whole ruleset -- this file gets
# reloaded live every time a Server Feature with its own included table
# (Forward/NAT, Port Forwarding, Spamhaus, PortSentry) is applied, not
# just at boot, so `flush ruleset` here would wipe those tables' live
# dynamic state (blocklists, etc.) on every one of those applies. `add
# table` first guarantees it exists (no-op if already present, required
# on a genuinely fresh box); `flush table` then resets just this table.
add table inet nftables_svc
flush table inet nftables_svc
# a common table for both IPv4 and IPv6
table inet nftables_svc {
	# protocols to allow
	set allowed_protocols {
		type inet_proto
		elements = { icmp, icmpv6 }
	}
	# interfaces to accept any traffic on
	set allowed_interfaces {
		type ifname
		elements = { "lo" }
	}
	# services to allow
	set allowed_tcp_dports {
		type inet_service
		elements = { ssh, 9090, http, https }
	}
	# udp services to allow -- populated as optional features (Kea DHCP,
	# OpenVPN, WireGuard) get installed via Server Features. No `elements =`
	# line at all for now -- nftables rejects `elements = { }` with nothing
	# inside as a syntax error, so an empty set just omits the line entirely.
	# RSG-Web's feature installer (nft_fw.py) adds this line the first time
	# a port needs to be persisted here.
	set allowed_udp_dports {
		type inet_service
	}
	# this chain gathers all accept conditions
	chain allow {
		ct state established,related accept
		meta l4proto @allowed_protocols accept
		iifname @allowed_interfaces accept
		tcp dport @allowed_tcp_dports accept
		udp dport @allowed_udp_dports accept
	}
	# base-chain for traffic to this host
	chain INPUT {
		type filter hook input priority filter + 20
		policy accept
		jump allow
		reject with icmpx type port-unreachable
	}
}
# By default, any forwarding traffic is allowed.
# Uncomment the following line to filter it based
# on the same criteria as input traffic.
#include "/etc/nftables/router.nft"
# Uncomment the following line to enable masquerading of
# forwarded traffic. May be used with or without router.nft.
#include "/etc/nftables/nat.nft"
EOF
  step_ok "/etc/nftables/main.nft written"

  cat > /etc/sysconfig/nftables.conf <<'EOF'
# Uncomment the include statement here to load the default config sample
# in /etc/nftables for nftables service.
include "/etc/nftables/main.nft"
# To customize, either edit the samples in /etc/nftables, append further
# commands to the end of this file or overwrite it after first service
# start by calling: 'nft list ruleset >/etc/sysconfig/nftables.conf'.
EOF
  step_ok "/etc/sysconfig/nftables.conf written"

  nft -c -f /etc/nftables/main.nft >>"$log" 2>&1
  if [[ $? -ne 0 ]]; then
    step_fail "main.nft failed syntax check -- see ${log}"
    return 1
  fi
  step_ok "main.nft passed syntax check"

  systemctl enable --now nftables >>"$log" 2>&1
  systemctl is-active --quiet nftables \
    && step_ok "nftables service running" \
    || { step_fail "nftables failed to start -- see ${log}"; return 1; }
  sleep 1
}

# =============================================================
# STEP 9 -- SELINUX FOR RSG-WEB
# =============================================================
configure_selinux_rsgweb() {
  section "SELinux -- RSG-WEB"
  local log="$LOGDIR/selinux-web.log"; : > "$log"
  command -v semanage >/dev/null 2>&1 || { step_fail "semanage not found"; return 1; }
  semanage fcontext -a -t httpd_sys_content_t \
    "${INSTALL_BASE}/ui(/.*)?" >>"$log" 2>&1 \
    || semanage fcontext -m -t httpd_sys_content_t \
      "${INSTALL_BASE}/ui(/.*)?" >>"$log" 2>&1 || true
  restorecon -Rv "${INSTALL_BASE}/ui" >>"$log" 2>&1 || true
  step_ok "SELinux: httpd_sys_content_t on ui/"
  setsebool -P httpd_can_network_connect 1 >>"$log" 2>&1
  step_ok "SELinux: httpd_can_network_connect enabled"
  sleep 1
}

# =============================================================
# STEP 10 -- SELF-SIGNED TLS CERTIFICATE
# =============================================================
generate_ssl_cert() {
  section "TLS Certificate (self-signed)"
  local log="$LOGDIR/ssl.log"; : > "$log"
  local CERT="/etc/pki/tls/certs/rsg-web.crt"
  local KEY="/etc/pki/tls/private/rsg-web.key"
  if [[ -f "$CERT" && -f "$KEY" ]]; then
    step_ok "TLS certificate already present"
    sleep 1
    return
  fi
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=rsg-web" >>"$log" 2>&1
  [[ -f "$CERT" && -f "$KEY" ]] \
    && step_ok "Self-signed certificate generated (825 days)" \
    || { step_fail "Certificate generation failed -- see ${log}"; return 1; }
  sleep 1
}

# =============================================================
# STEP 11 -- APACHE VIRTUALHOST (REVERSE PROXY)
#
# flushpackets=on matters here specifically because of the SSE
# (text/event-stream) endpoints already in the app -- feature
# install/remove progress and the Interfaces "detect new NIC" stream.
# Without it, mod_proxy's default response buffering can hold those
# chunks back instead of relaying them as they arrive, breaking the
# live-update UI even though the backend itself is streaming correctly.
# =============================================================
configure_apache() {
  section "Apache VirtualHost (HTTPS)"
  local log="$LOGDIR/apache.log"; : > "$log"

  local DEFAULT_SSL="/etc/httpd/conf.d/ssl.conf"
  if [[ -f "$DEFAULT_SSL" ]] && grep -qE '^[[:space:]]*<VirtualHost[[:space:]]+_default_:443>' "$DEFAULT_SSL"; then
    sed -i '/^[[:space:]]*<VirtualHost[[:space:]]\+_default_:443>/,/^[[:space:]]*<\/VirtualHost>/ s/^/# /' "$DEFAULT_SSL"
    step_ok "Default ssl.conf <VirtualHost _default_:443> block commented out (DNF-safe)"
  else
    step_ok "Default ssl.conf VirtualHost block already disabled or absent"
  fi

  cat > /etc/httpd/conf.d/rsg-web.conf <<'EOF'
# RSG-WEB Apache VirtualHost
# The stock mod_ssl ssl.conf VirtualHost is disabled above to avoid a
# conflict on :443 -- this file owns both :80 (redirect) and :443.
<VirtualHost *:80>
    ServerName rsg-web
    Redirect permanent / https://rsg-web/
</VirtualHost>

<VirtualHost *:443>
    ServerName rsg-web
    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/rsg-web.crt
    SSLCertificateKeyFile /etc/pki/tls/private/rsg-web.key

    DocumentRoot /opt/rsg-web/ui
    DirectoryIndex index.html login.html
    <Directory /opt/rsg-web/ui>
        Options -Indexes
        AllowOverride None
        Require all granted
    </Directory>

    ProxyPreserveHost On

    # Logout (not under /api/, needs its own rule -- see main.py's
    # @app.get("/logout"), which clears the rsg_session cookie)
    ProxyPass        /logout http://127.0.0.1:8000/logout
    ProxyPassReverse /logout http://127.0.0.1:8000/logout

    # WebSocket PTY terminal (Server Admin -> Terminal tile). mod_proxy_wstunnel
    # ships as part of the base httpd package on Rocky and is auto-loaded via
    # conf.modules.d/00-proxy.conf -- no extra package needed. Must come before
    # the /api/ catch-all below, same ordering RADS-web uses.
    ProxyPass        /ws/ ws://127.0.0.1:8000/ws/
    ProxyPassReverse /ws/ ws://127.0.0.1:8000/ws/

    # flushpackets=on -- see comment in configure_apache() above; the
    # SSE endpoints under /api/ need each chunk relayed immediately,
    # not buffered.
    ProxyPass        /api/ http://127.0.0.1:8000/api/ flushpackets=on
    ProxyPassReverse /api/ http://127.0.0.1:8000/api/
</VirtualHost>
EOF
  step_ok "/etc/httpd/conf.d/rsg-web.conf written"

  local syntax_out; syntax_out=$(apachectl configtest 2>&1)
  echo "$syntax_out" | grep -q "Syntax OK" \
    && step_ok "Apache config syntax OK" \
    || { step_fail "Apache config syntax error:"; echo "$syntax_out"; return 1; }

  systemctl enable --now httpd >>"$log" 2>&1
  systemctl restart httpd      >>"$log" 2>&1
  systemctl is-active --quiet httpd \
    && step_ok "Apache (httpd) running with SSL" \
    || step_fail "Apache failed to start -- see /var/log/httpd/error_log"
  sleep 1
}

# =============================================================
# STEP 12 -- RSG-WEB SYSTEMD SERVICE
# =============================================================
install_rsg_service() {
  section "RSG-WEB Service"
  local SVC_FILE="/etc/systemd/system/rsg-web.service"
  local log="$LOGDIR/service.log"; : > "$log"
  cat > "$SVC_FILE" <<'EOF'
[Unit]
Description=RSG-WEB FastAPI Backend
After=network.target
[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/rsg-web/api
ExecStart=/usr/local/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >>"$log" 2>&1
  systemctl enable --now rsg-web >>"$log" 2>&1
  sleep 3
  systemctl is-active --quiet rsg-web \
    && step_ok "rsg-web service running" \
    || { step_fail "rsg-web service failed to start"; step_info "Check: journalctl -u rsg-web -n 50 --no-pager"; }
  sleep 1
}

# =============================================================
# STEP 13 -- FAIL2BAN
# =============================================================
configure_fail2ban() {
  section "Fail2ban"
  local log="$LOGDIR/fail2ban.log"; : > "$log"
  [[ -f /etc/fail2ban/jail.conf ]] && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local >>"$log" 2>&1 || true
  cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
findtime = 300
bantime = 3600
bantime.increment = true
bantime.factor = 2
EOF
  systemctl enable --now fail2ban >>"$log" 2>&1
  sleep 2
  systemctl is-active --quiet fail2ban \
    && step_ok "Fail2ban running (SSH jail active)" \
    || step_fail "Fail2ban failed to start -- see ${log}"
  sleep 1
}

# =============================================================
# STEP 14 -- TIME SYNC
# =============================================================
configure_chrony() {
  section "Time Sync (chrony)"
  local log="$LOGDIR/chrony.log"; : > "$log"
  systemctl enable --now chronyd >>"$log" 2>&1
  systemctl is-active --quiet chronyd \
    && step_ok "chronyd running" \
    || step_fail "chronyd failed to start -- see ${log}"
  sleep 1
}

# =============================================================
# STEP 15 -- RSG-WEB PLATFORM UPDATE CHECK
#
# This only wires up the daily *check* (writes state/update_available.json
# for the Updates page + topbar banner to read) -- it never applies
# anything on its own. Applying a platform update is always an explicit
# operator action from the Updates page (root password required).
# =============================================================
install_rsg_update_check() {
  section "RSG-WEB Update Check"
  local log="$LOGDIR/rsg-update-check.log"; : > "$log"
  local CHECK_SCRIPT="${INSTALL_BASE}/upgrade/update_check.sh"

  if [[ ! -x "$CHECK_SCRIPT" ]]; then
    step_fail "update_check.sh not found at ${CHECK_SCRIPT} -- skipping timer setup"
    step_info "Platform Updates card will still work manually from the UI"
    return 0
  fi

  cat > /etc/systemd/system/rsg-update-check.service <<EOF
[Unit]
Description=RSG-WEB Update Check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CHECK_SCRIPT}
User=root
StandardOutput=journal
StandardError=journal
EOF
  cat > /etc/systemd/system/rsg-update-check.timer <<'EOF'
[Unit]
Description=RSG-WEB Daily Update Check
Requires=rsg-update-check.service

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >>"$log" 2>&1
  systemctl enable --now rsg-update-check.timer >>"$log" 2>&1

  if systemctl is-active --quiet rsg-update-check.timer; then
    step_ok "rsg-update-check.timer enabled (runs daily, checks fumatchu/RSG)"
  else
    step_fail "rsg-update-check.timer failed to start -- see ${log}"
  fi

  # Run one check now so the Platform Updates card has fresh state on first login
  bash "$CHECK_SCRIPT" >>"$log" 2>&1 || true
  sleep 1
}

# =============================================================
# STEP 16 -- DAY-ONE INTERFACE TOPOLOGY
#
# Calls zones_apply.describe_topology() (api/zones_apply.py) to decide
# which of three paths applies, based purely on how many physical
# interfaces nmcli sees:
#   1 interface  -> auto-assigned to Inside, no prompt
#   2 interfaces -> dialog asks which is Inside; the other becomes
#                   Outside (zero ports open) with NAT/forwarding
#                   wired up automatically
#   3+ interfaces (or 0) -> nothing auto-assigned; operator is told
#                   what was detected and points to the Zones/
#                   Interfaces pages to finish setup after first boot
# =============================================================
configure_interface_topology() {
  section "Interface Topology"
  local log="$LOGDIR/topology.log"; : > "$log"

  local TOPO
  TOPO=$(python3 -c "
import sys, json
sys.path.insert(0, '${INSTALL_BASE}/api')
import zones_apply as za
print(json.dumps(za.describe_topology()))
" 2>>"$log")

  if [[ -z "$TOPO" ]]; then
    step_fail "Could not detect interfaces -- see ${log}"
    return 1
  fi

  local CASE
  CASE=$(echo "$TOPO" | python3 -c "import sys, json; print(json.load(sys.stdin)['case'])")

  case "$CASE" in
    single)
      local IFACE
      IFACE=$(echo "$TOPO" | python3 -c "import sys, json; print(json.load(sys.stdin)['interfaces'][0])")
      step_info "One interface detected (${IFACE}) -- assigning it to Inside automatically"
      python3 -c "
import sys
sys.path.insert(0, '${INSTALL_BASE}/api')
import zones_apply as za
ok, msg = za.apply_single_interface_topology('${IFACE}')
print(msg)
sys.exit(0 if ok else 1)
" >>"$log" 2>&1
      [[ $? -eq 0 ]] && step_ok "${IFACE} assigned to Inside (level 100)" \
        || step_fail "Failed to assign ${IFACE} -- see ${log}"
      ;;

    dual)
      local IFACES IF_A IF_B
      IFACES=$(echo "$TOPO" | python3 -c "import sys, json; print(' '.join(json.load(sys.stdin)['interfaces']))")
      read -r IF_A IF_B <<< "$IFACES"
      local INSIDE
      INSIDE=$(dialog --backtitle "RSG-WEB Installer" --title "Choose Inside Interface" \
        --menu "Two interfaces detected. Which one is Inside (trusted, level 100)?\nThe other becomes Outside (untrusted, level 0, no ports open) and gets NATted through automatically." \
        13 78 2 \
        "$IF_A" "" \
        "$IF_B" "" \
        3>&1 1>&2 2>&3)
      clear
      if [[ -z "$INSIDE" ]]; then
        step_info "No interface chosen -- skipping topology assignment (configure manually later)"
      else
        local OUTSIDE
        [[ "$INSIDE" == "$IF_A" ]] && OUTSIDE="$IF_B" || OUTSIDE="$IF_A"
        step_info "Inside=${INSIDE}, Outside=${OUTSIDE} -- applying..."
        python3 -c "
import sys
sys.path.insert(0, '${INSTALL_BASE}/api')
import zones_apply as za
ok, msg = za.apply_dual_interface_topology('${INSIDE}', '${OUTSIDE}', nat=True)
print(msg)
sys.exit(0 if ok else 1)
" >>"$log" 2>&1
        [[ $? -eq 0 ]] && step_ok "Inside=${INSIDE} / Outside=${OUTSIDE} applied, NAT enabled" \
          || step_fail "Failed to apply topology -- see ${log}"
      fi
      ;;

    multi)
      local IFACES
      IFACES=$(echo "$TOPO" | python3 -c "import sys, json; print(', '.join(json.load(sys.stdin)['interfaces']))")
      dialog --backtitle "RSG-WEB Installer" --title "Multiple Interfaces Detected" \
        --msgbox "Detected: ${IFACES}\n\nWith 3+ interfaces, zone assignment isn't automatic -- deciding what a 3rd/4th NIC is for (DMZ, guest, second WAN...) is a deployment-specific call.\n\nConfigure each one from the Zones and Interfaces pages once RSG-Web is up." \
        14 76
      clear
      step_info "Detected: ${IFACES} -- none auto-assigned, configure via the web UI"
      ;;

    none)
      step_info "No physical interfaces detected -- nothing to configure"
      ;;
  esac
  sleep 1
}

# ============================================================
# MAIN
# ============================================================
clear
echo -e "${GREEN}"
echo -e "        ${GREEN}Rocky Linux${RESET} ${CYAN}RSG-WEB${RESET} ${YELLOW}Rocky Secure Gateway${TEXTRESET}"
echo ""
sleep 1

check_root_and_os
check_and_enable_selinux
install_base_packages
install_python_packages
deploy_rsg_web
scrape_known_services
remove_firewalld
configure_nftables
configure_selinux_rsgweb
generate_ssl_cert
configure_apache
install_rsg_service
configure_fail2ban
configure_chrony
install_rsg_update_check
configure_interface_topology

section "Done"
step_ok "RSG-Web installed. Log in at: https://$(hostname -f 2>/dev/null || hostname)/"
step_info "Default username: root (Rocky Linux system login, verified via PAM)"
step_info "Installer logs: ${LOGDIR}"
