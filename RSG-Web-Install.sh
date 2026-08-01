#!/usr/bin/env bash
# RSG-WEB Installer -- Rocky Secure Gateway (nftables-only firewall appliance)
# Requires: Rocky Linux 10.0+, run as root
#
# Not standalone -- run via RSG-Web-Installer.sh, or directly from
# inside a full clone/release tarball of the repo (deploy_rsg_web()
# below expects api/ and ui/ as subdirectories, and this script,
# RSG-Web-Installer.sh, and VERSION sitting flat, all alongside itself
# under SRC_BASE, as a fallback if the release tarball download fails).
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

# Absolute path to this script -- used to re-invoke ourselves from
# /root/.bash_profile after a reboot triggered by a static IP change
# below, regardless of whether we were launched from the bootstrap
# clone (/root/RSG-WebInstaller/installer/...) or directly from an
# already-extracted release tarball (/opt/rsg-web/installer/...).
SCRIPT_PATH="$(readlink -f "$0")"

# Written by configure_interface_topology_prompt() once all day-one
# interface/addressing/NTP questions have been asked -- both marks that
# step done (so a reboot-and-resume triggered by a static IP change
# skips straight past the questions instead of re-prompting) and records
# which case/interfaces were chosen, as TOPO_CASE/TOPO_IFACE/TOPO_INSIDE/
# TOPO_OUTSIDE shell variables, for configure_interface_topology_apply()
# to `source` and act on later, once RSG-Web is actually deployed and
# api/zones_apply.py exists to import.
TOPOLOGY_STATE_FILE="/etc/rsg-web-installer/topology-state.env"
# Marks configure_interface_topology_apply() as already run, so it isn't
# re-applied if this script is somehow re-invoked after that point.
TOPOLOGY_APPLY_MARKER="/etc/rsg-web-installer/.topology-applied"
# Set to 1 by prompt_iface_addressing() below if any interface was moved
# to a static IP -- signals configure_interface_topology_prompt() to
# reboot once all topology questions have been answered.
STATIC_IP_CONFIGURED=0
# Set to 1 by prompt_iface_addressing() below if ANY interface's
# addressing was changed at all (static or DHCP) -- staged via `nmcli
# con mod` only, never applied live with `nmcli con up`, so a reboot is
# what actually brings up the new addressing. This is also what
# triggers the reboot (broader than STATIC_IP_CONFIGURED, which only
# covers the static case) -- see the RADS-web precedent this is ported
# from, which never brings a changed connection up live either, only
# via reboot, specifically so a change to the interface carrying the
# operator's own SSH/console session doesn't disconnect them mid-prompt
# with no warning.
NETWORK_CHANGED=0
# Human-readable lines (dialog "\n"-joined) describing what changed on
# each interface, built up by prompt_iface_addressing() below, so the
# pre-reboot dialog can tell the operator exactly where to reconnect.
RECONNECT_INFO=""

# =============================================================
# OUTPUT HELPERS
# =============================================================
step_ok()   { echo -e "  [${GREEN}✓${TEXTRESET}] $*"; }
step_fail() { echo -e "  [${RED}✗${TEXTRESET}] $*"; }
step_info() { echo -e "  [${YELLOW}→${TEXTRESET}] $*"; }
section()   { echo ""; echo -e "${CYAN}── $* ──${TEXTRESET}"; }

# =============================================================
# VALIDATION HELPERS
# =============================================================
validate_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; }
validate_ip()   { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
# Plain hostname or FQDN -- RSG isn't AD-domain-joined like RADS-web, so
# this is deliberately looser than RADS's validate_fqdn() (no forced
# multi-label host.domain.tld requirement, no domain-membership check).
validate_hostname_format() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; }

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
# STEP -- HOSTNAME, ported from RADS-web's validate_and_set_hostname().
# Only prompts if the hostname is still Rocky's default unconfigured
# value -- once set, this check is naturally false on any later
# re-invocation (e.g. after the interface-topology reboot/resume above),
# so no separate marker/skip-state is needed the way the topology step
# needs one.
# =============================================================
validate_and_set_hostname() {
  section "Hostname"
  local current; current=$(hostname)
  if [[ "$current" == "localhost.localdomain" || "$current" == "localhost" ]]; then
    local NEW_HOSTNAME
    while true; do
      NEW_HOSTNAME=$(dialog --backtitle "RSG-WEB Installer" --title "Set Hostname" \
        --inputbox "Current hostname is '${current}'.\nEnter a hostname for this appliance (e.g., rsg-gw or gw1.example.com):" \
        9 70 3>&1 1>&2 2>&3)
      clear
      if validate_hostname_format "$NEW_HOSTNAME"; then
        hostnamectl set-hostname "$NEW_HOSTNAME"
        step_ok "Hostname set to: ${NEW_HOSTNAME}"
        break
      else
        dialog --msgbox "Invalid hostname. Use letters, digits, hyphens, and dots only." 6 60
        clear
      fi
    done
  else
    step_ok "Hostname: ${current}"
  fi
  sleep 1
}

