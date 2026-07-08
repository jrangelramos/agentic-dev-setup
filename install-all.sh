#!/usr/bin/env bash
# Install all Lightspeed agentic components on an OpenShift cluster from source.
#
# Builds images from sibling repos, pushes to the OpenShift internal registry,
# deploys the agentic operator, and configures the LLM provider.
#
# Prerequisites:
#   - oc CLI, podman, and envsubst on PATH
#   - Logged into an OpenShift cluster with cluster-admin
#   - Sibling repos cloned alongside this repo (see clone.sh)
#
# Required env:
#   VERTEX_PROJECT       GCP project ID
#   VERTEX_REGION        GCP region (e.g. us-east5)
#
# Optional env:
#   VERTEX_MODEL          (default: gemini-2.5-flash)
#   VERTEX_MODEL_PROVIDER (default: Google)
#   AGENTIC_NAMESPACE     (default: openshift-lightspeed)
#   SANDBOX_MODE          (default: bare-pod)
#   SANDBOX_IMAGE         Override sandbox image (skip build)
#   CONSOLE_IMAGE         Override console image
#   SKIP_BUILD            If set, skip all image builds
#   AGENTIC_OPERATOR_DIR  Path to lightspeed-agentic-operator source
#   SANDBOX_DIR           Path to lightspeed-agentic-sandbox source
#   SKILLS_DIR            Path to agentic-skills source
#
# Usage:
#   export VERTEX_PROJECT=my-project VERTEX_REGION=us-east5
#   ./install-all.sh
#
#   # Skip builds (use pre-built Konflux images):
#   SKIP_BUILD=1 ./install-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Install all Lightspeed agentic components on an OpenShift cluster from source.

Usage:
  ./install-all.sh
  SKIP_BUILD=1 ./install-all.sh
  BUILD_ONLY=1 ./install-all.sh

Environment variables:
  VERTEX_PROJECT         (required)  GCP project ID
  VERTEX_REGION          (required)  GCP region (e.g. us-east5)
  VERTEX_SA_KEY_PATH                 Path to GCP credentials JSON (auto-discovered)
  VERTEX_MODEL                       Model name (default: gemini-2.5-flash)
  VERTEX_MODEL_PROVIDER              Google, Anthropic, or OpenAI (default: Google)
  AGENTIC_NAMESPACE                  Namespace (default: openshift-lightspeed)
  SANDBOX_MODE                       bare-pod or sandbox-claim (default: bare-pod)
  SANDBOX_IMAGE                      Override sandbox image (skip its build)
  CONSOLE_IMAGE                      Override console image (skip its build)
  CLUSTER_UPDATE_IMAGE               Override cluster-update-console image
  SKIP_BUILD                         Skip all image builds (use pre-built Konflux images)
  BUILD_ONLY                         Build images locally only (no push, no deploy, no cluster needed)
  AGENTIC_OPERATOR_DIR               Path to lightspeed-agentic-operator (default: ../lightspeed-agentic-operator)
  SANDBOX_DIR                        Path to lightspeed-agentic-sandbox (default: ../lightspeed-agentic-sandbox)
  SKILLS_DIR                         Path to agentic-skills (default: ../agentic-skills)
  CONSOLE_DIR                        Path to lightspeed-agentic-console (default: ../lightspeed-agentic-console)
  CLUSTER_UPDATE_DIR                 Path to cluster-update-console-plugin (default: ../cluster-update-console-plugin)
EOF
}
lib::parse_args "$@"

# -- Prerequisites -------------------------------------------------------------

lib::log_step "0" "Checking prerequisites..."
if [[ -n "${BUILD_ONLY:-}" ]]; then
    lib::require_cmd podman
    lib::log_info "BUILD_ONLY mode — will build locally, no cluster required"
else
    lib::require_cmd oc
    lib::require_cmd envsubst
    lib::require_oc_login
    lib::require_var VERTEX_PROJECT
    lib::require_var VERTEX_REGION
fi

# -- Resolve sibling repos ----------------------------------------------------

AGENTIC_OPERATOR_DIR=$(lib::resolve_sibling AGENTIC_OPERATOR_DIR lightspeed-agentic-operator) || {
    lib::log_error "lightspeed-agentic-operator not found. Clone it next to this repo or set AGENTIC_OPERATOR_DIR."
    exit 1
}
lib::log_success "Agentic operator: ${AGENTIC_OPERATOR_DIR}"

SANDBOX_AVAILABLE=false
if SANDBOX_DIR=$(lib::resolve_sibling SANDBOX_DIR lightspeed-agentic-sandbox); then
    SANDBOX_AVAILABLE=true
    lib::log_success "Sandbox: ${SANDBOX_DIR}"
else
    lib::log_warning "lightspeed-agentic-sandbox not found — using pre-built image"
fi

SKILLS_AVAILABLE=false
if SKILLS_DIR=$(lib::resolve_sibling SKILLS_DIR agentic-skills); then
    SKILLS_AVAILABLE=true
    lib::log_success "Skills: ${SKILLS_DIR}"
else
    lib::log_warning "agentic-skills not found — skipping skills build"
fi

CONSOLE_AVAILABLE=false
if CONSOLE_DIR=$(lib::resolve_sibling CONSOLE_DIR lightspeed-agentic-console); then
    CONSOLE_AVAILABLE=true
    lib::log_success "Console: ${CONSOLE_DIR}"
