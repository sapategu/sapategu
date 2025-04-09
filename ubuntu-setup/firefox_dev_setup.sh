#!/usr/bin/env bash
set -euo pipefail

# Constants
readonly FIREFOX_DEV_URL="https://download.mozilla.org/?product=firefox-devedition-latest-ssl&os=linux64&lang=en-US"
readonly FIREFOX_INSTALL_DIR="/opt/firefox-dev"
readonly FIREFOX_DESKTOP_FILE="$HOME/.local/share/applications/firefox-dev.desktop"
readonly FIREFOX_TAR_FILE="$HOME/Downloads/firefox-dev.tar.xz"
readonly APPARMOR_PROFILE="/etc/apparmor.d/firefox-dev"
readonly DEPENDENCIES=("gum" "wget" "tar")
readonly GUM_VERSION_REQUIRED="0.14.5"

# Colors for UI styling (customize as desired)
readonly CLR_SCS="#16FF15"
readonly CLR_INF="#0095FF"
readonly CLR_BG="#131313"
readonly CLR_PRI="#6B30DA"
readonly CLR_ERR="#FB5854"
readonly CLR_WRN="#FFDA33"
readonly CLR_LGT="#F9F5E2"

sudo_pass=""

# Spinner style(s)
readonly SPINNERS=("meter" "line" "dot" "minidot" "jump" "pulse" "points" "globe" "moon" "monkey" "hamburger")
readonly SPINNER="${SPINNERS[0]}"

# --------------------- Utility Functions ---------------------

spinner() {
  local title="$1"
  local command="$2"
  local chars="|/-\\"
  local i=0

  if command -v gum &>/dev/null; then
    gum spin --spinner "$SPINNER" \
      --spinner.foreground="$CLR_SCS" \
      --title "$(gum style --bold "$title")" \
      -- bash -c "$command"
  else
    printf "%s " "$title"
    bash -c "$command" & local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      printf "\r%s %c" "$title" "${chars:i++%${#chars}}"
      sleep 0.1
    done
    printf "\r\033[K"
  fi
}

logg() {
  local TYPE="$1"
  local MSG="$2"
  local SYMBOL="" COLOR="" LABEL="" BGCOLOR="" FG=""
  if command -v gum &>/dev/null; then
    case "$TYPE" in
      error)   SYMBOL="\n ✖"; COLOR="$CLR_ERR"; LABEL=" ERROR "; BGCOLOR="$CLR_ERR"; FG="--foreground=$CLR_BG" ;;
      info)    SYMBOL=" »";  COLOR="$CLR_INF" ;;
      prompt)  SYMBOL=" ▶";  COLOR="$CLR_PRI" ;;
      success) SYMBOL=" ✔";  COLOR="$CLR_SCS" ;;
      warn)    SYMBOL="\n ◆"; COLOR="$CLR_WRN"; LABEL=" WARNING "; BGCOLOR="$CLR_WRN"; FG="--foreground=$CLR_BG" ;;
      *)       echo "$MSG"; return ;;
    esac
    gum style "$(gum style --foreground="$COLOR" "$SYMBOL") \
               $(gum style --bold ${BGCOLOR:+--background="$BGCOLOR"} ${FG:-} "${LABEL:-}") \
               $(gum style "$MSG")"
  else
    echo "${TYPE^^}: $MSG"
  fi
}

sudo_please() {
  while true; do
    if [[ -z "$sudo_pass" ]]; then
      if command -v gum &>/dev/null; then
        sudo_pass=$(gum input --password \
          --placeholder "Please enter your 'sudo' password: " \
          --header=" 🛡️  Let's keep things secure. " \
          --header.foreground="$CLR_LGT" \
          --header.background="$CLR_PRI" \
          --prompt="🗝️  ")
      else
        read -rsp "Please enter your 'sudo' password: " sudo_pass
        echo
      fi
    fi
    if echo "$sudo_pass" | sudo -S -k true &>/dev/null; then
      break
    else
      logg error "Incorrect password. Try again."
      sudo_pass=""
    fi
  done
}

