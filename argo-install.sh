#!/bin/bash
# =============================================================================
# argo-install.sh — ARGO Stack installer / uninstaller
#
# Usage:
#   ./argo-install.sh [COMMAND] [FLAGS]
#
# Commands:
#   install              Install CNPG (if not present) + ARGO stack
#   reinstall            Remove and reinstall ARGO only (CNPG untouched)
#   upgrade              Upgrade ARGO to latest chart version (CNPG untouched)
#   uninstall            Remove ARGO stack only (CNPG and CRDs untouched)
#   uninstall --all      Remove ARGO + CNPG operator + all CRDs
#   status               Show current installation status
#   help                 Show this help message
# =============================================================================

set -euo pipefail

ARGO_NAMESPACE="argo"
CNPG_NAMESPACE="cnpg-system"
ARGO_RELEASE="argo"
CNPG_RELEASE="cnpg"
ARGO_REPO_URL="https://rayjun-kim.github.io/argo-pg"
CNPG_REPO_URL="https://cloudnative-pg.github.io/charts"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}==> $*${NC}"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat << EOF

ARGO Stack Installer
DBaaCP Agent Framework on Kubernetes

Usage:
  $(basename "$0") [COMMAND] [FLAGS]

Commands:
  install              Install CNPG Operator (if not present) + ARGO stack
  reinstall            Remove and reinstall ARGO only (CNPG untouched)
  upgrade              Upgrade ARGO to latest chart version (CNPG untouched)
  uninstall            Remove ARGO stack only (CNPG and CRDs untouched)
  uninstall --all      Remove ARGO + CNPG operator + all CRDs
                       (only when no other workloads depend on CNPG)
  status               Show current installation status
  help                 Show this help message

Examples:
  $(basename "$0") install            # Fresh install
  $(basename "$0") reinstall          # Reinstall ARGO only
  $(basename "$0") upgrade            # Upgrade ARGO to latest version
  $(basename "$0") uninstall          # Remove ARGO only (safe for shared clusters)
  $(basename "$0") uninstall --all    # Remove everything including CNPG
  $(basename "$0") status             # Check current status

What gets installed:
  - CloudNativePG Operator      (cnpg-system, skipped if already installed)
  - PostgreSQL + ARGO schema    (argo namespace)
  - Ollama (gemma4:e2b + nomic-embed-text, pulled async)
  - Langflow with ARGO components and starter flows

Requirements:
  - Kubernetes cluster with kubectl configured
  - Helm 3.x
  - Cluster-admin permissions
  - Storage: ~40GB (30GB models + 10GB PostgreSQL)

After install:
  kubectl -n argo port-forward svc/argo-argo-stack-langflow 7860:7860
  open http://localhost:7860

EOF
}

# =============================================================================
# Prerequisites
# =============================================================================
check_prerequisites() {
    step "Checking prerequisites"

    if ! command -v kubectl > /dev/null 2>&1; then
        error "kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/"
    fi
    info "kubectl: $(kubectl version --client --short 2>/dev/null | head -1)"

    if ! command -v helm > /dev/null 2>&1; then
        error "helm not found. Install: https://helm.sh/docs/intro/install/"
    fi
    info "helm: $(helm version --short 2>/dev/null)"

    if ! kubectl cluster-info > /dev/null 2>&1; then
        error "Cannot connect to Kubernetes cluster.
  Check: kubectl config current-context
  Is the cluster running and kubeconfig configured?"
    fi

    local context
    context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    info "Cluster context: ${context}"

    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$node_count" -eq 0 ]; then
        error "No nodes found in the cluster. Is the cluster healthy?"
    fi
    info "Cluster nodes: ${node_count}"

    if ! kubectl auth can-i '*' '*' --all-namespaces > /dev/null 2>&1; then
        warn "Could not verify cluster-admin permissions. Install may fail if permissions are insufficient."
    else
        info "Cluster permissions: OK"
    fi

    info "Prerequisites OK."
}

# =============================================================================
# CNPG check
# =============================================================================
cnpg_is_installed() {
    kubectl get deployment -n "$CNPG_NAMESPACE" \
        -l app.kubernetes.io/name=cloudnative-pg \
        --no-headers 2>/dev/null | grep -q .
}

