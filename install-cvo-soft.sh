#!/usr/bin/env bash
# Overlay custom images onto the existing release without rebuilding CVO.
#
# Uses `oc adm release new --from-release` to create a patched release with
# agentic-skills and/or cluster-update-console-plugin images replaced, then
# patches the live CVO to use it as --release-image.
#
# The CVO binary stays stock — this only works when the shipping CVO already
# includes the agenticrun controller and the release payload already contains
# the agentic-skills / cluster-update-console-plugin tags (so we replace, not
# add).  For earlier clusters use install-cvo-full.sh instead.
#
# NOTE: `oc adm release new` may produce OCI-format images.  If the internal
# registry rejects the push, set RELEASE_REGISTRY to an external registry
# (e.g. quay.io/youruser).
#
# WARNING: NEVER RUN THIS AGAINST A PRODUCTION CLUSTER.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

CVO_DEV_PROJECT="cvo-dev"
CVO_NS="openshift-cluster-version"
CVO_DEPLOYMENT="cluster-version-operator"

usage() {
    cat <<EOF
Patch the cluster's release payload with custom images (no CVO rebuild).

Usage:
  ./install-cvo-soft.sh [OPTIONS]

Options:
  --skills-only    Only overlay agentic-skills image
  --console-only   Only overlay cluster-update-console-plugin image
  -h, --help       Show this help

By default both agentic-skills and cluster-update-console-plugin are overlaid.

Environment variables:
  AGENTIC_NAMESPACE    Namespace for agentic-skills (default: openshift-lightspeed)
  RELEASE_REGISTRY     External registry for patched release if internal rejects
                       OCI format (e.g. quay.io/myuser)
EOF
}

# -- Parse args ----------------------------------------------------------------

OVERLAY_SKILLS=true
OVERLAY_CONSOLE=true
for arg in "$@"; do
    case "${arg}" in
        -h|--help)       usage; exit 0 ;;
        --skills-only)   OVERLAY_CONSOLE=false ;;
        --console-only)  OVERLAY_SKILLS=false ;;
        *)               usage >&2; exit 1 ;;
    esac
done
lib::dev_disclaimer

# -- Prerequisites -------------------------------------------------------------

lib::subheading "Soft CVO patch (release overlay)"
lib::step "Checking prerequisites..."
for cmd in oc podman jq; do
    lib::require_cmd "${cmd}"
done
lib::require_oc_login

# -- Current release -----------------------------------------------------------

lib::step "Getting current release image..."

CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
if [[ -z "${CLUSTER_VERSION}" ]]; then
    lib::log_error "Could not determine cluster version"
    exit 1
fi

# Find the original release image. If desired.image already points to the
# internal registry (from a previous install), fall back to history.
CURRENT_RELEASE=$(oc get clusterversion version -o jsonpath='{.status.desired.image}')
if [[ "${CURRENT_RELEASE}" == *"image-registry.openshift-image-registry.svc"* ]]; then
    lib::log_warning "desired.image points to internal registry (previous install)"
    lib::log_info "Searching history for original release image..."
    CURRENT_RELEASE=$(oc get clusterversion version -o json | \
        jq -r '[.status.history[].image | select(test("image-registry.openshift-image-registry") | not)] | first // empty')
    if [[ -z "${CURRENT_RELEASE}" ]]; then
        lib::log_error "Could not find original release image in history"
        lib::log_error "Set ORIGINAL_RELEASE=<image> and re-run"
        exit 1
    fi
fi
CURRENT_RELEASE="${ORIGINAL_RELEASE:-${CURRENT_RELEASE}}"

lib::log_success "Cluster version: ${CLUSTER_VERSION}"
lib::log_success "Release image: ${CURRENT_RELEASE}"

# -- Capture original --release-image for revert --------------------------------

ORIGINAL_RELEASE_ARG=$(oc get deployment -n "${CVO_NS}" "${CVO_DEPLOYMENT}" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | \
    jq -r '.[] | select(startswith("--release-image="))')
lib::log_info "Original arg: ${ORIGINAL_RELEASE_ARG}"

# -- Ensure cvo-dev project ----------------------------------------------------

lib::step "Ensuring '${CVO_DEV_PROJECT}' project..."
if oc get project "${CVO_DEV_PROJECT}" &>/dev/null; then
    lib::log_success "Project '${CVO_DEV_PROJECT}' already exists"
else
    oc new-project "${CVO_DEV_PROJECT}" --skip-config-write &>/dev/null
    lib::log_success "Created project '${CVO_DEV_PROJECT}'"
fi

# -- Registry ------------------------------------------------------------------

lib::step "Setting up registry..."
_REGISTRY=$(lib::get_registry_hostname)
if [[ -z "$_REGISTRY" ]]; then
    lib::ensure_registry_route
fi
podman login --tls-verify=false -u kubeadmin -p "$(oc whoami -t)" "${_REGISTRY}" >&2
lib::log_success "Logged into registry: ${_REGISTRY}"

# -- Resolve images to overlay -------------------------------------------------

OVERLAY_ARGS=()

if [[ "${OVERLAY_SKILLS}" == "true" ]]; then
    lib::step "Resolving agentic-skills image..."
    SKILLS_IMAGE=$(lib::detect_registry_image agentic-skills "${AGENTIC_NAMESPACE}") || {
        lib::log_error "agentic-skills imagestream not found. Push the image first."
        exit 1
    }
    lib::log_success "Skills image: ${SKILLS_IMAGE}"
    OVERLAY_ARGS+=("agentic-skills=${SKILLS_IMAGE}")
fi

