#!/usr/bin/env bash
# Build the agentic sandbox image and push to the OpenShift internal registry.
#
# Env:
#   SANDBOX_DIR          (default: ../lightspeed-agentic-sandbox)
#   AGENTIC_NAMESPACE    (default: openshift-lightspeed)
#   SKIP_BUILD           If set, skip image build
#
# Outputs SANDBOX_IMAGE (in-cluster URL) on stdout for callers to capture.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Build the agentic sandbox image and push to the OpenShift internal registry.

Usage:
  ./install-sandbox.sh
  BUILD_ONLY=1 ./install-sandbox.sh

Environment variables:
  SANDBOX_DIR          Path to source (default: ../lightspeed-agentic-sandbox)
  AGENTIC_NAMESPACE    Namespace (default: openshift-lightspeed)
  SKIP_BUILD           Skip image build
  BUILD_ONLY           Build image locally only (no push, no cluster needed)
EOF
}
lib::parse_args "$@"

SANDBOX_DIR=$(lib::resolve_sibling SANDBOX_DIR lightspeed-agentic-sandbox) || {
    lib::log_error "Sandbox source not found. Set SANDBOX_DIR or clone lightspeed-agentic-sandbox next to this repo."
    exit 1
}

if [[ -n "${SKIP_BUILD:-}" ]]; then
    lib::log_info "SKIP_BUILD set — skipping sandbox build"
    exit 0
fi

if [[ -n "${BUILD_ONLY:-}" ]]; then
    SANDBOX_IMAGE=$(lib::build_local "lightspeed-agentic-sandbox" "${SANDBOX_DIR}" "Containerfile")
else
    lib::setup_registry
    SANDBOX_IMAGE=$(lib::build_and_push "lightspeed-agentic-sandbox" "${SANDBOX_DIR}" "Containerfile")
fi
echo "${SANDBOX_IMAGE}"
