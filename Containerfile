FROM quay.io/fedora/fedora-bootc:41 AS base

# Enable the simple "automatic update containers" timer for both quadlets and os updates
RUN systemctl enable podman-auto-update.timer
RUN systemctl enable bootc-fetch-apply-updates.timer

# Install base packages
RUN dnf install git cloud-init distrobox qemu-guest-agent \ 
    cockpit-system cockpit-ws cockpit-files cockpit-networkmanager cockpit-ostree cockpit-selinux cockpit-storaged cockpit-podman \
    nfs-utils libnfsidmap sssd-nfs-idmap \
    zsh \ 
    -y
RUN dnf clean all

# Change default shell to zsh
RUN chsh -s $(which zsh)
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Enable Cockpit
RUN systemctl enable cockpit.socket

# Nginx as quadlet
FROM base AS nginx
COPY nginx/nginx.container /usr/share/containers/systemd
COPY nginx/nginx.conf /etc/nginx

# Pihole as a rootful quadlet
# Pihole has to run as rootful container so we copy it 
# to the system folder instead of user like nginx
FROM base AS pihole
COPY pihole/* /etc/containers/systemd
# Disable systemd-resolved to not conflict on port 53 for pihole
RUN systemctl disable systemd-resolved.service
