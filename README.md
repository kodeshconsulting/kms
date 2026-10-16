# @buildmegachurch/kms

Chiffre et déchiffre des données sensibles avec **Google Cloud KMS** avant de les stocker dans
Supabase. Deux fonctions, rien d'autre :

```ts
import { encrypt, decrypt } from '@buildmegachurch/kms';

const chiffre = await encrypt('texte sensible');   // → base64, à stocker tel quel
const clair = await decrypt(chiffre);              // → 'texte sensible'
```

Ce document explique tout depuis zéro : ce qu'est KMS, comment la librairie s'en sert, comment
l'installer dans un projet, comment déployer, et que faire quand ça casse.

---

## 1. Google Cloud KMS expliqué simplement

**Le problème.** Une base de données chiffre ses disques, mais quiconque a accès à la base (tableau
de bord, clé secrète, sauvegarde) lit les données en clair. Pour protéger un champ vraiment sensible,
il faut le chiffrer *avant* qu'il entre dans la base, avec une clé que la base ne possède pas.

**Le risque classique.** Si cette clé est un fichier ou une variable d'environnement, elle finit par
fuir : commit par erreur, copie sur un poste, ancien employé. Et personne ne sait qui s'en est servi.

**La réponse de KMS.** Google garde la clé dans un coffre matériel. **Elle n'en sort jamais.**
Personne ne la voit, ni toi, ni ton code, ni Google. Tu envoies des octets à chiffrer, tu reçois des
octets chiffrés, et inversement. Chaque usage est journalisé, et seules les identités que tu as
autorisées peuvent appeler.

### Le vocabulaire, en une ligne chacun

| Terme | Ce que c'est | Ici |
|---|---|---|
| **Projet GCP** | Le compte de facturation et de permissions | `buildmegachurch` |
| **Emplacement** | Où vit la clé physiquement | `northamerica-northeast1` (Montréal, donc données au Canada) |
| **Keyring** (trousseau) | Un dossier de clés. Il ne se supprime jamais | `buildmegachurch` |
| **Clé** (CryptoKey) | La clé de chiffrement elle-même | `supabase-fields` |
| **Version de clé** | Chaque rotation crée une version. Les anciennes restent utilisables pour déchiffrer | version 1, puis 2 tous les 90 jours |
| **Rotation** | Google crée une nouvelle version automatiquement. Rien à faire côté code | tous les 90 jours |
| **Service account** (SA) | Une identité technique, pour un programme et non une personne | `kms-encrypter@buildmegachurch.iam.gserviceaccount.com` |
| **Rôle IAM** | Ce qu'une identité a le droit de faire | `Cloud KMS CryptoKey Encrypter/Decrypter` : chiffrer et déchiffrer, rien d'autre |
| **ADC** (Application Default Credentials) | La façon dont un programme trouve des credentials sans fichier : ta session `gcloud` en local | `gcloud auth application-default login` |

### Qui peut chiffrer et déchiffrer ?

Seulement deux identités, et seulement sur cette clé :

- le service account `kms-encrypter`, utilisé par le code en production ;
- ton compte Google, pour développer en local.

Elles ne peuvent ni voir la clé, ni la modifier, ni la détruire. Le rôle **Administrateur Cloud
KMS** (qui crée des clés et donne des droits) est séparé et ne permet pas de déchiffrer.

### Combien ça coûte

- 0,06 $ US par mois par version de clé active (une nouvelle version tous les 90 jours).
- 0,03 $ US par 10 000 opérations.

Pour un site qui chiffre quelques milliers de réponses par mois : quelques cents.

---

## 2. Comment la librairie chiffre : le « chiffrement enveloppe »

Un appel KMS direct est limité à 64 Ko et coûte un aller-retour réseau par donnée. Google
recommande donc le **chiffrement enveloppe**, que cette librairie applique :

```
encrypt(texte)
  1. génère une clé jetable de 32 octets (la « clé de données »)
  2. chiffre le texte sur place, en AES-256-GCM, avec cette clé jetable       ← rapide, taille illimitée
  3. envoie la clé jetable à KMS, qui la renvoie chiffrée par la clé du coffre  ← un seul appel réseau
  4. assemble : [clé jetable chiffrée][iv][tag][texte chiffré] → base64

decrypt(base64)
  1. sépare les morceaux
  2. envoie la clé jetable chiffrée à KMS, qui la renvoie en clair            ← un seul appel réseau
  3. déchiffre le texte sur place avec cette clé jetable
```

