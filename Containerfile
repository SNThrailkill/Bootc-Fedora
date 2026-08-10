FROM quay.io/fedora/fedora-bootc:44 AS base

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

# Enable Podman and Cockpit sockets
RUN systemctl enable podman.socket
RUN systemctl enable cockpit.socket
RUN bootc container lint


FROM base AS observability
WORKDIR /tmp
# Install Alloy for sending metrics and logs to Prometheus
COPY observability/alloy/alloy.container /etc/containers/systemd
COPY observability/alloy/containers.alloy observability/alloy/linux.alloy /etc/alloy/
# Create dir to use to mount into container
RUN mkdir /var/lib/alloy
RUN bootc container lint

FROM observability AS prometheus
WORKDIR /tmp
# Install Prometheus with standalone binary
RUN curl -OL https://github.com/prometheus/prometheus/releases/download/v3.4.0/prometheus-3.4.0.linux-amd64.tar.gz
RUN tar -xvf prometheus-3.4.0.linux-amd64.tar.gz && \
    mkdir /etc/prometheus && \
    mv prometheus-3.4.0.linux-amd64/prometheus /usr/local/bin/ && \
    mv prometheus-3.4.0.linux-amd64/promtool /usr/local/bin/
    COPY observability/prometheus/prometheus.yml /etc/prometheus
    COPY observability/prometheus/prometheus.service /etc/systemd/system
    RUN systemctl enable prometheus
# Install Loki
# Refresh base packages and (re)extract the TLS CA bundle before adding the
# grafana repo. dnf's librepo fails with curl error 77 ("error adding trust
# anchors from file: /etc/pki/tls/certs/ca-bundle.crt") when that bundle is
# missing/empty in the bootc build container. Updating ca-certificates runs its
# %post (update-ca-trust), and we call update-ca-trust explicitly too so the
# bundle is repopulated even when ca-certificates is already current. This must
# run before the grafana repo is configured, otherwise dnf tries to refresh
# grafana's repo metadata against the broken bundle and fails the same way.
RUN dnf update -y && update-ca-trust
RUN curl -LO https://rpm.grafana.com/gpg.key && \
    rpm --import gpg.key && \
    echo -e '[grafana]\nname=grafana\nbaseurl=https://rpm.grafana.com\nrepo_gpgcheck=0\nenabled=1\ngpgcheck=1\ngpgkey=https://rpm.grafana.com/gpg.key\nsslverify=1\nsslcacert=/etc/pki/tls/certs/ca-bundle.crt' | sudo tee /etc/yum.repos.d/grafana.repo
RUN dnf install loki grafana -y
COPY observability/loki/config.yml /etc/loki
RUN systemctl enable loki.service
RUN bootc container lint

# This image builds on observaility and combines a user-level quadlet for Nginx and a system-level quadlet for Pi-Hole in one image
FROM observability AS nginx
COPY nginx/nginx.container /usr/share/containers/systemd
COPY nginx/nginx.conf /etc/nginx
COPY pihole/* /etc/containers/systemd
# Disable systemd-resolved to not conflict on port 53 for pihole
RUN systemctl disable systemd-resolved.service
RUN bootc container lint