#!/usr/bin/env bash
# Usage:
#   ./mirror-images.sh export   # on a machine WITH internet -> generates ./images/*.tar
#   ./mirror-images.sh import   # on a machine with access to Harbor (after: skopeo login harbor...)
# Requires: skopeo
set -euo pipefail

HARBOR="harbor.example.com"
DIR="./images"
CERTDIR=""            # directory with Harbor's CA (ca.crt) if it is not in the system

# --- Adjust before use ---------------------------------------------------
RUNNER_VER="17.6.0"
K8S_TAG="CAMBIAR"     # alpine/k8s tag with kubectl 1.35/1.36, e.g. 1.36.0
NODE_TAG="22-alpine"  # the one the development team uses
# -----------------------------------------------------------------------------

# source | destination (without the destination registry)
IMAGES=(
  "docker.io/gitlab/gitlab-runner:alpine-v${RUNNER_VER}|ci/gitlab-runner:alpine-v${RUNNER_VER}"
  "docker.io/gitlab/gitlab-runner-helper:x86_64-v${RUNNER_VER}|ci/gitlab-runner-helper:x86_64-v${RUNNER_VER}"
  "docker.io/library/alpine:3.20|base/alpine:3.20"
  "docker.io/alpine/k8s:${K8S_TAG}|ci/helm-kubectl:${K8S_TAG}"
  "gcr.io/kaniko-project/executor:v1.23.2-debug|ci/kaniko:v1.23.2-debug"
  "docker.io/library/node:${NODE_TAG}|base/node:${NODE_TAG}"
  "docker.io/library/nginx:1.27-alpine|base/nginx:1.27-alpine"
)

[[ "$K8S_TAG" != "CAMBIAR" ]] || { echo "Set K8S_TAG in the script"; exit 1; }
mkdir -p "$DIR"
fname() { echo "$DIR/$(echo "$1" | tr '/:' '__').tar"; }

case "${1:-}" in
  export)
    for pair in "${IMAGES[@]}"; do
      src="${pair%%|*}"; dst="${pair##*|}"
      echo ">> export $src"
      skopeo copy --override-os linux --override-arch amd64 \
        "docker://$src" "oci-archive:$(fname "$dst"):$dst"
    done
    ;;
  import)
    for pair in "${IMAGES[@]}"; do
      dst="${pair##*|}"
      echo ">> import $HARBOR/$dst"
      skopeo copy ${CERTDIR:+--dest-cert-dir "$CERTDIR"} \
        "oci-archive:$(fname "$dst"):$dst" "docker://$HARBOR/$dst"
    done
    ;;
  *) echo "Usage: $0 export|import"; exit 1 ;;
esac