# =============================================================================
# Wait for Langflow to be ready
# =============================================================================
wait_for_langflow() {
    info "Waiting for Langflow to be ready..."
    local svc="${ARGO_RELEASE}-argo-stack-langflow"
    local pod

    # Wait for pod to be running
    kubectl rollout status deployment/${svc} \
        -n "$ARGO_NAMESPACE" --timeout=5m

    # Wait for health endpoint
    pod=$(kubectl get pod -n "$ARGO_NAMESPACE" \
        -l app.kubernetes.io/component=langflow \
        -o name | head -1)

    for i in $(seq 1 60); do
        if kubectl exec -n "$ARGO_NAMESPACE" "$pod" -- \
            curl -sf http://localhost:7860/health > /dev/null 2>&1; then
            info "Langflow ready."
            return 0
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    warn "Langflow health check timed out — continuing anyway."
}

# =============================================================================
# Run post-install/upgrade hooks
# =============================================================================
run_hooks() {
    step "Running post-install setup (roles, seed data, flow import)"
    wait_for_langflow
    helm upgrade "$ARGO_RELEASE" argo/argo-stack \
        --namespace "$ARGO_NAMESPACE" \
        --set cloudnative-pg.enabled=false \
        --reuse-values \
        --wait \
        --timeout 5m
    info "Post-install setup complete."
}

# =============================================================================
# Cleanup ARGO only
# =============================================================================
cleanup_argo() {
    kubectl delete secret ${ARGO_RELEASE}-argo-stack-argo-passwords \
        -n "$ARGO_NAMESPACE" 2>/dev/null && \
        info "Removed Secret: argo-passwords." || true

    helm uninstall "$ARGO_RELEASE" -n "$ARGO_NAMESPACE" --no-hooks 2>/dev/null && \
        info "Removed ARGO release." || true

    kubectl delete namespace "$ARGO_NAMESPACE" --force --grace-period=0 2>/dev/null && \
        info "Deleted namespace: ${ARGO_NAMESPACE}" || true

    info "Waiting for namespace to terminate..."
    for i in $(seq 1 30); do
        if ! kubectl get namespace "$ARGO_NAMESPACE" > /dev/null 2>&1; then
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""
}

# =============================================================================
# Remove CNPG + CRDs
# =============================================================================
remove_cnpg() {
    step "Removing CNPG Operator and CRDs"

    helm uninstall "$CNPG_RELEASE" -n "$CNPG_NAMESPACE" --no-hooks 2>/dev/null && \
        info "Removed CNPG release." || true

    kubectl delete namespace "$CNPG_NAMESPACE" --force --grace-period=0 2>/dev/null && \
        info "Deleted namespace: ${CNPG_NAMESPACE}" || true

    info "Removing CNPG CRDs..."
    for crd in \
        clusters.postgresql.cnpg.io \
        backups.postgresql.cnpg.io \
        poolers.postgresql.cnpg.io \
        scheduledbackups.postgresql.cnpg.io \
        databases.postgresql.cnpg.io \
        imagecatalogs.postgresql.cnpg.io \
        clusterimagecatalogs.postgresql.cnpg.io \
        publications.postgresql.cnpg.io \
        subscriptions.postgresql.cnpg.io \
        failoverquorums.postgresql.cnpg.io; do
        kubectl delete crd "$crd" 2>/dev/null && \
            info "  Deleted CRD: ${crd}" || true
    done

    info "Waiting for namespace to terminate..."
    for i in $(seq 1 30); do
        if ! kubectl get namespace "$CNPG_NAMESPACE" > /dev/null 2>&1; then
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""
}

