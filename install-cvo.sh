#!/usr/bin/env bash
# Build and deploy a dev CVO with the agenticrun controller to a test cluster.
#
# Builds the CVO from the cluster-version-operator sibling repo, extracts the
# full release payload from the running cluster (image-references + verification
# configmap), merges in custom agentic-skills / cluster-update-console-plugin
# images, and bakes everything into the dev CVO image.  The result is a dev CVO
# whose release is "real" — all ~130 operator images present, verification keys
# included — so cluster updates work without --force.
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
Build a dev CVO with full release manifest (agenticrun controller + all images).

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
    "")               ;;
    *)                usage >&2; exit 1 ;;
esac
lib::dev_disclaimer

# -- Prerequisites -------------------------------------------------------------

lib::subheading "Dev CVO (full release manifest)"
lib::step "Checking prerequisites..."
for cmd in oc go podman jq gzip; do
    lib::require_cmd "${cmd}"
done
lib::require_oc_login

# -- Resolve CVO repo ---------------------------------------------------------

CVO_DIR=$(lib::resolve_sibling CVO_DIR cluster-version-operator) || {
    lib::log_error "cluster-version-operator not found. Clone it next to this repo or set CVO_DIR."
    exit 1
}
lib::log_success "CVO repo: ${CVO_DIR}"

DOCKERFILE_DEV="${CVO_DIR}/Dockerfile.dev"
IMAGE_REFS_DEV="${CVO_DIR}/.dev-image-references"
RELEASE_META_DEV="${CVO_DIR}/.dev-release-metadata"
VERIFY_CM_DEV="${CVO_DIR}/.dev-verification-configmap.yaml"
RELEASE_EXTRACT_DIR=""

cleanup() {
    rm -f "${DOCKERFILE_DEV}" "${IMAGE_REFS_DEV}" "${RELEASE_META_DEV}" "${VERIFY_CM_DEV}"
    [[ -n "${RELEASE_EXTRACT_DIR}" ]] && rm -rf "${RELEASE_EXTRACT_DIR}"
}
trap cleanup EXIT

# -- Cluster version -----------------------------------------------------------

lib::step "Checking cluster version..."

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

# -- Resolve custom images ----------------------------------------------------

lib::step "Resolving agentic-skills image..."

SKILLS_IMAGE=$(lib::detect_registry_image agentic-skills "${AGENTIC_NAMESPACE}") || {
    lib::log_error "agentic-skills imagestream not found. Push the image first."
    exit 1
}
lib::log_success "Skills image: ${SKILLS_IMAGE}"

CONSOLE_PLUGIN_NS="openshift-cluster-update-console-plugin"

lib::step "Resolving cluster-update-console-plugin image..."

CONSOLE_PLUGIN_IMAGE=$(lib::detect_registry_image cluster-update-console-plugin "${CONSOLE_PLUGIN_NS}") || {
    lib::log_error "cluster-update-console-plugin imagestream not found. Run install-cluster-update-console.sh first."
    exit 1
}
lib::log_success "Console plugin image: ${CONSOLE_PLUGIN_IMAGE}"

# -- Extract release payload ---------------------------------------------------

lib::step "Extracting release payload (image-references + verification config)..."

PULL_SECRET=$(mktemp)
oc get secret pull-secret -n openshift-config \
    -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${PULL_SECRET}"

RELEASE_EXTRACT_DIR=$(mktemp -d)
oc adm release extract -a "${PULL_SECRET}" --to="${RELEASE_EXTRACT_DIR}" "${CURRENT_RELEASE}" >&2
rm -f "${PULL_SECRET}"

# Image-references
cp "${RELEASE_EXTRACT_DIR}/image-references" "${IMAGE_REFS_DEV}"
TAG_COUNT=$(jq '.spec.tags | length' "${IMAGE_REFS_DEV}")
lib::log_success "Extracted ${TAG_COUNT} image tags from release"

# Verification configmap (contains GPG keys + signature store URLs)
HAS_VERIFICATION=false
VERIFY_CM=$(grep -rl "release.openshift.io/verification-config-map" "${RELEASE_EXTRACT_DIR}/" 2>/dev/null | head -1 || echo "")
if [[ -n "${VERIFY_CM}" ]]; then
    cp "${VERIFY_CM}" "${VERIFY_CM_DEV}"
    HAS_VERIFICATION=true
    lib::log_success "Found verification configmap: $(basename "${VERIFY_CM}")"
else
    lib::log_warning "No verification configmap in release — updates will require --force"
fi

rm -rf "${RELEASE_EXTRACT_DIR}"
RELEASE_EXTRACT_DIR=""

# -- Merge custom images into image-references ---------------------------------

lib::step "Merging custom images into image-references..."

