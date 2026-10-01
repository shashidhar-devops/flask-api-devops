#!/usr/bin/env bash
set -euo pipefail

REGION="us-east-1"
CLUSTER="flask-api-cluster"
ACCOUNT="253264393553"
EBS_ROLE="AmazonEKS_EBS_CSI_DriverRole"
ARGOCD_VERSION="v3.5.3"

# ============================================================
# 0. Pre-flight
#    - Required secrets must be exported (run 'source .env' first).
#    - Sync with GitHub first: CI pushes its own commits (image
#      tag updates), so the re-seal push in section 3 would be
#      rejected if this clone is behind.
# ============================================================
for var in POSTGRES_USER POSTGRES_PASSWORD GRAFANA_ADMIN_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var not set. Run 'source .env' before this script."
    exit 1
  fi
done

git -C . pull --ff-only

# ============================================================
# 1. Create cluster
#    VPC CNI (network policy enforcement + prefix delegation) is
#    configured as a managed addon in eks/cluster-config.yaml.
# ============================================================
eksctl create cluster -f eks/cluster-config.yaml

kubectl rollout status daemonset/aws-node -n kube-system --timeout=180s

eksctl utils associate-iam-oidc-provider \
  --region "$REGION" \
  --cluster "$CLUSTER" \
  --approve

# ============================================================
# 1c. Cluster Autoscaler — IRSA + Helm install, BEFORE any
#     other section schedules pods, so node capacity can scale
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
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set fullnameOverride=cluster-autoscaler

kubectl -n kube-system rollout status deployment/cluster-autoscaler --timeout=120s

# Applied by this script, not ArgoCD: cluster infrastructure outside GitOps.
kubectl apply -f eks/network-policy-cluster-autoscaler.yaml

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
  --version v1.66.0-eksbuild.1 \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT}:role/${EBS_ROLE}" \
  --region "$REGION" \
  --wait

kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=180s

# ============================================================
# 3. Sealed Secrets controller (kube-system — cluster-wide
#    infra, outside GitOps).
#    fullnameOverride keeps `kubeseal` CLI defaults working
#    (it expects "sealed-secrets-controller" in kube-system).
#    MUST run before ArgoCD: every rebuild generates a NEW
#    keypair, so the SealedSecret in Git (sealed against the
#    previous, now-deleted key) must be re-sealed against this
#    rebuild's key before ArgoCD syncs it.
# ============================================================
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update
helm install sealed-secrets -n kube-system \
  --version 2.20.0 \
  --set-string fullnameOverride=sealed-secrets-controller \
  sealed-secrets/sealed-secrets

kubectl -n kube-system rollout status deployment/sealed-secrets-controller --timeout=120s

# Re-fetch the public cert fresh each rebuild (git-ignored).
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > pub-cert.pem

# Re-seal postgres-db-secret against this rebuild's key.
kubectl create secret generic postgres-db-secret \
  --namespace flask-app \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubeseal --cert pub-cert.pem --format yaml > k8s/secret.yaml

# Push so ArgoCD (which deploys from GitHub) picks it up.
# Only k8s/ changes here, so CI's paths filter skips this push.
git -C . add k8s/secret.yaml
git -C . commit -m "Re-seal postgres-db-secret for cluster rebuild"
git -C . push

# ============================================================
# 4. ArgoCD — pinned version. Syncs only k8s/ (the app,
#    StorageClass, the re-sealed Secret). ArgoCD's own RBAC and
#    NetworkPolicy are applied here by the script, NOT by ArgoCD,
#    so a mistake in them can't lock ArgoCD out of fixing itself.
# ============================================================
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s

kubectl apply -f argocd/appproject-flask-api.yaml
kubectl apply -f argocd/network-policy-argocd.yaml
kubectl apply -f argocd/argocd-application.yaml

# ============================================================
# 5. Monitoring stack — namespace + Grafana secret BEFORE Helm.
#    Sealed with this rebuild's key and applied directly (not
#    via ArgoCD); the Sealed Secrets controller decrypts it into
#    grafana-admin-secret, referenced by monitoring/values.yaml
#    via existingSecret.
# ============================================================
kubectl create namespace monitoring

kubectl create secret generic grafana-admin-secret \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubeseal --cert pub-cert.pem --format yaml > monitoring/secret.yaml

kubectl apply -f monitoring/secret.yaml
# Wait until the controller has decrypted it into a real Secret,
# so Grafana doesn't start before its admin password exists.
kubectl wait --for=create secret/grafana-admin-secret -n monitoring --timeout=60s

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack \
  --version 91.7.0 \
  --namespace monitoring \
  --values monitoring/values.yaml

kubectl apply -f monitoring/flask-servicemonitor.yaml
kubectl apply -f monitoring/postgres-servicemonitor.yaml

# Loki datasource for Grafana (picked up by the Grafana sidecar
# via the grafana_datasource: "1" label).
kubectl apply -f monitoring/loki-grafana-datasource.yaml

# ============================================================
# 6. Logging — Loki (IRSA role/ServiceAccount BEFORE Helm) and
#    Alloy. The IRSA role + SA don't survive teardown (tied to
#    the cluster's OIDC provider) and are recreated every rebuild.
#    LokiS3AccessPolicy itself is a standalone IAM policy that
#    must already exist in the account.
# ============================================================
kubectl create namespace logging

eksctl create iamserviceaccount \
  --name loki-s3-sa \
  --namespace logging \
  --cluster "$CLUSTER" \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT}:policy/LokiS3AccessPolicy" \
  --region "$REGION" \
  --approve

helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update
helm install loki grafana-community/loki \
  --version 18.13.5 \
  --namespace logging \
  -f logging/values.yml

# Alloy — log collection agent (DaemonSet), ships Pod logs to Loki.
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install alloy grafana/alloy \
  --version 1.13.0 \
  --namespace logging \
  -f logging/alloy-values.yaml

# ============================================================
# 7. Verify (|| true throughout — diagnostic checks only; a
#    zero-match grep or an unready Metrics Server shouldn't kill
#    the script this late)
# ============================================================
# Network policy agent must appear in the aws-node containers,
# otherwise NetworkPolicies are not enforced.
kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}' || true
kubectl get pods -n kube-system | grep -E "ebs-csi|sealed-secrets|cluster-autoscaler" || true
kubectl get pods -n argocd || true
kubectl get pods -n flask-app || true
kubectl get pods -n monitoring || true
kubectl get pods -n logging || true
kubectl get servicemonitors -n monitoring || true
kubectl get networkpolicies -A || true
kubectl top nodes || true
kubectl get svc -n monitoring | grep grafana || true
