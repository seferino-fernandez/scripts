#!/bin/bash
#
# Bootstraps a fresh Debian server.
#
# This script is idempotent and can be run multiple times safely. It performs the following actions:
#   - Installs required packages.
#   - Configures system locale to en_US.UTF-8 and timezone to UTC.
#   - Configures the UFW firewall, Fail2Ban, and Unattended Upgrades.
#   - Creates a new non-root user for SSH access.
#   - Configures passwordless sudo for the new user.
#   - Adds a specified public SSH key for both root and the new user.
#   - Secures the SSH daemon by disabling password authentication.

# Abort on any error, unbound variable, or pipeline failure.
set -euo pipefail

# --- Configuration ---

# The username for the new non-root user.
readonly NEW_USER="NEW_USER"

# The public SSH key to be added for both root and the new user.
# IMPORTANT: Replace the placeholder with your actual public SSH key.
readonly AUTHORIZED_SSH_KEY="ssh-rsa AAAA... user@example.com"

# The script's log file.
# The filename is made unique for each run by including the script's base name,
# a timestamp, and the script's Process ID ($$).
# e.g., /tmp/bootstrap-debian_20250719_154830_12345.log
LOG_FILE="/tmp/$(basename "${BASH_SOURCE[0]%.*}")_$(date +'%Y%m%d_%H%M%S')_$$.log"

# --- Logging Functions ---

# Function to print info messages to stderr and a log file.
log_info() {
  echo "INFO[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" | tee -a "${LOG_FILE}" >&2
}

# Function to print error messages to stderr and a log file.
log_error() {
  echo "❌ ERROR[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" | tee -a "${LOG_FILE}" >&2
}

# --- Setup Functions ---

# Installs required packages.
install_software() {
  log_info "Updating package information..."
  if ! apt-get update; then
    log_error "Failed to update package lists."
    exit 1
  fi

  log_info "Upgrading distribution..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y; then
    log_error "Failed to upgrade distribution."
    exit 1
  fi

  log_info "Upgrading existing packages..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
    log_error "Failed to upgrade packages."
    exit 1
  fi

  log_info "Installing essential system packages..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y locales vim zsh curl fail2ban ufw unattended-upgrades apt-listchanges apt-transport-https ca-certificates; then
    log_error "Failed to install essential packages."
    exit 1
  fi
}

# Configures the system locale and timezone.
configure_system_locale_and_timezone() {
    log_info "Configuring system locale to en_US.UTF-8..."
    # Uncomment the en_US.UTF-8 locale in the generation file.
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
    # Generate the locale.
    if ! locale-gen; then
        log_error "Failed to generate locales."
        exit 1
    fi
    # Set the system-wide locale.
    if ! update-locale LANG=en_US.UTF-8; then
        log_error "Failed to update system locale."
        exit 1
    fi
    log_info "System locale set to en_US.UTF-8."

    log_info "Configuring system timezone to UTC..."
    if ! timedatectl set-timezone UTC; then
        log_error "Failed to set timezone to UTC."
        exit 1
    fi
    log_info "System timezone set to UTC."
}

# Creates the new user and grants passwordless sudo.
create_and_configure_user() {
  if id "${NEW_USER}" &>/dev/null; then
    log_info "User '${NEW_USER}' already exists. Skipping creation."
  else
    log_info "Creating user '${NEW_USER}'..."
    if ! useradd -m -s /bin/zsh "${NEW_USER}"; then
      log_error "Failed to create user '${NEW_USER}'."
      exit 1
    fi
    log_info "User '${NEW_USER}' created."

    log_info "Locking password for '${NEW_USER}' to enforce key-based SSH."
    log_info ""
    log_info "*** ${NEW_USER}'s PASSWORD ***\n"
    if ! passwd -l "${NEW_USER}"; then
      log_error "Failed to lock password for '${NEW_USER}'."
      exit 1
    fi
    log_info "*** *** ***"
  fi

  log_info "Configuring passwordless sudo for '${NEW_USER}'..."
  local -r sudoers_file="/etc/sudoers.d/${NEW_USER}-nopasswd"
  echo "${NEW_USER} ALL=(ALL) NOPASSWD: ALL" | (EDITOR="tee" visudo -f "${sudoers_file}")
  log_info "Passwordless sudo configured for '${NEW_USER}'."
}

# Adds the authorized SSH key for a specified user.
# Arguments:
#   $1: The username (e.g., 'root' or 'NEW_USER')
#   $2: The user's home directory (e.g., '/root' or '/home/NEW_USER')
add_ssh_key_for_user() {
    local -r user="$1"
    local -r home_dir="$2"
    local -r ssh_dir="${home_dir}/.ssh"
    local -r auth_keys_file="${ssh_dir}/authorized_keys"

    log_info "Configuring SSH key for user '${user}'..."

    if ! [ -d "${ssh_dir}" ]; then
        log_info "Creating .ssh directory for ${user}..."
        mkdir -p "${ssh_dir}"
    fi

    # Check if the key already exists to ensure idempotency.
    if grep -qF "${AUTHORIZED_SSH_KEY}" "${auth_keys_file}" 2>/dev/null; then
        log_info "SSH key already exists for '${user}'. Skipping."
    else
        log_info "Adding SSH key to ${auth_keys_file}..."
        echo "${AUTHORIZED_SSH_KEY}" >> "${auth_keys_file}"
    fi

    # Set correct permissions and ownership.
    log_info "Setting permissions for ${user}'s .ssh directory..."
    chmod 700 "${ssh_dir}"
    chmod 600 "${auth_keys_file}"
    chown -R "${user}:${user}" "${ssh_dir}"
}


