#!/usr/bin/env bash

set -Eeuo pipefail

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-lakesail-poc}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-8}"
MINIKUBE_MEMORY_MB="${MINIKUBE_MEMORY_MB:-12288}"
MINIKUBE_DISK_SIZE="${MINIKUBE_DISK_SIZE:-40g}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argo}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
FORCE_TOOL_INSTALL="${FORCE_TOOL_INSTALL:-0}"
TEMP_DIR=""
ARGO_CRDS=(
  clusterworkflowtemplates.argoproj.io
  cronworkflows.argoproj.io
  workflowartifactgctasks.argoproj.io
  workfloweventbindings.argoproj.io
  workflows.argoproj.io
  workflowtaskresults.argoproj.io
  workflowtasksets.argoproj.io
  workflowtemplates.argoproj.io
)

cleanup_temp_dir() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}

trap cleanup_temp_dir EXIT

usage() {
  printf '%s\n' \
    "Usage: $0 setup|status|cleanup" \
    "" \
    "Commands:" \
    "  setup    Install kubectl, Minikube and Argo CLI; create the cluster; install Argo Workflows" \
    "  status   Show the dedicated Minikube cluster and Argo status" \
    "  cleanup  Delete only the '${MINIKUBE_PROFILE}' Minikube cluster" \
    "" \
    "Optional environment variables:" \
    "  MINIKUBE_PROFILE       Default: lakesail-poc" \
    "  MINIKUBE_CPUS          Default: 8" \
    "  MINIKUBE_MEMORY_MB     Default: 12288" \
    "  MINIKUBE_DISK_SIZE     Default: 40g" \
    "  ARGO_NAMESPACE         Default: argo" \
    "  INSTALL_DIR            Default: /usr/local/bin" \
    "  FORCE_TOOL_INSTALL     Set to 1 to reinstall/update CLI tools"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

validate_profile() {
  [[ -n "$MINIKUBE_PROFILE" ]] || die "MINIKUBE_PROFILE cannot be empty"
  [[ "$MINIKUBE_PROFILE" =~ ^[a-zA-Z0-9._-]+$ ]] || \
    die "MINIKUBE_PROFILE contains unsupported characters: $MINIKUBE_PROFILE"
}

detect_architecture() {
  case "$(uname -m)" in
    x86_64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

require_base_tools() {
  command -v docker >/dev/null 2>&1 || die "Required command not found: docker"

  docker info >/dev/null 2>&1 || \
    die "Docker is not running or your user cannot access it. Test with: docker info"
}

install_tools() {
  local architecture="" kubectl_version tool
  local install_minikube=0 install_kubectl=0 install_argo_cli=0

  if [[ "$FORCE_TOOL_INSTALL" == "1" ]] || ! command -v minikube >/dev/null 2>&1; then
    install_minikube=1
  else
    printf 'Minikube is already installed; skipping installation.\n'
  fi

  if [[ "$FORCE_TOOL_INSTALL" == "1" ]] || ! command -v kubectl >/dev/null 2>&1; then
    install_kubectl=1
  else
    printf 'kubectl is already installed; skipping installation.\n'
  fi

  if [[ "$FORCE_TOOL_INSTALL" == "1" ]] || ! command -v argo >/dev/null 2>&1; then
    install_argo_cli=1
  else
    printf 'Argo Workflows CLI is already installed; skipping installation.\n'
  fi

  if (( install_minikube || install_kubectl || install_argo_cli )); then
    for tool in curl sudo mktemp; do
      command -v "$tool" >/dev/null 2>&1 || die "Required command not found: $tool"
    done
    architecture="$(detect_architecture)"
    TEMP_DIR="$(mktemp -d)"
  fi

  if (( install_minikube )); then
    printf 'Installing Minikube for linux/%s...\n' "$architecture"
    curl --fail --location --silent --show-error \
      "https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-${architecture}" \
      --output "$TEMP_DIR/minikube"
    sudo install -m 0755 "$TEMP_DIR/minikube" "$INSTALL_DIR/minikube"
  fi

  if (( install_kubectl )); then
    command -v sha256sum >/dev/null 2>&1 || die "Required command not found: sha256sum"
    printf 'Installing kubectl for linux/%s...\n' "$architecture"
    kubectl_version="$(curl --fail --location --silent --show-error \
      https://dl.k8s.io/release/stable.txt)"
    curl --fail --location --silent --show-error \
      "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${architecture}/kubectl" \
      --output "$TEMP_DIR/kubectl"
    curl --fail --location --silent --show-error \
      "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${architecture}/kubectl.sha256" \
      --output "$TEMP_DIR/kubectl.sha256"
    (
      cd "$TEMP_DIR"
      printf '%s  kubectl\n' "$(<kubectl.sha256)" | sha256sum --check --status
    ) || die "kubectl checksum verification failed"
    sudo install -m 0755 "$TEMP_DIR/kubectl" "$INSTALL_DIR/kubectl"
  fi

  if (( install_argo_cli )); then
    command -v gzip >/dev/null 2>&1 || die "Required command not found: gzip"
    printf 'Installing Argo Workflows CLI for linux/%s...\n' "$architecture"
    curl --fail --location --silent --show-error \
      "https://github.com/argoproj/argo-workflows/releases/latest/download/argo-linux-${architecture}.gz" \
      --output "$TEMP_DIR/argo.gz"
    gzip --decompress "$TEMP_DIR/argo.gz"
    sudo install -m 0755 "$TEMP_DIR/argo" "$INSTALL_DIR/argo"
  fi

  printf 'Available versions:\n'
  minikube version --short
  kubectl version --client=true
  argo version --short
}

start_cluster() {
  if minikube status --profile "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
    printf 'Minikube profile %s is already running; reusing it.\n' "$MINIKUBE_PROFILE"
  else
    printf 'Starting Minikube profile %s...\n' "$MINIKUBE_PROFILE"
    minikube start \
      --profile "$MINIKUBE_PROFILE" \
      --driver docker \
      --cpus "$MINIKUBE_CPUS" \
      --memory "$MINIKUBE_MEMORY_MB" \
      --disk-size "$MINIKUBE_DISK_SIZE"
  fi

  kubectl config use-context "$MINIKUBE_PROFILE" >/dev/null
  minikube addons enable metrics-server --profile "$MINIKUBE_PROFILE"
}

argo_crds_ready() {
  local crd

  for crd in "${ARGO_CRDS[@]}"; do
    kubectl get "crd/$crd" >/dev/null 2>&1 || return 1
    [[ "$(kubectl get "crd/$crd" \
      --output jsonpath='{.status.conditions[?(@.type=="Established")].status}' \
      2>/dev/null)" == "True" ]] || return 1
  done
}

install_argo() {
  local applied_manifest=0 attempt crd

  if kubectl get namespace "$ARGO_NAMESPACE" >/dev/null 2>&1; then
    printf 'Namespace %s already exists.\n' "$ARGO_NAMESPACE"
  else
    kubectl create namespace "$ARGO_NAMESPACE"
  fi

  if argo_crds_ready && \
     kubectl get deployment workflow-controller --namespace "$ARGO_NAMESPACE" >/dev/null 2>&1 && \
     kubectl get deployment argo-server --namespace "$ARGO_NAMESPACE" >/dev/null 2>&1; then
    printf 'Argo Workflows and all required CRDs are already installed.\n'
  else
    printf 'Installing or repairing Argo Workflows in namespace %s...\n' "$ARGO_NAMESPACE"
    # Argo CRDs are too large for kubectl's client-side last-applied annotation.
    # Server-side apply avoids the 256 KiB annotation limit and also repairs a
    # partially completed previous installation.
    kubectl apply \
      --server-side \
      --force-conflicts \
      --namespace "$ARGO_NAMESPACE" \
      --filename https://github.com/argoproj/argo-workflows/releases/latest/download/install.yaml
    applied_manifest=1
  fi

  printf 'Waiting for Argo CRDs to become established...\n'
  for crd in "${ARGO_CRDS[@]}"; do
    kubectl wait \
      --for=condition=Established \
      "crd/$crd" \
      --timeout=180s
  done

  # A CRD can be Established just before the API discovery endpoint refreshes.
  # Confirm the Workflow resource itself is queryable before starting controllers.
  for attempt in {1..30}; do
    if kubectl get workflows.argoproj.io \
      --namespace "$ARGO_NAMESPACE" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  kubectl get workflows.argoproj.io \
    --namespace "$ARGO_NAMESPACE" >/dev/null 2>&1 || \
    die "Argo Workflow API did not become available after CRD installation"

  if (( applied_manifest )); then
    printf 'Restarting Argo deployments after CRD repair...\n'
    kubectl rollout restart \
      --namespace "$ARGO_NAMESPACE" \
      deployment/workflow-controller \
      deployment/argo-server
  fi

  kubectl rollout status \
    --namespace "$ARGO_NAMESPACE" \
    deployment/workflow-controller \
    --timeout=300s

  kubectl rollout status \
    --namespace "$ARGO_NAMESPACE" \
    deployment/argo-server \
    --timeout=300s
}

show_status() {
  minikube status --profile "$MINIKUBE_PROFILE"
  kubectl config use-context "$MINIKUBE_PROFILE" >/dev/null

  printf '\nKubernetes nodes:\n'
  kubectl get nodes --output wide

  printf '\nArgo pods:\n'
  kubectl get pods --namespace "$ARGO_NAMESPACE" --output wide

  printf '\nArgo workflows:\n'
  kubectl get workflows.argoproj.io --namespace "$ARGO_NAMESPACE" 2>/dev/null || true
}

cleanup_cluster() {
  if ! minikube profile list --output json 2>/dev/null | \
      grep -Fq "\"Name\": \"${MINIKUBE_PROFILE}\""; then
    printf 'Minikube profile %s does not exist; nothing to clean up.\n' "$MINIKUBE_PROFILE"
    return
  fi

  printf 'This will delete only Minikube profile %s and everything inside it.\n' \
    "$MINIKUBE_PROFILE"
  printf 'Type the profile name to confirm: '
  read -r confirmation

  [[ "$confirmation" == "$MINIKUBE_PROFILE" ]] || \
    die "Confirmation did not match; cleanup cancelled"

  minikube delete --profile "$MINIKUBE_PROFILE"
  printf 'Deleted Minikube profile %s. Installed CLI binaries were kept.\n' \
    "$MINIKUBE_PROFILE"
}

main() {
  validate_profile

  case "${1:-}" in
    setup)
      require_base_tools
      install_tools
      start_cluster
      install_argo
      show_status
      printf '\nSetup complete. To open the Argo UI, run:\n'
      printf 'kubectl -n %s port-forward service/argo-server 2746:2746\n' \
        "$ARGO_NAMESPACE"
      printf 'Then open: https://localhost:2746\n'
      ;;
    status)
      command -v minikube >/dev/null 2>&1 || die "Minikube is not installed"
      command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed"
      show_status
      ;;
    cleanup)
      command -v minikube >/dev/null 2>&1 || die "Minikube is not installed"
      cleanup_cluster
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
