# Bootc Examples

This repo contains some examples of how someone can use bootable containers to deploy a wide variety of applications. 
The base images in this repo are based off the [Fedora bootc image](https://quay.io/repository/fedora/fedora-bootc?tab=tags). 
All images come with `distrobox`, `cloud-init`, and `cockpit`. 
These images assume you are using `cloud-init`, `kickstart`, or similar tool to provision your hosts with things like desired hostnames, IP addresses, etc during initial boot.

The `Containerfile` contains multiple stages that can be used to get exactly the software you need. See [Multi-stage Builds](https://docs.docker.com/build/building/multi-stage/) documentation for more information on how this works. For this repo, the image tag is the same as the build target name.

The GitHub Actions and Containerfile has support for private registry/repository if you uncomment the applicable lines.

The GitHub Actions also will create a [SBOM](https://anchore.com/sbom/what-is-an-sbom/) of your image using [Syft](https://github.com/anchore/syft/), run a vulnerbility scan using [Grype](https://github.com/anchore/grype/), and upload the report to your Code Scanning page in the Security center of your repository. This will only work if your repo has Code Scanning enabled for your repository. [See the GitHub docs](https://docs.github.com/en/code-security/code-scanning/introduction-to-code-scanning/about-code-scanning) for which repos can enable this.

## Build locally

The examples build with podman (or docker) and Python 3.9+. `build.py` is the
single source of truth for the image list, so the same commands run locally and
in CI. `just` recipes are a convenience wrapper.

```bash
./build.py doctor
./build.py images
./build.py build --image nginx --tag demo
./build.py shell --image nginx --tag demo
```

`./build.py matrix` prints the image matrix as JSON. The GitHub Actions workflow
still lists its jobs explicitly for now; the matrix is the hand-off point for
the CI port.

### Sealed images (demo)

The `sealed` target builds a content stage with a signed UKI, a composefs root
and fs-verity. The demo uses a throwaway key hierarchy so attendees do not need
to manage Secure Boot keys:

```bash
./build.py keygen --demo
./build.py seal --image nginx-sealed --tag demo
./build.py verify --image nginx-sealed --tag demo
```

`keygen --demo` writes `target/keys/` (gitignored). Never commit `db.key`. For
a Secure Boot VM boot, add `--with-auth` to generate the UEFI enrollment blobs
as well.

- In CI, add the db private key as `SECUREBOOT_DB_KEY`: a GitHub Actions
  repository secret, or a masked/protected GitLab CI/CD variable.
- The public certificate (`keys/db.crt`) and the `.auth` enrollment blobs are
  safe to commit; the private key is not.
- The default sealed variant is `SEALED_FROM=observability`; the `nginx-sealed`
  entry in `build.py` uses `SEALED_FROM=nginx`.

See [docs/sealed.md](docs/sealed.md) for the chain and the demo runbook.

## K3S
This image simply installs k3s on our base image. Meant to be used as either server or agent.

## NAS
CentOS Stream 10 bootc image with OpenZFS (Stream 9 remains available via
`BASE_IMAGE` for x86-64-v2 hosts). The ZFS kernel modules are compiled in a
throwaway builder against the exact kernel the final image ships, and the
kernel is tracked from the CentOS Stream `kernel-devel` repo, so a base-image
bump picks up the matching kernel automatically. Only the compiled modules and
ZFS userspace cross into the final image; `dkms`, `gcc` and `kernel-devel` stay
in the builder.

```bash
./build.py build --image nas --tag demo
```

Notes: Secure Boot must be off, or the module must be signed with an enrolled
MOK key; ZFS userspace is copied from a manifest and is not RPM-owned, so
package/SBOM tracking will not list it. See [docs/nas.md](docs/nas.md) for the
kernel-pinning and Stream 9 rationale.

## Nginx
This runs as a quadlet and is configured by the `nginx.conf` which is placed in the `/etc/nginx` folder.

## Pihole
This quadlet will work out of the box but because there's no way to include secrets as part of the quadlet definition you will have to `podman exec` into the pod and change the password manually by running `pihole -a -p` to set a password. This is a one time operation.

## Prometheus
This image installs [Promethus](https://prometheus.io/docs/introduction/overview/) on the host itself instead of using a container. Useful as a base image so observability comes baked into all your systems!