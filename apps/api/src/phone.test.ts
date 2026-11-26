import { afterAll, afterEach, beforeAll, expect, spyOn, test } from 'bun:test';
import { createDb, migrateDb, phoneCodes, users } from '@app/db';
import { Evaluation, EvaluationRequest, Oprf, OPRFClient, OPRFServer } from '@cloudflare/voprf-ts';
import { solveChallenge } from 'altcha-lib';
import { deriveKey } from 'altcha-lib/algorithms/pbkdf2';
import { createDecipheriv, createHash } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { CryptoNoble } from '@cloudflare/voprf-ts/crypto-noble';
import { createApp } from './app';
import { challengeSchema } from './lib/altcha';

const OPRF_KEY = 'a'.repeat(63) + '1';
process.env.OPRF_KEY = OPRF_KEY;
// Codes go to the log, never to real numbers
delete process.env.SEVEN_API_KEY;

const db = createDb(process.env.DATABASE_URL);
const app = createApp({ db, resolve: async () => { throw new Error('unused'); } });
const log = spyOn(console, 'log');
const suite = Oprf.Suite.P256_SHA256;

beforeAll(() => migrateDb(process.env.DATABASE_URL), 20_000);
afterAll(() => db.$client.end());
afterEach(() => { delete process.env.SIGNUP_ALLOWLIST; });

const json = async (response: Response) => z.looseObject({}).parse(await response.json());

