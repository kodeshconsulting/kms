import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encrypt, decrypt } from './index.ts';

// Tests d'intégration : ils appellent vraiment KMS. Requièrent KMS_KEY_NAME et des credentials (README).
const skip = !process.env.KMS_KEY_NAME && 'KMS_KEY_NAME is not set';

test('encrypt then decrypt returns the original text', { skip }, async () => {
    const secret = 'SIN 123-456-789 — éàü 🙂';
    const first = await encrypt(secret);
    const second = await encrypt(secret);
    assert.notEqual(first, secret);
    assert.notEqual(first, second, 'each call produces a different ciphertext (random key and IV)');
    assert.equal(await decrypt(first), secret);
    assert.equal(await decrypt(second), secret);
});

test('handles payloads far beyond the 64 KiB limit of a direct KMS call', { skip }, async () => {
    const large = 'long answer ✍️ '.repeat(80_000); // ≈ 1.3 MB
    assert.equal(await decrypt(await encrypt(large)), large);
});

test('rejects a tampered ciphertext', { skip }, async () => {
    const bytes = Buffer.from(await encrypt('intact'), 'base64');
    bytes[bytes.length - 1] ^= 1;
    await assert.rejects(decrypt(bytes.toString('base64')));
});