# =============================================================
# STEP 7 -- SYSTEM UPGRADE (dnf, ported from RADS-web)
# =============================================================
run_system_upgrade() {
  section "System Upgrade"
  local log="$LOGDIR/system-upgrade.log"; : > "$log"
  step_info "Checking for available updates..."
  local PIPE; PIPE=$(mktemp -u); mkfifo "$PIPE"
  mapfile -t PACKAGE_LIST < <(dnf -q repoquery --upgrades --qf '%{name}' 2>/dev/null | sort -u)
  local TOTAL=${#PACKAGE_LIST[@]}
  if [[ $TOTAL -eq 0 ]]; then
    step_ok "System already up to date"
    rm -f "$PIPE"; sleep 1; return
  fi
  clear
  dialog --backtitle "RSG-WEB Installer" --title "System Upgrade" \
    --gauge "Starting system upgrade..." 10 70 0 < "$PIPE" &
  local COUNT=0
  {
    for PKG in "${PACKAGE_LIST[@]}"; do
      ((COUNT++))
      local PCT=$(( COUNT * 100 / TOTAL ))
      echo "$PCT"; echo "XXX"; echo "Upgrading: $PKG (${COUNT}/${TOTAL})"; echo "XXX"
      dnf -y -q upgrade --color=never --best --allowerasing "$PKG" >>"$log" 2>&1
    done
    echo "100"; echo "XXX"; echo "Upgrade complete."; echo "XXX"
  } > "$PIPE"
  wait; rm -f "$PIPE"
  clear; section "System Upgrade"
  step_ok "System packages upgraded (${TOTAL} packages) -- see ${log}"
  sleep 1
}

# =============================================================
# STEP 8 -- BASE PACKAGES
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

  # nftables is listed first in this list deliberately -- it must land
  # before /etc/nftables/ or /etc/sysconfig/nftables.conf exist (see
  # comment above), and the gauge loop below installs strictly in order.
  local PKGS=(
    nftables
    httpd mod_ssl mod_proxy_html
    python3 python3-pip python3-devel python3-psutil
    policycoreutils-python-utils openssl
    fail2ban chrony bind-utils net-tools wget curl rsync tar gzip
    nano htop at tuned
  )
  local TOTAL=${#PKGS[@]} COUNT=0
  local PIPE; PIPE=$(mktemp -u); mkfifo "$PIPE"
  clear
  dialog --backtitle "RSG-WEB Installer" --title "Installing Base Packages" \
    --gauge "Preparing..." 10 70 0 < "$PIPE" &
  {
    for PKG in "${PKGS[@]}"; do
      ((COUNT++))
      local PCT=$(( COUNT * 100 / TOTAL ))
      echo "$PCT"; echo "XXX"; echo "Installing: $PKG (${COUNT}/${TOTAL})"; echo "XXX"
      dnf -y -q install --color=never --setopt=tsflags=nodocs --setopt=install_weak_deps=False "$PKG" >>"$log" 2>&1
    done
    echo "100"; echo "XXX"; echo "Base packages installed."; echo "XXX"
  } > "$PIPE"
  wait; rm -f "$PIPE"
  clear; section "Base Packages"
  step_ok "Base packages installed (${TOTAL} packages) -- see ${log}"
  sleep 1
}

# =============================================================
# STEP 9 -- PYTHON PACKAGES
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
# STEP -- DEPLOY RSG-WEB APPLICATION (runs late -- see MAIN below.
# Everything that needs api/ or ui/ on disk -- this, the topology
# *apply* step, the known-services scrape, and the SELinux restorecon
# on ui/ -- is grouped together after configure_chrony, once RSG-Web is
# actually deployed.)
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
    # SRC_BASE existing isn't enough -- a `git clone` of an empty/missing
    # repo, or a partial manual copy, still leaves the directory itself
    # in place with nothing useful inside it. Check for the actual
    # source subdirectories the cp commands below depend on *before*
    # running them, so a bad source is caught here with one clear
    # message instead of three silent `cp: cannot stat` lines in this
    # log and a cascade of confusing ModuleNotFoundError/restorecon
    # failures in every step downstream.
    if [[ -d "${SRC_BASE}/api" && -d "${SRC_BASE}/ui" ]]; then
      mkdir -p "$INSTALL_BASE"
      cp -r "${SRC_BASE}/api"       "$INSTALL_BASE/" >>"$log" 2>&1
      cp -r "${SRC_BASE}/ui"        "$INSTALL_BASE/" >>"$log" 2>&1
      # The installer scripts sit flat at SRC_BASE's root (alongside
      # api/, ui/, and VERSION), not in their own installer/ subfolder --
      # only the *deployed* copy at INSTALL_BASE/installer/ is a
      # subdirectory. Copy them there by name instead of expecting a
      # pre-existing SRC_BASE/installer/ to `cp -r`.
      mkdir -p "${INSTALL_BASE}/installer"
      for f in RSG-Web-Install.sh RSG-Web-Installer.sh; do
        [[ -f "${SRC_BASE}/${f}" ]] && cp "${SRC_BASE}/${f}" "${INSTALL_BASE}/installer/" >>"$log" 2>&1
      done
      [[ -d "${SRC_BASE}/upgrade" ]]   && cp -r "${SRC_BASE}/upgrade"   "$INSTALL_BASE/" >>"$log" 2>&1
      [[ -f "${SRC_BASE}/VERSION" ]]   && cp "${SRC_BASE}/VERSION"      "$INSTALL_BASE/" >>"$log" 2>&1
      # Verify the copy actually landed something usable -- cp itself can
      # still fail mid-copy (permissions, disk space) without this
      # function noticing, and everything after this step assumes
      # main.py/index.html are really there.
      if [[ -f "${INSTALL_BASE}/api/main.py" && -f "${INSTALL_BASE}/ui/index.html" ]]; then
        step_ok "Installed from source: ${SRC_BASE}"
      else
        step_fail "Copy from ${SRC_BASE} did not produce a usable install -- see ${log}"
        step_info "Expected ${INSTALL_BASE}/api/main.py and ${INSTALL_BASE}/ui/index.html to exist after copying"
        return 1
      fi
    else
      step_fail "No release tarball and no usable source at ${SRC_BASE} (missing api/ and/or ui/)"
      step_info "If you're testing from a partial checkout, make sure ${SRC_BASE}/api and ${SRC_BASE}/ui are populated"
      step_info "Otherwise: build rsg-web.tar.gz (api/, ui/, installer/, upgrade/, VERSION at its root) and upload it to the GitHub Release fetched from ${TARBALL_URL}"
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
# STEP 5 -- KNOWN-SERVICES CATALOG
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
# STEP 10 -- REMOVE FIREWALLD, GO NFTABLES-ONLY
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
    # firewalld's own backend depends on nftables, and fail2ban pulls in
    # fail2ban-firewalld as a weak dep -- dnf's default "clean up unused
    # dependencies" behavior on a plain `dnf remove firewalld` has been
    # observed taking BOTH nftables and fail2ban down with it (confirmed
    # from a live install log: "Removing dependent packages: fail2ban"
    # and "Removing unused dependencies: nftables..." in the same
    # transaction), which then breaks every later step that assumes
    # either one is still installed. clean_requirements_on_remove=false
    # scopes this removal to firewalld itself, nothing else.
    dnf remove -y firewalld --color=never --setopt=clean_requirements_on_remove=false >>"$log" 2>&1
    step_ok "firewalld disabled, masked, and removed"
  else
    step_ok "firewalld not present -- nothing to remove"
  fi

  # Belt-and-suspenders: reinstall either package if it's somehow still
  # missing after the above (an older dnf, a different removal path,
  # whatever) -- cheap no-op if they're already present.
  if ! command -v nft >/dev/null 2>&1; then
    step_info "nftables missing after firewalld removal -- reinstalling..."
    dnf -y install nftables --color=never >>"$log" 2>&1
    command -v nft >/dev/null 2>&1 \
      && step_ok "nftables reinstalled" \
      || step_fail "nftables reinstall failed -- see ${log}"
  fi
  if ! rpm -q fail2ban >/dev/null 2>&1; then
    step_info "fail2ban missing after firewalld removal -- reinstalling..."
    dnf -y install fail2ban --color=never >>"$log" 2>&1
    rpm -q fail2ban >/dev/null 2>&1 \
      && step_ok "fail2ban reinstalled" \
      || step_fail "fail2ban reinstall failed -- see ${log}"
  fi
  sleep 1
}