# Configures Uncomplicated Firewall (UFW) with basic rules.
configure_ufw() {
  log_info "Configuring firewall (ufw)..."
  ufw default deny
  ufw allow ssh
  ufw limit ssh
  ufw --force enable
  log_info "Firewall (ufw) configured and enabled."
  log_info "UFW status: $(ufw status)"
}

# Configures Fail2Ban with a local jail for SSH.
configure_fail2ban() {
  log_info "Configuring fail2ban..."
  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Ban for 1 day
bantime  = 1d
# Find 3 failures within 10 minutes
findtime = 10m
maxretry = 3

[sshd]
enabled = true
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  log_info "Fail2Ban configured and restarted."
}

# Configures unattended-upgrades for automatic security updates.
configure_unattended_upgrades() {
  log_info "Configuring unattended-upgrades..."
  # This file enables the periodic jobs.
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  # This file configures what gets updated and other behaviors.
  cat >/etc/apt/apt.conf.d/50unattended-upgrades <<EOF
// Automatically upgrade packages from these origin patterns
Unattended-Upgrade::Origins-Pattern {
      "origin=Debian,codename=\${distro_codename},label=Debian";
      "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
      "origin=Debian,codename=\${distro_codename}-updates,label=Debian";
};

// Other settings for good hygiene and stability
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF

  log_info "Unattended upgrades configured."
}

# Configures SSH daemon for enhanced security.
configure_secure_ssh() {
  log_info "Configuring and securing SSH daemon (sshd)..."
  local -r ssh_config_dir="/etc/ssh/sshd_config.d"
  local -r ssh_config_file="${ssh_config_dir}/99-${NEW_USER}-defaults.conf"

  if [ -f "$ssh_config_file" ]; then
    log_info "SSH security configuration already exists. Skipping."
  else
    log_info "Creating SSH security configuration at $ssh_config_file"
    mkdir -p "$ssh_config_dir"
    cat >"$ssh_config_file" <<EOF
# --- Custom SSH security settings ---
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
EOF
  fi

  log_info "Testing SSH configuration..."
  if ! sshd -t; then
    log_error "SSH configuration test failed. Review settings in '$ssh_config_file'."
    rm -f "$ssh_config_file" # Clean up bad config
    exit 1
  fi

  log_info "Reloading SSH service to apply changes..."
  if ! systemctl reload-or-restart sshd; then
    log_error "Failed to reload SSH service. Check 'systemctl status sshd'."
    exit 1
  fi

  log_info "SSH secured successfully."
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root. Please use sudo."
    exit 1
  fi

  if [[ "${NEW_USER}" == "NEW_USER" ]]; then
      log_error "Placeholder user detected. Please edit the script and update the name in the 'NEW_USER' variable."
      exit 1
  fi

  if [[ "${AUTHORIZED_SSH_KEY}" == "ssh-rsa AAAA... user@example.com" ]]; then
      log_error "Placeholder SSH key detected. Please edit the script and add your public key to the 'AUTHORIZED_SSH_KEY' variable."
      exit 1
  fi

  log_info "Debian server bootstrap script started. Logging to: ${LOG_FILE}"

  install_software
  configure_system_locale_and_timezone
  create_and_configure_user
  add_ssh_key_for_user "root" "/root"
  add_ssh_key_for_user "${NEW_USER}" "/home/${NEW_USER}"
  configure_ufw
  configure_fail2ban
  configure_unattended_upgrades
  configure_secure_ssh

  log_info "✅ ✅ ✅"
  log_info "------------------------------------------------------------------"
  log_info "Debian server bootstrap completed, output logged to: ${LOG_FILE}"
  log_info ""
  log_info "System configured with:"
  log_info "  - Updated system packages."
  log_info "  - Locale set to en_US.UTF-8 and timezone to UTC."
  log_info "  - UFW Firewall, Fail2Ban, and Unattended Upgrades enabled."
  log_info "  - User '${NEW_USER}' created with passwordless sudo."
  log_info "  - SSH key added for 'root' and '${NEW_USER}'."
  log_info "  - SSH secured (public key authentication required)."
  log_info ""
  log_info "You should now be able to SSH into the server as 'root' or '${NEW_USER}' using your key."
  log_info "Consider rebooting ('sudo reboot') to apply any kernel updates and for all locale changes to take effect."
  log_info "------------------------------------------------------------------"
}

main "$@"
