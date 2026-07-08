#!/usr/bin/env bash
# Build the agentic console plugin image and push to the OpenShift internal registry.
#
# Env:
#   CONSOLE_DIR          (default: ../lightspeed-agentic-console)
#   AGENTIC_NAMESPACE    (default: openshift-lightspeed)
#   SKIP_BUILD           If set, skip image build
#
# Outputs CONSOLE_IMAGE (in-cluster URL) on stdout for callers to capture.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Build the agentic console plugin image and push to the OpenShift internal registry.

Usage:
  ./install-console.sh
  BUILD_ONLY=1 ./install-console.sh

Environment variables:
  CONSOLE_DIR          Path to source (default: ../lightspeed-agentic-console)
  AGENTIC_NAMESPACE    Namespace (default: openshift-lightspeed)
  SKIP_BUILD           Skip image build
  BUILD_ONLY           Build image locally only (no push, no cluster needed)
EOF
}
lib::parse_args "$@"

CONSOLE_DIR=$(lib::resolve_sibling CONSOLE_DIR lightspeed-agentic-console) || {
    lib::log_error "Console source not found. Set CONSOLE_DIR or clone lightspeed-agentic-console next to this repo."
    exit 1
}

if [[ -n "${SKIP_BUILD:-}" ]]; then
    lib::log_info "SKIP_BUILD set — skipping console build"
    exit 0
fi

if [[ -n "${BUILD_ONLY:-}" ]]; then
    CONSOLE_IMAGE=$(lib::build_local "lightspeed-agentic-console" "${CONSOLE_DIR}" "Dockerfile")
else
    lib::setup_registry
    CONSOLE_IMAGE=$(lib::build_and_push "lightspeed-agentic-console" "${CONSOLE_DIR}" "Dockerfile")
fi
echo "${CONSOLE_IMAGE}"