if [[ "${OVERLAY_CONSOLE}" == "true" ]]; then
    lib::step "Resolving cluster-update-console-plugin image..."
    CONSOLE_PLUGIN_NS="openshift-cluster-update-console-plugin"
    CONSOLE_PLUGIN_IMAGE=$(lib::detect_registry_image cluster-update-console-plugin "${CONSOLE_PLUGIN_NS}") || {
        lib::log_error "cluster-update-console-plugin imagestream not found. Run install-cluster-update-console.sh first."
        exit 1
    }
    lib::log_success "Console plugin image: ${CONSOLE_PLUGIN_IMAGE}"
    OVERLAY_ARGS+=("cluster-update-console-plugin=${CONSOLE_PLUGIN_IMAGE}")
fi

if [[ ${#OVERLAY_ARGS[@]} -eq 0 ]]; then
    lib::log_error "No images selected for overlay"
    exit 1
fi

# -- Create patched release ----------------------------------------------------

lib::step "Creating patched release image..."

RELEASE_TARGET="${RELEASE_REGISTRY:-${_REGISTRY}/${CVO_DEV_PROJECT}}/custom-release:${CLUSTER_VERSION}"

lib::log_info "From:    ${CURRENT_RELEASE}"
lib::log_info "Overlay: ${OVERLAY_ARGS[*]}"
lib::log_info "To:      ${RELEASE_TARGET}"

# Use cluster pull secret for access to the source release image.
PULL_SECRET=$(mktemp)
trap "rm -f '${PULL_SECRET}'" EXIT
oc get secret pull-secret -n openshift-config \
    -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${PULL_SECRET}"

oc adm release new \
    -a "${PULL_SECRET}" \
    --from-release="${CURRENT_RELEASE}" \
    "${OVERLAY_ARGS[@]}" \
    --to-image="${RELEASE_TARGET}" \
    --insecure=true 2>&1 | grep -v "^Warning:" >&2

lib::log_success "Patched release pushed"

# -- Get pullspec --------------------------------------------------------------

if [[ -n "${RELEASE_REGISTRY:-}" ]]; then
    RELEASE_PULLSPEC="${RELEASE_TARGET}"
else
    RELEASE_PULLSPEC=$(oc get imagestream -n "${CVO_DEV_PROJECT}" custom-release \
        -o jsonpath="{.status.tags[?(@.tag==\"${CLUSTER_VERSION}\")].items[0].dockerImageReference}" 2>/dev/null || echo "")
    if [[ -z "${RELEASE_PULLSPEC}" ]]; then
        RELEASE_PULLSPEC="${RELEASE_TARGET}"
        lib::log_warning "Using push target as pullspec (imagestream lookup failed)"
    fi
fi
lib::log_info "Pullspec: ${RELEASE_PULLSPEC}"

# -- Patch CVO deployment -----------------------------------------------------

lib::step "Patching CVO --release-image..."

RELEASE_ARG_IDX=$(oc get deployment -n "${CVO_NS}" "${CVO_DEPLOYMENT}" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | \
    jq -r 'to_entries[] | select(.value | startswith("--release-image=")) | .key')
if [[ -z "${RELEASE_ARG_IDX}" ]]; then
    lib::log_error "Could not find --release-image arg in CVO deployment"
    exit 1
fi

oc patch -n "${CVO_NS}" deployment "${CVO_DEPLOYMENT}" --type json --patch="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/${RELEASE_ARG_IDX}\",\"value\":\"--release-image=${RELEASE_PULLSPEC}\"}
]" 2>&1 | grep -v "^Warning:" >&2
lib::log_success "Patched --release-image"

lib::wait_for_deployment "${CVO_DEPLOYMENT}" "${CVO_NS}" "120s"

# -- Image-puller access -------------------------------------------------------

oc policy add-role-to-group system:image-puller \
    "system:serviceaccounts:${AGENTIC_NAMESPACE}" -n "${CVO_DEV_PROJECT}" >&2
lib::log_success "Image-puller granted"

# -- Summary -------------------------------------------------------------------

echo "" >&2
echo "  Pod status:" >&2
oc get pods -n "${CVO_NS}" -l k8s-app=cluster-version-operator 2>&1 | sed 's/^/    /' >&2
echo "" >&2
echo "  ClusterVersion conditions:" >&2
oc get clusterversion version \
    -o jsonpath='{range .status.conditions[*]}    {.type}={.status}{"\n"}{end}' 2>/dev/null >&2 || true

printf '%b' "$(cat <<DONE

════════════════════════════════════════════════════════════════
  Soft CVO patch complete!
  Overlaid: ${OVERLAY_ARGS[*]}
════════════════════════════════════════════════════════════════

── When to use this vs install-cvo-full.sh ─────────────────────

  This script works when the stock CVO already ships with the
  agenticrun controller and the release already has the image
  tags (agentic-skills, cluster-update-console-plugin).  It
  swaps them for your dev images.

  If the stock CVO does NOT have the agenticrun controller,
  use install-cvo-full.sh instead (builds CVO from source).

── Next steps ──────────────────────────────────────────────────

  1. oc adm upgrade
  2. oc logs -n ${CVO_NS} -l k8s-app=cluster-version-operator -f
  3. oc get agenticruns -n ${AGENTIC_NAMESPACE}

  ${_YELLOW}To revert to original release:${_RESET}

    oc patch -n ${CVO_NS} deployment ${CVO_DEPLOYMENT} --type json \\
      -p '[{"op":"replace","path":"/spec/template/spec/containers/0/args/${RELEASE_ARG_IDX}","value":"${ORIGINAL_RELEASE_ARG}"}]'

────────────────────────────────────────────────────────────────
DONE
)" >&2
