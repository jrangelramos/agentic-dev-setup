#!/usr/bin/env bash
# Build and deploy a dev CVO with the agenticrun controller to a test cluster.
#
# Builds the CVO from the cluster-version-operator sibling repo, generates a
# dev image with embedded release metadata and agentic-skills reference, pushes
# it to the cluster's internal registry, and patches the live CVO deployment.
#
# Note on release payload:
#   The standard dev workflow uses `oc adm release new` to build a full release
#   payload image.  This script skips that because `oc adm release new` produces
#   OCI-format images that the internal registry + CRI-O combination rejects.
#   Instead, the dev image is built with minimal release-metadata and
#   image-references baked in and used as both the container image and the
#   --release-image arg.  CVO reconciles from itself, skipping manifests whose
#   images aren't in the references.
#
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
Build and deploy a dev CVO with the agenticrun controller.

Usage:
  ./install-cvo.sh [--skip-tp-check]

Options:
  --skip-tp-check   Skip TechPreviewNoUpgrade feature gate check.
                    Use when you have patched shouldEnableAgenticRunController()
                    to return true in pkg/cvo/cvo.go.

Environment variables:
  CVO_DIR              Path to cluster-version-operator repo (default: ../cluster-version-operator)
  AGENTIC_NAMESPACE    Namespace where agentic-skills image lives (default: openshift-lightspeed)
EOF
}

# -- Parse args ----------------------------------------------------------------

SKIP_TP_CHECK=false
case "${1:-}" in
    -h|--help)        usage; exit 0 ;;
    --skip-tp-check)  SKIP_TP_CHECK=true ;;
    "")               ;; # no args is fine
    *)                usage >&2; exit 1 ;;
esac
lib::dev_disclaimer

# -- Prerequisites -------------------------------------------------------------

lib::subheading "Dev CVO (agenticrun controller)"
lib::step "Checking prerequisites..."
for cmd in oc go podman jq gzip; do
    lib::require_cmd "${cmd}"
done
lib::require_oc_login

# -- Resolve CVO repo ----------------------------------------------------------

CVO_DIR=$(lib::resolve_sibling CVO_DIR cluster-version-operator) || {
    lib::log_error "cluster-version-operator not found. Clone it next to this repo or set CVO_DIR."
    exit 1
}
lib::log_success "CVO repo: ${CVO_DIR}"

DOCKERFILE_DEV="${CVO_DIR}/Dockerfile.dev"

cleanup() {
    rm -f "${DOCKERFILE_DEV}"
}
trap cleanup EXIT

# -- Check cluster version -----------------------------------------------------

lib::step "Checking cluster version..."

CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
if [[ -z "${CLUSTER_VERSION}" ]]; then
    lib::log_error "Could not determine cluster version"
    exit 1
fi
lib::log_success "Cluster version: ${CLUSTER_VERSION}"

# -- Ensure cvo-dev project ----------------------------------------------------

lib::step "Ensuring '${CVO_DEV_PROJECT}' project exists..."

if oc get project "${CVO_DEV_PROJECT}" &>/dev/null; then
    lib::log_success "Project '${CVO_DEV_PROJECT}' already exists"
else
    oc new-project "${CVO_DEV_PROJECT}" --skip-config-write &>/dev/null
    lib::log_success "Created project '${CVO_DEV_PROJECT}'"
fi

# -- Set up registry -----------------------------------------------------------

lib::step "Setting up internal registry..."

lib::require_cmd podman

_REGISTRY=$(lib::get_registry_hostname)
if [[ -z "$_REGISTRY" ]]; then
    lib::ensure_registry_route
fi

podman login --tls-verify=false -u kubeadmin -p "$(oc whoami -t)" "${_REGISTRY}" >&2
lib::log_success "Logged into registry: ${_REGISTRY}"

# -- Resolve skills image ------------------------------------------------------

lib::step "Resolving agentic-skills image..."

SKILLS_IMAGE=$(oc get imagestream -n "${AGENTIC_NAMESPACE}" agentic-skills \
    -o jsonpath='{.status.tags[?(@.tag=="latest")].items[0].dockerImageReference}' 2>/dev/null || echo "")
if [[ -z "${SKILLS_IMAGE}" ]]; then
    lib::log_warning "No 'latest' tag found, trying 'dev' tag"
    SKILLS_IMAGE=$(oc get imagestream -n "${AGENTIC_NAMESPACE}" agentic-skills \
        -o jsonpath='{.status.tags[?(@.tag=="dev")].items[0].dockerImageReference}' 2>/dev/null || echo "")
fi
if [[ -z "${SKILLS_IMAGE}" ]]; then
    lib::log_error "agentic-skills imagestream not found in ${AGENTIC_NAMESPACE} (tried 'latest' and 'dev' tags). Push the image first."
    exit 1
fi
lib::log_success "Skills image: ${SKILLS_IMAGE}"

# -- Build CVO binaries --------------------------------------------------------

lib::step "Building CVO binaries (linux/amd64)..."

(
    cd "${CVO_DIR}"
    export GOOS=linux GOARCH=amd64
    # shellcheck source=/dev/null
    source hack/build-info.sh
    CGO_ENABLED=0 hack/build-go.sh
)

# Retrieve VERSION_OVERRIDE from the CVO repo's build-info (needed for image tags).
VERSION_OVERRIDE=$(cd "${CVO_DIR}" && source hack/build-info.sh >&2 && echo "${VERSION_OVERRIDE}")
lib::log_success "Built CVO binaries: ${VERSION_OVERRIDE}"

