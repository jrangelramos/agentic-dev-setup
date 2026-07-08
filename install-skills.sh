#!/usr/bin/env bash
# Build the agentic skills OCI image and push to the OpenShift internal registry.
#
# Env:
#   SKILLS_DIR           (default: ../agentic-skills)
#   AGENTIC_NAMESPACE    (default: openshift-lightspeed)
#   SKIP_BUILD           If set, skip image build
#
# Skills are OCI image volumes mounted per-Proposal into sandbox pods.
# After building, reference the image in your Proposal CR:
#   tools:
#     skills:
#       - image: <printed image URL>
#         paths:
#           - /skills/cluster-update
#
# Outputs SKILLS_IMAGE (in-cluster URL) on stdout for callers to capture.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Build the agentic skills OCI image and push to the OpenShift internal registry.

Usage:
  ./install-skills.sh
  BUILD_ONLY=1 ./install-skills.sh

Environment variables:
  SKILLS_DIR           Path to source (default: ../agentic-skills)
  AGENTIC_NAMESPACE    Namespace (default: openshift-lightspeed)
  SKIP_BUILD           Skip image build
  BUILD_ONLY           Build image locally only (no push, no cluster needed)
EOF
}
lib::parse_args "$@"

SKILLS_DIR=$(lib::resolve_sibling SKILLS_DIR agentic-skills) || {
    lib::log_error "Skills source not found. Set SKILLS_DIR or clone agentic-skills next to this repo."
    exit 1
}

if [[ -n "${SKIP_BUILD:-}" ]]; then
    lib::log_info "SKIP_BUILD set — skipping skills build"
    exit 0
fi

if [[ -n "${BUILD_ONLY:-}" ]]; then
    SKILLS_IMAGE=$(lib::build_local "agentic-skills" "${SKILLS_DIR}" "Containerfile")
else
    lib::setup_registry
    SKILLS_IMAGE=$(lib::build_and_push "agentic-skills" "${SKILLS_DIR}" "Containerfile")
fi
echo "${SKILLS_IMAGE}"