# =============================================================
# STEP 11 -- WRITE BASE NFTABLES RULESET
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

  # Defense-in-depth: remove_firewalld() already guards against dnf
  # sweeping nftables away as an "unused dependency" of firewalld, but
  # guard here too in case this function is ever called on its own or
  # the package was removed by some other path.
  if ! command -v nft >/dev/null 2>&1; then
    step_info "nft binary not found -- installing nftables..."
    dnf -y install nftables --color=never >>"$log" 2>&1
    command -v nft >/dev/null 2>&1 || { step_fail "nftables install failed -- see ${log}"; return 1; }
  fi

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
# STEP 12 -- SELINUX FOR RSG-WEB
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
# STEP 13 -- SELF-SIGNED TLS CERTIFICATE
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
# STEP 14 -- APACHE VIRTUALHOST (REVERSE PROXY)
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
# STEP 15 -- RSG-WEB SYSTEMD SERVICE
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
# STEP 16 -- FAIL2BAN
# =============================================================
configure_fail2ban() {
  section "Fail2ban"
  local log="$LOGDIR/fail2ban.log"; : > "$log"

  # Defense-in-depth: remove_firewalld() already guards against dnf
  # sweeping fail2ban away as an "unused dependency" of firewalld, but
  # guard here too in case this function is ever called on its own or
  # the package was removed by some other path.
  if ! rpm -q fail2ban >/dev/null 2>&1; then
    step_info "fail2ban not installed -- installing..."
    dnf -y install fail2ban --color=never >>"$log" 2>&1
    rpm -q fail2ban >/dev/null 2>&1 || { step_fail "fail2ban install failed -- see ${log}"; return 1; }
  fi
  mkdir -p /etc/fail2ban/jail.d

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
# STEP 17 -- TIME SYNC
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
# STEP 18 -- RSG-WEB PLATFORM UPDATE CHECK
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
# INTERFACE ADDRESSING (static IP / DHCP + NTP), ported from
# RADS-web's prompt_static_ip_if_dhcp() / configure_ntp(), adapted
# for RSG's per-role (Inside/Outside) dual-interface topology instead
# of a single AD-DC uplink. Called by configure_interface_topology_prompt()
# below, once per assigned interface.
# =============================================================
get_connection_for_iface() {
  local iface="$1"
  nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$iface" '$2==d{print $1; exit}'
}

apply_ntp_server() {
  local ntp="$1"
  local log="$LOGDIR/chrony.log"; : > "$log"
  [[ -z "$ntp" ]] && return 0
  cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
  sed -i '/^\(server\|pool\)[[:space:]]/d' /etc/chrony.conf
  echo "server ${ntp} iburst" >> /etc/chrony.conf
  systemctl enable --now chronyd >>"$log" 2>&1
  systemctl restart chronyd >>"$log" 2>&1
  step_ok "NTP server set to ${ntp}"
}

prompt_iface_addressing() {
  local iface="$1" role="$2" ask_ntp="${3:-0}"
  local log="$LOGDIR/topology.log"
  local conn; conn=$(get_connection_for_iface "$iface")
  if [[ -z "$conn" ]]; then
    step_fail "No NetworkManager connection found for ${iface} -- skipping addressing prompt (configure manually later)"
    return 1
  fi

  local METHOD
  METHOD=$(dialog --backtitle "RSG-WEB Installer" --title "${role} Interface -- ${iface}" \
    --menu "How should ${iface} (${role}) get its IP address?" \
    12 70 2 \
    "static" "Static IP (recommended for ${role})" \
    "dhcp"   "DHCP (automatic)" \
    3>&1 1>&2 2>&3)
  clear
  if [[ -z "$METHOD" ]]; then
    step_info "${role} (${iface}): no choice made -- leaving current addressing as-is"
  elif [[ "$METHOD" == "dhcp" ]]; then
    # Staged with `nmcli con mod` only -- deliberately NOT brought up live
    # with `nmcli con up` here. If this is the interface carrying the
    # operator's own SSH/console session, bringing it up immediately would
    # disconnect them with zero warning, mid-prompt, before they've even
    # finished answering the rest of the topology questions. The change
    # takes effect on the reboot at the end of
    # configure_interface_topology_prompt(), which warns first.
    nmcli con mod "$conn" ipv4.method auto ipv4.addresses "" ipv4.gateway "" >>"$log" 2>&1
    step_ok "${role} (${iface}): set to DHCP (takes effect after reboot)"
    NETWORK_CHANGED=1
    RECONNECT_INFO="${RECONNECT_INFO}\n${role} (${iface}): DHCP -- check your router/DHCP server for the assigned address"
  else
    local IPADDR GW DNSSERVER
    while true; do
      IPADDR=$(dialog --backtitle "RSG-WEB Installer" --title "${role} -- Static IP" \
        --inputbox "Enter static IP in CIDR format for ${iface} (e.g., 192.168.1.1/24):" \
        9 72 3>&1 1>&2 2>&3)
      clear
      validate_cidr "$IPADDR" && break || dialog --msgbox "Invalid CIDR format. Try again." 6 40
    done
    while true; do
      GW=$(dialog --backtitle "RSG-WEB Installer" --title "${role} -- Gateway" \
        --inputbox "Enter default gateway for ${iface} (leave blank if none, e.g. Outside handed off by an upstream router):" 8 70 3>&1 1>&2 2>&3)
      clear
      { [[ -z "$GW" ]] || validate_ip "$GW"; } && break || dialog --msgbox "Invalid IP. Try again." 6 40
    done
    while true; do
      DNSSERVER=$(dialog --backtitle "RSG-WEB Installer" --title "${role} -- DNS Server" \
        --inputbox "Enter DNS server IP(s) for ${iface}, comma-separated (leave blank to skip):" 9 72 3>&1 1>&2 2>&3)
      clear
      if [[ -z "$DNSSERVER" ]]; then break; fi
      local bad=0 d
      IFS=',' read -ra _dns <<< "$DNSSERVER"
      for d in "${_dns[@]}"; do validate_ip "$(echo "$d" | xargs)" || bad=1; done
      [[ $bad -eq 0 ]] && break || dialog --msgbox "Invalid DNS IP in list. Try again." 6 40
    done

    dialog --backtitle "RSG-WEB Installer" --title "Confirm ${role} Settings" \
      --yesno "Apply these settings to ${iface} (${role})?\n\nIP: ${IPADDR}\nGateway: ${GW:-none}\nDNS: ${DNSSERVER:-none}" \
      12 65
    local confirm=$?
    clear
    if [[ $confirm -ne 0 ]]; then
      step_info "${role} (${iface}): settings not applied (cancelled)"
    else
      local NMARGS=(ipv4.addresses "$IPADDR" ipv4.method manual)
      [[ -n "$GW" ]] && NMARGS+=(ipv4.gateway "$GW")
      [[ -n "$DNSSERVER" ]] && NMARGS+=(ipv4.dns "$DNSSERVER")
      # Staged only, same reasoning as the DHCP branch above -- no
      # `nmcli con up` here. Applying a new static address live would
      # disconnect an SSH/console session on this interface with no
      # warning; the reboot at the end of
      # configure_interface_topology_prompt() is what actually brings
      # this up, after telling the operator exactly where to reconnect.
      nmcli con mod "$conn" "${NMARGS[@]}" >>"$log" 2>&1
      step_ok "${role} (${iface}): static ${IPADDR}${GW:+, gw ${GW}}${DNSSERVER:+, dns ${DNSSERVER}} (takes effect after reboot)"
      STATIC_IP_CONFIGURED=1
      NETWORK_CHANGED=1
      RECONNECT_INFO="${RECONNECT_INFO}\n${role} (${iface}): ${IPADDR%%/*}"
    fi
  fi

  if [[ "$ask_ntp" -eq 1 ]]; then
    local NTPSRV
    NTPSRV=$(dialog --backtitle "RSG-WEB Installer" --title "NTP Server" \
      --inputbox "Enter an NTP server IP or FQDN for this appliance (or press Enter for pool.ntp.org):" \
      8 70 "pool.ntp.org" 3>&1 1>&2 2>&3)
    clear
    [[ -z "$NTPSRV" ]] && NTPSRV="pool.ntp.org"
    apply_ntp_server "$NTPSRV"
  fi
  sleep 1
}

# =============================================================
# STEP 6 -- DAY-ONE INTERFACE TOPOLOGY: PROMPT (asked up front, before
# ANY package installs or deploy -- see MAIN below)
#
# Detects topology directly via nmcli (no python/api dependency -- RSG-
# Web isn't deployed yet at this point in the run) using the same
# physical-ethernet-only filter api/zones_apply.py's
# detect_physical_interfaces() uses, to decide which of three paths
# applies:
#   1 interface  -> auto-assigned to Inside, no prompt, then
#                   prompted for static/DHCP + NTP + DNS
#   2 interfaces -> dialog asks which is Inside; the other becomes
#                   Outside (zero ports open) with NAT/forwarding
#                   wired up automatically. Inside is then prompted
#                   for static/DHCP + NTP + DNS; Outside is prompted
#                   for static/DHCP only.
#   3+ interfaces (or 0) -> nothing auto-assigned; operator is told
#                   what was detected and points to the Zones/
#                   Interfaces pages to finish setup after first boot
#
# This function only asks questions and applies network-level changes
# (nmcli addressing, chrony NTP) -- it does NOT touch nftables zone
# assignment, since that requires api/zones_apply.py, which doesn't
# exist on disk yet. Instead it records the case/interface choice to
# TOPOLOGY_STATE_FILE for configure_interface_topology_apply() (below)
# to actually apply later, once RSG-Web is deployed.
#
# If any interface is set to a static IP below, this function reboots
# the box once all questions are answered (writing a resume hook to
# /root/.bash_profile first so the installer picks back up automatically
# on next login) -- see the end of this function. TOPOLOGY_STATE_FILE
# existing is what makes that resume skip straight past these questions
# instead of re-asking.
# =============================================================
configure_interface_topology_prompt() {
  section "Interface Topology"
  local log="$LOGDIR/topology.log"; : > "$log"

  if [[ -f "$TOPOLOGY_STATE_FILE" ]]; then
    step_ok "Interface topology already configured (resumed after reboot) -- skipping"
    sleep 1
    return 0
  fi

  # Physical ethernet devices only -- same filter as
  # zones_apply.detect_physical_interfaces()/interfaces._list_devices()
  # (type=="ethernet" excludes loopback, RSG's own ifb-* QoS devices,
  # and anything else nmcli reports that isn't a real NIC).
  local -a IFACES_ARR=()
  local _line
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && IFACES_ARR+=("$_line")
  done < <(nmcli -t -f DEVICE,TYPE device status 2>>"$log" | awk -F: '$2=="ethernet"{print $1}')
  local n=${#IFACES_ARR[@]}

  local CASE
  if   [[ $n -eq 0 ]]; then CASE="none"
  elif [[ $n -eq 1 ]]; then CASE="single"
  elif [[ $n -eq 2 ]]; then CASE="dual"
  else CASE="multi"
  fi

  local sel_iface="" sel_inside="" sel_outside=""

  case "$CASE" in
    single)
      sel_iface="${IFACES_ARR[0]}"
      step_info "One interface detected (${sel_iface}) -- will be assigned to Inside once RSG-Web is deployed"
      prompt_iface_addressing "$sel_iface" "Inside" 1
      ;;

    dual)
      local IF_A="${IFACES_ARR[0]}" IF_B="${IFACES_ARR[1]}"
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
        [[ "$INSIDE" == "$IF_A" ]] && sel_outside="$IF_B" || sel_outside="$IF_A"
        sel_inside="$INSIDE"
        step_ok "Inside=${sel_inside}, Outside=${sel_outside} selected -- will be applied once RSG-Web is deployed"
        prompt_iface_addressing "$sel_inside" "Inside" 1
        prompt_iface_addressing "$sel_outside" "Outside" 0
      fi
      ;;

    multi)
      local IFACE_LIST; IFACE_LIST=$(IFS=', '; echo "${IFACES_ARR[*]}")
      dialog --backtitle "RSG-WEB Installer" --title "Multiple Interfaces Detected" \
        --msgbox "Detected: ${IFACE_LIST}\n\nWith 3+ interfaces, zone assignment isn't automatic -- deciding what a 3rd/4th NIC is for (DMZ, guest, second WAN...) is a deployment-specific call.\n\nConfigure each one from the Zones and Interfaces pages once RSG-Web is up." \
        14 76
      clear
      step_info "Detected: ${IFACE_LIST} -- none auto-assigned, configure via the web UI"
      ;;

    none)
      step_info "No physical interfaces detected -- nothing to configure"
      ;;
  esac

  mkdir -p "$(dirname "$TOPOLOGY_STATE_FILE")"
  {
    echo "TOPO_CASE=${CASE}"
    [[ -n "$sel_iface" ]]   && echo "TOPO_IFACE=${sel_iface}"
    [[ -n "$sel_inside" ]]  && echo "TOPO_INSIDE=${sel_inside}"
    [[ -n "$sel_outside" ]] && echo "TOPO_OUTSIDE=${sel_outside}"
  } > "$TOPOLOGY_STATE_FILE"

  if [[ "$NETWORK_CHANGED" -eq 1 ]]; then
    local profile="/root/.bash_profile"
    if ! grep -q "RSG-WEB Installer -- auto-resume after reboot" "$profile" 2>/dev/null; then
      {
        echo '## RSG-WEB Installer -- auto-resume after reboot ##'
        echo 'if [[ $- == *i* ]]; then'
        echo "  bash \"${SCRIPT_PATH}\""
        echo 'fi'
      } >> "$profile"
    fi
    # Nothing above was applied live (see the "takes effect after
    # reboot" notes in prompt_iface_addressing()) -- this reboot is what
    # actually brings the new addressing up, and this is the one and
    # only place the operator is told about it, with exactly where to
    # reconnect, before it happens.
    dialog --backtitle "RSG-WEB Installer" --title "Reboot Required" \
      --msgbox "Interface addressing changed. Nothing was applied live -- the system will reboot now to bring the new addressing up.\n\nReconnect at:${RECONNECT_INFO}\n\nJust log back in as root afterward -- the installer resumes automatically and picks up right where it left off." \
      14 74
    clear
    step_info "Rebooting to apply new network settings -- installer resumes automatically after login..."
    reboot
    exit 0
  fi

  sleep 1
}

