import { KeyManagementServiceClient } from '@google-cloud/kms';

let client: KeyManagementServiceClient | undefined;

// En local : rien à configurer, `gcloud auth application-default login` suffit.
// En prod (Vercel…) : GCP_SA_KEY = contenu JSON de la clé du service account.
function kms(): KeyManagementServiceClient {
  return (client ??= new KeyManagementServiceClient(
    process.env.GCP_SA_KEY ? { credentials: JSON.parse(process.env.GCP_SA_KEY) } : undefined,
  ));
}

// projects/<projet>/locations/<région>/keyRings/<keyring>/cryptoKeys/<clé>
function keyName(): string {
  const name = process.env.KMS_KEY_NAME;
  if (!name) throw new Error('KMS_KEY_NAME manquant (voir .env.example)');
  return name;
}

/** Chiffre une chaîne UTF-8. Retourne du base64 à stocker tel quel dans une colonne `text`. */
export async function encrypt(plaintext: string): Promise<string> {
  const [res] = await kms().encrypt({ name: keyName(), plaintext: Buffer.from(plaintext, 'utf8') });
  return Buffer.from(res.ciphertext as Uint8Array).toString('base64');
}

/** Inverse de `encrypt`. Fonctionne quelle que soit la version de clé utilisée au chiffrement. */
export async function decrypt(ciphertext: string): Promise<string> {
  const [res] = await kms().decrypt({ name: keyName(), ciphertext: Buffer.from(ciphertext, 'base64') });
  return Buffer.from(res.plaintext as Uint8Array).toString('utf8');
}
