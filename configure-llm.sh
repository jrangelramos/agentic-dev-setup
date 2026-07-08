#!/usr/bin/env bash
# Configure the LLM provider (Vertex AI) by creating credentials secret,
# LLMProvider CR, and Agent CR.
#
# Required env:
#   VERTEX_PROJECT       GCP project ID
#   VERTEX_REGION        GCP region (e.g. us-east5)
#
# Optional env:
#   VERTEX_SA_KEY_PATH    Path to GCP credentials JSON. Auto-discovered from:
#                         1. VERTEX_SA_KEY_PATH (if set)
#                         2. GOOGLE_APPLICATION_CREDENTIALS (if set)
#                         3. ~/.config/gcloud/application_default_credentials.json
#   VERTEX_MODEL          (default: claude-opus-4-6 — alternatives: gemini-2.5-flash)
#   VERTEX_MODEL_PROVIDER (default: Google — alternatives: Anthropic, OpenAI)
#   AGENTIC_NAMESPACE     (default: openshift-lightspeed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Configure the LLM provider (Vertex AI) with credentials, LLMProvider CR, and Agent CRs.

Usage:
  ./configure-llm.sh

Environment variables:
  VERTEX_PROJECT         (required)  GCP project ID
  VERTEX_REGION          (required)  GCP region (e.g. us-east5)
  VERTEX_SA_KEY_PATH                 Path to GCP credentials JSON (auto-discovered)
  VERTEX_MODEL                       Model name (default: claude-opus-4-6)
  VERTEX_MODEL_PROVIDER              Google, Anthropic, or OpenAI (default: Anthropic)
  AGENTIC_NAMESPACE                  Namespace (default: openshift-lightspeed)
EOF
}
lib::parse_args "$@"

if [[ -n "${BUILD_ONLY:-}" ]]; then
    lib::log_info "BUILD_ONLY set — skipping LLM configuration"
    exit 0
fi

lib::require_var VERTEX_PROJECT
lib::require_var VERTEX_REGION

# -- Resolve credentials path -------------------------------------------------

ADC_DEFAULT="${HOME}/.config/gcloud/application_default_credentials.json"

if [[ -n "${VERTEX_SA_KEY_PATH:-}" ]]; then
    CREDS_PATH="${VERTEX_SA_KEY_PATH}"
elif [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    CREDS_PATH="${GOOGLE_APPLICATION_CREDENTIALS}"
elif [[ -f "${ADC_DEFAULT}" ]]; then
    CREDS_PATH="${ADC_DEFAULT}"
else
    lib::log_error "No GCP credentials found. Either:"
    lib::log_error "  - Set VERTEX_SA_KEY_PATH to a service account key JSON"
    lib::log_error "  - Set GOOGLE_APPLICATION_CREDENTIALS"
    lib::log_error "  - Run: gcloud auth application-default login"
    exit 1
fi

if [[ ! -f "${CREDS_PATH}" ]]; then
    lib::log_error "Credentials file not found: ${CREDS_PATH}"
    exit 1
fi

lib::log_info "Using credentials: ${CREDS_PATH}"

export VERTEX_MODEL="${VERTEX_MODEL:-claude-opus-4-6}"
export VERTEX_MODEL_PROVIDER="${VERTEX_MODEL_PROVIDER:-Anthropic}"
export VERTEX_PROJECT
export VERTEX_REGION

# -- Step 1: Create credentials secret ----------------------------------------

lib::log_step "1/3" "Creating LLM credentials secret..."

oc create secret generic llm-creds-vertex \
    -n "${AGENTIC_NAMESPACE}" \
    --from-file=GOOGLE_APPLICATION_CREDENTIALS="${CREDS_PATH}" \
    --dry-run=client -o yaml | oc apply -f -

lib::log_success "Secret llm-creds-vertex created"

# -- Step 2: Apply LLMProvider CR ---------------------------------------------

lib::log_step "2/3" "Applying LLMProvider CR (${VERTEX_MODEL_PROVIDER})..."

envsubst < "${SCRIPT_DIR}/templates/llmprovider-vertex-ai.yaml" | oc apply -f -

lib::log_success "LLMProvider 'vertex-ai' applied"

# -- Step 3: Apply Agent CRs --------------------------------------------------

lib::log_step "3/3" "Applying Agent CRs..."

for tmpl in "${SCRIPT_DIR}"/templates/agent-*.yaml; do
    envsubst < "${tmpl}" | oc apply -f -
    lib::log_success "Applied $(basename "${tmpl}")"
done

lib::log_success "LLM configuration complete"
