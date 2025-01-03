FROM quay.io/fedora/fedora-bootc:41 AS base

# Enable the simple "automatic update containers" timer for both quadlets and os updates
RUN systemctl enable podman-auto-update.timer
RUN systemctl enable bootc-fetch-apply-updates.timer

# Install base packages
RUN dnf install cloud-init distrobox qemu-guest-agent \
    cockpit-system cockpit-ws cockpit-files cockpit-networkmanager cockpit-ostree cockpit-selinux cockpit-storaged cockpit-podman \
    nfs-utils libnfsidmap sssd-nfs-idmap \
    -y
RUN dnf clean all

# Enable Cockpit
RUN systemctl enable cockpit.socket

# Nginx as quadlet
FROM base AS nginx
COPY nginx/* /usr/share/containers/systemd

# Pihole as a rootful quadlet
# Pihole has to run as rootful container so we copy it 
# to the system folder instead of user like nginx
FROM base as pihole
COPY pihole/* /etc/containers/systemd
# Disable systemd-resolved to not conflict on port 53 for pihole
RUN systemctl disable systemd-resolved.service
