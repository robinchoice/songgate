import { type Database, serverSecrets } from '@app/db';
import { createChallenge, randomInt, verifySolution } from 'altcha-lib';
import { deriveKey } from 'altcha-lib/algorithms/pbkdf2';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { generateToken } from './auth';
import { rateLimit } from './rate-limit';

// Proof of work before login mails, the same as in starter (README, „ALTCHA“).
// The app solves it in 0.1–0.5 s, bots pay for every mail they ask for.
const ALGORITHM = 'PBKDF2/SHA-256';
const COST = 100;
const MIN_COUNTER = 1_500;
const MAX_COUNTER = 3_000;
const LIFETIME = 10 * 60 * 1000;

// Each solution counts once. The window outlasts the challenge, after that it has expired.
const usedPayloads = rateLimit('altcha-used', 1, LIFETIME);

export const challengeSchema = z.looseObject({
  parameters: z.looseObject({ algorithm: z.string(), nonce: z.string(), salt: z.string(), cost: z.number(), keyLength: z.number(), keyPrefix: z.string() }),
  signature: z.string().exactOptional(),
});

const payloadSchema = z.object({
  challenge: challengeSchema,
  solution: z.object({ counter: z.number(), derivedKey: z.string(), time: z.number().exactOptional() }),
});

let key: string | undefined;

async function hmacKey(db: Database) {
  if (key) return key;
  await db.insert(serverSecrets).values({ name: 'altcha', value: generateToken() }).onConflictDoNothing();
  const [row] = await db.select().from(serverSecrets).where(eq(serverSecrets.name, 'altcha'));
  key = row!.value;
  return key;
}

export async function altchaChallenge(db: Database) {
  return createChallenge({
    algorithm: ALGORITHM,
    cost: COST,
    counter: randomInt(MAX_COUNTER, MIN_COUNTER),
    deriveKey,
    expiresAt: new Date(Date.now() + LIFETIME),
    hmacSignatureSecret: await hmacKey(db),
  });
}

// The app sends the solution as base64 JSON. Anything that doesn't parse, verify or was used before fails.
export async function altchaSolved(db: Database, payload: string) {
  try {
    const parsed = payloadSchema.safeParse(JSON.parse(atob(payload)));
    if (!parsed.success) return false;
    const { challenge, solution } = parsed.data;
    const result = await verifySolution({ challenge, solution, deriveKey, hmacSignatureSecret: await hmacKey(db) });
    return result.verified && (await usedPayloads.hit(db, challenge.parameters.nonce));
  } catch {
    return false;
  }
}
