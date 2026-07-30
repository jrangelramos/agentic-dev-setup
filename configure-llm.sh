#!/usr/bin/env bash
# Configure an LLM provider and Agent CR on the cluster.
#
# Usage:
#   ./config-llm.sh --openai
#   ./config-llm.sh --vertex-anthropic
#   ./config-llm.sh --vertex-google

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Configure an LLM provider (secret + LLMProvider CR + Agent CR).

Usage:
  ./config-llm.sh <provider>

Providers:
  --openai              OpenAI (direct API key)
  --vertex-anthropic    Anthropic models via Google Cloud Vertex AI
  --vertex-google       Google models via Google Cloud Vertex AI

Required environment variables:

  --openai:
    OPENAI_API_KEY              OpenAI API key
    OPENAI_MODEL                Model name (default: gpt-5.4)

  --vertex-anthropic / --vertex-google:
    VERTEX_PROJECT              GCP project ID
    VERTEX_REGION               GCP region (e.g. us-east5)

Optional environment variables:

  --vertex-anthropic:
    VERTEX_MODEL                Model name (default: claude-opus-4-6)

  --vertex-google:
    VERTEX_MODEL                Model name (default: gemini-2.5-flash)

  --vertex-anthropic / --vertex-google:
    VERTEX_SA_KEY_PATH          Path to GCP credentials JSON (auto-discovered from
                                GOOGLE_APPLICATION_CREDENTIALS or gcloud ADC)

  All providers:
    AGENTIC_NAMESPACE           Target namespace (default: openshift-lightspeed)
EOF
}

resolve_vertex_creds() {
    local adc_default="${HOME}/.config/gcloud/application_default_credentials.json"

    if [[ -n "${VERTEX_SA_KEY_PATH:-}" ]]; then
        CREDS_PATH="${VERTEX_SA_KEY_PATH}"
    elif [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
        CREDS_PATH="${GOOGLE_APPLICATION_CREDENTIALS}"
    elif [[ -f "${adc_default}" ]]; then
        CREDS_PATH="${adc_default}"
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
}

# -- Parse provider flag ------------------------------------------------------

PROVIDER=""
case "${1:-}" in
    -h|--help)          usage; exit 0 ;;
    --openai)           PROVIDER="openai" ;;
    --vertex-anthropic) PROVIDER="vertex-anthropic" ;;
    --vertex-google)    PROVIDER="vertex-google" ;;
    *)
        usage >&2
        exit 1
        ;;
esac

if [[ -n "${BUILD_ONLY:-}" ]]; then
    lib::log_info "BUILD_ONLY set — skipping LLM configuration"
    exit 0
fi

lib::require_cmd oc
lib::require_cmd envsubst
lib::subheading "LLM Provider (${PROVIDER})"

# -- Provider-specific setup --------------------------------------------------

case "${PROVIDER}" in
    openai)
        lib::require_var OPENAI_API_KEY
        export OPENAI_MODEL="${OPENAI_MODEL:-gpt-5.4}"
        export AGENTIC_NAMESPACE

        lib::step "Creating OpenAI credentials secret..."
        oc create secret generic llm-creds-openai \
            -n "${AGENTIC_NAMESPACE}" \
            --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}" \
            --dry-run=client -o yaml | oc apply -f -
        lib::log_success "Secret llm-creds-openai created"

        lib::step "Applying LLMProvider + Agent CR (OpenAI)..."
        envsubst < "${SCRIPT_DIR}/templates/openai.yaml" | oc apply -f -
        lib::log_success "LLMProvider 'openai' and Agent applied"
        ;;

    vertex-anthropic)
        lib::require_var VERTEX_PROJECT
        lib::require_var VERTEX_REGION
        resolve_vertex_creds

        export VERTEX_PROJECT
        export VERTEX_REGION
        export VERTEX_MODEL="${VERTEX_MODEL:-claude-opus-4-6}"

        lib::step "Creating Vertex AI credentials secret..."
        oc create secret generic llm-creds-vertex \
            -n "${AGENTIC_NAMESPACE}" \
            --from-file=GOOGLE_APPLICATION_CREDENTIALS="${CREDS_PATH}" \
            --dry-run=client -o yaml | oc apply -f -
        lib::log_success "Secret llm-creds-vertex created"

        lib::step "Applying LLMProvider + Agent CR (Vertex/Anthropic)..."
        envsubst < "${SCRIPT_DIR}/templates/vertex-anthropic.yaml" | oc apply -f -
        lib::log_success "LLMProvider 'vertex-anthropic' and Agent applied"
        ;;

    vertex-google)
        lib::require_var VERTEX_PROJECT
        lib::require_var VERTEX_REGION
        resolve_vertex_creds

        export VERTEX_PROJECT
        export VERTEX_REGION
        export VERTEX_MODEL="${VERTEX_MODEL:-gemini-2.5-flash}"

        lib::step "Creating Vertex AI credentials secret..."
        oc create secret generic llm-creds-vertex \
            -n "${AGENTIC_NAMESPACE}" \
            --from-file=GOOGLE_APPLICATION_CREDENTIALS="${CREDS_PATH}" \
            --dry-run=client -o yaml | oc apply -f -
        lib::log_success "Secret llm-creds-vertex created"

        lib::step "Applying LLMProvider + Agent CR (Vertex/Google)..."
        envsubst < "${SCRIPT_DIR}/templates/vertex-google.yaml" | oc apply -f -
        lib::log_success "LLMProvider 'vertex-google' and Agent applied"
        ;;
esac

lib::log_success "LLM configuration complete (${PROVIDER})"