check_dependencies() {
  spinner "Checking dependencies..." "sleep 1"
  local missing_packages=()
  for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      missing_packages+=("$dep")
    fi
  done
  # Check gum version if installed
  if command -v gum &>/dev/null; then
    local gum_installed_version
    gum_installed_version=$(gum --version 2>/dev/null || true)
    if [[ "$gum_installed_version" != "$GUM_VERSION_REQUIRED" ]]; then
      logg warn "Detected gum version $gum_installed_version; expected $GUM_VERSION_REQUIRED (proceeding but styling may differ)."
    fi
  else
    missing_packages+=("gum")
  fi
  if ((${#missing_packages[@]} > 0)); then
    logg prompt "Installing missing packages: ${missing_packages[*]}"
    sudo_please
    spinner "Installing dependencies" "echo \"$sudo_pass\" | sudo -S apt update -y && sudo -S apt install -y ${missing_packages[*]}"
  fi
  logg success "All required dependencies are installed!"
}

# --------------------- AppArmor Configuration ---------------------
configure_apparmor() {
  logg prompt "Setting up AppArmor configuration for Firefox Developer Edition..."
  sudo_please
  if ! systemctl is-active --quiet apparmor; then
    logg warn "AppArmor is not active. Enabling and starting the service..."
    spinner "Enabling and starting AppArmor" "sudo -S <<< \"$sudo_pass\" systemctl enable apparmor && sudo -S <<< \"$sudo_pass\" systemctl start apparmor"
    logg success "AppArmor service started and enabled."
  fi
  # Use printf via sudo to create the profile. Update the profile name and paths accordingly.
  sudo -S <<< "$sudo_pass" bash -c "printf 'abi <abi/4.0>,\ninclude <tunables/global>\n\nprofile firefox-dev \"%s\" flags=(unconfined) {\n  userns,\n  include if exists <local/firefox>\n}\n' \"$FIREFOX_INSTALL_DIR/firefox/firefox\" > \"$APPARMOR_PROFILE\""
  if spinner "Applying AppArmor profile" "sleep 2 && sudo -S <<< \"$sudo_pass\" apparmor_parser -r \"$APPARMOR_PROFILE\""; then
    logg success "AppArmor profile successfully applied!"
  else
    logg error "Couldn't apply AppArmor profile. Check your system configuration."
  fi
}

# --------------------- Firefox Developer Edition Installation ---------------------

download_firefox_dev() {
  logg prompt "Starting Firefox Developer Edition download..."
  mkdir -p "$(dirname "$FIREFOX_TAR_FILE")"
  rm -f "$FIREFOX_TAR_FILE"
  if ! spinner "Downloading Firefox Developer Edition..." "wget -O \"$FIREFOX_TAR_FILE\" --show-progress \"$FIREFOX_DEV_URL\""; then
    logg error "Failed to download Firefox Developer Edition from $FIREFOX_DEV_URL"
    exit 1
  fi
  logg success "Downloaded archive to: $FIREFOX_TAR_FILE"
}

extract_firefox_dev() {
  logg prompt "Extracting the Firefox Developer Edition archive..."
  sudo_please
  spinner "Removing old installation" "echo \"$sudo_pass\" | sudo -S rm -rf \"$FIREFOX_INSTALL_DIR\""
  spinner "Creating installation directory" "echo \"$sudo_pass\" | sudo -S mkdir -p \"$FIREFOX_INSTALL_DIR\""
  if ! spinner "Extracting tar.xz file" "echo \"$sudo_pass\" | sudo -S tar -xf \"$FIREFOX_TAR_FILE\" -C \"$FIREFOX_INSTALL_DIR\""; then
    logg error "Failed to extract the archive."
    exit 1
  fi
  spinner "Setting permissions" "echo \"$sudo_pass\" | sudo -S chmod -R a+rx \"$FIREFOX_INSTALL_DIR\""
  logg success "Extraction complete! The package is located in $FIREFOX_INSTALL_DIR"
}

create_firefox_launcher() {
  logg prompt "Creating a desktop launcher for Firefox Developer Edition..."
  local exec_path="$FIREFOX_INSTALL_DIR/firefox/firefox"
  local icon_path="$FIREFOX_INSTALL_DIR/firefox/browser/chrome/icons/default/default128.png"
  spinner "Generating .desktop file" "sleep 1 && cat <<EOF > \"$FIREFOX_DESKTOP_FILE\"
[Desktop Entry]
Name=Firefox Developer Edition
Exec=$exec_path %u
Terminal=false
Icon=$icon_path
Type=Application
Categories=Network;WebBrowser;
StartupNotify=true
Comment=Firefox Developer Edition Browser
MimeType=text/html;text/xml;application/xhtml_xml;
EOF
"
  chmod +x "$FIREFOX_DESKTOP_FILE" || true
  if command -v gio &>/dev/null; then
    spinner "Marking launcher as trusted" "gio set \"$FIREFOX_DESKTOP_FILE\" \"metadata::trusted\" true || true"
  fi
  logg success "Desktop launcher created: $FIREFOX_DESKTOP_FILE"
  logg info "To have it appear in your application menu, run:
    update-desktop-database ~/.local/share/applications
  or log out and back in."
}

add_firefox_cli_command() {
  logg prompt "Adding 'firefox-dev' CLI command (symlink) to /usr/local/bin..."
  sudo_please
  spinner "Linking command" "echo \"$sudo_pass\" | sudo -S ln -sf \"$FIREFOX_INSTALL_DIR/firefox/firefox\" /usr/local/bin/firefox-dev"
  logg success "You can now launch Firefox Developer Edition by typing: firefox-dev"
}

# --------------------- Uninstallation Function ---------------------
check_local_installation() {
  local found=false
  if [[ -d "$FIREFOX_INSTALL_DIR" ]]; then
    found=true
  fi
  if [[ -f "$FIREFOX_DESKTOP_FILE" ]]; then
    found=true
  fi
  if [[ -L "/usr/local/bin/firefox-dev" ]]; then
    found=true
  fi
  if [[ -d "$HOME/.mozilla" ]]; then
    found=true
  fi
  echo "$found"
}

uninstall_firefox_dev() {
  logg prompt "Are you sure you want to uninstall Firefox Developer Edition and remove your ~/.mozilla directory? (y/n)"
  if command -v gum &>/dev/null; then
    if ! gum confirm --affirmative="Yes" --negative="No" "This will remove the installation, desktop launcher, CLI symlink, and your entire ~/.mozilla directory. Continue?"; then
      logg info "Uninstallation cancelled."
      exit 0
    fi
  else
    read -rp "Are you sure you want to uninstall Firefox Developer Edition and remove ~/.mozilla? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      logg info "Uninstallation cancelled."
      exit 0
    fi
  fi

  if [[ "$(check_local_installation)" == "false" ]]; then
    logg info "No Firefox Developer Edition installation or related files were found."
    exit 0
  fi

  sudo_please
  spinner "Removing installation directory" "echo \"$sudo_pass\" | sudo -S rm -rf \"$FIREFOX_INSTALL_DIR\""
  spinner "Removing desktop launcher" "rm -f \"$FIREFOX_DESKTOP_FILE\""
  spinner "Removing CLI symlink" "echo \"$sudo_pass\" | sudo -S rm -f /usr/local/bin/firefox-dev"
  if [[ -d "$HOME/.mozilla" ]]; then
    spinner "Removing ~/.mozilla directory" "rm -rf \"$HOME/.mozilla\""
    logg success "~/.mozilla directory has been removed."
  else
    logg info "~/.mozilla directory not found; nothing to remove."
  fi

  logg success "Firefox Developer Edition has been fully uninstalled."
}

# --------------------- Main ---------------------

main_install() {
  check_dependencies
  download_firefox_dev
  extract_firefox_dev
  create_firefox_launcher
  add_firefox_cli_command
  configure_apparmor
  logg success "Installation of Firefox Developer Edition is complete!"
  logg info "Type 'firefox-dev' to launch the browser or use the desktop launcher."
}

# If the first argument is "uninstall", run the uninstallation function.
if [[ "${1:-}" == "uninstall" ]]; then
  uninstall_firefox_dev
else
  main_install
fi