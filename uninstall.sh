#!/usr/bin/env bash
# Uninstall all agentic dev components.
#
# Delegates to the agentic-operator's quickstart uninstall.sh if available,
# otherwise cleans up manually.
#
# Env:
#   AGENTIC_NAMESPACE       (default: openshift-lightspeed)
#   AGENTIC_OPERATOR_DIR    (default: ../lightspeed-agentic-operator)
#   FORCE                   If set to 1, skip confirmation prompt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
    cat <<EOF
Uninstall all agentic dev components.

Usage:
  ./uninstall.sh
  FORCE=1 ./uninstall.sh

Environment variables:
  AGENTIC_NAMESPACE      Namespace (default: openshift-lightspeed)
  AGENTIC_OPERATOR_DIR   Path to lightspeed-agentic-operator (default: ../lightspeed-agentic-operator)
  FORCE                  Skip confirmation prompt
EOF
}
lib::parse_args "$@"

lib::require_cmd oc

UPSTREAM_UNINSTALL=""
if dir=$(lib::resolve_sibling AGENTIC_OPERATOR_DIR lightspeed-agentic-operator); then
    if [[ -x "${dir}/hack/quickstart/uninstall.sh" ]]; then
        UPSTREAM_UNINSTALL="${dir}/hack/quickstart/uninstall.sh"
    fi
fi

if [[ -n "$UPSTREAM_UNINSTALL" ]]; then
    lib::log_info "Using upstream uninstall script: ${UPSTREAM_UNINSTALL}"
    NAMESPACE="${AGENTIC_NAMESPACE}" \
        QUICKSTART_FORCE="${FORCE:-}" \
        bash "${UPSTREAM_UNINSTALL}"
    exit 0
fi

# -- Manual fallback -----------------------------------------------------------

if [[ "${FORCE:-}" != "1" ]]; then
    echo "This will delete ALL agentic resources in namespace ${AGENTIC_NAMESPACE},"
    echo "remove CRDs cluster-wide, and the namespace itself."
    echo ""
    read -rp "Continue? [y/N] " confirm
    case "${confirm}" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

lib::log_step "1/7" "Deleting custom resources..."
for kind in proposals proposalapprovals analysisresults executionresults verificationresults escalationresults; do
    oc delete "${kind}" --all -n "${AGENTIC_NAMESPACE}" --ignore-not-found 2>/dev/null || true
done
oc delete agents --all --ignore-not-found 2>/dev/null || true
oc delete llmproviders --all --ignore-not-found 2>/dev/null || true
oc delete approvalpolicy cluster --ignore-not-found 2>/dev/null || true
oc delete agenticolsconfig cluster --ignore-not-found 2>/dev/null || true
lib::log_success "Custom resources deleted"

lib::log_step "2/7" "Deleting secrets..."
for secret in llm-creds-vertex llm-creds-openai llm-creds-azure llm-creds-bedrock; do
    oc delete secret "${secret}" -n "${AGENTIC_NAMESPACE}" --ignore-not-found 2>/dev/null || true
done
lib::log_success "Secrets deleted"

lib::log_step "3/7" "Removing cluster-update-console-plugin..."
if helm status cluster-update-console-plugin -n "${AGENTIC_NAMESPACE}" >/dev/null 2>&1; then
    helm uninstall cluster-update-console-plugin -n "${AGENTIC_NAMESPACE}" || true
    lib::log_success "cluster-update-console-plugin removed"
else
    lib::log_info "cluster-update-console-plugin not installed — skipping"
fi

lib::log_step "4/7" "Deleting webhook resources..."
oc delete mutatingwebhookconfiguration agentic-operator-mutating-webhook --ignore-not-found 2>/dev/null || true
oc delete service agentic-operator-webhook-service -n "${AGENTIC_NAMESPACE}" --ignore-not-found 2>/dev/null || true
oc delete secret agentic-operator-webhook-certs -n "${AGENTIC_NAMESPACE}" --ignore-not-found 2>/dev/null || true
lib::log_success "Webhook resources deleted"

lib::log_step "5/7" "Deleting operator..."
oc delete deployment lightspeed-agentic-operator -n "${AGENTIC_NAMESPACE}" --ignore-not-found 2>/dev/null || true
oc delete sa lightspeed-agentic-operator -n "${AGENTIC_NAMESPACE}" --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding lightspeed-agentic-operator --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding lightspeed-agent-cluster-reader --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding lightspeed-agent-monitoring-view --ignore-not-found 2>/dev/null || true
lib::log_success "Operator removed"

lib::log_step "6/7" "Deleting CRDs..."
for crd in \
    agenticolsconfigs.agentic.openshift.io \
    agents.agentic.openshift.io \
    analysisresults.agentic.openshift.io \
    approvalpolicies.agentic.openshift.io \
    escalationresults.agentic.openshift.io \
    executionresults.agentic.openshift.io \
    llmproviders.agentic.openshift.io \
    proposalapprovals.agentic.openshift.io \
    proposals.agentic.openshift.io \
    verificationresults.agentic.openshift.io; do
    oc delete crd "${crd}" --ignore-not-found --timeout=30s 2>/dev/null || true
done
lib::log_success "CRDs deleted"

lib::log_step "7/7" "Deleting namespace ${AGENTIC_NAMESPACE}..."
oc delete namespace "${AGENTIC_NAMESPACE}" --ignore-not-found --timeout=60s 2>/dev/null || true
lib::log_success "Namespace deleted"

echo ""
echo "  Agentic dev environment uninstalled."
echo ""
