#!/usr/bin/env bash
# Shared helpers for agentic dev setup scripts.
# Source this file; do not execute directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

AGENTIC_NAMESPACE="${AGENTIC_NAMESPACE:-openshift-lightspeed}"
SANDBOX_MODE="${SANDBOX_MODE:-bare-pod}"

# Resolved once by lib::setup_registry; empty until then.
_REGISTRY=""
_INTERNAL_REGISTRY=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_CYAN='\033[0;36m'
_BOLD='\033[1m'
_RESET='\033[0m'

lib::parse_args() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
}

lib::log_step()    { echo -e "\n${_BOLD}[${1}]${_RESET} ${2}" >&2; }
lib::log_info()    { echo -e "  ${_CYAN}ℹ${_RESET} $*" >&2; }
lib::log_success() { echo -e "  ${_GREEN}✓${_RESET} $*" >&2; }
lib::log_warning() { echo -e "  ${_YELLOW}⚠${_RESET} $*" >&2; }
lib::log_error()   { echo -e "  ${_RED}✗${_RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
lib::require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        lib::log_error "Required command not found: $1"
        exit 1
    fi
}

lib::require_var() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        lib::log_error "Required env var not set: ${var_name}"
        exit 1
    fi
}

lib::require_oc_login() {
    lib::require_cmd oc
    if ! oc whoami >/dev/null 2>&1; then
        lib::log_error "Not logged into a cluster. Run: oc login ..."
        exit 1
    fi
    if ! oc auth can-i create clusterrolebindings >/dev/null 2>&1; then
        lib::log_error "Current user lacks cluster-admin privileges."
        exit 1
    fi
    lib::log_success "Logged in as $(oc whoami) (cluster-admin)"
}

