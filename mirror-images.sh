#!/usr/bin/env bash
# Uso:
#   ./mirror-images.sh export   # en una máquina CON internet -> genera ./images/*.tar
#   ./mirror-images.sh import   # en una máquina con acceso a Harbor (tras: skopeo login harbor...)
# Requiere: skopeo
set -euo pipefail

HARBOR="harbor.stic.intranet.net"
DIR="./images"
CERTDIR=""            # directorio con la CA de Harbor (ca.crt) si no está en el sistema

# --- Ajustar antes de usar ---------------------------------------------------
RUNNER_VER="17.6.0"
K8S_TAG="CAMBIAR"     # tag de alpine/k8s con kubectl 1.35/1.36, p. ej. 1.36.0
NODE_TAG="22-alpine"  # el que use el equipo de desarrollo
# -----------------------------------------------------------------------------

# origen | destino (sin el registro de destino)
IMAGES=(
  "docker.io/gitlab/gitlab-runner:alpine-v${RUNNER_VER}|ci/gitlab-runner:alpine-v${RUNNER_VER}"
  "docker.io/gitlab/gitlab-runner-helper:x86_64-v${RUNNER_VER}|ci/gitlab-runner-helper:x86_64-v${RUNNER_VER}"
  "docker.io/library/alpine:3.20|base/alpine:3.20"
  "docker.io/alpine/k8s:${K8S_TAG}|ci/helm-kubectl:${K8S_TAG}"
  "gcr.io/kaniko-project/executor:v1.23.2-debug|ci/kaniko:v1.23.2-debug"
  "docker.io/library/node:${NODE_TAG}|base/node:${NODE_TAG}"
  "docker.io/library/nginx:1.27-alpine|base/nginx:1.27-alpine"
)

[[ "$K8S_TAG" != "CAMBIAR" ]] || { echo "Define K8S_TAG en el script"; exit 1; }
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
  *) echo "Uso: $0 export|import"; exit 1 ;;
esac
