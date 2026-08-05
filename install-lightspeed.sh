#!/usr/bin/env bash
# Build and deploy the OpenShift Lightspeed operator.
#
# Builds the operator image from source, pushes to the internal registry,
# deploys via upstream kustomize (make deploy), and configures the LLM
# provider via ols-configure-llm.sh.
#
# Env:
#   LIGHTSPEED_DIR       (default: ../lightspeed-operator)
#   AGENTIC_NAMESPACE    (default: openshift-lightspeed)
#   SKIP_BUILD           If set, use pre-built images
#   BUILD_ONLY           Build image locally only (no deploy)
#   LLM_PROVIDER         Provider flag for ols-configure-llm.sh (default: --vertex-anthropic)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Build and deploy the OpenShift Lightspeed operator.

Usage:
  ./install-lightspeed.sh
  SKIP_BUILD=1 ./install-lightspeed.sh
  BUILD_ONLY=1 ./install-lightspeed.sh

Environment variables:
  LIGHTSPEED_DIR         Path to source (default: ../lightspeed-operator)
  AGENTIC_NAMESPACE      Namespace (default: openshift-lightspeed)
  SKIP_BUILD             Skip image build, use pre-built images
  BUILD_ONLY             Build image locally only (no push, no deploy)
  LLM_PROVIDER           Provider flag for OLS LLM config (default: --vertex-anthropic)
                         Options: --openai, --vertex-anthropic, --vertex-google
EOF
}
lib::parse_args "$@"
lib::subheading "Lightspeed Operator"

LIGHTSPEED_DIR=$(lib::resolve_sibling LIGHTSPEED_DIR lightspeed-operator) || {
    lib::log_error "lightspeed-operator source not found. Set LIGHTSPEED_DIR or clone lightspeed-operator next to this repo."
    exit 1
}
lib::log_success "Source: ${LIGHTSPEED_DIR}"

OPERATOR_IMAGE=""

# -- Build operator image (unless SKIP_BUILD) ----------------------------------

if [[ -z "${SKIP_BUILD:-}" ]]; then
    lib::step "Building lightspeed-operator from source..."
    if [[ -n "${BUILD_ONLY:-}" ]]; then
        OPERATOR_IMAGE=$(lib::build_local "lightspeed-operator" "${LIGHTSPEED_DIR}" "Dockerfile")
    else
        lib::setup_registry
        lib::ensure_namespace
        OPERATOR_IMAGE=$(lib::build_and_push "lightspeed-operator" "${LIGHTSPEED_DIR}" "Dockerfile")
        lib::ensure_pull_secret "${AGENTIC_NAMESPACE}" "lightspeed-operator-controller-manager"
    fi
    lib::log_success "Operator image: ${OPERATOR_IMAGE}"
else
    lib::step "Skipping build (SKIP_BUILD set)"
fi

if [[ -n "${BUILD_ONLY:-}" ]]; then
    lib::log_info "BUILD_ONLY set — skipping deploy"
    printf '%s' "${OPERATOR_IMAGE}"
    exit 0
fi

# -- Deploy via make deploy ----------------------------------------------------

lib::step "Deploying lightspeed-operator (make deploy)..."

DEPLOY_IMG="${OPERATOR_IMAGE}"
if [[ -z "${DEPLOY_IMG}" ]]; then
    DEPLOY_IMG="${_INTERNAL_REGISTRY:-image-registry.openshift-image-registry.svc:5000}/${AGENTIC_NAMESPACE}/lightspeed-operator:dev"
    lib::log_info "Using default in-cluster image: ${DEPLOY_IMG}"
fi

(
    cd "${LIGHTSPEED_DIR}"
    make deploy IMG="${DEPLOY_IMG}" KUBECTL=oc
) >&2

lib::step "Waiting for lightspeed-operator..."
lib::wait_for_deployment "lightspeed-operator-controller-manager"

# -- Configure OLS LLM --------------------------------------------------------

LLM_PROVIDER="${LLM_PROVIDER:---vertex-anthropic}"

lib::step "Configuring OLS LLM provider..."
"${SCRIPT_DIR}/ols-configure-llm.sh" "${LLM_PROVIDER}"

# -- Patch sandbox image (if custom-built) ------------------------------------

if [[ -n "${SANDBOX_IMAGE:-}" ]]; then
    lib::step "Patching controller-manager with custom sandbox image..."
    oc patch deployment lightspeed-operator-controller-manager \
        -n "${AGENTIC_NAMESPACE}" --type=json -p "[
        {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",
         \"value\":\"--agentic-sandbox-image=${SANDBOX_IMAGE}\"}
      ]"
    lib::wait_for_deployment "lightspeed-operator-controller-manager"
    lib::log_success "Controller-manager patched with sandbox image: ${SANDBOX_IMAGE}"
fi

lib::log_success "Lightspeed operator deployed and configured"
