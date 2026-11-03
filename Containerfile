# Sealed target: choose the content stage with SEALED_FROM.
#   observability:sealed  ->  --target sealed (SEALED_FROM=observability, default)
#   nginx:sealed          ->  --target sealed --build-arg SEALED_FROM=nginx
ARG SEALED_FROM=observability

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
ARG PROMETHEUS_VERSION=3.4.0
WORKDIR /tmp
# Install Prometheus with standalone binary
RUN curl -OL https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
RUN tar -xvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz && \
    mkdir /etc/prometheus && \
    mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/ && \
    mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
    COPY observability/prometheus/prometheus.yml /etc/prometheus
    COPY observability/prometheus/prometheus.service /etc/systemd/system
    RUN systemctl enable prometheus
# Install Loki & Grafana
# The default system CA trust store works fine; do NOT pin sslcacert to
# /etc/pki/tls/certs/ca-bundle.crt. That classic Fedora symlink does not
# exist in the fedora-bootc base image, so dnf fails with curl error 77
# ("error adding trust anchors from file: ...") when fetching the grafana
# repo metadata. Omitting sslcacert lets dnf/curl use the system default
# bundle (extracted by ca-certificates at /etc/pki/ca-trust/extracted/pem/).
RUN curl -LO https://rpm.grafana.com/gpg.key && \
    rpm --import gpg.key && \
    echo -e '[grafana]\nname=grafana\nbaseurl=https://rpm.grafana.com\nrepo_gpgcheck=0\nenabled=1\ngpgcheck=1\ngpgkey=https://rpm.grafana.com/gpg.key\nsslverify=1' | sudo tee /etc/yum.repos.d/grafana.repo
RUN dnf install loki grafana -y
COPY observability/loki/config.yml /etc/loki
RUN systemctl enable loki.service
RUN bootc container lint

