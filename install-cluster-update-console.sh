#!/usr/bin/env bash
# Build the cluster-update-console-plugin image and push to the OpenShift
# internal registry.  Deployment is handled by the CVO agenticrun controller
# (not by this script).  The CVO reads the image reference from its embedded
# image-references; see install-cvo.sh for how that is wired up.
#
# The image is pushed to the "openshift-cluster-update-console-plugin"
# namespace (matching the CVO's bindata assets), NOT to AGENTIC_NAMESPACE.
#
# Env:
#   CLUSTER_UPDATE_DIR   (default: ../cluster-update-console-plugin)
#   SKIP_BUILD           If set, skip image build
#   CLUSTER_UPDATE_IMAGE Override image (skip build)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

PLUGIN_NAME="cluster-update-console-plugin"
PLUGIN_NAMESPACE="openshift-cluster-update-console-plugin"

usage() {
    cat <<EOF
Build the cluster-update-console-plugin image and push to the internal registry.
Deployment is deferred to the CVO agenticrun controller.

Usage:
  ./install-cluster-update-console.sh
  BUILD_ONLY=1 ./install-cluster-update-console.sh

Environment variables:
  CLUSTER_UPDATE_DIR     Path to source (default: ../cluster-update-console-plugin)
  CLUSTER_UPDATE_IMAGE   Override image (skip build)
  SKIP_BUILD             Skip image build
  BUILD_ONLY             Build image locally only (no push, no cluster needed)
EOF
}
lib::parse_args "$@"
lib::dev_disclaimer
lib::subheading "Cluster Update Console Plugin"

CLUSTER_UPDATE_DIR=$(lib::resolve_sibling CLUSTER_UPDATE_DIR cluster-update-console-plugin) || {
    lib::log_error "cluster-update-console-plugin source not found. Set CLUSTER_UPDATE_DIR or clone it next to this repo."
    exit 1
}

# -- Build image ---------------------------------------------------------------

if [[ -n "${SKIP_BUILD:-}" && -n "${CLUSTER_UPDATE_IMAGE:-}" ]]; then
    lib::log_info "SKIP_BUILD set — using provided CLUSTER_UPDATE_IMAGE"
elif [[ -n "${SKIP_BUILD:-}" ]]; then
    lib::log_info "SKIP_BUILD set — skipping cluster-update-console-plugin build"
    exit 0
elif [[ -n "${CLUSTER_UPDATE_IMAGE:-}" ]]; then
    lib::log_info "CLUSTER_UPDATE_IMAGE provided — skipping build"
elif [[ -n "${BUILD_ONLY:-}" ]]; then
    CLUSTER_UPDATE_IMAGE=$(lib::build_local "${PLUGIN_NAME}" "${CLUSTER_UPDATE_DIR}" "Dockerfile")
else
    lib::step "Setting up registry..."
    lib::setup_registry "${PLUGIN_NAMESPACE}"

    lib::step "Building and pushing ${PLUGIN_NAME}..."
    local_tag="${_REGISTRY}/${PLUGIN_NAMESPACE}/${PLUGIN_NAME}:dev"
    podman build -t "${local_tag}" -f "${CLUSTER_UPDATE_DIR}/Dockerfile" "${CLUSTER_UPDATE_DIR}" >&2
    oc create imagestream "${PLUGIN_NAME}" -n "${PLUGIN_NAMESPACE}" >/dev/null 2>&1 || true
    podman push --tls-verify=false "${local_tag}" >&2

    CLUSTER_UPDATE_IMAGE="image-registry.openshift-image-registry.svc:5000/${PLUGIN_NAMESPACE}/${PLUGIN_NAME}:dev"
    lib::log_success "${PLUGIN_NAME} → ${CLUSTER_UPDATE_IMAGE}"

    # Grant image-puller so CVO-deployed pods can pull from this namespace.
    lib::step "Granting image-puller access..."
    oc policy add-role-to-group system:image-puller \
        "system:serviceaccounts:${PLUGIN_NAMESPACE}" -n "${PLUGIN_NAMESPACE}" >&2
    lib::log_success "image-puller granted to ${PLUGIN_NAMESPACE} serviceaccounts"
fi

lib::log_success "Image: ${CLUSTER_UPDATE_IMAGE}"

if [[ -n "${BUILD_ONLY:-}" ]]; then
    lib::log_info "BUILD_ONLY set — skipping deploy (deploy is handled by CVO)"
    exit 0
fi

lib::log_info "Deployment is handled by the CVO agenticrun controller."
lib::log_info "Run install-cvo.sh to build a dev CVO that references this image."

echo "${CLUSTER_UPDATE_IMAGE}"
