import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
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
    if (!name) throw new Error('KMS_KEY_NAME is not set (see .env.example)');
    return name;
}

// Chiffrement enveloppe : les données sont chiffrées ici (AES-256-GCM) avec une clé jetable, et
// seule cette clé jetable passe par KMS. Un appel KMS par opération, aucune limite de taille.
// Format du chiffré (base64) :
//   [2 octets : taille de la clé enveloppée][clé enveloppée][iv 12 octets][tag 16 octets][données]
const IV_BYTES = 12;
const TAG_BYTES = 16;

/** Chiffre une chaîne UTF-8. Retourne du base64 à stocker tel quel dans une colonne `text`. */
export async function encrypt(plaintext: string): Promise<string> {
    const dataKey = randomBytes(32);
    const iv = randomBytes(IV_BYTES);
    const cipher = createCipheriv('aes-256-gcm', dataKey, iv);
    const data = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
    const [res] = await kms().encrypt({ name: keyName(), plaintext: dataKey });
    const wrappedKey = Buffer.from(res.ciphertext as Uint8Array);
    const header = Buffer.alloc(2);
    header.writeUInt16BE(wrappedKey.length);
    return Buffer.concat([header, wrappedKey, iv, cipher.getAuthTag(), data]).toString('base64');
}

/** Inverse de `encrypt`. Fonctionne quelle que soit la version de clé KMS utilisée au chiffrement. */
export async function decrypt(ciphertext: string): Promise<string> {
    const buf = Buffer.from(ciphertext, 'base64');
    const keyLength = buf.readUInt16BE(0);
    let offset = 2;
    const wrappedKey = buf.subarray(offset, (offset += keyLength));
    const iv = buf.subarray(offset, (offset += IV_BYTES));
    const tag = buf.subarray(offset, (offset += TAG_BYTES));
    const data = buf.subarray(offset);
    const [res] = await kms().decrypt({ name: keyName(), ciphertext: wrappedKey });
    const decipher = createDecipheriv('aes-256-gcm', Buffer.from(res.plaintext as Uint8Array), iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(data), decipher.final()]).toString('utf8');
}
