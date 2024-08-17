# In this example, a simple "podman-systemd" unit which runs
# an application container via https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
# that is also configured for automatic updates via
# https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html
FROM quay.io/fedora/fedora-bootc:40
COPY nginx.container /usr/share/containers/systemd

# Enable the simple "automatic update containers" timer, in the same way
# that there is a simplistic bootc upgrade timer.
RUN systemctl enable podman-auto-update.timer

# Enable EPEL
RUN dnf install cloud-init distrobox qemu-guest-agent cockpit cockpit-bridge cockpit-composer cockpit-files cockpit-ostree cockpit-storaged cockpit-podman -y
RUN dnf clean all

# Enable Cockpit
RUN systemctl enable cockpit.socket