# =============================================================================
# Install ARGO stack (assumes CNPG already ready)
# =============================================================================
install_argo() {
    step "Installing ARGO stack"
    helm install "$ARGO_RELEASE" argo/argo-stack \
        --namespace "$ARGO_NAMESPACE" \
        --create-namespace \
        --set cloudnative-pg.enabled=false

    step "Waiting for core components"

    info "Waiting for PostgreSQL..."
    kubectl wait pod \
        -l "cnpg.io/cluster=${ARGO_RELEASE}-argo-stack-argo-pg" \
        -n "$ARGO_NAMESPACE" \
        --for=condition=ready --timeout=5m

    info "Waiting for Ollama..."
    kubectl rollout status deployment/${ARGO_RELEASE}-argo-stack-ollama \
        -n "$ARGO_NAMESPACE" --timeout=5m

    run_hooks
}

# =============================================================================
# Print summary
# =============================================================================
print_summary() {
    echo ""
    step "Pod Status"
    kubectl get pods -n "$ARGO_NAMESPACE"

    echo ""
    step "Job Status"
    kubectl get jobs -n "$ARGO_NAMESPACE" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}${BOLD}=========================================="
    echo "ARGO Stack ready!"
    echo -e "==========================================${NC}"
    echo ""
    echo "Access Langflow:"
    echo "  open http://localhost:30860"
    echo "  (or: kubectl -n ${ARGO_NAMESPACE} port-forward svc/${ARGO_RELEASE}-argo-stack-langflow 7860:7860)"
    echo ""
    echo "Check model download progress (background):"
    echo "  kubectl logs -n ${ARGO_NAMESPACE} -l app.kubernetes.io/component=ollama-model-pull -f"
    echo ""
    echo "Check PostgreSQL:"
    echo "  kubectl exec -n ${ARGO_NAMESPACE} ${ARGO_RELEASE}-argo-stack-argo-pg-1 -- \\"
    echo "    psql -U postgres -d argo -c 'SELECT * FROM argo_public.v_session_progress;'"
    echo ""
}

# =============================================================================
# Commands
# =============================================================================
do_install() {
    step "Starting fresh ARGO stack installation"

    # Clean up existing ARGO
    step "Cleaning up existing ARGO installation"
    cleanup_argo
    info "Cleanup complete."

    # Helm repos
    step "Setting up Helm repositories"
    helm repo add argo  "$ARGO_REPO_URL"  2>/dev/null || true
    helm repo add cnpg  "$CNPG_REPO_URL" 2>/dev/null || true
    helm repo update
    info "Helm repos updated."

    # CNPG — install only if not present
    step "Checking CloudNativePG Operator"
    if cnpg_is_installed; then
        info "CNPG Operator already installed — skipping."
    else
        info "CNPG Operator not found — installing..."
        helm install "$CNPG_RELEASE" cnpg/cloudnative-pg \
            --namespace "$CNPG_NAMESPACE" \
            --create-namespace \
            --wait \
            --timeout 5m
        info "CNPG Operator installed."
    fi

    kubectl wait --for=condition=established \
        crd/clusters.postgresql.cnpg.io \
        --timeout=60s
    info "CNPG CRDs ready."

    install_argo
    print_summary
}

do_reinstall() {
    step "Reinstalling ARGO stack (CNPG untouched)"

    echo ""
    warn "This will remove and reinstall ARGO only."
    echo "  CNPG Operator and CRDs will NOT be touched."
    echo ""
    read -r -p "Are you sure? [y/N] " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY]) ;;
        *) info "Aborted."; exit 0 ;;
    esac

    step "Removing existing ARGO installation"
    cleanup_argo
    info "Cleanup complete."

    step "Setting up Helm repositories"
    helm repo add argo "$ARGO_REPO_URL" 2>/dev/null || true
    helm repo update
    info "Helm repos updated."

    kubectl wait --for=condition=established \
        crd/clusters.postgresql.cnpg.io \
        --timeout=60s

    install_argo
    print_summary
}

