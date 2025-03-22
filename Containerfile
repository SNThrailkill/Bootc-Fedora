FROM quay.io/fedora/fedora-bootc:41 AS base

# Copy over the creds needed for future bootc updates
COPY ./auth.json /etc/ostree/auth.json

# Enable the simple "automatic update containers" timer for both quadlets and os updates
RUN systemctl enable podman-auto-update.timer
RUN systemctl enable bootc-fetch-apply-updates.timer

# Install base packages
RUN dnf install curl git cloud-init distrobox qemu-guest-agent \ 
    cockpit-system cockpit-ws cockpit-files cockpit-networkmanager cockpit-ostree cockpit-selinux cockpit-storaged cockpit-podman \
    nfs-utils libnfsidmap sssd-nfs-idmap \
    zsh \ 
    -y
RUN dnf clean all

# Enable Cockpit
RUN systemctl enable cockpit.socket
RUN bootc container lint

# My personal LB & DNS
FROM base AS nginx
COPY nginx/nginx.container /usr/share/containers/systemd
COPY nginx/nginx.conf /etc/nginx
COPY pihole/* /etc/containers/systemd
# Disable systemd-resolved to not conflict on port 53 for pihole
RUN systemctl disable systemd-resolved.service
RUN bootc container lint

FROM base AS k3s-agent
RUN dnf install -y https://rpm.rancher.io/k3s/stable/common/coreos/noarch/
RUN --mount=type=secret,id=K3S_TOKEN,env=K3S_TOKEN curl -sfL https://get.k3s.io | K3S_URL=https://10.0.0.6:6443 K3S_TOKEN=${K3S_TOKEN} INSTALL_K3S_SKIP_ENABLE=true sh -
RUN systemctl enable k3s-agent.service