# =============================================================
# STEP -- DAY-ONE INTERFACE TOPOLOGY: APPLY (runs late, right after
# deploy_rsg_web() -- see MAIN below)
#
# Reads the case/interface choice configure_interface_topology_prompt()
# recorded in TOPOLOGY_STATE_FILE and actually applies it via
# api/zones_apply.py -- split out from the prompt step because this
# needs RSG-Web already deployed (api/zones_apply.py has to exist on
# disk to import).
# =============================================================
configure_interface_topology_apply() {
  section "Interface Topology -- Apply"
  local log="$LOGDIR/topology.log"

  if [[ -f "$TOPOLOGY_APPLY_MARKER" ]]; then
    step_ok "Interface topology already applied -- skipping"
    sleep 1
    return 0
  fi
  if [[ ! -f "$TOPOLOGY_STATE_FILE" ]]; then
    step_fail "No topology state file at ${TOPOLOGY_STATE_FILE} -- configure_interface_topology_prompt() didn't run? Nothing to apply."
    return 1
  fi

  # shellcheck disable=SC1090
  source "$TOPOLOGY_STATE_FILE"

  case "${TOPO_CASE:-}" in
    single)
      if [[ -z "${TOPO_IFACE:-}" ]]; then
        step_info "Single-interface case recorded with nothing selected -- nothing to apply"
      else
        python3 -c "