# ---------------------------------------------------------------------------
# Sibling repo resolution
# ---------------------------------------------------------------------------
lib::resolve_sibling() {
    local var_name="$1" default_dir="$2"
    local dir="${!var_name:-${PARENT_DIR}/${default_dir}}"
    if [[ ! -d "$dir" ]]; then
        return 1
    fi
    printf '%s' "$(cd "$dir" && pwd)"
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------
lib::get_registry_hostname() {
    local reg=""
    reg=$(oc registry info --public 2>/dev/null) || true
    if [[ -z "$reg" ]]; then
        reg=$(oc get routes.route.openshift.io -n openshift-image-registry \
            -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1) || true
    fi
    if [[ -z "$reg" ]]; then
        reg=$(oc get configs.imageregistry.operator.openshift.io cluster \
            -o jsonpath='{.status.routes[0].hostname}' 2>/dev/null) || true
    fi
    printf '%s' "$reg"
}

lib::ensure_registry_route() {
    lib::log_info "Patching imageregistry to expose default route..."
    oc patch configs.imageregistry.operator.openshift.io/cluster \
        --type=merge -p '{"spec":{"defaultRoute":true}}' || {
        lib::log_error "Failed to patch imageregistry (need cluster-admin)"
        exit 1
    }
    local wait=0
    while [[ $wait -lt 60 ]]; do
        _REGISTRY=$(lib::get_registry_hostname)
        [[ -n "$_REGISTRY" ]] && return 0
        [[ $wait -eq 0 ]] && lib::log_info "Waiting for registry hostname (up to ~120s)..."
        sleep 2
        wait=$((wait + 1))
    done
    lib::log_error "Registry hostname not available after waiting"
    exit 1
}

lib::setup_registry() {
    lib::require_cmd podman

    _REGISTRY=$(lib::get_registry_hostname)
    if [[ -z "$_REGISTRY" ]]; then
        lib::ensure_registry_route
    fi
    _INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

    lib::log_info "Registry: ${_REGISTRY}"

    lib::ensure_namespace
    local token
    token=$(oc create token builder -n "${AGENTIC_NAMESPACE}")
    if ! podman login -u unused --password "${token}" --tls-verify=false "${_REGISTRY}" >&2; then
        lib::log_error "podman login to ${_REGISTRY} failed"
        exit 1
    fi
    lib::log_success "Logged into registry (builder SA)"
}

lib::ensure_namespace() {
    oc create namespace "${AGENTIC_NAMESPACE}" >/dev/null 2>&1 || true
    lib::log_success "Namespace ${AGENTIC_NAMESPACE} ready"
}

# ---------------------------------------------------------------------------
# Build (local only)
# ---------------------------------------------------------------------------
lib::build_local() {
    local name="$1" source_dir="$2" containerfile="${3:-}"

    if [[ -z "$containerfile" ]]; then
        if [[ -f "${source_dir}/Dockerfile" ]]; then
            containerfile="Dockerfile"
        elif [[ -f "${source_dir}/Containerfile" ]]; then
            containerfile="Containerfile"
        else
            lib::log_error "No Dockerfile or Containerfile found in ${source_dir}"
            exit 1
        fi
    fi

    local local_img="localhost/${name}:dev"

    lib::log_info "Building ${name} from ${source_dir}/${containerfile}..."
    podman build -t "${local_img}" -f "${source_dir}/${containerfile}" "${source_dir}" >&2

    lib::log_success "${name} → ${local_img}"
    printf '%s' "${local_img}"
}

# ---------------------------------------------------------------------------
# Build + push
# ---------------------------------------------------------------------------
lib::build_and_push() {
    local name="$1" source_dir="$2" containerfile="${3:-}"

    if [[ -z "$containerfile" ]]; then
        if [[ -f "${source_dir}/Dockerfile" ]]; then
            containerfile="Dockerfile"
        elif [[ -f "${source_dir}/Containerfile" ]]; then
            containerfile="Containerfile"
        else
            lib::log_error "No Dockerfile or Containerfile found in ${source_dir}"
            exit 1
        fi
    fi

    local push_img="${_REGISTRY}/${AGENTIC_NAMESPACE}/${name}:dev"
    local internal_img="${_INTERNAL_REGISTRY}/${AGENTIC_NAMESPACE}/${name}:dev"

    lib::log_info "Building ${name} from ${source_dir}/${containerfile}..."
    podman build -t "${push_img}" -f "${source_dir}/${containerfile}" "${source_dir}" >&2

    # Ensure imagestream exists so the push target is valid.
    oc create imagestream "${name}" -n "${AGENTIC_NAMESPACE}" >/dev/null 2>&1 || true

    lib::log_info "Pushing ${push_img}..."
    podman push --tls-verify=false "${push_img}" >&2

    lib::log_success "${name} → ${internal_img}"

    # Return the in-cluster image reference.
    printf '%s' "${internal_img}"
}

# ---------------------------------------------------------------------------
# Wait helpers
# ---------------------------------------------------------------------------
lib::wait_for_deployment() {
    local name="$1" ns="${2:-${AGENTIC_NAMESPACE}}" timeout="${3:-300s}"
    lib::log_info "Waiting for deployment/${name} (timeout ${timeout})..."
    if oc rollout status "deployment/${name}" -n "${ns}" --timeout="${timeout}" >/dev/null 2>&1; then
        lib::log_success "deployment/${name} is ready"
    else
        lib::log_error "deployment/${name} did not become ready within ${timeout}"
        oc get pods -n "${ns}" -l app="${name}" -o wide 2>/dev/null || true
        return 1
    fi
}

lib::ensure_pull_secret() {
    local ns="${1:-${AGENTIC_NAMESPACE}}" sa="${2:-default}"
    oc -n "${ns}" create secret docker-registry internal-registry-pull \
        --docker-server="${_REGISTRY}" \
        --docker-username="$(oc whoami)" \
        --docker-password="$(oc whoami -t)" \
        --dry-run=client -o yaml | oc apply -f - >&2
    oc -n "${ns}" secrets link "serviceaccount/${sa}" internal-registry-pull --for=pull 2>/dev/null || true
}
