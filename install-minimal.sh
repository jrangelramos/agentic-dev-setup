#!/usr/bin/env bash
# Minimal install: deploy the agentic operator (pre-built images), configure
# Claude as the LLM, build the console plugin and skills from source, and
# deploy a dev CVO that wires them together.
#
# Prerequisites:
#   - oc, podman, go, envsubst, jq, gzip on PATH
#   - Logged into an OpenShift cluster with cluster-admin
#   - GCP credentials for Vertex AI (Claude via Anthropic)
#   - Sibling repos: lightspeed-agentic-operator, cluster-update-console-plugin,
#     agentic-skills, cluster-version-operator
#
# Required env:
#   VERTEX_PROJECT   GCP project ID
#   VERTEX_REGION    GCP region (e.g. us-east5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Minimal agentic install: pre-built operator + Claude LLM + build from source
the console plugin, skills, and dev CVO.

Usage:
  export VERTEX_PROJECT=my-project VERTEX_REGION=us-east5
  ./install-minimal.sh

Environment variables:
  VERTEX_PROJECT         (required) GCP project ID
  VERTEX_REGION          (required) GCP region (e.g. us-east5)
  VERTEX_MODEL           Model name (default: claude-opus-4-6)
  VERTEX_SA_KEY_PATH     Path to GCP credentials JSON (auto-discovered)
  AGENTIC_NAMESPACE      Namespace (default: openshift-lightspeed)
  AGENTIC_OPERATOR_DIR   Path to lightspeed-agentic-operator (default: ../lightspeed-agentic-operator)
  CLUSTER_UPDATE_DIR     Path to cluster-update-console-plugin (default: ../cluster-update-console-plugin)
  SKILLS_DIR             Path to agentic-skills (default: ../agentic-skills)
  CVO_DIR                Path to cluster-version-operator (default: ../cluster-version-operator)
EOF
}
lib::parse_args "$@"
lib::dev_disclaimer

# -- Resolve sibling repos (check before anything else) -----------------------

AGENTIC_OPERATOR_DIR=$(lib::resolve_sibling AGENTIC_OPERATOR_DIR lightspeed-agentic-operator) || AGENTIC_OPERATOR_DIR=""
CLUSTER_UPDATE_DIR=$(lib::resolve_sibling CLUSTER_UPDATE_DIR cluster-update-console-plugin) || CLUSTER_UPDATE_DIR=""
SKILLS_DIR=$(lib::resolve_sibling SKILLS_DIR agentic-skills) || SKILLS_DIR=""
CVO_DIR=$(lib::resolve_sibling CVO_DIR cluster-version-operator) || CVO_DIR=""

# -- Show plan and source paths -----------------------------------------------

PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cat >&2 <<BANNER

════════════════════════════════════════════════════════════════════
  Minimal Agentic Install
════════════════════════════════════════════════════════════════════

  This script will run the following steps, in order:

  1. Deploy the Agentic Operator (pre-built Konflux images, no build)
     Installs the lightspeed-agentic-operator which manages agentic
     runs, proposals, and sandbox lifecycle.

  2. Configure LLM — Claude (Anthropic via Vertex AI)
     Creates the LLM credentials secret, LLMProvider CR, and Agent CR
     using your GCP/Vertex AI credentials for Claude.

  3. Build and push cluster-update-console-plugin (from source)
     Builds the OCP console plugin that provides the cluster update UI.

  4. Build and push agentic-skills (from source)
     Builds the skills OCI image used by sandbox pods for cluster
     update operations.

  5. Build and deploy dev CVO (from source)
     Builds a development Cluster Version Operator with the agenticrun
     controller enabled, wired to use the custom console plugin and
     skills images built in steps 3-4.

────────────────────────────────────────────────────────────────────
  Source repos (expected in ${PARENT_DIR}/):
────────────────────────────────────────────────────────────────────
BANNER

MISSING=()
_check_repo() {
    local label="$1" dir="$2" name="$3"
    if [[ -n "${dir}" ]]; then
        echo -e "  ${_GREEN}✓${_RESET} ${label}: ${dir}" >&2
    else
        echo -e "  ${_RED}✗${_RESET} ${label}: NOT FOUND (expected ../${name})" >&2
        MISSING+=("${name}")
    fi
}

_check_repo "lightspeed-agentic-operator"  "${AGENTIC_OPERATOR_DIR}" "lightspeed-agentic-operator"
_check_repo "cluster-update-console-plugin" "${CLUSTER_UPDATE_DIR}"  "cluster-update-console-plugin"
_check_repo "agentic-skills"                "${SKILLS_DIR}"          "agentic-skills"
_check_repo "cluster-version-operator"      "${CVO_DIR}"             "cluster-version-operator"

echo "" >&2

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "  ${_RED}✗${_RESET} Missing repos: ${MISSING[*]}" >&2
    echo "" >&2
    echo "  Clone them with:" >&2
    echo "    cd ${PARENT_DIR} && ./agentic-dev-setup/clone.sh" >&2
    echo "" >&2
    exit 1
