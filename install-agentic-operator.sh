#!/usr/bin/env bash
# Build and deploy the lightspeed-agentic-operator.
#
# Builds the operator image from source, then delegates the actual deployment
# to the upstream quickstart install.sh (CRDs, RBAC, Deployment, webhook, etc.).
# When SKIP_BUILD is set, the quickstart runs with pre-built Konflux images.
#
# Env:
#   AGENTIC_OPERATOR_DIR (default: ../lightspeed-agentic-operator)
#   AGENTIC_NAMESPACE    (default: openshift-lightspeed)
#   SANDBOX_IMAGE        (default: Konflux main image)
#   CONSOLE_IMAGE        (default: Konflux main image)
#   SANDBOX_MODE         (default: bare-pod)
#   SKIP_BUILD           If set, use pre-built images
#   IMAGE_PULL_POLICY    (default: empty — cluster default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Build and deploy the lightspeed-agentic-operator.

Usage:
  ./install-agentic-operator.sh
  SKIP_BUILD=1 ./install-agentic-operator.sh
  BUILD_ONLY=1 ./install-agentic-operator.sh

Environment variables:
  AGENTIC_OPERATOR_DIR   Path to source (default: ../lightspeed-agentic-operator)
  AGENTIC_NAMESPACE      Namespace (default: openshift-lightspeed)
  SANDBOX_IMAGE          Sandbox image for operator args (default: Konflux main)
  CONSOLE_IMAGE          Console image for operator args (default: Konflux main)
  SANDBOX_MODE           bare-pod or sandbox-claim (default: bare-pod)
  IMAGE_PULL_POLICY      Pull policy (default: Always)
  SKIP_BUILD             Skip image build, use pre-built images
  BUILD_ONLY             Build image locally only (no push, no deploy, no cluster needed)
EOF
}
lib::parse_args "$@"

AGENTIC_OPERATOR_DIR=$(lib::resolve_sibling AGENTIC_OPERATOR_DIR lightspeed-agentic-operator) || {
    lib::log_error "Agentic operator source not found. Set AGENTIC_OPERATOR_DIR or clone lightspeed-agentic-operator next to this repo."
    exit 1
}

QUICKSTART="${AGENTIC_OPERATOR_DIR}/hack/quickstart/install.sh"
if [[ ! -f "${QUICKSTART}" ]]; then
    lib::log_error "Quickstart script not found: ${QUICKSTART}"
    exit 1
fi

OPERATOR_IMAGE="${OPERATOR_IMAGE:-}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-Always}"

# -- Build operator image (unless SKIP_BUILD) ----------------------------------

if [[ -z "${SKIP_BUILD:-}" ]]; then
    lib::log_step "1/3" "Building agentic operator from source..."
    if [[ -n "${BUILD_ONLY:-}" ]]; then
        OPERATOR_IMAGE=$(lib::build_local "lightspeed-agentic-operator" "${AGENTIC_OPERATOR_DIR}" "Dockerfile")
    else
        lib::setup_registry
        lib::ensure_namespace
        OPERATOR_IMAGE=$(lib::build_and_push "lightspeed-agentic-operator" "${AGENTIC_OPERATOR_DIR}" "Dockerfile")
        lib::ensure_pull_secret "${AGENTIC_NAMESPACE}" "lightspeed-agentic-operator"
        IMAGE_PULL_POLICY="Always"
    fi
    lib::log_success "Operator image: ${OPERATOR_IMAGE}"
else
    lib::log_step "1/3" "Skipping build (SKIP_BUILD set)"
fi

if [[ -n "${BUILD_ONLY:-}" ]]; then
    lib::log_info "BUILD_ONLY set — skipping deploy"
    exit 0
fi

# -- Deploy via upstream quickstart --------------------------------------------

lib::log_step "2/3" "Deploying via quickstart install.sh..."

NAMESPACE="${AGENTIC_NAMESPACE}" \
    OPERATOR_IMAGE="${OPERATOR_IMAGE}" \
    SANDBOX_IMAGE="${SANDBOX_IMAGE:-}" \
    CONSOLE_IMAGE="${CONSOLE_IMAGE:-}" \
    SANDBOX_MODE="${SANDBOX_MODE}" \
    IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY}" \
    bash "${QUICKSTART}"

# -- Apply ApprovalPolicy (cluster-scoped singleton) --------------------------

lib::log_step "3/3" "Applying ApprovalPolicy..."

oc apply -f "${SCRIPT_DIR}/templates/approvalpolicy-manual.yaml"

lib::log_success "ApprovalPolicy 'cluster' applied"
