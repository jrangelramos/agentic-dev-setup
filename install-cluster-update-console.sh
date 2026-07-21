#!/usr/bin/env bash
# Build and deploy the cluster-update-console-plugin.
#
# This is a standalone OpenShift console plugin (not managed by the agentic
# operator), deployed via its Helm chart.
#
# Env:
#   CLUSTER_UPDATE_DIR   (default: ../cluster-update-console-plugin)
#   AGENTIC_NAMESPACE    (default: openshift-lightspeed)
#   SKIP_BUILD           If set, skip image build
#   CLUSTER_UPDATE_IMAGE Override image (skip build)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Build and deploy the cluster-update-console-plugin.

Usage:
  ./install-cluster-update-console.sh
  BUILD_ONLY=1 ./install-cluster-update-console.sh

Environment variables:
  CLUSTER_UPDATE_DIR     Path to source (default: ../cluster-update-console-plugin)
  CLUSTER_UPDATE_IMAGE   Override image (skip build)
  AGENTIC_NAMESPACE      Namespace (default: openshift-lightspeed)
  SKIP_BUILD             Skip image build
  BUILD_ONLY             Build image locally only (no push, no deploy, no cluster needed)
EOF
}
lib::parse_args "$@"

CLUSTER_UPDATE_DIR=$(lib::resolve_sibling CLUSTER_UPDATE_DIR cluster-update-console-plugin) || {
    lib::log_error "cluster-update-console-plugin source not found. Set CLUSTER_UPDATE_DIR or clone it next to this repo."
    exit 1
}

PLUGIN_NAME="cluster-update-console-plugin"
CHART_DIR="${CLUSTER_UPDATE_DIR}/charts/openshift-console-plugin"

if [[ -z "${BUILD_ONLY:-}" ]]; then
    if [[ ! -d "${CHART_DIR}" ]]; then
        lib::log_error "Helm chart not found at ${CHART_DIR}"
        exit 1
    fi
    lib::require_cmd helm
fi

# -- Build image ---------------------------------------------------------------

if [[ -z "${SKIP_BUILD:-}" && -z "${CLUSTER_UPDATE_IMAGE:-}" ]]; then
    lib::log_step "1/2" "Building cluster-update-console-plugin..."
    if [[ -n "${BUILD_ONLY:-}" ]]; then
        CLUSTER_UPDATE_IMAGE=$(lib::build_local "${PLUGIN_NAME}" "${CLUSTER_UPDATE_DIR}" "Dockerfile")
    else
        lib::setup_registry
        CLUSTER_UPDATE_IMAGE=$(lib::build_and_push "${PLUGIN_NAME}" "${CLUSTER_UPDATE_DIR}" "Dockerfile")
    fi
else
    lib::log_step "1/2" "Skipping build"
    CLUSTER_UPDATE_IMAGE="${CLUSTER_UPDATE_IMAGE:-quay.io/openshift/${PLUGIN_NAME}:latest}"
fi

lib::log_success "Image: ${CLUSTER_UPDATE_IMAGE}"

if [[ -n "${BUILD_ONLY:-}" ]]; then
    lib::log_info "BUILD_ONLY set — skipping deploy"
    exit 0
fi

# -- Deploy via Helm -----------------------------------------------------------

lib::log_step "2/2" "Deploying via Helm chart..."

# Clean up orphaned resources from a previous partial install.
# Deployment selectors are immutable so it must be deleted for Helm to recreate it.
# Other resources are adopted in place via Helm ownership labels.
if ! helm status "${PLUGIN_NAME}" -n "${AGENTIC_NAMESPACE}" >/dev/null 2>&1; then
    oc delete deployment "${PLUGIN_NAME}" -n "${AGENTIC_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    for kind in sa service configmap consoleplugin; do
        oc label "${kind}" "${PLUGIN_NAME}" -n "${AGENTIC_NAMESPACE}" \
            app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
        oc annotate "${kind}" "${PLUGIN_NAME}" -n "${AGENTIC_NAMESPACE}" \
            meta.helm.sh/release-name="${PLUGIN_NAME}" \
            meta.helm.sh/release-namespace="${AGENTIC_NAMESPACE}" \
            --overwrite 2>/dev/null || true
    done
fi

echo helm upgrade --install "${PLUGIN_NAME}" "${CHART_DIR}" \
    --namespace "${AGENTIC_NAMESPACE}" \
    --create-namespace \
    --set plugin.name="${PLUGIN_NAME}" \
    --set plugin.image="${CLUSTER_UPDATE_IMAGE}" \
    --set plugin.imagePullPolicy=Always

helm upgrade --install "${PLUGIN_NAME}" "${CHART_DIR}" \
    --namespace "${AGENTIC_NAMESPACE}" \
    --create-namespace \
    --set plugin.name="${PLUGIN_NAME}" \
    --set plugin.image="${CLUSTER_UPDATE_IMAGE}" \
    --set plugin.imagePullPolicy=Always

# Force pod rollout so new images are pulled even when the tag hasn't changed.
oc rollout restart deployment/"${PLUGIN_NAME}" -n "${AGENTIC_NAMESPACE}"

lib::wait_for_deployment "${PLUGIN_NAME}" "${AGENTIC_NAMESPACE}" "120s" || true
lib::log_success "cluster-update-console-plugin deployed"
