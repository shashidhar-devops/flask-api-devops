#!/usr/bin/env bash
set -euo pipefail

REGION="us-east-1"
CLUSTER="flask-api-cluster"
ACCOUNT="253264393553"
ROLE="AmazonEKS_EBS_CSI_DriverRole"

eksctl create cluster -f cluster-config.yaml

eksctl utils associate-iam-oidc-provider \
  --region "$REGION" \
  --cluster "$CLUSTER" \
  --approve

eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster "$CLUSTER" \
  --role-name "$ROLE" \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --region "$REGION"

eksctl create addon \
  --cluster "$CLUSTER" \
  --name aws-ebs-csi-driver \
  --version latest \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT}:role/${ROLE}" \
  --region "$REGION" \
  --force

kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=180s