# This image builds on observability and adds a user-level quadlet for Nginx
# and a system-level quadlet for Pi-Hole in one image
FROM observability AS nginx
COPY nginx/nginx.container /usr/share/containers/systemd
COPY nginx/nginx.conf /etc/nginx
COPY pihole/* /etc/containers/systemd
# Disable systemd-resolved to not conflict on port 53 for pihole
RUN systemctl disable systemd-resolved.service
RUN bootc container lint
# ---------------------------------------------------------------------------
# Sealed variants: UKI + composefs + fs-verity + Secure Boot (docs/sealed.md)
#
#   observability:sealed  ->  --target sealed  (SEALED_FROM=observability, default)
#   nginx:sealed          ->  --target sealed --build-arg SEALED_FROM=nginx
#
# Requires build secrets: secureboot_key (db.key), secureboot_cert (db.crt).
# `./build.py seal --image nginx-sealed` supplies them from target/keys.
# ---------------------------------------------------------------------------
FROM ${SEALED_FROM} AS seal-prep
# Newest bootc + UKI toolchain; systemd-boot replaces bootupd/GRUB.
# If (and only if) bootc actually changed, the initramfs MUST be regenerated
# with the new bootc dracut modules before the UKI is built from it (bootc
# docs: "Upgrading from bootc 1.16").
RUN set -eux; \
    prev_bootc=$(rpm -q bootc); \
    dnf -y update bootc; \
    dnf -y install systemd-boot-unsigned systemd-ukify sbsigntools fsverity-utils binutils; \
    dnf -y remove bootupd; \
    dnf clean all; \
    cur_bootc=$(rpm -q bootc); \
    if [ "$prev_bootc" != "$cur_bootc" ]; then \
        kver=$(ls /usr/lib/modules); \
        echo "bootc changed ($prev_bootc -> $cur_bootc): regenerating initramfs for $kver"; \
        dracut --force --no-hostonly "/usr/lib/modules/${kver}/initramfs.img" "${kver}"; \
    else \
        echo "bootc unchanged ($cur_bootc): keeping compose-time initramfs"; \
    fi

# Install-time config baked into the sealed tree: ext4 root (fs-verity),
# console kargs for the signed UKI cmdline, and the public Secure Boot
# enrollment blobs. bootc copies secureboot-keys/auto/*.auth to the ESP;
# systemd-boot auto-enrolls them on first boot when the firmware is in
# Setup Mode inside a VM.
COPY sealed/00-ext4-default.toml /usr/lib/bootc/install/00-ext4-default.toml
COPY sealed/kargs.d/ /usr/lib/bootc/kargs.d/
COPY keys/auth/auto/ /usr/lib/bootc/install/secureboot-keys/auto/
# Mark the image as composefs-native: this is the default config path the
# initramfs's initramfs-setup reads when booting with `composefs=` on the
# cmdline, and its presence makes bootc select the composefs backend at
# install time independently of UKI detection.
COPY sealed/setup-root-conf.toml /usr/lib/composefs/setup-root-conf.toml
# /var/lib directories the quadlets bind-mount (the scrub below empties /var,
# so systemd-tmpfiles recreates them each boot), and the composefs fix for the
# ostree-only condition on bootc-fetch-apply-updates.
COPY sealed/tmpfiles.d/ /usr/lib/tmpfiles.d/
COPY sealed/timer-dropin/ /etc/systemd/system/

# Tries to write /boot at first boot, which is read-only on sealed images
RUN systemctl mask systemd-tpm2-setup.service

# Sign systemd-boot in place. Private key arrives via build secret and never
# lands in a layer. Must happen BEFORE the composefs digest is computed.
RUN --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    set -eux; \
    /usr/lib/systemd/systemd-sbsign sign \
        --private-key /run/secrets/secureboot_key \
        --certificate /run/secrets/secureboot_cert \
        --output /tmp/systemd-bootx64.efi.signed \
        /usr/lib/systemd/boot/efi/systemd-bootx64.efi; \
    mv /tmp/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi

# The F44 base ships a pre-composed ~2 GB ostree deployment under /sysroot
# that must not be part of the sealed tree; scrub /var + /tmp so the tree is
# effectively empty at seal time (keeps bootc's var lints happy). Directories
# themselves are kept so first boot finds them pre-labeled.
RUN set -eux; \
    rm -rf /sysroot/ostree; \
    find /var/log /var/lib /var/cache /tmp -mindepth 1 -delete; \
    { find /run -mindepth 1 -delete 2>/dev/null || true; }; \
    for f in /etc/hostname /etc/resolv.conf; do \
        if [ -f "$f" ] && [ ! -s "$f" ]; then rm -f "$f"; fi; \
    done

# Split the kernel and initramfs out of the tree that gets sealed. ukify embeds
# both inside the signed UKI, so leaving the originals in /usr/lib/modules
# duplicates ~130 MB in every sealed image, in the composefs object store of
# every deployment, and in every update pull.
RUN bootc container split-kernel-and-rootfs --rootfs / --output /kernel

# The tree that actually ships: seal-prep minus the split kernel/initramfs.
FROM seal-prep AS seal-tree
RUN rm -rf /kernel

# Flatten to a single layer so the composefs digest cannot depend on how
# layers happen to stack at pull time.
FROM scratch AS seal-flat
COPY --from=seal-tree / /

# Compute the composefs digest of the flattened tree, assemble the UKI with
# the digest (+ kargs.d) on the kernel cmdline, and sign it with the db key.
FROM seal-prep AS seal-uki
RUN --mount=type=bind,from=seal-flat,target=/target \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    set -eux; \
    kver=$(ls /kernel); \
    mkdir -p /out/boot/EFI/Linux; \
    bootc container ukify --rootfs /target --kernel-dir "/kernel/${kver}" -- \
        --signtool systemd-sbsign \
        --secureboot-private-key /run/secrets/secureboot_key \
        --secureboot-certificate /run/secrets/secureboot_cert \
        --no-sign-kernel \
        --output "/out/boot/EFI/Linux/${kver}.efi"; \
    ls -lh /out/boot/EFI/Linux/; \
    bootc container lint --rootfs /target --fatal-warnings --skip buildah-injected

# Final sealed image: flattened tree + signed UKI under /boot (not covered by
# the digest) + the signed systemd-boot (already inside the flat tree).
FROM seal-flat AS sealed
COPY --from=seal-uki /out/boot /boot
LABEL containers.bootc 1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