import sys
sys.path.insert(0, '${INSTALL_BASE}/api')
import zones_apply as za
ok, msg = za.apply_single_interface_topology('${TOPO_IFACE}')
print(msg)
sys.exit(0 if ok else 1)
" >>"$log" 2>&1
        if [[ $? -eq 0 ]]; then
          step_ok "${TOPO_IFACE} assigned to Inside (level 100)"
        else
          step_fail "Failed to assign ${TOPO_IFACE} -- see ${log}"
        fi
      fi
      ;;

    dual)
      if [[ -z "${TOPO_INSIDE:-}" || -z "${TOPO_OUTSIDE:-}" ]]; then
        step_info "Dual-interface case recorded with no Inside/Outside choice -- nothing to apply"
      else
        python3 -c "
import sys
sys.path.insert(0, '${INSTALL_BASE}/api')
import zones_apply as za
ok, msg = za.apply_dual_interface_topology('${TOPO_INSIDE}', '${TOPO_OUTSIDE}', nat=True)
print(msg)
sys.exit(0 if ok else 1)
" >>"$log" 2>&1
        if [[ $? -eq 0 ]]; then
          step_ok "Inside=${TOPO_INSIDE} / Outside=${TOPO_OUTSIDE} applied, NAT enabled"
        else
          step_fail "Failed to apply topology -- see ${log}"
        fi
      fi
      ;;

    multi|none|"")
      step_info "No auto-assignment needed for this topology -- configure via the web UI if desired"
      ;;
  esac

  mkdir -p "$(dirname "$TOPOLOGY_APPLY_MARKER")"
  touch "$TOPOLOGY_APPLY_MARKER"
  sleep 1
}

