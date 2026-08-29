#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_LOCAL_FILE="${SCRIPT_DIR}/env.local.sh"
PYTHON_FILE="${PYTHON_FILE:-${SCRIPT_DIR}/lakesail_distributed_test.py}"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"

if [[ -f "$ENV_LOCAL_FILE" ]]; then
  # Load repo-local overrides such as S3_BUCKET without hardcoding them here.
  # shellcheck disable=SC1090
  source "$ENV_LOCAL_FILE"
fi

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-lakesail-poc}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argo}"
WORKFLOW_NAME="${WORKFLOW_NAME:-lakesail-distributed-poc}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-lakesail-runner}"
CONFIG_MAP_NAME="${CONFIG_MAP_NAME:-lakesail-distributed-test}"
AWS_SECRET_NAME="${AWS_SECRET_NAME:-lakesail-aws-credentials}"

AWS_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-${HOME}/lakesail-credentials}"
AWS_PROFILE="${AWS_PROFILE:-lakesail}"
AWS_REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-}"
GLUE_CATALOG="${GLUE_CATALOG:-glue}"
GLUE_DATABASE="${GLUE_DATABASE:-lakesail_poc}"

SAIL_IMAGE="${SAIL_IMAGE:-lakesail-poc:pysail-0.6.6-rustls-aws-lc-v4}"
SAIL_SOURCE_TAG="${SAIL_SOURCE_TAG:-v0.6.6}"
SAIL_PATCH_REVISION="rustls-aws-lc-idempotent-v3"
FORCE_IMAGE_BUILD="${FORCE_IMAGE_BUILD:-0}"
FORCE_IMAGE_LOAD="${FORCE_IMAGE_LOAD:-0}"
IMAGE_WAS_BUILT=0

POC_ROW_COUNT="${POC_ROW_COUNT:-100000}"
POC_PARTITIONS="${POC_PARTITIONS:-4}"
SAIL_WORKER_INITIAL_COUNT="${SAIL_WORKER_INITIAL_COUNT:-4}"
SAIL_WORKER_MAX_COUNT="${SAIL_WORKER_MAX_COUNT:-4}"
SAIL_WORKER_TASK_SLOTS="${SAIL_WORKER_TASK_SLOTS:-1}"
MONITOR_INTERVAL_SECONDS="${MONITOR_INTERVAL_SECONDS:-5}"
WORKER_FAILURE_GRACE_POLLS="${WORKER_FAILURE_GRACE_POLLS:-3}"

log() {
  printf '[%s] %s\n' "$(date --utc '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 run|status|logs|cleanup" \
    "" \
    "Commands:" \
    "  run      Prepare all resources, submit the POC, wait and print logs" \
    "  status   Show the workflow, driver pod and LakeSail worker pods" \
    "  logs     Print logs from the current workflow" \
    "  cleanup  Remove only this POC's Kubernetes resources" \
    "" \
    "Common overrides:" \
    "  POC_ROW_COUNT=100000 POC_PARTITIONS=4 $0 run" \
    "  MONITOR_INTERVAL_SECONDS=10 $0 run" \
    "  FORCE_IMAGE_BUILD=1 $0 run" \
    "  S3_BUCKET=your-bucket-name $0 run" \
    "  AWS_CREDENTIALS_FILE=/path/to/credentials $0 run" \
    "  or create ${ENV_LOCAL_FILE} and rerun" \
    "" \
    "The image is built from requirements.txt beside this script." \
    "Its dependency checksum is used to detect when a rebuild is required."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_positive_integer() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer"
}