else
    lib::log_warning "lightspeed-agentic-console not found — using pre-built image"
fi

CLUSTER_UPDATE_AVAILABLE=false
if CLUSTER_UPDATE_DIR=$(lib::resolve_sibling CLUSTER_UPDATE_DIR cluster-update-console-plugin); then
    CLUSTER_UPDATE_AVAILABLE=true
    lib::log_success "Cluster update console: ${CLUSTER_UPDATE_DIR}"
else
    lib::log_warning "cluster-update-console-plugin not found — skipping"
fi

# -- Build optional images (before operator, so we can pass image URLs) --------

if [[ -z "${SKIP_BUILD:-}" ]]; then
    lib::require_cmd podman

    if [[ "$SANDBOX_AVAILABLE" == "true" && -z "${SANDBOX_IMAGE:-}" ]]; then
        lib::log_step "A" "Building sandbox image..."
        SANDBOX_IMAGE=$(SANDBOX_DIR="${SANDBOX_DIR}" "${SCRIPT_DIR}/install-sandbox.sh")
        export SANDBOX_IMAGE
        lib::log_success "Sandbox image: ${SANDBOX_IMAGE}"
    fi

    if [[ "$SKILLS_AVAILABLE" == "true" ]]; then
        lib::log_step "B" "Building skills image..."
        SKILLS_IMAGE=$(SKILLS_DIR="${SKILLS_DIR}" "${SCRIPT_DIR}/install-skills.sh")
        export SKILLS_IMAGE
        lib::log_success "Skills image: ${SKILLS_IMAGE}"
    fi

    if [[ "$CONSOLE_AVAILABLE" == "true" && -z "${CONSOLE_IMAGE:-}" ]]; then
        lib::log_step "C" "Building console plugin image..."
        CONSOLE_IMAGE=$(CONSOLE_DIR="${CONSOLE_DIR}" "${SCRIPT_DIR}/install-console.sh")
        export CONSOLE_IMAGE
        lib::log_success "Console image: ${CONSOLE_IMAGE}"
    fi
fi

if [[ -n "${BUILD_ONLY:-}" ]]; then
    cat <<DONE

════════════════════════════════════════════════════════════════
  Images built (BUILD_ONLY mode — no deploy)

  Sandbox image  : ${SANDBOX_IMAGE:-not built}
  Skills image   : ${SKILLS_IMAGE:-not built}
  Console image  : ${CONSOLE_IMAGE:-not built}
════════════════════════════════════════════════════════════════

  To deploy, run without BUILD_ONLY:

    SKIP_BUILD=1 \\
      SANDBOX_IMAGE=${SANDBOX_IMAGE:-<sandbox-image>} \\
      CONSOLE_IMAGE=${CONSOLE_IMAGE:-<console-image>} \\
      ./install-all.sh

DONE
    exit 0
fi

# -- Deploy agentic operator ---------------------------------------------------

lib::log_step "D" "Deploying agentic operator..."
AGENTIC_OPERATOR_DIR="${AGENTIC_OPERATOR_DIR}" \
    SANDBOX_IMAGE="${SANDBOX_IMAGE:-}" \
    CONSOLE_IMAGE="${CONSOLE_IMAGE:-}" \
    "${SCRIPT_DIR}/install-agentic-operator.sh"

# -- Deploy cluster-update-console-plugin (standalone, not managed by operator) -

if [[ "$CLUSTER_UPDATE_AVAILABLE" == "true" ]]; then
    lib::log_step "E" "Deploying cluster-update-console-plugin..."
    CLUSTER_UPDATE_DIR="${CLUSTER_UPDATE_DIR}" "${SCRIPT_DIR}/install-cluster-update-console.sh"
fi

# -- Configure LLM -------------------------------------------------------------

lib::log_step "F" "Configuring LLM provider..."
"${SCRIPT_DIR}/configure-llm.sh"

# -- Summary -------------------------------------------------------------------

EXAMPLES_DIR="${AGENTIC_OPERATOR_DIR}/hack/quickstart/examples"

cat <<DONE

════════════════════════════════════════════════════════════════
  Agentic dev environment installed!

  Namespace      : ${AGENTIC_NAMESPACE}
  Sandbox mode   : ${SANDBOX_MODE}
  Sandbox image  : ${SANDBOX_IMAGE:-default Konflux image}
  Console image  : ${CONSOLE_IMAGE:-default Konflux image}
  Skills image   : ${SKILLS_IMAGE:-not built}
  Model          : ${VERTEX_MODEL:-gemini-2.5-flash} (${VERTEX_MODEL_PROVIDER:-Google})
════════════════════════════════════════════════════════════════

  Submit an example proposal:

    oc apply -f ${EXAMPLES_DIR}/namespace-inventory.yaml
    oc apply -f ${EXAMPLES_DIR}/deploy-test-workload.yaml

  Watch proposals:

    oc get proposals -n ${AGENTIC_NAMESPACE} -w

  Approve execution:

    oc patch proposalapproval <name> -n ${AGENTIC_NAMESPACE} \\
      --type=json \\
      -p '[{"op":"add","path":"/spec/stages/-","value":{"type":"Execution","execution":{"option":0}}}]'

  Uninstall:

    ${SCRIPT_DIR}/uninstall.sh

DONE