# -- Generate Dockerfile.dev ---------------------------------------------------

lib::step "Generating Dockerfile.dev..."

cat > "${DOCKERFILE_DEV}" <<DOCKERFILE
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
COPY _output/linux/amd64/cluster-version-operator _output/linux/amd64/cluster-version-operator-tests.gz /usr/bin/
COPY install /manifests
COPY vendor/github.com/openshift/api/config/v1/zz_generated.crd-manifests/0000_00_cluster-version-operator_* /manifests/
COPY vendor/github.com/openshift/api/operator/v1alpha1/zz_generated.crd-manifests/0000_00_cluster-version-operator_* /manifests/
COPY bootstrap /bootstrap
RUN rm -f /manifests/0000_50_* && \\
    mkdir -p /release-manifests && \\
    echo '{"kind":"cincinnati-metadata-v0","version":"${CLUSTER_VERSION}"}' > /release-manifests/release-metadata && \\
    printf '{"kind":"ImageStream","apiVersion":"image.openshift.io/v1","metadata":{"name":"${CLUSTER_VERSION}","creationTimestamp":null},"spec":{"tags":[{"name":"cluster-version-operator","annotations":{"io.openshift.build.versions":"kubernetes=1.35.0"},"from":{"kind":"DockerImage","name":"cluster-version-operator:latest"},"generation":null,"importPolicy":{},"referencePolicy":{"type":""}},{"name":"agentic-skills","from":{"kind":"DockerImage","name":"${SKILLS_IMAGE}"},"generation":null,"importPolicy":{},"referencePolicy":{"type":""}}]}}' > /release-manifests/image-references
ENTRYPOINT ["/usr/bin/cluster-version-operator"]
DOCKERFILE
lib::log_success "Generated Dockerfile.dev (version: ${CLUSTER_VERSION})"

# -- Build container image -----------------------------------------------------

lib::step "Building and pushing container image..."

IMAGE_TAG="cluster-version-operator:${VERSION_OVERRIDE}"
podman build -t "${IMAGE_TAG}" -f "${DOCKERFILE_DEV}" --no-cache "${CVO_DIR}" >&2

podman push --tls-verify=false \
    "${IMAGE_TAG}" \
    "${_REGISTRY}/${CVO_DEV_PROJECT}/origin-cluster-version-operator:${VERSION_OVERRIDE}" >&2
podman push --tls-verify=false \
    "${IMAGE_TAG}" \
    "${_REGISTRY}/${CVO_DEV_PROJECT}/origin-cluster-version-operator:latest" >&2
lib::log_success "Pushed to ${_REGISTRY}/${CVO_DEV_PROJECT}/origin-cluster-version-operator:{${VERSION_OVERRIDE},latest}"

# -- Patch CVO deployment -----------------------------------------------------

lib::step "Patching CVO deployment..."

PULLSPEC=$(oc get imagestream -n "${CVO_DEV_PROJECT}" origin-cluster-version-operator \
    -o jsonpath='{.status.tags[?(@.tag=="latest")].items[0].dockerImageReference}')
if [[ -z "${PULLSPEC}" ]]; then
    lib::log_error "Could not get pullspec from imagestream"
    exit 1
fi
lib::log_info "Pullspec: ${PULLSPEC}"

oc patch -n "${CVO_NS}" deployment "${CVO_DEPLOYMENT}" --type json --patch="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${PULLSPEC}\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/1\",\"value\":\"--release-image=${PULLSPEC}\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"Always\"}
]" 2>&1 | grep -v "^Warning:" >&2
lib::log_success "Patched image, --release-image, and imagePullPolicy"

lib::wait_for_deployment "${CVO_DEPLOYMENT}" "${CVO_NS}" "120s"

# -- Grant image-puller access -------------------------------------------------

oc policy add-role-to-group system:image-puller \
    "system:serviceaccounts:${AGENTIC_NAMESPACE}" -n "${CVO_DEV_PROJECT}" >&2
lib::log_success "Image-puller granted to ${AGENTIC_NAMESPACE} serviceaccounts"

# -- Verify and summarize ------------------------------------------------------

echo "" >&2
echo "  Pod status:" >&2
oc get pods -n "${CVO_NS}" -l k8s-app=cluster-version-operator 2>&1 | sed 's/^/    /' >&2
echo "" >&2
echo "  Pod image:" >&2
echo "    $(oc get pods -n "${CVO_NS}" -l k8s-app=cluster-version-operator \
    -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo 'pending...')" >&2
echo "" >&2
echo "  ClusterVersion conditions:" >&2
oc get clusterversion version \
    -o jsonpath='{range .status.conditions[*]}    {.type}={.status}{"\n"}{end}' 2>/dev/null >&2 || true

cat >&2 <<DONE

════════════════════════════════════════════════════════════════
  CVO dev deployment complete!
  Version: ${VERSION_OVERRIDE} → ${CLUSTER_VERSION}
════════════════════════════════════════════════════════════════

── Next steps ──────────────────────────────────────────────────

  1. Trigger an upgrade check:

     oc adm upgrade

  2. Watch CVO logs:

     oc logs -n ${CVO_NS} -l k8s-app=cluster-version-operator -f

  3. Check agenticruns (created when updates are available):

     oc get agenticruns -n ${AGENTIC_NAMESPACE}
     oc get agenticruns -n ${AGENTIC_NAMESPACE} -o yaml

  4. Check ClusterVersion status:

     oc get clusterversion version -o yaml

────────────────────────────────────────────────────────────────
DONE