Conséquences :

- **Un appel KMS par opération**, quelle que soit la taille des données (testé à 1,3 Mo).
- **Chaque chiffrement est différent**, même pour le même texte : impossible de faire
  `WHERE colonne = '…'` sur une colonne chiffrée. Garde en clair ce que tu dois filtrer.
- **Toute altération est détectée** : un chiffré modifié d'un seul bit est refusé au déchiffrement.
- **La rotation est transparente** : le chiffré contient de quoi retrouver la bonne version de clé.

Le chiffré est une chaîne base64. Stocke-la dans une colonne `text`.

---

## 3. Mise en place sur ton poste (une fois)

### Installer gcloud et se connecter

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

Les deux `login` ouvrent le navigateur. Le premier connecte la commande `gcloud` ; le second donne
des credentials **au code qui tourne sur ton poste** (ADC). Rien à mettre dans `.env` pour ça.

### Créer la clé et le service account

Déjà fait pour `buildmegachurch`. Le script reste utile pour une autre clé ou un autre projet, et il
est idempotent : le relancer ne casse rien.

```bash
./scripts/setup-gcp.sh
```

Il crée, s'ils n'existent pas : l'API activée, le keyring, la clé avec rotation, le service account,
et le droit encrypt/decrypt pour le SA **et pour ton compte**. Il affiche la valeur `KMS_KEY_NAME`.

Il faut un compte **Propriétaire** du projet ou **Administrateur Cloud KMS**. Le rôle Éditeur ne
suffit pas : il crée des clés mais ne peut ni les utiliser, ni donner des droits, ni les détruire.