do_upgrade() {
    step "Upgrading ARGO stack to latest version (CNPG untouched)"

    step "Setting up Helm repositories"
    helm repo add argo "$ARGO_REPO_URL" 2>/dev/null || true
    helm repo update

    local current
    current=$(helm list -n "$ARGO_NAMESPACE" --filter "^${ARGO_RELEASE}$" \
        -o json 2>/dev/null | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d[0]['chart'] if d else 'not installed')" \
        2>/dev/null || echo "unknown")
    info "Current: ${current}"

    local latest
    latest=$(helm search repo argo/argo-stack --output json 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['version'] if d else 'unknown')" \
        2>/dev/null || echo "unknown")
    info "Latest:  argo-stack-${latest}"

    helm upgrade "$ARGO_RELEASE" argo/argo-stack \
        --namespace "$ARGO_NAMESPACE" \
        --set cloudnative-pg.enabled=false \
        --reuse-values

    step "Waiting for rollout"
    kubectl rollout status deployment/${ARGO_RELEASE}-argo-stack-langflow \
        -n "$ARGO_NAMESPACE" --timeout=5m
    kubectl rollout status deployment/${ARGO_RELEASE}-argo-stack-ollama \
        -n "$ARGO_NAMESPACE" --timeout=5m

    run_hooks
    print_summary
}

do_uninstall() {
    local remove_all="${1:-}"

    if [ "$remove_all" = "--all" ]; then
        echo ""
        warn "This will remove ALL ARGO and CNPG resources including:"
        echo "  - ARGO namespace and all its resources"
        echo "  - CNPG Operator (${CNPG_NAMESPACE} namespace)"
        echo "  - All CNPG CRDs (affects ALL clusters using CNPG)"
        echo ""
        warn "Only use --all when no other workloads depend on CNPG."
    else
        echo ""
        warn "This will remove ARGO resources only:"
        echo "  - Helm release '${ARGO_RELEASE}' (${ARGO_NAMESPACE} namespace)"
        echo "  - All PVCs (PostgreSQL data, Ollama models, Langflow data)"
        echo ""
        info "CNPG Operator and CRDs will NOT be touched."
    fi

    echo ""
    read -r -p "Are you sure? [y/N] " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY]) ;;
        *) info "Aborted."; exit 0 ;;
    esac

    cleanup_argo

    if [ "$remove_all" = "--all" ]; then
        remove_cnpg
    fi

    info "Uninstall complete."
}

do_status() {
    step "ARGO Stack Status"

    echo ""
    echo -e "${BOLD}Helm releases:${NC}"
    helm list -n "$ARGO_NAMESPACE" 2>/dev/null || echo "  (none in ${ARGO_NAMESPACE})"
    helm list -n "$CNPG_NAMESPACE" 2>/dev/null || echo "  (none in ${CNPG_NAMESPACE})"

    echo ""
    echo -e "${BOLD}Pods (argo):${NC}"
    kubectl get pods -n "$ARGO_NAMESPACE" 2>/dev/null || echo "  (namespace not found)"

    echo ""
    echo -e "${BOLD}Jobs (argo):${NC}"
    kubectl get jobs -n "$ARGO_NAMESPACE" 2>/dev/null || echo "  (none)"

    echo ""
    echo -e "${BOLD}CNPG Cluster:${NC}"
    kubectl get cluster -n "$ARGO_NAMESPACE" 2>/dev/null || echo "  (none)"

    echo ""
    echo -e "${BOLD}CNPG Operator:${NC}"
    if cnpg_is_installed; then
        kubectl get deployment -n "$CNPG_NAMESPACE" \
            -l app.kubernetes.io/name=cloudnative-pg 2>/dev/null
    else
        echo "  (not installed)"
    fi

    echo ""
    echo -e "${BOLD}Model pull progress:${NC}"
    kubectl logs -n "$ARGO_NAMESPACE" \
        -l app.kubernetes.io/component=ollama-model-pull \
        --tail=5 2>/dev/null || echo "  (model pull job not running)"
}

# =============================================================================
# Main
# =============================================================================
COMMAND="${1:-install}"
FLAG="${2:-}"

case "$COMMAND" in
    install)
        check_prerequisites
        do_install
        ;;
    reinstall)
        check_prerequisites
        do_reinstall
        ;;
    upgrade)
        check_prerequisites
        do_upgrade
        ;;
    uninstall)
        check_prerequisites
        do_uninstall "$FLAG"
        ;;
    status)
        check_prerequisites
        do_status
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        error "Unknown command: '${COMMAND}'\nRun '$(basename "$0") help' for usage."
        ;;
esac