function call(path: string, { method = 'GET', body, token, ip = crypto.randomUUID() }: { method?: string; body?: unknown; token?: string; ip?: string } = {}) {
  return app.request(`/api/v1${path}`, {
    method,
    headers: { 'content-type': 'application/json', 'x-forwarded-for': ip, ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

const lastCode = (prefix: string) =>
  log.mock.calls.map(args => String(args[0])).findLast(line => line.startsWith(prefix))?.match(/\b(\d{6})\b/)?.[1];

async function logIn(name = 'Lea', platform = 'spotify') {
  const email = `test-${crypto.randomUUID()}@example.com`;
  process.env.SIGNUP_ALLOWLIST = email;
  const challenge = challengeSchema.parse(await (await call('/altcha')).json());
  const altcha = btoa(JSON.stringify({ challenge, solution: await solveChallenge({ challenge, deriveKey }) }));
  await call('/auth/code', { method: 'POST', body: { email, altcha } });
  const answer = z.object({ token: z.string(), user: z.object({ id: z.string() }) }).parse(await (await call('/auth/code/verify', { method: 'POST', body: { email, code: lastCode(`[mail] To ${email}:`) } })).json());
  await call('/me', { method: 'PATCH', token: answer.token, body: { name, platform } });
  return { token: answer.token, id: answer.user.id };
}

const randomPhone = () => `+4915${String(Math.floor(Math.random() * 1e9)).padStart(9, '0')}`;

async function confirm(token: string, phone = randomPhone()) {
  expect((await call('/me/phone', { method: 'POST', token, body: { phone } })).status).toBe(200);
  const response = await call('/me/phone/verify', { method: 'POST', token, body: { phone, code: lastCode(`[sms] To ${phone}:`) } });
  expect(response.status).toBe(200);
  return { phone, user: await json(response) };
}

// What the app does: blind, let the API evaluate, finalize to the key
async function keysFor(token: string, phones: string[]) {
  const client = new OPRFClient(suite, CryptoNoble);
  const [finalize, request] = await client.blind(phones.map(phone => new TextEncoder().encode(phone)));
  const blinded = request.blinded.map(element => Buffer.from(element.serialize(true)).toString('base64'));
  const response = await call('/discover/evaluate', { method: 'POST', token, body: { blinded } });
  if (response.status !== 200) return response.status;
  const { evaluated } = z.object({ evaluated: z.array(z.string()) }).parse(await response.json());
  const elements = evaluated.map(element => Buffer.from(element, 'base64'));
  const count = Buffer.alloc(2);
  count.writeUInt16BE(elements.length);
  // The request format is the plain list of points, the same as the answer here
  const points = EvaluationRequest.deserialize(suite, Buffer.concat([count, ...elements]), CryptoNoble).blinded;
  const outputs = await client.finalize(finalize, new Evaluation(Oprf.Mode.OPRF, points));
  return outputs.map(output => Buffer.from(output).toString('hex'));
}

test('a number confirmed by SMS makes the account discoverable without storing the number', async () => {
  const { token, id } = await logIn();
  const { phone, user } = await confirm(token);
  expect(user).toMatchObject({ user: { discoverable: true } });
  const [row] = await db.select().from(users).where(eq(users.id, id));
  const expected = Buffer.from(await new OPRFServer(suite, Buffer.from(OPRF_KEY, 'hex'), CryptoNoble).evaluate(new TextEncoder().encode(phone))).toString('hex');
  expect(row!.phoneKey).toBe(expected);
  expect(JSON.stringify(row)).not.toContain(phone.slice(1));
  expect(JSON.stringify(await db.select().from(phoneCodes).where(eq(phoneCodes.userId, id)))).not.toContain(phone.slice(1));
});

test('a wrong SMS code fails and five wrong guesses use it up', async () => {
  const { token } = await logIn();
  const phone = randomPhone();
  await call('/me/phone', { method: 'POST', token, body: { phone } });
  const code = lastCode(`[sms] To ${phone}:`)!;
  const wrong = code === '000000' ? '000001' : '000000';
  for (let i = 0; i < 5; i++) expect((await call('/me/phone/verify', { method: 'POST', token, body: { phone, code: wrong } })).status).toBe(400);
  expect((await call('/me/phone/verify', { method: 'POST', token, body: { phone, code } })).status).toBe(400);
});

test('numbers must be in E.164', async () => {
  const { token } = await logIn();
  expect((await call('/me/phone', { method: 'POST', token, body: { phone: '0151 2345678' } })).status).toBe(400);
});

test('regression: production without a seven.io key does not log a phone number or code', async () => {
  const { token } = await logIn();
  const phone = randomPhone();
  const mode = process.env.NODE_ENV;
  process.env.NODE_ENV = 'production';
  try {
    expect((await call('/me/phone', { method: 'POST', token, body: { phone } })).status).toBe(503);
    expect(lastCode(`[sms] To ${phone}:`)).toBeUndefined();
  } finally {
    if (mode === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = mode;
  }
});

test('a number gets at most three SMS an hour', async () => {
  const phone = randomPhone();
  for (let i = 0; i < 3; i++) {
    const { token } = await logIn();
    expect((await call('/me/phone', { method: 'POST', token, body: { phone } })).status).toBe(200);
  }
  const { token } = await logIn();
  expect((await call('/me/phone', { method: 'POST', token, body: { phone } })).status).toBe(429);
});

const derive = (label: string, output: Buffer) => createHash('sha256').update(label).update(output).digest();
const entrySchema = z.object({ entries: z.array(z.object({ tag: z.string(), box: z.string() })) });

// What the app does with the directory: find the tag of a key, open its box
function open(directory: z.infer<typeof entrySchema>, key: string) {
  const output = Buffer.from(key, 'hex');
  const entry = directory.entries.find(candidate => candidate.tag === derive('Songgate discover tag', output).subarray(0, 16).toString('hex'));
  if (!entry) return null;
  const sealed = Buffer.from(entry.box, 'base64');
  const decipher = createDecipheriv('aes-256-gcm', derive('Songgate discover box', output), sealed.subarray(0, 12));
  decipher.setAuthTag(sealed.subarray(-16));
  return JSON.parse(Buffer.concat([decipher.update(sealed.subarray(12, -16)), decipher.final()]).toString());
}

test('discovery finds confirmed contacts by their numbers and nobody else', async () => {
  const lea = await logIn('Lea', 'appleMusic');
  const me = await logIn('Robin', 'spotify');
  const { phone: leaPhone } = await confirm(lea.token);
  const { phone: myPhone } = await confirm(me.token);
  const strangerPhone = randomPhone();

  const keys = await keysFor(me.token, [leaPhone, strangerPhone, myPhone]);
  if (typeof keys === 'number') throw new Error(`evaluate failed with ${keys}`);
  const directory = entrySchema.parse(await (await call('/discover/directory', { token: me.token })).json());
  expect(open(directory, keys[0]!)).toEqual({ id: lea.id, name: 'Lea', platform: 'appleMusic' });
  expect(open(directory, keys[1]!)).toBeNull();
  // The own entry is left out
  expect(open(directory, keys[2]!)).toBeNull();
  // The directory itself names nobody
  expect(JSON.stringify(directory)).not.toContain(lea.id);
  expect(JSON.stringify(directory)).not.toContain('Lea');
});

test('regression: a code only confirms the number it was sent to', async () => {
  const { token } = await logIn();
  const first = randomPhone();
  const second = randomPhone();
  await call('/me/phone', { method: 'POST', token, body: { phone: first } });
  await call('/me/phone', { method: 'POST', token, body: { phone: second } });
  const firstCode = lastCode(`[sms] To ${first}:`);
  expect((await call('/me/phone/verify', { method: 'POST', token, body: { phone: second, code: firstCode } })).status).toBe(400);
});

test('regression: switching discovery off leaves no code that switches it back on', async () => {
  const { token, id } = await logIn();
  const phone = randomPhone();
  await call('/me/phone', { method: 'POST', token, body: { phone } });
  const code = lastCode(`[sms] To ${phone}:`);
  await call('/me/phone', { method: 'DELETE', token, body: {} });
  expect(await db.select().from(phoneCodes).where(eq(phoneCodes.userId, id))).toEqual([]);
  expect((await call('/me/phone/verify', { method: 'POST', token, body: { phone, code } })).status).toBe(400);
});

test('regression: moving a number to another account keeps its daily quota', async () => {
  const first = await logIn();
  const { phone } = await confirm(first.token);
  const phones = Array.from({ length: 200 }, randomPhone);
  for (let i = 0; i < 5; i++) expect(Array.isArray(await keysFor(first.token, phones))).toBe(true);
  const second = await logIn();
  await confirm(second.token, phone);
  expect(await keysFor(second.token, [randomPhone()])).toBe(429);
}, 60_000);

test('discovery needs an own confirmed number', async () => {
  const { token } = await logIn();
  expect(await keysFor(token, [randomPhone()])).toBe(403);
  expect((await call('/discover/directory', { token })).status).toBe(403);
  expect((await call('/discover/directory')).status).toBe(401);
});

test('an account checks at most 1000 numbers a day', async () => {
  const { token } = await logIn();
  await confirm(token);
  const phones = Array.from({ length: 200 }, randomPhone);
  for (let i = 0; i < 5; i++) expect(Array.isArray(await keysFor(token, phones))).toBe(true);
  expect(await keysFor(token, [randomPhone()])).toBe(429);
}, 60_000);

test('a request holds at most 200 numbers', async () => {
  const { token } = await logIn();
  await confirm(token);
  expect(await keysFor(token, Array.from({ length: 201 }, randomPhone))).toBe(400);
});

test('regression: an invalid point is refused, not a server error', async () => {
  const { token } = await logIn();
  await confirm(token);
  const bogus = Buffer.alloc(33, 7).toString('base64');
  expect((await call('/discover/evaluate', { method: 'POST', token, body: { blinded: [bogus] } })).status).toBe(400);
});

test('the newest confirmation of a number wins and removing it ends discoverability', async () => {
  const first = await logIn();
  const second = await logIn();
  const { phone } = await confirm(first.token);
  await confirm(second.token, phone);
  expect(await json(await call('/me', { token: first.token }))).toMatchObject({ user: { discoverable: false } });
  expect(await json(await call('/me/phone', { method: 'DELETE', token: second.token, body: {} }))).toMatchObject({ user: { discoverable: false } });
  const [row] = await db.select().from(users).where(eq(users.id, second.id));
  expect(row!.phoneKey).toBeNull();
});

test('regression: concurrent confirmations of the same number leave one discoverable account', async () => {
  const first = await logIn();
  const second = await logIn();
  const phone = randomPhone();
  async function requestCode(token: string) {
    expect((await call('/me/phone', { method: 'POST', token, body: { phone } })).status).toBe(200);
    return lastCode(`[sms] To ${phone}:`);
  }
  const firstCode = await requestCode(first.token);
  const secondCode = await requestCode(second.token);
  const responses = await Promise.all([
    call('/me/phone/verify', { method: 'POST', token: first.token, body: { phone, code: firstCode } }),
    call('/me/phone/verify', { method: 'POST', token: second.token, body: { phone, code: secondCode } }),
  ]);
  expect(responses.map(response => response.status)).toEqual([200, 200]);
  const profiles = await Promise.all([
    call('/me', { token: first.token }),
    call('/me', { token: second.token }),
  ]);
  const profile = z.object({ user: z.object({ discoverable: z.boolean() }) });
  const states = await Promise.all(profiles.map(async response => profile.parse(await json(response)).user.discoverable));
  expect(states.filter(Boolean)).toHaveLength(1);
});
