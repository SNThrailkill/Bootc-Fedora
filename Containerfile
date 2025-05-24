FROM quay.io/fedora/fedora-bootc:42 AS base

# Copy any the creds needed for registry auth
# COPY ./auth.json /etc/ostree/auth.json

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

# This image combines a user-level quadlet for Nginx and a system-level quadlet for Pi-Hole in one image
FROM base AS nginx
COPY nginx/nginx.container /usr/share/containers/systemd
COPY nginx/nginx.conf /etc/nginx
COPY pihole/* /etc/containers/systemd
# Disable systemd-resolved to not conflict on port 53 for pihole
RUN systemctl disable systemd-resolved.service
RUN bootc container lint

FROM base AS prometheus
WORKDIR /tmp
# Install Prometheus
RUN curl -OL https://github.com/prometheus/prometheus/releases/download/v3.4.0/prometheus-3.4.0.linux-amd64.tar.gz && \
    tar -xvf prometheus-3.4.0.linux-amd64.tar.gz && \
    mkdir /etc/prometheus && \
    mv prometheus-3.4.0.linux-amd64/prometheus /usr/local/bin/ && \
    mv prometheus-3.4.0.linux-amd64/promtool /usr/local/bin/
COPY prometheus/prometheus.yml /etc/prometheus
COPY prometheus/prometheus.service /etc/systemd/system
RUN systemctl enable prometheus
# Install Node Exporter
RUN curl -OL https://github.com/prometheus/node_exporter/releases/download/v1.9.1/node_exporter-1.9.1.linux-amd64.tar.gz && \
    tar -xvf node_exporter-1.9.1.linux-amd64.tar.gz && \
    mv node_exporter-1.9.1.linux-amd64/node_exporter /usr/local/bin/
COPY prometheus/node_exporter.service /etc/systemd/system
RUN systemctl enable node_exporter
RUN bootc container lint