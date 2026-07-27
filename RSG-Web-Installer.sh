#!/usr/bin/env bash
# RSG-WEB Bootstrap Installer
# Rocky Secure Gateway -- nftables-only firewall appliance
# Requires: Rocky Linux 10.0+, run as root
#
# This is the small, standalone entry point -- meant to be fetched on
# its own (curl/wget) before the rest of the repo exists on the box.
# It installs just enough (wget, git, dialog) to clone the real repo,
# then hands off to installer/RSG-Web-Install.sh, which is *not*
# standalone -- it expects to be run from inside a full clone/tarball
# of the repo (it deploys api/ and ui/ from alongside itself).

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
TEXTRESET="\033[0m"
CYAN="\e[36m"
RESET="\e[0m"

clear
echo -e "${CYAN}RSG-WEB${TEXTRESET} ${YELLOW}Bootstrap${TEXTRESET}"

# =============================================================
# ROOT CHECK
# =============================================================
if [[ $EUID -eq 0 ]]; then
  echo -e "  [${GREEN}✓${TEXTRESET}] Running as root"
else
  echo -e "  [${RED}✗${TEXTRESET}] Must be run as root"
  exit 1
fi

# =============================================================
# OS VERSION CHECK  (Rocky 10.0+)
# =============================================================
OSVER_RAW=""
if [[ -f /etc/os-release ]]; then
  OSVER_RAW=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null)
elif [[ -f /etc/redhat-release ]]; then
  OSVER_RAW=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)
fi

if [[ -z "$OSVER_RAW" ]]; then
  echo -e "  [${RED}✗${TEXTRESET}] Unable to detect Rocky Linux version"
  exit 1
fi

OSVER_MAJOR=$(echo "$OSVER_RAW" | awk -F. '{print $1}')
OSVER_MINOR=$(echo "$OSVER_RAW" | awk -F. '{print ($2==""?0:$2)}')

if ! [[ "$OSVER_MAJOR" =~ ^[0-9]+$ ]]; then
  echo -e "  [${RED}✗${TEXTRESET}] Cannot parse OS version: ${OSVER_RAW}"
  exit 1
fi

if (( OSVER_MAJOR >= 10 )); then
  echo -e "  [${GREEN}✓${TEXTRESET}] Rocky Linux ${OSVER_MAJOR}.${OSVER_MINOR} detected"
else
  echo -e "  [${RED}✗${TEXTRESET}] Rocky Linux 10.0+ required (detected: ${OSVER_MAJOR}.${OSVER_MINOR})"
  echo -e "  Please upgrade to ${GREEN}Rocky 10.x${TEXTRESET} or later"
  exit 1
fi

# =============================================================
# INSTALL BOOTSTRAP DEPS
# =============================================================
echo -e "${CYAN}==> Installing bootstrap dependencies...${TEXTRESET}"

spinner() {
  local pid=$1 delay=0.1 spinstr='|/-\'
  while ps -p $pid > /dev/null 2>&1; do
    for i in $(seq 0 3); do
      printf "\r  [${YELLOW}INFO${TEXTRESET}] Installing... ${spinstr:$i:1}"
      sleep $delay
    done
  done
  printf "\r  [${GREEN}✓${TEXTRESET}] Bootstrap packages installed   \n"
}

dnf -y install wget git dialog >/dev/null 2>&1 &
spinner $!

# =============================================================
# CLONE RSG REPO
# =============================================================
echo -e "${CYAN}==> Cloning RSG from GitHub...${TEXTRESET}"

INSTALL_DIR="/root/RSG-WebInstaller"
rm -rf "$INSTALL_DIR"
git clone https://github.com/fumatchu/RSG.git "$INSTALL_DIR" >/dev/null 2>&1

if [[ $? -ne 0 ]]; then
  echo -e "  [${RED}✗${TEXTRESET}] Failed to clone RSG repository"
  echo -e "  Check internet connectivity and try again."
  exit 1
fi

chmod 700 "${INSTALL_DIR}/installer"/*.sh 2>/dev/null || true
echo -e "  [${GREEN}✓${TEXTRESET}] Repository cloned to ${INSTALL_DIR}"

dnf -y remove git >/dev/null 2>&1

# =============================================================
# LAUNCH MAIN INSTALLER
# =============================================================
clear
echo -e "${GREEN}"
echo -e "        ${GREEN}Rocky Linux${RESET} ${CYAN}RSG-WEB${RESET} ${YELLOW}Rocky Secure Gateway -- nftables firewall appliance${TEXTRESET}"
echo ""
sleep 2

INSTALL_CHOICE=$(dialog --backtitle "RSG-WEB Installer" \
  --title "Select Installation Type" \
  --menu "Choose what to install on this appliance:" 12 72 3 \
  1 "Install RSG-Web (fresh firewall appliance)" \
  3>&1 1>&2 2>&3)
DIALOG_RC=$?
clear

if [[ $DIALOG_RC -ne 0 || -z "$INSTALL_CHOICE" ]]; then
  echo -e "  [${YELLOW}→${TEXTRESET}] Installation cancelled."
  exit 1
fi

case "$INSTALL_CHOICE" in
  1)
    bash "${INSTALL_DIR}/installer/RSG-Web-Install.sh"
    ;;
  *)
    echo -e "  [${YELLOW}→${TEXTRESET}] Installation cancelled."
    exit 1
    ;;
esac
