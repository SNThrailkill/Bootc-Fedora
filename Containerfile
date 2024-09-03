FROM quay.io/fedora/fedora-bootc:40 as base

# Copy over the creds needed for future bootc updates
COPY ./auth.json /etc/ostree/auth.json

# Enable the simple "automatic update containers" timer for both quadlets and os updates
RUN systemctl enable podman-auto-update.timer
RUN systemctl enable bootc-fetch-apply-updates.timer

# Install base packages
RUN dnf install cloud-init distrobox qemu-guest-agent \
    cockpit cockpit-bridge cockpit-files cockpit-ostree cockpit-storaged cockpit-podman \
    nfs-utils libnfsidmap sssd-nfs-idmap \
    nmap \
    -y
RUN dnf clean all

# Enable Cockpit
RUN systemctl enable cockpit.socket

# Nginx + Pihole as quadlets
# Pihole has to run as rootful container so we copy it 
# to the system folder instead of user like nginx
FROM base as nginx
COPY nginx/* /usr/share/containers/systemd
COPY pihole/* /etc/containers/systemd
# Disable systemd-resolved to not conflict on port 53
RUN systemctl disable systemd-resolved.service
RUN systemctl stop systemd-resolved

FROM base as k3s-agent
# Enable ports necessary
RUN firewall-cmd --permanent --add-port=10250/tcp
RUN firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
RUN firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
RUN curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent --server https://k3s.example.com --token mypassword" sh -s -

FROM k3s-agent as k3s-server

RUN firewall-cmd --permanent --add-port=6443/tcp
RUN firewall-cmd --permanent --add-port=2379/tcp
RUN firewall-cmd --permanent --add-port=2380/tcp
