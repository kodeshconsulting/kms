import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encrypt, decrypt } from './index.ts';

// Test d'intégration : appelle vraiment KMS. Requiert KMS_KEY_NAME + credentials (voir README).
test(
  'encrypt → decrypt round-trip',
  { skip: !process.env.KMS_KEY_NAME && 'KMS_KEY_NAME manquant' },
  async () => {
    const secret = 'NAS 123-456-789 — éàü 🙂';
    const a = await encrypt(secret);
    const b = await encrypt(secret);
    assert.notEqual(a, secret);
    assert.notEqual(a, b, 'le chiffré change à chaque appel (IV aléatoire)');
    assert.equal(await decrypt(a), secret);
    assert.equal(await decrypt(b), secret);
  },
);