# Upsert helper: replace tag if exists, add if not.
_upsert_tag() {
    local file="$1" tag_name="$2" image="$3"
    jq --arg name "${tag_name}" --arg img "${image}" '
        if (.spec.tags | map(.name) | index($name)) then
            .spec.tags |= map(
                if .name == $name then .from.name = $img else . end
            )
        else
            .spec.tags += [{
                "name": $name,
                "from": {"kind": "DockerImage", "name": $img},
                "generation": null,
                "importPolicy": {},
                "referencePolicy": {"type": ""}
            }]
        end
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

_upsert_tag "${IMAGE_REFS_DEV}" "agentic-skills" "${SKILLS_IMAGE}"
_upsert_tag "${IMAGE_REFS_DEV}" "cluster-update-console-plugin" "${CONSOLE_PLUGIN_IMAGE}"

TAG_COUNT=$(jq '.spec.tags | length' "${IMAGE_REFS_DEV}")
lib::log_success "Image-references ready (${TAG_COUNT} tags, custom images merged)"

# -- Generate release-metadata -------------------------------------------------

cat > "${RELEASE_META_DEV}" <<EOF
{"kind":"cincinnati-metadata-v0","version":"${CLUSTER_VERSION}"}
EOF

# -- Build CVO binaries --------------------------------------------------------

lib::step "Building CVO binaries (linux/amd64)..."

(
    cd "${CVO_DIR}"
    export GOOS=linux GOARCH=amd64
    # shellcheck source=/dev/null
    source hack/build-info.sh
    CGO_ENABLED=0 hack/build-go.sh
)

VERSION_OVERRIDE=$(cd "${CVO_DIR}" && source hack/build-info.sh >&2 && echo "${VERSION_OVERRIDE}")
lib::log_success "Built CVO binaries: ${VERSION_OVERRIDE}"

# -- Generate Dockerfile.dev ---------------------------------------------------

lib::step "Generating Dockerfile.dev..."

VERIFY_COPY=""
if [[ "${HAS_VERIFICATION}" == "true" ]]; then
    VERIFY_COPY="COPY .dev-verification-configmap.yaml /manifests/0000_00_cluster-version-operator_verification.yaml"
fi

cat > "${DOCKERFILE_DEV}" <<DOCKERFILE
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
COPY _output/linux/amd64/cluster-version-operator _output/linux/amd64/cluster-version-operator-tests.gz /usr/bin/
COPY install /manifests
COPY vendor/github.com/openshift/api/config/v1/zz_generated.crd-manifests/0000_00_cluster-version-operator_* /manifests/
COPY vendor/github.com/openshift/api/operator/v1alpha1/zz_generated.crd-manifests/0000_00_cluster-version-operator_* /manifests/
COPY bootstrap /bootstrap
RUN rm -f /manifests/0000_50_* && mkdir -p /release-manifests
COPY .dev-release-metadata /release-manifests/release-metadata
COPY .dev-image-references /release-manifests/image-references
${VERIFY_COPY}
ENTRYPOINT ["/usr/bin/cluster-version-operator"]
DOCKERFILE
lib::log_success "Generated Dockerfile.dev (version: ${CLUSTER_VERSION}, ${TAG_COUNT} image tags, verification: ${HAS_VERIFICATION})"

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

RELEASE_ARG_IDX=$(oc get deployment -n "${CVO_NS}" "${CVO_DEPLOYMENT}" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | \
    jq -r 'to_entries[] | select(.value | startswith("--release-image=")) | .key')
if [[ -z "${RELEASE_ARG_IDX}" ]]; then
    lib::log_error "Could not find --release-image arg in CVO deployment"
    exit 1
fi

oc patch -n "${CVO_NS}" deployment "${CVO_DEPLOYMENT}" --type json --patch="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${PULLSPEC}\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/${RELEASE_ARG_IDX}\",\"value\":\"--release-image=${PULLSPEC}\"},
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

printf '%b' "$(cat <<DONE

════════════════════════════════════════════════════════════════
  CVO dev deployment complete! (full release manifest)
  Version: ${VERSION_OVERRIDE} → ${CLUSTER_VERSION}
  Image tags: ${TAG_COUNT} (full release + custom images merged)
  Verification configmap: ${HAS_VERIFICATION}
════════════════════════════════════════════════════════════════

── Summary ─────────────────────────────────────────────────────

  Built CVO from source, extracted the cluster's real release
  payload (~${TAG_COUNT} images + GPG verification keys), merged
  in custom agentic-skills and console-plugin images, and baked
  it all into a single dev image used as both container and
  --release-image.

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

  ${_YELLOW}5. If agenticrun is not created (no upgrade path available),
     point to a mock Cincinnati graph API:${_RESET}

     oc patch clusterversion version --type json -p '[{"op": "add", "path": "/spec/upstream", "value": "https://fauxinnati-fauxinnati.apps.ota-stage.q2z4.p1.openshiftapps.com/api/upgrades_info/graph"}]'
     oc adm upgrade channel smoke-test

     Browse https://fauxinnati-fauxinnati.apps.ota-stage.q2z4.p1.openshiftapps.com/
     to check the available channels in this mock app.

  ${_YELLOW}   Or point to the release CI Cincinnati graph (live):${_RESET}

     oc patch clusterversion/version --patch '{"spec":{"upstream":"https://amd64.ocp.releases.ci.openshift.org/graph"}}' --type=merge

────────────────────────────────────────────────────────────────
DONE
)" >&2
