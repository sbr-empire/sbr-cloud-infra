#!/usr/bin/env bash
set -euo pipefail

# ============================================
# SBR Empire - Complete GCP Setup Script
# This script sets up the entire Google Cloud
# infrastructure for production deployment
# ============================================

export PROJECT_ID="${PROJECT_ID:-sbr-empire-prod}"
export REGION="${REGION:-us-central1}"
export BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"

if [[ -z "$BILLING_ACCOUNT" ]]; then
  echo "ERROR: BILLING_ACCOUNT is required"
  echo "Usage: export BILLING_ACCOUNT='012345-6789AB-CDEF01' && bash setup-gcp.sh"
  exit 1
fi

echo "=========================================="
echo "SBR Empire GCP Setup"
echo "=========================================="
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Billing Account: $BILLING_ACCOUNT"
echo "=========================================="

# Step 1: Set project
echo "[1/11] Setting GCP project..."
gcloud config set project "$PROJECT_ID"

# Step 2: Enable APIs
echo "[2/11] Enabling required APIs..."
gcloud services enable \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  sqladmin.googleapis.com \
  containerregistry.googleapis.com \
  --project="$PROJECT_ID"

echo "✅ APIs enabled"

# Step 3: Create Artifact Registry repositories
echo "[3/11] Creating Artifact Registry repositories..."
for repo in sbrhikkmah sbrbioforge sbrbeautyhub sbrcore; do
  gcloud artifacts repositories create "$repo" \
    --repository-format=docker \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --description="Docker images for $repo" \
    --quiet || true
done

echo "✅ Artifact Registry repos created"

# Step 4: Create runtime service account
echo "[4/11] Creating Cloud Run runtime service account..."
gcloud iam service-accounts create cloudrun-runtime \
  --display-name="Cloud Run Runtime Service Account" \
  --project="$PROJECT_ID" \
  --quiet || true

RUNTIME_SA="cloudrun-runtime@${PROJECT_ID}.iam.gserviceaccount.com"

# Grant runtime SA permissions
for role in \
  roles/secretmanager.secretAccessor \
  roles/artifactregistry.reader \
  roles/logging.logWriter \
  roles/monitoring.metricWriter \
  roles/cloudsql.client
do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME_SA}" \
    --role="$role" \
    --quiet || true
done

echo "✅ Runtime service account created: $RUNTIME_SA"

# Step 5: Create deployer service account
echo "[5/11] Creating Cloud Run deployer service account..."
gcloud iam service-accounts create cloudrun-deployer \
  --display-name="Cloud Run Deployer Service Account" \
  --project="$PROJECT_ID" \
  --quiet || true

DEPLOYER_SA="cloudrun-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

# Grant deployer SA permissions
for role in \
  roles/run.admin \
  roles/iam.serviceAccountUser \
  roles/artifactregistry.writer \
  roles/secretmanager.secretAccessor
do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEPLOYER_SA}" \
    --role="$role" \
    --quiet || true
done

echo "✅ Deployer service account created: $DEPLOYER_SA"

# Step 6: Enable Secret Manager
echo "[6/11] Enabling Secret Manager..."
gcloud services enable secretmanager.googleapis.com --project="$PROJECT_ID"

echo "✅ Secret Manager enabled"

# Step 7: Create budget alert
echo "[7/11] Creating billing budget alert..."
gcloud beta billing budgets create \
  --billing-account="$BILLING_ACCOUNT" \
  --display-name="sbr-empire-prod-budget" \
  --budget-amount=500 \
  --threshold-rule=0.5,0.8,1.0 \
  --project="$PROJECT_ID" \
  --quiet || true

echo "✅ Budget alert created (₹500 limit)"

# Step 8: Create Workload Identity Pool (GitHub OIDC)
echo "[8/11] Setting up Workload Identity Federation for GitHub Actions..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

# Create the workload identity pool
gcloud iam workload-identity-pools create "github-actions" \
  --project="$PROJECT_ID" \
  --location="global" \
  --display-name="GitHub Actions Pool" \
  --disabled=false \
  --quiet || true

echo "✅ Workload Identity Pool created"

# Step 9: Create GitHub provider
echo "[9/11] Creating GitHub OIDC provider..."
gcloud iam workload-identity-providers create-oidc "github" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="github-actions" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.aud=assertion.aud,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref,attribute.workflow=assertion.workflow,attribute.actor=assertion.actor" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --quiet || true

echo "✅ GitHub OIDC provider created"

# Step 10: Grant OIDC permissions to deployer SA
echo "[10/11] Binding GitHub OIDC to deployer service account..."
gcloud iam service-accounts add-iam-policy-binding "${DEPLOYER_SA}" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-actions/attribute.repository/sbr-empire/*" \
  --quiet || true

echo "✅ OIDC bindings configured"

# Step 11: Display summary
echo "[11/11] Setup complete!"
echo ""
echo "=========================================="
echo "✅ SETUP COMPLETE"
echo "=========================================="
echo ""
echo "Project ID: $PROJECT_ID"
echo "Region: $REGION"
echo "Runtime SA: $RUNTIME_SA"
echo "Deployer SA: $DEPLOYER_SA"
echo "Workload Identity Pool: github-actions"
echo "OIDC Provider URI: projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-actions/providers/github"
echo ""
echo "Next steps:"
echo "1. Run: bash scripts/setup-secrets.sh"
echo "2. Run: bash scripts/deploy-cloudrun.sh"
echo "3. Run: bash scripts/domain-mapping.sh"
echo "4. Add GitHub workflows to your repos"
echo ""
