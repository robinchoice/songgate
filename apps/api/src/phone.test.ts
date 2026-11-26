import { afterAll, afterEach, beforeAll, expect, spyOn, test } from 'bun:test';
import { createDb, migrateDb, phoneCodes, users } from '@app/db';
import { Evaluation, EvaluationRequest, Oprf, OPRFClient, OPRFServer } from '@cloudflare/voprf-ts';
import { solveChallenge } from 'altcha-lib';
import { deriveKey } from 'altcha-lib/algorithms/pbkdf2';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { CryptoNoble } from '@cloudflare/voprf-ts/crypto-noble';
import { createApp } from './app';
import { challengeSchema } from './lib/altcha';

const OPRF_KEY = 'a'.repeat(63) + '1';
process.env.OPRF_KEY = OPRF_KEY;

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
  const response = await call('/me/phone/verify', { method: 'POST', token, body: { code: lastCode(`[sms] To ${phone}:`) } });
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
  for (let i = 0; i < 5; i++) expect((await call('/me/phone/verify', { method: 'POST', token, body: { code: wrong } })).status).toBe(400);
  expect((await call('/me/phone/verify', { method: 'POST', token, body: { code } })).status).toBe(400);
});

test('numbers must be in E.164', async () => {
  const { token } = await logIn();
  expect((await call('/me/phone', { method: 'POST', token, body: { phone: '0151 2345678' } })).status).toBe(400);
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

test('discovery finds confirmed contacts by their numbers and nobody else', async () => {
  const lea = await logIn('Lea', 'appleMusic');
  const ben = await logIn('Ben', 'deezer');
  const me = await logIn('Robin', 'spotify');
  const { phone: leaPhone } = await confirm(lea.token);
  await confirm(me.token);
  const benPhone = randomPhone();

  const keys = await keysFor(me.token, [leaPhone, benPhone]);
  if (typeof keys === 'number') throw new Error(`evaluate failed with ${keys}`);
  const all = z.object({ keys: z.array(z.string()) }).parse(await (await call('/discover/keys', { token: me.token })).json()).keys;
  expect(all).toContain(keys[0]!);
  expect(all).not.toContain(keys[1]!);

  const profiles = await json(await call('/discover/profiles', { method: 'POST', token: me.token, body: { keys } }));
  expect(profiles).toEqual({ profiles: [{ key: keys[0], id: lea.id, name: 'Lea', platform: 'appleMusic' }] });
  expect(JSON.stringify(profiles)).not.toContain('@');
  expect(ben.id).not.toBe(lea.id);
});

test('discovery needs an own confirmed number', async () => {
  const { token } = await logIn();
  expect(await keysFor(token, [randomPhone()])).toBe(403);
  expect((await call('/discover/keys', { token })).status).toBe(403);
  expect((await call('/discover/keys')).status).toBe(401);
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

test('the blinded request format matches the library', async () => {
  const client = new OPRFClient(suite);
  const [, request] = await client.blind([new TextEncoder().encode('+491511')]);
  expect(EvaluationRequest.deserialize(suite, request.serialize(), CryptoNoble).blinded[0]!.serialize(true).length).toBe(33);
});
