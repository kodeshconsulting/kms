#!/usr/bin/env bash
# Crée la clé KMS et le service account dans le projet GCP. Idempotent : relancer sans risque.
# Usage : ./scripts/setup-gcp.sh [nom-de-clé]   (défaut : supabase-fields)
set -euo pipefail

PROJECT=buildmegachurch
LOCATION=northamerica-northeast1   # Montréal : les données restent au Canada
KEYRING=buildmegachurch
KEY=${1:-supabase-fields}
SA=kms-encrypter
SA_EMAIL="$SA@$PROJECT.iam.gserviceaccount.com"
NEXT_ROTATION=$(date -u -v+90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)

echo "▸ Activation de l'API Cloud KMS"
gcloud services enable cloudkms.googleapis.com --project="$PROJECT"

echo "▸ Keyring $KEYRING ($LOCATION)"
gcloud kms keyrings describe "$KEYRING" --location="$LOCATION" --project="$PROJECT" >/dev/null 2>&1 \
  || gcloud kms keyrings create "$KEYRING" --location="$LOCATION" --project="$PROJECT"

echo "▸ Clé $KEY (rotation automatique : 90 jours)"
gcloud kms keys describe "$KEY" --keyring="$KEYRING" --location="$LOCATION" --project="$PROJECT" >/dev/null 2>&1 \
  || gcloud kms keys create "$KEY" --keyring="$KEYRING" --location="$LOCATION" --project="$PROJECT" \
       --purpose=encryption --rotation-period=90d --next-rotation-time="$NEXT_ROTATION"

echo "▸ Service account $SA"
gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" >/dev/null 2>&1 \
  || gcloud iam service-accounts create "$SA" --display-name="KMS encrypt/decrypt" --project="$PROJECT"

echo "▸ Droit encrypt/decrypt sur cette clé seulement (service account + ton compte, pour le dev local)"
ROLE=roles/cloudkms.cryptoKeyEncrypterDecrypter
ensure_binding() {  # $1 = principal ; ne fait rien si la liaison existe déjà
  gcloud kms keys get-iam-policy "$KEY" --keyring="$KEYRING" --location="$LOCATION" --project="$PROJECT" \
      --flatten="bindings[].members" --filter="bindings.role=$ROLE AND bindings.members=$1" \
      --format="value(bindings.members)" 2>/dev/null | grep -q . \
    || gcloud kms keys add-iam-policy-binding "$KEY" --keyring="$KEYRING" --location="$LOCATION" --project="$PROJECT" \
         --member="$1" --role="$ROLE" >/dev/null
}
ensure_binding "serviceAccount:$SA_EMAIL"
ensure_binding "user:$(gcloud config get-value account 2>/dev/null)"

cat <<MSG

✔ Terminé. À mettre dans .env (et dans les variables d'env de chaque projet consommateur) :

KMS_KEY_NAME=projects/$PROJECT/locations/$LOCATION/keyRings/$KEYRING/cryptoKeys/$KEY

Pour la prod (Vercel…), génère la clé du service account — fichier SECRET, jamais commité :
  gcloud iam service-accounts keys create sa-key.json --iam-account=$SA_EMAIL
MSG
