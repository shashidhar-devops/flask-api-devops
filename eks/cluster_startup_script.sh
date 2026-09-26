#!/usr/bin/env bash
set -euo pipefail

REGION="us-east-1"
CLUSTER="flask-api-cluster"
ACCOUNT="253264393553"
EBS_ROLE="AmazonEKS_EBS_CSI_DriverRole"

# ============================================================
# 1. Create cluster
# ============================================================
eksctl create cluster -f cluster-config.yaml

# ============================================================
# 1b. Enable prefix delegation on VPC CNI BEFORE anything else
#     schedules pods — t3.medium hits the default per-node pod
#     ceiling (~17) quickly otherwise.
# ============================================================
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true
kubectl rollout status daemonset/aws-node -n kube-system --timeout=120s

eksctl utils associate-iam-oidc-provider \
  --region "$REGION" \
  --cluster "$CLUSTER" \
  --approve

# ============================================================
# 1c. Cluster Autoscaler — IRSA + Helm install, BEFORE any
#     other section schedules pods. Ensures node-level capacity
#     can respond automatically if nodes run low on CPU/RAM
#     while the rest of this script's workloads come up.
# ============================================================
eksctl create iamserviceaccount \
  --name cluster-autoscaler \
  --namespace kube-system \
  --cluster "$CLUSTER" \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT}:policy/ClusterAutoscalerPolicy" \
  --approve \
  --region "$REGION"

helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --version 9.59.0 \
  --namespace kube-system \
  --set image.tag=v1.35.0 \
  --set autoDiscovery.clusterName="$CLUSTER" \
  --set awsRegion="$REGION" \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler

kubectl -n kube-system rollout status deployment/cluster-autoscaler --timeout=120s

# ============================================================
# 2. EBS CSI driver — IRSA role + addon
# ============================================================
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster "$CLUSTER" \
  --role-name "$EBS_ROLE" \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --region "$REGION"

eksctl create addon \
  --cluster "$CLUSTER" \
  --name aws-ebs-csi-driver \
  --version latest \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT}:role/${EBS_ROLE}" \
  --region "$REGION" \
  --force

kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=180s

# ============================================================
# 3. Sealed Secrets controller (kube-system, matches Cluster
#    Autoscaler convention — cluster-wide infra, outside GitOps)
#    Repo migrated bitnami-labs -> bitnami mid-2026.
#    fullnameOverride keeps `kubeseal` CLI defaults working
#    (it expects "sealed-secrets-controller" in kube-system).
#    MUST run before ArgoCD: every rebuild generates a NEW
#    keypair, so any SealedSecret already committed to Git
#    (sealed against the previous, now-dead key) will fail to
#    decrypt until it's re-sealed against this rebuild's key —
#    and that re-seal must happen before ArgoCD ever syncs it.
# ============================================================
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update
helm install sealed-secrets -n kube-system \
  --set-string fullnameOverride=sealed-secrets-controller \
  sealed-secrets/sealed-secrets

kubectl -n kube-system rollout status deployment/sealed-secrets-controller --timeout=120s

# Re-fetch the public cert fresh each rebuild.
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > pub-cert.pem

# Re-seal postgres-db-secret against this rebuild's fresh key.
# POSTGRES_PASSWORD must be exported in your shell before running
# this script — source .env first (git-ignored, never committed).
if [ -z "${POSTGRES_PASSWORD:-}" ]; then
  echo "ERROR: POSTGRES_PASSWORD not set. Run 'source .env' before this script."
  exit 1
fi

kubectl create secret generic postgres-db-secret \
  --namespace flask-app --dry-run=client \
  --from-literal=POSTGRES_USER=flaskuser \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubeseal --cert pub-cert.pem --format yaml > k8s/secret.yaml

git -C . add k8s/secret.yaml
git -C . commit -m "Re-seal postgres-db-secret for cluster rebuild"
git -C . push

# ============================================================
# 4. ArgoCD (syncs k8s/ manifests, including StorageClass and
#    the freshly re-sealed Secret — must happen before the
#    monitoring stack, per Layer 7 lesson, and after Sealed
#    Secrets above, per the ordering fix noted there)
# ============================================================
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f eks/argocd-application.yaml

# ============================================================
# 5. Monitoring stack — namespace + Grafana secret BEFORE Helm
#    GRAFANA_ADMIN_PASSWORD must be exported in your shell before
#    running this script — source .env first (git-ignored).
#    Not sealed/committed to Git: created live, direct to cluster,
#    referenced by monitoring/values.yaml via existingSecret.
# ============================================================
kubectl create namespace monitoring

if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: GRAFANA_ADMIN_PASSWORD not set. Run 'source .env' before this script."
  exit 1
fi

kubectl create secret generic grafana-admin-secret \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubeseal --cert pub-cert.pem --format yaml > monitoring/secret.yaml

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/values.yaml

kubectl apply -f monitoring/flask-servicemonitor.yaml
kubectl apply -f monitoring/postgres-servicemonitor.yaml

# ============================================================
# 6. Loki — namespace + IRSA role/ServiceAccount BEFORE Helm
#    (same OIDC-staleness pattern as EBS CSI and Cluster
#    Autoscaler above: role+SA don't survive cluster teardown,
#    must be recreated every rebuild)
# ============================================================
kubectl create namespace logging

eksctl create iamserviceaccount \
  --name loki-s3-sa \
  --namespace logging \
  --cluster "$CLUSTER" \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT}:policy/LokiS3AccessPolicy" \
  --approve

helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update
helm install loki grafana-community/loki \
  --namespace logging \
  -f loki-values.yaml

# ============================================================
# 7. Verify (|| true throughout — these are diagnostic checks,
#    not critical steps; a zero-match grep or unready Metrics
#    Server shouldn't kill the script this late)
# ============================================================
kubectl get pods -n kube-system | grep -E "ebs-csi|sealed-secrets|cluster-autoscaler" || true
kubectl get pods -n argocd || true
kubectl get pods -n monitoring || true
kubectl get pods -n logging || true
kubectl get servicemonitors -n monitoring || true
kubectl top nodes || true
kubectl get svc -n monitoring | grep grafana || true
