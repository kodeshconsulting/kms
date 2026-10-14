# @buildmegachurch/kms

Chiffre et déchiffre des champs sensibles avec **Google Cloud KMS** avant de les stocker dans Supabase.
Deux fonctions : `encrypt(texte) → base64` et `decrypt(base64) → texte`. C'est tout.

## Comment ça marche (2 minutes)

- Une **clé de chiffrement** vit dans Google Cloud KMS et **n'en sort jamais**. Ni toi, ni le code, ni Supabase ne la voient.
- Ton code envoie le texte en clair à Google, qui renvoie le texte chiffré (et l'inverse au déchiffrement). Chaque opération = 1 appel HTTPS, environ 50 à 100 ms.
- Tu stockes le résultat (base64) dans une colonne `text` Supabase. Si la base fuit, c'est illisible sans accès à la clé.
- **Qui** peut utiliser la clé est contrôlé par IAM. Un *service account* (identité technique) reçoit le rôle `cloudkms.cryptoKeyEncrypterDecrypter` sur cette clé et rien d'autre.
- La clé **tourne automatiquement tous les 90 jours**. Les anciennes versions restent utilisables pour déchiffrer, donc rien à migrer : `decrypt` marche sur tout ce qui a déjà été chiffré.
- **Coût** : 0,06 $ US/mois par version de clé active, 0,03 $ par 10 000 opérations. Négligeable.

Deux limites à connaître :

- **64 KiB maximum** par appel. Pour un champ (NAS, adresse, note, numéro de compte) c'est très large.
- **Le chiffré change à chaque appel** (vecteur d'initialisation aléatoire). Impossible de faire `WHERE colonne_chiffree = '...'`. Garde en clair ce que tu dois filtrer, ou stocke un hash SHA-256 à côté pour la recherche exacte.

## 1. Installer gcloud et se connecter (une fois, sur ton poste)

```bash
brew install --cask google-cloud-sdk
```

```bash
gcloud auth login
```

```bash
gcloud config set project buildmegachurch
```

```bash
gcloud auth application-default login
```

La dernière commande donne au code qui tourne **sur ton poste** le droit d'appeler Google avec ton identité. Rien à mettre dans `.env` pour ça.

Pour exécuter le script de l'étape 2, ton compte doit être *Propriétaire* du projet ou avoir le rôle **Administrateur Cloud KMS** (`roles/cloudkms.admin`). Le rôle *Éditeur* ne suffit pas : il permet de créer des clés mais ni de les utiliser, ni d'en gérer les droits, ni de les détruire.

## 2. Créer la clé et le service account (une fois)

```bash
./scripts/setup-gcp.sh
```

Le script est idempotent (relançable). Il crée :

| Quoi | Nom | Pourquoi |
|---|---|---|
| API Cloud KMS | activée sur `buildmegachurch` | obligatoire |
| Keyring | `buildmegachurch` à `northamerica-northeast1` (Montréal) | conteneur de clés, données au Canada |
| Clé symétrique | `supabase-fields`, rotation 90 jours | celle qui chiffre |
| Service account | `kms-encrypter@buildmegachurch.iam.gserviceaccount.com` | identité de la prod |
| Droit IAM | encrypt/decrypt pour ce SA **et pour ton compte**, sur cette clé seulement | moindre privilège, et le dev local marche |

Il affiche à la fin la valeur `KMS_KEY_NAME` à copier.

Une clé distincte par projet consommateur (recommandé si les projets ont des équipes ou des niveaux de sensibilité différents) :

```bash
./scripts/setup-gcp.sh nom-du-projet
```

Attention : un keyring KMS **ne se supprime jamais** et une clé ne se détruit qu'après un délai planifié. Choisis les noms une fois pour toutes.

## 3. Tester en local

```bash
cp .env.example .env
```

Colle la valeur `KMS_KEY_NAME` affichée par le script, puis :

```bash
npm test
```

Le test chiffre une chaîne, vérifie que deux chiffrements diffèrent, et la déchiffre. S'il passe, tout est branché.

## 4. Utiliser dans un autre projet

```bash
npm install github:kodeshconsulting/kms
```

Variables d'environnement du projet : `KMS_KEY_NAME` (et `GCP_SA_KEY` en prod, voir section 5).

```ts
import { encrypt, decrypt } from '@buildmegachurch/kms';

// Avant d'écrire
await supabase.from('membres').insert({ nom, nas: await encrypt(nas) });

// Après avoir lu
const { data } = await supabase.from('membres').select('nas').eq('id', id).single();
const nas = await decrypt(data.nas);
```

**Côté serveur uniquement** : Server Components, Route Handlers, Server Actions, API Node. Jamais dans du code qui s'exécute dans le navigateur, sinon les credentials GCP fuient.

Plusieurs lignes à déchiffrer ? `Promise.all(rows.map(r => decrypt(r.nas)))`. Les appels partent en parallèle.

## 5. Déployer (Vercel ou autre)

En prod il n'y a pas de `gcloud` ni de session à toi. Le code s'authentifie avec la clé du service account :

```bash
gcloud iam service-accounts keys create sa-key.json --iam-account=kms-encrypter@buildmegachurch.iam.gserviceaccount.com
```

Dans Vercel, Settings → Environment Variables :

- `KMS_KEY_NAME` = la valeur du script
- `GCP_SA_KEY` = le contenu complet de `sa-key.json`, sur une ligne

Puis supprime `sa-key.json` de ton disque. Il est dans `.gitignore`, ne le commite jamais. Si la clé fuit un jour :

```bash
gcloud iam service-accounts keys list --iam-account=kms-encrypter@buildmegachurch.iam.gserviceaccount.com
```

```bash
gcloud iam service-accounts keys delete <KEY_ID> --iam-account=kms-encrypter@buildmegachurch.iam.gserviceaccount.com
```

Les données déjà chiffrées restent protégées : la clé KMS elle-même n'a jamais quitté Google.

## Non inclus, volontairement

- **Envelope encryption** (clé AES locale, elle-même chiffrée par KMS). Utile au-delà de 64 KiB ou si tu chiffres des milliers de valeurs par requête. À ajouter quand la latence KMS devient un vrai problème.
- **Vérification CRC32C** des réponses KMS. TLS garantit déjà l'intégrité en transit.
- **Service HTTP centralisé**. Une lib importée suffit ; chaque projet porte ses propres credentials.