Une clé par projet consommateur (recommandé si les projets n'ont pas la même sensibilité) :

```bash
./scripts/setup-gcp.sh nom-du-projet
```

### Tester

```bash
cp .env.example .env
```

```bash
npm install && npm test
```

Les trois tests appellent vraiment KMS : aller-retour, 1,3 Mo, chiffré altéré refusé.

---

## 4. Utiliser dans un projet

### Installer

Le dépôt est privé. En local, ta session Git suffit :

```bash
npm install github:kodeshconsulting/kms#v0.2.0
```

Le `#v0.2.0` fige la version : une mise à jour de la librairie ne change rien dans le projet tant
que tu ne changes pas ce tag.

### Configurer

Deux variables d'environnement :

| Variable | Secret ? | Local | Production |
|---|---|---|---|
| `KMS_KEY_NAME` | non | dans `.env.local` | dans les variables du projet |
| `GCP_SA_KEY` | **oui** | absent, ADC fait le travail | contenu JSON de la clé du SA |

### Écrire le code

**Côté serveur uniquement** : route d'API, Server Action, script Node. Jamais dans du code qui
s'exécute dans le navigateur, sinon les credentials fuient.

```ts
import { encrypt, decrypt } from '@buildmegachurch/kms';

// Avant d'écrire
await supabase.from('reponses').upsert({ site, uid, numero, chiffre: await encrypt(JSON.stringify(textes)) });

// Après avoir lu
const { data } = await supabase.from('reponses').select('numero, chiffre').eq('site', site);
const textes = await Promise.all(data.map(async (l) => JSON.parse(await decrypt(l.chiffre))));
```

Plusieurs lignes à déchiffrer : `Promise.all`, les appels partent en parallèle.

Une erreur KMS (droit manquant, réseau) remonte comme une exception ordinaire. Attrape-la et
affiche un échec, sans jamais perdre la saisie de la personne.

---

## 5. Déployer sur Vercel

En production il n'y a ni `gcloud` ni ta session. Trois choses à poser dans le projet Vercel.

### a. Un jeton pour installer le dépôt privé

Vercel exécute `npm install` sur ses serveurs et n'a pas accès à tes dépôts privés.

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** →
   Generate. Dépôt : `kodeshconsulting/kms` seulement. Permission : **Contents : Read-only**.
2. Vercel → projet → Settings → Environment Variables : `GITHUB_TOKEN` = le jeton.
3. Vercel → Settings → General → Build & Development Settings → **Install Command** :

```bash
git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "ssh://git@github.com/" && npm ci
```

Pourquoi `ssh://` : npm enregistre les dépendances GitHub sous la forme `git+ssh://git@github.com/…`
dans `package-lock.json`, et Vercel n'a pas de clé SSH. Cette ligne dit à Git de remplacer cette
adresse par la version HTTPS avec le jeton, le temps de l'installation.

### b. La clé du service account

Génère-la sur ton poste (fichier **secret**, déjà dans `.gitignore`) :

```bash
gcloud iam service-accounts keys create sa-key.json --iam-account=kms-encrypter@buildmegachurch.iam.gserviceaccount.com
```

Dans Vercel, variable `GCP_SA_KEY` = le contenu complet du fichier, sur une ligne. Puis supprime
`sa-key.json` de ton disque.

### c. Le nom de la clé

Variable `KMS_KEY_NAME` = la même valeur qu'en local.

---

## 6. Entretien

**Rotation.** Automatique tous les 90 jours. Rien à faire, rien à migrer.

**Si la clé du service account fuit.** Révoque-la, régénère-la, remplace `GCP_SA_KEY` :

```bash
gcloud iam service-accounts keys list --iam-account=kms-encrypter@buildmegachurch.iam.gserviceaccount.com
```

```bash
gcloud iam service-accounts keys delete <KEY_ID> --iam-account=kms-encrypter@buildmegachurch.iam.gserviceaccount.com
```

Les données déjà chiffrées restent protégées : la clé KMS elle-même n'a jamais quitté Google.

**Voir qui a chiffré ou déchiffré.** Console Google → Logging → filtre `cloudkms.googleapis.com`.

**Détruire une clé.** Jamais tant que des données en dépendent : elles deviendraient illisibles pour
toujours. La destruction est différée de 30 jours et annulable pendant ce délai.

---

## 7. Erreurs fréquentes

| Message | Cause | Solution |
|---|---|---|
| `KMS_KEY_NAME is not set` | Variable absente | Copier `.env.example` en `.env`, ou poser la variable sur Vercel |
| `Could not load the default credentials` | Pas de credentials en local | `gcloud auth application-default login` |
| `PERMISSION_DENIED … useToEncrypt` ou `useToDecrypt` | L'identité n'a pas le rôle Encrypter/Decrypter sur la clé | Relancer `./scripts/setup-gcp.sh` avec un compte admin, ou demander le rôle au propriétaire du projet |
| `PERMISSION_DENIED … setIamPolicy` | Ton compte peut créer des clés mais pas donner de droits (rôle Éditeur) | Demander le rôle **Cloud KMS Admin** au propriétaire |
| `FAILED_PRECONDITION: Billing is disabled` | Le projet GCP n'a pas de compte de facturation | Console → Facturation → lier le projet |
| `Unsupported state or unable to authenticate data` | Le chiffré a été modifié ou tronqué | La donnée en base est corrompue ; elle n'est pas récupérable |
| `INVALID_ARGUMENT` au déchiffrement | La chaîne n'est pas un chiffré produit par cette librairie | Vérifier la colonne lue |

---

## 8. Ce que ça ne fait pas

- **Pas de « zéro connaissance ».** Qui contrôle à la fois la base et les credentials Google (ou
  l'IAM du projet) peut déchiffrer. La protection vise l'accès isolé à la base.
- **Pas de recherche** dans les champs chiffrés.
- **Pas de liaison** entre un chiffré et sa ligne : un administrateur de la base qui copie le
  chiffré de la ligne A dans la ligne B ne le lit pas pour autant, mais B le déchiffrerait. À ajouter
  si ce scénario devient réaliste (données additionnelles authentifiées dans AES-GCM).

---

## Structure du dépôt

| Fichier | Rôle |
|---|---|
| `src/index.ts` | les deux fonctions |
| `src/index.test.ts` | tests d'intégration contre KMS |
| `scripts/setup-gcp.sh` | création idempotente de la clé, du SA et des droits |
| `.env.example` | les deux variables, commentées |