validate_configuration() {
  local kubernetes_name_pattern='^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'

  [[ -f "$PYTHON_FILE" ]] || die "Python test not found: $PYTHON_FILE"
  [[ -f "$REQUIREMENTS_FILE" ]] || \
    die "Dependency file not found: $REQUIREMENTS_FILE"
  [[ -f "$AWS_CREDENTIALS_FILE" ]] || \
    die "AWS credentials file not found: $AWS_CREDENTIALS_FILE"

  [[ "$ARGO_NAMESPACE" =~ $kubernetes_name_pattern ]] || \
    die "Invalid ARGO_NAMESPACE: $ARGO_NAMESPACE"
  [[ "$WORKFLOW_NAME" =~ $kubernetes_name_pattern ]] || \
    die "Invalid WORKFLOW_NAME: $WORKFLOW_NAME"
  [[ "$SERVICE_ACCOUNT" =~ $kubernetes_name_pattern ]] || \
    die "Invalid SERVICE_ACCOUNT: $SERVICE_ACCOUNT"
  [[ "$CONFIG_MAP_NAME" =~ $kubernetes_name_pattern ]] || \
    die "Invalid CONFIG_MAP_NAME: $CONFIG_MAP_NAME"
  [[ "$AWS_SECRET_NAME" =~ $kubernetes_name_pattern ]] || \
    die "Invalid AWS_SECRET_NAME: $AWS_SECRET_NAME"

  [[ "$SAIL_IMAGE" =~ ^[a-zA-Z0-9._/@:-]+$ ]] || \
    die "SAIL_IMAGE contains unsupported characters"
  [[ "$AWS_PROFILE" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid AWS_PROFILE"
  [[ "$AWS_REGION" =~ ^[a-z0-9-]+$ ]] || die "Invalid AWS_REGION"
  [[ -n "$S3_BUCKET" ]] || \
    die "S3_BUCKET must be set. Export it or add it to ${ENV_LOCAL_FILE}"
  [[ "$S3_BUCKET" =~ ^[a-z0-9.-]+$ ]] || die "Invalid S3_BUCKET"
  [[ "$GLUE_CATALOG" =~ ^[a-zA-Z0-9_]+$ ]] || die "Invalid GLUE_CATALOG"
  [[ "$GLUE_DATABASE" =~ ^[a-zA-Z0-9_]+$ ]] || die "Invalid GLUE_DATABASE"

  validate_positive_integer POC_ROW_COUNT "$POC_ROW_COUNT"
  validate_positive_integer POC_PARTITIONS "$POC_PARTITIONS"
  validate_positive_integer SAIL_WORKER_INITIAL_COUNT \
    "$SAIL_WORKER_INITIAL_COUNT"
  validate_positive_integer SAIL_WORKER_MAX_COUNT "$SAIL_WORKER_MAX_COUNT"
  validate_positive_integer SAIL_WORKER_TASK_SLOTS "$SAIL_WORKER_TASK_SLOTS"
  validate_positive_integer MONITOR_INTERVAL_SECONDS "$MONITOR_INTERVAL_SECONDS"
  validate_positive_integer WORKER_FAILURE_GRACE_POLLS \
    "$WORKER_FAILURE_GRACE_POLLS"

  (( SAIL_WORKER_INITIAL_COUNT <= SAIL_WORKER_MAX_COUNT )) || \
    die "SAIL_WORKER_INITIAL_COUNT cannot exceed SAIL_WORKER_MAX_COUNT"
}

print_worker_failure_diagnostics() {
  local worker_pod="$1"
  local termination="" events="" worker_logs="" previous_logs=""

  termination="$(kubectl get "pod/${worker_pod}" \
    --namespace "$ARGO_NAMESPACE" \
    --output jsonpath='{range .status.containerStatuses[*]}container={.name} ready={.ready} restarts={.restartCount} reason={.state.terminated.reason} exitCode={.state.terminated.exitCode} signal={.state.terminated.signal} message={.state.terminated.message}{"\n"}{end}' \
    2>/dev/null || true)"

  printf '\nFAILED WORKER: %s\n' "$worker_pod"
  if [[ -n "$termination" ]]; then
    printf '  termination: %s\n' "$termination"
  fi

  events="$(kubectl get events \
    --namespace "$ARGO_NAMESPACE" \
    --field-selector "involvedObject.kind=Pod,involvedObject.name=${worker_pod}" \
    --sort-by=.lastTimestamp \
    --output custom-columns='TYPE:.type,REASON:.reason,MESSAGE:.message' \
    --no-headers 2>/dev/null || true)"
  if [[ -n "$events" ]]; then
    printf '  pod events:\n%s\n' "$events"
  fi

  worker_logs="$(kubectl logs "pod/${worker_pod}" \
    --namespace "$ARGO_NAMESPACE" \
    --all-containers=true \
    --tail=80 \
    --timestamps 2>&1 || true)"
  if [[ -n "$worker_logs" ]]; then
    printf '  last worker logs:\n%s\n' "$worker_logs"
  fi

  previous_logs="$(kubectl logs "pod/${worker_pod}" \
    --namespace "$ARGO_NAMESPACE" \
    --all-containers=true \
    --previous \
    --tail=80 \
    --timestamps 2>/dev/null || true)"
  if [[ -n "$previous_logs" ]]; then
    printf '  previous worker logs:\n%s\n' "$previous_logs"
  fi
}

use_cluster_context() {
  minikube status --profile "$MINIKUBE_PROFILE" >/dev/null 2>&1 || \
    die "Minikube profile '$MINIKUBE_PROFILE' is not running"
  kubectl config use-context "$MINIKUBE_PROFILE" >/dev/null
}

check_argo() {
  kubectl get namespace "$ARGO_NAMESPACE" >/dev/null 2>&1 || \
    die "Namespace '$ARGO_NAMESPACE' does not exist"
  kubectl wait \
    --for=condition=Established \
    crd/workflows.argoproj.io \
    --timeout=30s >/dev/null
  kubectl rollout status \
    --namespace "$ARGO_NAMESPACE" \
    deployment/workflow-controller \
    --timeout=60s >/dev/null
}

image_runtime_ready() {
  docker run --rm \
    --entrypoint python3 \
    "$SAIL_IMAGE" \
    -c 'import pandas, pyarrow, pysail, pyspark; from pyspark.sql.connect.session import SparkSession' \
    >/dev/null 2>&1
}

image_worker_cli_ready() {
  docker run --rm \
    "$SAIL_IMAGE" \
    --help \
    >/dev/null 2>&1
}

image_glue_tls_ready() {
  docker run --rm \
    --entrypoint python3 \
    --volume "$AWS_CREDENTIALS_FILE:/var/run/lakesail/aws/credentials:ro" \
    --env "AWS_PROFILE=$AWS_PROFILE" \
    --env "AWS_REGION=$AWS_REGION" \
    --env AWS_SDK_LOAD_CONFIG=true \
    --env AWS_SHARED_CREDENTIALS_FILE=/var/run/lakesail/aws/credentials \
    --env "GLUE_DATABASE=$GLUE_DATABASE" \
    --env SAIL_MODE=local \
    --env "SAIL_CATALOG__LIST=[{type=\"glue\",name=\"$GLUE_CATALOG\",region=\"$AWS_REGION\"}]" \
    --env "SAIL_CATALOG__DEFAULT_CATALOG=$GLUE_CATALOG" \
    --env "SAIL_CATALOG__DEFAULT_DATABASE=[\"$GLUE_DATABASE\"]" \
    --env RUST_LOG=warn \
    "$SAIL_IMAGE" \
    -c 'import os; from pysail.spark import SparkConnectServer; from pyspark.sql import SparkSession; server = SparkConnectServer(); server.start(); _, port = server.listening_address; spark = SparkSession.builder.remote(f"sc://127.0.0.1:{port}").getOrCreate(); database = os.environ["GLUE_DATABASE"].replace("`", "``"); spark.sql(f"SHOW TABLES IN `{database}`").collect(); spark.stop()'
}

build_image_if_needed() {
  local current_requirements_sha="" image_requirements_sha=""
  local image_patch_revision=""

  current_requirements_sha="$(sha256sum "$REQUIREMENTS_FILE" | awk '{print $1}')"

  if [[ "$FORCE_IMAGE_BUILD" != "1" ]] && \
     docker image inspect "$SAIL_IMAGE" >/dev/null 2>&1; then
    image_requirements_sha="$(docker image inspect "$SAIL_IMAGE" \
      --format '{{ index .Config.Labels "org.lakesail.poc.requirements-sha" }}' \
      2>/dev/null || true)"
    image_patch_revision="$(docker image inspect "$SAIL_IMAGE" \
      --format '{{ index .Config.Labels "org.lakesail.poc.patch-revision" }}' \
      2>/dev/null || true)"
    if [[ "$image_requirements_sha" == "$current_requirements_sha" ]] && \
       [[ "$image_patch_revision" == "$SAIL_PATCH_REVISION" ]] && \
       image_runtime_ready && image_worker_cli_ready; then
      log "Docker image $SAIL_IMAGE matches requirements.txt; skipping build"
      return
    fi
    log "Docker image $SAIL_IMAGE is stale or incomplete; rebuilding"
  fi

  local build_started_at
  build_started_at="$(date +%s)"
  log "Building $SAIL_IMAGE from $REQUIREMENTS_FILE"

  docker build \
    --tag "$SAIL_IMAGE" \
    --build-arg "REQUIREMENTS_SHA=$current_requirements_sha" \
    --build-arg "SAIL_SOURCE_TAG=$SAIL_SOURCE_TAG" \
    --build-arg "SAIL_PATCH_REVISION=$SAIL_PATCH_REVISION" \
    --progress=plain \
    --file - \
    "$SCRIPT_DIR" <<'DOCKERFILE'
# syntax=docker/dockerfile:1
FROM rust:1.95-bookworm AS pysail-builder

ARG SAIL_SOURCE_TAG

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      gcc \
      git \
      libc6-dev \
      libprotobuf-dev \
      pkg-config \
      protobuf-compiler \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/build-venv
ENV PATH="/opt/build-venv/bin:${PATH}"
RUN python3 -m pip install --no-cache-dir "maturin>=1.9,<2"
RUN rustup component add rustfmt

WORKDIR /src/sail
RUN git clone --depth 1 --branch "${SAIL_SOURCE_TAG}" \
      https://github.com/lakehq/sail.git .

# Rustls deliberately refuses to auto-select when transitive dependencies
# enable both providers. Install AWS-LC when pysail._native is imported so
# both the embedded Spark server and worker CLI have a process-level provider.
# LakeSail's CLI also installs AWS-LC and treats an existing provider as fatal;
# make that second installation idempotent.
RUN sed -i \
      '/^fastrace = { workspace = true }$/a rustls = { workspace = true }' \
      crates/sail-python/Cargo.toml && \
    sed -i \
      '/fn _native(m: &Bound/a\    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();' \
      crates/sail-python/src/lib.rs && \
    sed -i \
      '/    if rustls::crypto::aws_lc_rs::default_provider()/,/    }/c\    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();' \
      crates/sail-cli/src/runner.rs && \
    grep -Fq 'rustls = { workspace = true }' crates/sail-python/Cargo.toml && \
    grep -Fq 'aws_lc_rs::default_provider().install_default()' \
      crates/sail-python/src/lib.rs && \
    grep -Fq 'let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();' \
      crates/sail-cli/src/runner.rs && \
    ! grep -Fq 'failed to install crypto provider' \
      crates/sail-cli/src/runner.rs

RUN --mount=type=cache,id=lakesail-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=lakesail-cargo-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=lakesail-cargo-target,target=/src/sail/target \
    maturin build --release --out /opt/wheels

FROM python:3.11-slim

ARG REQUIREMENTS_SHA
ARG SAIL_PATCH_REVISION
LABEL org.lakesail.poc.requirements-sha="${REQUIREMENTS_SHA}"
LABEL org.lakesail.poc.patch-revision="${SAIL_PATCH_REVISION}"

COPY requirements.txt /tmp/lakesail-requirements.txt
COPY --from=pysail-builder /opt/wheels/pysail-*.whl /tmp/wheels/

RUN python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel && \
    python3 -m pip install --no-cache-dir \
      --requirement /tmp/lakesail-requirements.txt \
      /tmp/wheels/pysail-*.whl && \
    rm -rf /tmp/lakesail-requirements.txt /tmp/wheels

ENTRYPOINT ["/usr/local/bin/sail"]
DOCKERFILE

  IMAGE_WAS_BUILT=1
  image_runtime_ready || die \
    "The rebuilt image still cannot import the Spark Connect runtime"
  image_worker_cli_ready || die \
    "The rebuilt image still fails while starting the LakeSail worker CLI"
  log "Image build and runtime validation completed in $(( $(date +%s) - build_started_at ))s"
}

load_image_if_needed() {
  local image_present=0 load_started_at="" load_pid=""

  if minikube image ls --profile "$MINIKUBE_PROFILE" | \
      grep -Fq "$SAIL_IMAGE"; then
    image_present=1
  fi

  if [[ "$IMAGE_WAS_BUILT" == "1" || \
        "$FORCE_IMAGE_LOAD" == "1" || \
        "$image_present" == "0" ]]; then
    load_started_at="$(date +%s)"
    log "Loading $SAIL_IMAGE into Minikube profile $MINIKUBE_PROFILE"
    minikube image load \
      --profile "$MINIKUBE_PROFILE" \
      --overwrite=true \
      "$SAIL_IMAGE" &
    load_pid=$!
    while kill -0 "$load_pid" 2>/dev/null; do
      sleep "$MONITOR_INTERVAL_SECONDS"
      if kill -0 "$load_pid" 2>/dev/null; then
        log "Minikube image load is still running; elapsed=$(( $(date +%s) - load_started_at ))s"
      fi
    done
    if ! wait "$load_pid"; then
      die "Minikube image load failed"
    fi
    log "Minikube image load completed in $(( $(date +%s) - load_started_at ))s"
  else
    log "Image $SAIL_IMAGE is already available in Minikube; skipping load"
  fi
}

apply_credentials_and_script() {
  log "Creating or updating AWS credentials secret"
  kubectl create secret generic "$AWS_SECRET_NAME" \
    --namespace "$ARGO_NAMESPACE" \
    --from-file="credentials=$AWS_CREDENTIALS_FILE" \
    --dry-run=client \
    --output yaml | kubectl apply --filename - >/dev/null

  log "Creating or updating Python test ConfigMap"
  kubectl create configmap "$CONFIG_MAP_NAME" \
    --namespace "$ARGO_NAMESPACE" \
    --from-file="lakesail_distributed_test.py=$PYTHON_FILE" \
    --dry-run=client \
    --output yaml | kubectl apply --filename - >/dev/null
}

apply_rbac() {
  log "Creating or updating LakeSail worker RBAC"
  kubectl apply --filename - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT}
  namespace: ${ARGO_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${SERVICE_ACCOUNT}
  namespace: ${ARGO_NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: ["argoproj.io"]
    resources: ["workflowtaskresults"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${SERVICE_ACCOUNT}
  namespace: ${ARGO_NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${SERVICE_ACCOUNT}
    namespace: ${ARGO_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${SERVICE_ACCOUNT}
EOF

  kubectl auth can-i create pods \
    --namespace "$ARGO_NAMESPACE" \
    --as "system:serviceaccount:${ARGO_NAMESPACE}:${SERVICE_ACCOUNT}" | \
    grep -Fxq yes || die "LakeSail service account cannot create worker pods"
}

submit_workflow() {
  log "Removing the previous $WORKFLOW_NAME workflow, if present"
  kubectl delete "workflow/${WORKFLOW_NAME}" \
    --namespace "$ARGO_NAMESPACE" \
    --ignore-not-found \
    --wait=true >/dev/null

  log "Removing stale LakeSail worker pods from the previous POC run"
  kubectl delete pods \
    --namespace "$ARGO_NAMESPACE" \
    --selector 'app.kubernetes.io/component=worker,lakesail-poc/driver' \
    --ignore-not-found \
    --wait=true >/dev/null

  log "Submitting workflow $WORKFLOW_NAME"
  kubectl apply --filename - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: ${WORKFLOW_NAME}
  namespace: ${ARGO_NAMESPACE}
spec:
  serviceAccountName: ${SERVICE_ACCOUNT}
  entrypoint: distributed-test
  activeDeadlineSeconds: 1800
  ttlStrategy:
    secondsAfterCompletion: 3600
  templates:
    - name: distributed-test
      container:
        image: ${SAIL_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["python3"]
        args: ["/opt/lakesail-poc/lakesail_distributed_test.py"]
        env:
          - name: POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: POD_IP
            valueFrom:
              fieldRef:
                fieldPath: status.podIP
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
          - name: SAIL_IMAGE
            value: ${SAIL_IMAGE}
          - name: SAIL_SERVICE_ACCOUNT
            value: ${SERVICE_ACCOUNT}
          - name: AWS_CREDENTIALS_SECRET
            value: ${AWS_SECRET_NAME}
          - name: AWS_SHARED_CREDENTIALS_FILE
            value: /var/run/lakesail/aws/credentials
          - name: AWS_PROFILE
            value: ${AWS_PROFILE}
          - name: AWS_REGION
            value: ${AWS_REGION}
          - name: S3_BUCKET
            value: ${S3_BUCKET}
          - name: GLUE_CATALOG
            value: ${GLUE_CATALOG}
          - name: GLUE_DATABASE
            value: ${GLUE_DATABASE}
          - name: POC_ROW_COUNT
            value: "${POC_ROW_COUNT}"
          - name: POC_PARTITIONS
            value: "${POC_PARTITIONS}"
          - name: SAIL_WORKER_INITIAL_COUNT
            value: "${SAIL_WORKER_INITIAL_COUNT}"
          - name: SAIL_WORKER_MAX_COUNT
            value: "${SAIL_WORKER_MAX_COUNT}"
          - name: SAIL_WORKER_TASK_SLOTS
            value: "${SAIL_WORKER_TASK_SLOTS}"
        resources:
          requests:
            cpu: "500m"
            memory: 1Gi
          limits:
            cpu: "2"
            memory: 3Gi
        volumeMounts:
          - name: test-script
            mountPath: /opt/lakesail-poc
            readOnly: true
          - name: aws-credentials
            mountPath: /var/run/lakesail/aws
            readOnly: true
      volumes:
        - name: test-script
          configMap:
            name: ${CONFIG_MAP_NAME}
        - name: aws-credentials
          secret:
            secretName: ${AWS_SECRET_NAME}
EOF
}

monitor_workflow() {
  local wait_pid="" wait_status=0
  local workflow_phase="" driver_pod="" driver_phase=""
  local worker_rows="" worker_name="" worker_phase=""
  local total_workers=0 running_workers=0 pending_workers=0 failed_workers=0
  local peak_running_workers=0 latest_driver_log="" driver_pods_used=0
  local all_workers_failed_polls=0 monitor_failure=0
  declare -A observed_workers=()
  declare -A diagnosed_workers=()

  argo wait --namespace "$ARGO_NAMESPACE" "$WORKFLOW_NAME" >/dev/null &
  wait_pid=$!

  while true; do
    workflow_phase="$(kubectl get "workflow/${WORKFLOW_NAME}" \
      --namespace "$ARGO_NAMESPACE" \
      --output jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ -n "$workflow_phase" ]] || workflow_phase="Pending"

    driver_pod="$(kubectl get pods \
      --namespace "$ARGO_NAMESPACE" \
      --selector "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" \
      --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    driver_phase="Pending"
    if [[ -n "$driver_pod" ]]; then
      driver_pods_used=1
      driver_phase="$(kubectl get "pod/${driver_pod}" \
        --namespace "$ARGO_NAMESPACE" \
        --output jsonpath='{.status.phase}' 2>/dev/null || true)"
      [[ -n "$driver_phase" ]] || driver_phase="Pending"
    fi

    total_workers=0
    running_workers=0
    pending_workers=0
    failed_workers=0
    worker_rows=""
    if [[ -n "$driver_pod" ]]; then
      worker_rows="$(kubectl get pods \
        --namespace "$ARGO_NAMESPACE" \
        --selector "lakesail-poc/driver=${driver_pod}" \
        --output jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' \
        2>/dev/null || true)"
    fi

    while read -r worker_name worker_phase; do
      [[ -n "$worker_name" ]] || continue
      observed_workers["$worker_name"]=1
      total_workers=$((total_workers + 1))
      case "$worker_phase" in
        Running) running_workers=$((running_workers + 1)) ;;
        Pending) pending_workers=$((pending_workers + 1)) ;;
        Failed) failed_workers=$((failed_workers + 1)) ;;
      esac
    done <<< "$worker_rows"

    while read -r worker_name worker_phase; do
      [[ -n "$worker_name" && "$worker_phase" == "Failed" ]] || continue
      if [[ -z "${diagnosed_workers[$worker_name]:-}" ]]; then
        diagnosed_workers["$worker_name"]=1
        print_worker_failure_diagnostics "$worker_name"
      fi
    done <<< "$worker_rows"

    if (( running_workers > peak_running_workers )); then
      peak_running_workers=$running_workers
    fi

    log "workflow=${workflow_phase} driver=${driver_phase} workers(total=${total_workers}, running=${running_workers}, pending=${pending_workers}, failed=${failed_workers})"

    if [[ -n "$driver_pod" ]]; then
      latest_driver_log="$(kubectl logs "pod/${driver_pod}" \
        --namespace "$ARGO_NAMESPACE" \
        --container main \
        --tail=1 2>/dev/null || true)"
      if [[ -n "$latest_driver_log" ]]; then
        printf '  latest-driver-log: %s\n' "$latest_driver_log"
      fi
    fi

    if (( total_workers > 0 && failed_workers == total_workers && \
          running_workers == 0 && pending_workers == 0 )); then
      all_workers_failed_polls=$((all_workers_failed_polls + 1))
      printf '  worker-failure-guard: all workers failed (%d/%d polls)\n' \
        "$all_workers_failed_polls" "$WORKER_FAILURE_GRACE_POLLS"
    else
      all_workers_failed_polls=0
    fi

    if (( all_workers_failed_polls >= WORKER_FAILURE_GRACE_POLLS )); then
      printf '\nAll LakeSail workers remained failed; terminating the stuck workflow.\n' >&2
      argo terminate --namespace "$ARGO_NAMESPACE" "$WORKFLOW_NAME" \
        >/dev/null 2>&1 || true
      monitor_failure=1
      break
    fi

    case "$workflow_phase" in
      Succeeded|Failed|Error) break ;;
    esac

    if ! kill -0 "$wait_pid" 2>/dev/null; then
      break
    fi
    sleep "$MONITOR_INTERVAL_SECONDS"
  done

  if wait "$wait_pid"; then
    wait_status=0
  else
    wait_status=$?
  fi

  if (( monitor_failure != 0 )); then
    wait_status=1
  fi

  printf '\nLakeSail execution resource summary:\n'
  printf '  Driver pods used:                    %d\n' "$driver_pods_used"
  printf '  Unique LakeSail worker pods used:    %d\n' "${#observed_workers[@]}"
  printf '  Peak concurrent running workers:     %d\n' "$peak_running_workers"
  printf '  Spark executor JVMs used:             0 (LakeSail is Rust-native)\n'
  printf '  Executor-equivalent worker count:     %d\n' "$peak_running_workers"
  printf '  Configured task slots per worker:     %d\n' "$SAIL_WORKER_TASK_SLOTS"
  printf '  Peak executor-equivalent task slots:  %d\n' \
    "$((peak_running_workers * SAIL_WORKER_TASK_SLOTS))"

  return "$wait_status"
}

show_status() {
  use_cluster_context

  printf 'Workflow:\n'
  kubectl get "workflow/${WORKFLOW_NAME}" \
    --namespace "$ARGO_NAMESPACE" \
    --output wide 2>/dev/null || printf 'No workflow found.\n'

  printf '\nPOC pods:\n'
  kubectl get pods \
    --namespace "$ARGO_NAMESPACE" \
    --selector "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" \
    --output wide 2>/dev/null || true

  printf '\nLakeSail worker pods:\n'
  kubectl get pods \
    --namespace "$ARGO_NAMESPACE" \
    --selector app.kubernetes.io/component=worker \
    --output wide 2>/dev/null || true

  local failed_worker=""
  while read -r failed_worker; do
    [[ -n "$failed_worker" ]] || continue
    print_worker_failure_diagnostics "$failed_worker"
  done < <(kubectl get pods \
    --namespace "$ARGO_NAMESPACE" \
    --selector app.kubernetes.io/component=worker \
    --field-selector status.phase=Failed \
    --output jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null || true)
}

show_logs() {
  use_cluster_context
  kubectl get "workflow/${WORKFLOW_NAME}" \
    --namespace "$ARGO_NAMESPACE" >/dev/null 2>&1 || \
    die "Workflow '$WORKFLOW_NAME' does not exist"
  argo logs --namespace "$ARGO_NAMESPACE" "$WORKFLOW_NAME"
}

run_cycle() {
  require_command docker
  require_command minikube
  require_command kubectl
  require_command argo
  require_command python3
  require_command grep
  require_command awk
  require_command sha256sum
  require_command date
  require_command sleep

  log "Starting LakeSail distributed POC cycle"
  validate_configuration
  docker info >/dev/null 2>&1 || die "Docker is not running or not accessible"
  log "Preflight checks passed; selecting Minikube context"
  use_cluster_context
  check_argo
  log "Minikube and Argo are ready"
  build_image_if_needed
  log "Running local Glue/TLS smoke test inside $SAIL_IMAGE"
  image_glue_tls_ready || die \
    "Glue access failed. Refresh the AWS session credentials in $AWS_CREDENTIALS_FILE and retry; Argo was not submitted"
  log "Local Glue/TLS smoke test passed"
  load_image_if_needed
  apply_credentials_and_script
  apply_rbac
  submit_workflow

  printf '\nLive status updates every %s seconds:\n' "$MONITOR_INTERVAL_SECONDS"
  if ! monitor_workflow; then
    argo logs --namespace "$ARGO_NAMESPACE" "$WORKFLOW_NAME" || true
    die "Workflow monitoring command failed"
  fi

  argo logs --namespace "$ARGO_NAMESPACE" "$WORKFLOW_NAME"

  local phase
  phase="$(kubectl get "workflow/${WORKFLOW_NAME}" \
    --namespace "$ARGO_NAMESPACE" \
    --output jsonpath='{.status.phase}')"
  [[ "$phase" == "Succeeded" ]] || die "Workflow finished with phase: $phase"

  printf '\nPOC succeeded. Delta tables:\n'
  printf '  %s.distributed_sales_events\n' "$GLUE_DATABASE"
  printf '  %s.distributed_category_summary\n' "$GLUE_DATABASE"
}

cleanup_poc() {
  local driver_pod=""

  use_cluster_context

  printf 'This removes only the %s workflow, worker pods, ConfigMap, secret and RBAC.\n' \
    "$WORKFLOW_NAME"
  printf 'It does not delete Minikube, Argo, the Docker image, Glue tables or S3 data.\n'
  printf 'Type %s to confirm: ' "$WORKFLOW_NAME"
  read -r confirmation
  [[ "$confirmation" == "$WORKFLOW_NAME" ]] || die "Cleanup cancelled"

  driver_pod="$(kubectl get pods \
    --namespace "$ARGO_NAMESPACE" \
    --selector "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" \
    --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$driver_pod" ]]; then
    kubectl delete pods \
      --namespace "$ARGO_NAMESPACE" \
      --selector "lakesail-poc/driver=${driver_pod}" \
      --ignore-not-found >/dev/null
  fi
  kubectl delete "workflow/${WORKFLOW_NAME}" \
    --namespace "$ARGO_NAMESPACE" \
    --ignore-not-found >/dev/null
  kubectl delete "configmap/${CONFIG_MAP_NAME}" \
    --namespace "$ARGO_NAMESPACE" \
    --ignore-not-found >/dev/null
  kubectl delete "secret/${AWS_SECRET_NAME}" \
    --namespace "$ARGO_NAMESPACE" \
    --ignore-not-found >/dev/null
  kubectl delete "rolebinding/${SERVICE_ACCOUNT}" \
    --namespace "$ARGO_NAMESPACE" \
    --ignore-not-found >/dev/null
  kubectl delete "role/${SERVICE_ACCOUNT}" \
    --namespace "$ARGO_NAMESPACE" \
    --ignore-not-found >/dev/null
  kubectl delete "serviceaccount/${SERVICE_ACCOUNT}" \
    --namespace "$ARGO_NAMESPACE" \
    --ignore-not-found >/dev/null

  printf 'POC Kubernetes resources removed. Glue tables and S3 data were kept.\n'
}

main() {
  case "${1:-run}" in
    run) run_cycle ;;
    status)
      require_command minikube
      require_command kubectl
      show_status
      ;;
    logs)
      require_command minikube
      require_command kubectl
      require_command argo
      show_logs
      ;;
    cleanup)
      require_command minikube
      require_command kubectl
      cleanup_poc
      ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