# ============================================================
# MAIN
# ============================================================
clear
echo -e "${GREEN}
                               .*((((((((((((((((*
                         .(((((((((((((((((((((((((((/
                      ,((((((((((((((((((((((((((((((((((.
                    (((((((((((((((((((((((((((((((((((((((/
                  (((((((((((((((((((((((((((((((((((((((((((/
                .(((((((((((((((((((((((((((((((((((((((((((((
               ,((((((((((((((((((((((((((((((((((((((((((((((((.
               ((((((((((((((((((((((((((((((/   ,(((((((((((((((
              /((((((((((((((((((((((((((((.        /((((((((((((*
              ((((((((((((((((((((((((((/              ((((((((((
              ((((((((((((((((((((((((                   *((((((/
              /((((((((((((((((((((*                        (((((*
               ((((((((((((((((((             (((*            ,((
               .((((((((((((((.            /(((((((
                 ((((((((((/             (((((((((((((/
                  *((((((.            /((((((((((((((((((.
                    *(*)            ,(((((((((((((((((((((((,
                                 (((((((((((((((((((((((/
                              /((((((((((((((((((((((.
                                ,((((((((((((((,
${RESET}"
echo -e "        ${GREEN}Rocky Linux${RESET} ${CYAN}RSG-WEB${RESET} ${YELLOW}Rocky Secure Gateway${TEXTRESET}"
echo ""
sleep 1

check_root_and_os
check_and_enable_selinux

# Every operator-facing question -- interface topology, static/DHCP
# addressing, gateway, DNS, NTP -- is asked here, first, before any
# package installs or the app deploy run. Nothing later in the install
# needs further interaction. This step is pure bash/nmcli/dialog, no
# dependency on RSG-Web being deployed yet. If a static IP was applied
# to any interface, it reboots the box itself (after writing a
# /root/.bash_profile hook that re-launches this script on next login)
# and does not return from that call in that case.
configure_interface_topology_prompt
validate_and_set_hostname

run_system_upgrade
install_base_packages
install_python_packages
remove_firewalld
configure_nftables
generate_ssl_cert
configure_apache
install_rsg_service
configure_fail2ban
configure_chrony

# Deploy runs last, once the box itself is fully set up -- everything
# below this line depends on RSG-Web actually being on disk (api/, ui/),
# so it's grouped here together: the deploy itself, applying the
# interface topology decisions gathered above (needs api/zones_apply.py
# to import), the SELinux restorecon on ui/ (a no-op earlier since ui/
# didn't exist yet to relabel), the known-services scrape, and the
# platform update-check timer (needs upgrade/update_check.sh).
deploy_rsg_web || {
  step_fail "Deployment failed -- nothing past this point can work without ${INSTALL_BASE}/api and ${INSTALL_BASE}/ui. Aborting."
  exit 1
}
configure_interface_topology_apply
configure_selinux_rsgweb
scrape_known_services
install_rsg_update_check

section "Done"
step_ok "RSG-Web installed. Log in at: https://$(hostname -f 2>/dev/null || hostname)/"
step_info "Default username: root (Rocky Linux system login, verified via PAM)"
step_info "Installer logs: ${LOGDIR}"

# Installer completed in a single boot (or resumed and finished) --
# remove the auto-resume hook so a future manual reboot doesn't
# re-launch the installer, and clear the topology state so a
# from-scratch re-run of this script (e.g. testing) asks the topology
# questions again instead of thinking they're already done.
sed -i '/## RSG-WEB Installer -- auto-resume after reboot ##/,/^fi$/d' /root/.bash_profile 2>/dev/null || true
rm -f "$TOPOLOGY_STATE_FILE" "$TOPOLOGY_APPLY_MARKER" 2>/dev/null || true