fi

echo -e "────────────────────────────────────────────────────────────────────" >&2
echo "" >&2

read -r -p "  Do you understand and would you like to proceed? [y/N] " answer
echo "" >&2
if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
    echo "Aborted." >&2
    exit 0
fi

# -- Prerequisites ------------------------------------------------------------

lib::heading "PREREQUISITES"
lib::step "Checking prerequisites..."
for cmd in oc podman envsubst go jq gzip; do
    lib::require_cmd "${cmd}"
done
lib::require_oc_login
lib::require_var VERTEX_PROJECT
lib::require_var VERTEX_REGION

lib::step "Checking internal registry access..."
_REGISTRY=$(lib::get_registry_hostname)
if [[ -z "$_REGISTRY" ]]; then
    lib::log_info "Registry route not exposed — enabling it..."
    lib::ensure_registry_route
    _REGISTRY=$(lib::get_registry_hostname)
fi

if [[ -z "$_REGISTRY" ]]; then
    lib::log_error "Could not determine internal registry hostname."
    lib::log_error "Ensure the image-registry operator is running and a route is exposed."
    exit 1
fi

TOKEN=$(oc whoami -t 2>/dev/null || true)
if [[ -z "${TOKEN}" ]]; then
    SERVER=$(oc whoami --show-server 2>/dev/null || echo "<api-server-url>")
    lib::log_error "No OAuth token for the current session."
    lib::log_error "A token-based login is required for registry operations."
    echo "" >&2
    lib::log_info "Option A: Log in with kubeadmin:"
    echo "    oc login -u kubeadmin ${SERVER}" >&2
    echo "" >&2
    lib::log_info "Option B: Copy the login command from the OCP web console:"
    echo "    1. Click your username (top right) → 'Copy login command'" >&2
    echo "    2. Click 'Display Token' and run the oc login --token=... command" >&2
    exit 1
fi

if ! podman login -u unused --password "${TOKEN}" --tls-verify=false "${_REGISTRY}" >&2 2>/dev/null; then
    lib::log_error "podman login to ${_REGISTRY} failed."
    echo "" >&2
    lib::log_info "Try re-authenticating:"
    echo "    oc login -u kubeadmin \$(oc whoami --show-server)" >&2
    echo "    podman login --tls-verify=false -u kubeadmin -p \$(oc whoami -t) ${_REGISTRY}" >&2
    exit 1
fi
lib::log_success "Registry accessible: ${_REGISTRY}"

# -- Step 1: Agentic Operator (SKIP_BUILD) ------------------------------------

lib::heading "STEP 1/5 — AGENTIC OPERATOR (pre-built images)"
SKIP_BUILD=1 \
    AGENTIC_OPERATOR_DIR="${AGENTIC_OPERATOR_DIR}" \
    "${SCRIPT_DIR}/install-agentic-operator.sh"

# -- Step 2: Configure LLM (Claude via Vertex AI) ----------------------------

lib::heading "STEP 2/5 — CONFIGURE LLM (Claude via Vertex AI)"
"${SCRIPT_DIR}/configure-llm.sh" --vertex-anthropic

# -- Step 3: Cluster Update Console Plugin (build from source) ----------------

lib::heading "STEP 3/5 — CLUSTER UPDATE CONSOLE PLUGIN (build from source)"
CLUSTER_UPDATE_IMAGE=$(CLUSTER_UPDATE_DIR="${CLUSTER_UPDATE_DIR}" "${SCRIPT_DIR}/install-cluster-update-console.sh")
lib::log_success "Console plugin image: ${CLUSTER_UPDATE_IMAGE}"

# -- Step 4: Skills (build from source) ---------------------------------------

lib::heading "STEP 4/5 — AGENTIC SKILLS (build from source)"
SKILLS_IMAGE=$(SKILLS_DIR="${SKILLS_DIR}" "${SCRIPT_DIR}/install-skills.sh")
lib::log_success "Skills image: ${SKILLS_IMAGE}"

# -- Step 5: Dev CVO (build from source) --------------------------------------

lib::heading "STEP 5/5 — DEV CVO (build from source)"
CVO_DIR="${CVO_DIR}" "${SCRIPT_DIR}/install-cvo.sh"

# -- Summary ------------------------------------------------------------------

cat >&2 <<DONE

════════════════════════════════════════════════════════════════════
  Minimal agentic install complete!

  Agentic operator  : deployed (pre-built Konflux images)
  LLM provider      : Claude (Vertex AI / Anthropic)
  Console plugin    : ${CLUSTER_UPDATE_IMAGE}
  Skills image      : ${SKILLS_IMAGE}
  Dev CVO           : deployed with agenticrun controller

  Namespace         : ${AGENTIC_NAMESPACE}
════════════════════════════════════════════════════════════════════

  Uninstall:

    ${SCRIPT_DIR}/uninstall.sh

DONE
