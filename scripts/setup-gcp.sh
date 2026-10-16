#!/usr/bin/env bash
# Crée la clé KMS et le service account dans le projet GCP. Idempotent : relancer sans risque.
# Usage : ./scripts/setup-gcp.sh [key-name]   (défaut : supabase-fields)
# Prérequis : gcloud connecté avec un compte Propriétaire du projet ou Administrateur Cloud KMS.
set -euo pipefail

PROJECT=buildmegachurch
LOCATION=northamerica-northeast1   # Montréal : les données restent au Canada
KEYRING=buildmegachurch
KEY=${1:-supabase-fields}
SERVICE_ACCOUNT=kms-encrypter
SERVICE_ACCOUNT_EMAIL="$SERVICE_ACCOUNT@$PROJECT.iam.gserviceaccount.com"
ROLE=roles/cloudkms.cryptoKeyEncrypterDecrypter
NEXT_ROTATION=$(date -u -v+90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)

echo "▸ Enabling the Cloud KMS API"
gcloud services enable cloudkms.googleapis.com --project="$PROJECT"

echo "▸ Key ring $KEYRING ($LOCATION)"
gcloud kms keyrings describe "$KEYRING" --location="$LOCATION" --project="$PROJECT" >/dev/null 2>&1 \
  || gcloud kms keyrings create "$KEYRING" --location="$LOCATION" --project="$PROJECT"

echo "▸ Key $KEY (automatic rotation: 90 days)"
gcloud kms keys describe "$KEY" --keyring="$KEYRING" --location="$LOCATION" --project="$PROJECT" >/dev/null 2>&1 \
  || gcloud kms keys create "$KEY" --keyring="$KEYRING" --location="$LOCATION" --project="$PROJECT" \
       --purpose=encryption --rotation-period=90d --next-rotation-time="$NEXT_ROTATION"

echo "▸ Service account $SERVICE_ACCOUNT"
gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project="$PROJECT" >/dev/null 2>&1 \
  || gcloud iam service-accounts create "$SERVICE_ACCOUNT" --display-name="KMS encrypt/decrypt" --project="$PROJECT"

echo "▸ Encrypt/decrypt permission on this key only (service account + your own account, for local dev)"
# Ne fait rien si la liaison existe déjà : un compte sans droit setIamPolicy passe quand même.
ensure_binding() {  # $1 = principal
  gcloud kms keys get-iam-policy "$KEY" --keyring="$KEYRING" --location="$LOCATION" --project="$PROJECT" \
      --flatten="bindings[].members" --filter="bindings.role=$ROLE AND bindings.members=$1" \
      --format="value(bindings.members)" 2>/dev/null | grep -q . \
    || gcloud kms keys add-iam-policy-binding "$KEY" --keyring="$KEYRING" --location="$LOCATION" --project="$PROJECT" \
         --member="$1" --role="$ROLE" >/dev/null
}
ensure_binding "serviceAccount:$SERVICE_ACCOUNT_EMAIL"
ensure_binding "user:$(gcloud config get-value account 2>/dev/null)"

cat <<MSG

✔ Done. Put this in .env (and in the environment variables of every consuming project):

KMS_KEY_NAME=projects/$PROJECT/locations/$LOCATION/keyRings/$KEYRING/cryptoKeys/$KEY

For production (Vercel…), generate the service account key — a SECRET file, never committed:
  gcloud iam service-accounts keys create sa-key.json --iam-account=$SERVICE_ACCOUNT_EMAIL
MSG
