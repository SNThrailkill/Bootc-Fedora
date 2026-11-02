# Local build helpers. The real logic lives in build.py so the same commands
# run here, in GitHub Actions and in GitLab CI.
set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Check podman/docker, disk space and (later) sealed-image prerequisites
doctor:
    ./build.py doctor

# List the image table: name, Containerfile target, CI membership
images:
    ./build.py images

# Build one image locally, e.g. `just build nginx demo`
build image="base" tag="demo":
    ./build.py build --image {{image}} --tag {{tag}}

# Open a shell in a built image, e.g. `just shell nginx demo`
shell image="base" tag="demo":
    ./build.py shell --image {{image}} --tag {{tag}}

# Print the image matrix that CI consumes
matrix:
    ./build.py matrix

# Golden tests for the image table and matrix shape
test:
    python3 -m unittest discover -s tests -v

# Sealed images are stage 2. The commands will be:
#   ./build.py keygen --demo
#   ./build.py seal --image nginx
#   ./build.py verify --image nginx
#
# Demo keys live in target/keys/ and are gitignored. Never commit db.key.
# In CI, add the db private key as a secret:
#   GitHub Actions: SECUREBOOT_DB_KEY repository secret
#   GitLab CI:      SECUREBOOT_DB_KEY masked + protected CI/CD variable
