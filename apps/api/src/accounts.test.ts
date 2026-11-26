import { afterAll, afterEach, beforeAll, expect, spyOn, test } from 'bun:test';
import { createDb, migrateDb, sessions, socials, users } from '@app/db';
import { solveChallenge } from 'altcha-lib';
import { deriveKey } from 'altcha-lib/algorithms/pbkdf2';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { createApp } from './app';
import { challengeSchema } from './lib/altcha';

const db = createDb(process.env.DATABASE_URL);
const app = createApp({ db, resolve: async () => { throw new Error('unused'); } });
const log = spyOn(console, 'log');

beforeAll(() => migrateDb(process.env.DATABASE_URL), 20_000);
afterAll(() => db.$client.end());
afterEach(() => { delete process.env.SIGNUP_ALLOWLIST; delete process.env.SIGNUP_OPEN; });

const json = async (response: Response) => z.looseObject({}).parse(await response.json());
const loginSchema = z.object({
  token: z.string(),
  user: z.object({ id: z.string(), email: z.string(), name: z.string().nullable(), platform: z.string().nullable() }),
});

function call(path: string, { method = 'GET', body, token, ip = crypto.randomUUID() }: { method?: string; body?: unknown; token?: string; ip?: string } = {}) {
  return app.request(`/api/v1${path}`, {
    method,
    headers: { 'content-type': 'application/json', 'x-forwarded-for': ip, ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

async function altcha() {
  const challenge = challengeSchema.parse(await (await call('/altcha')).json());
  const solution = await solveChallenge({ challenge, deriveKey });
  return btoa(JSON.stringify({ challenge, solution }));
}

const mailedCode = (email: string) => {
  const line = log.mock.calls.map(args => String(args[0])).findLast(entry => entry.startsWith(`[mail] To ${email}:`));
  return line?.match(/\b(\d{6})\b/)?.[1];
};

const newEmail = () => `test-${crypto.randomUUID()}@example.com`;

async function logIn(email = newEmail()) {
  process.env.SIGNUP_ALLOWLIST = email;
  expect((await call('/auth/code', { method: 'POST', body: { email, altcha: await altcha() } })).status).toBe(200);
  const response = await call('/auth/code/verify', { method: 'POST', body: { email, code: mailedCode(email.toLowerCase()) } });
  expect(response.status).toBe(200);
  return loginSchema.parse(await response.json());
}

test('a code by mail logs in and creates the account without a profile', async () => {
  const email = newEmail();
  const { token, user } = await logIn(email.toUpperCase());
  expect(user).toMatchObject({ email, name: null, platform: null });
  const me = await json(await call('/me', { token }));
  expect(me.user).toMatchObject({ id: user.id, email });
});

test('sign-up is closed for addresses outside the allowlist and no mail goes out', async () => {
  const email = newEmail();
  const response = await call('/auth/code', { method: 'POST', body: { email, altcha: await altcha() } });
  expect(response.status).toBe(403);
  expect(mailedCode(email)).toBeUndefined();
});

test('an existing account logs in after it left the allowlist', async () => {
  const email = newEmail();
  await logIn(email);
  delete process.env.SIGNUP_ALLOWLIST;
  expect((await call('/auth/code', { method: 'POST', body: { email, altcha: await altcha() } })).status).toBe(200);
});

test('a login code needs a solved ALTCHA, and each solution counts once', async () => {
  const email = newEmail();
  process.env.SIGNUP_ALLOWLIST = email;
  expect((await call('/auth/code', { method: 'POST', body: { email, altcha: 'nonsense' } })).status).toBe(403);
  const solved = await altcha();
  expect((await call('/auth/code', { method: 'POST', body: { email, altcha: solved } })).status).toBe(200);
  expect((await call('/auth/code', { method: 'POST', body: { email, altcha: solved } })).status).toBe(403);
});

test('a wrong code fails and five wrong guesses use the code up', async () => {
  const email = newEmail();
  process.env.SIGNUP_ALLOWLIST = email;
  await call('/auth/code', { method: 'POST', body: { email, altcha: await altcha() } });
  const code = mailedCode(email)!;
  const wrong = code === '000000' ? '000001' : '000000';
  for (let i = 0; i < 5; i++) expect((await call('/auth/code/verify', { method: 'POST', body: { email, code: wrong } })).status).toBe(400);
  expect((await call('/auth/code/verify', { method: 'POST', body: { email, code } })).status).toBe(400);
});

test('a code works once', async () => {
  const email = newEmail();
  process.env.SIGNUP_ALLOWLIST = email;
  await call('/auth/code', { method: 'POST', body: { email, altcha: await altcha() } });
  const code = mailedCode(email);
  expect((await call('/auth/code/verify', { method: 'POST', body: { email, code } })).status).toBe(200);
  expect((await call('/auth/code/verify', { method: 'POST', body: { email, code } })).status).toBe(400);
});

test('the profile is public by id with name and service only', async () => {
  const { token, user } = await logIn();
  expect((await call(`/profiles/${user.id}`)).status).toBe(404);
  const patched = await json(await call('/me', { method: 'PATCH', token, body: { name: 'Lea', platform: 'spotify' } }));
  expect(patched.user).toMatchObject({ name: 'Lea', platform: 'spotify' });
  expect(await json(await call(`/profiles/${user.id}`))).toEqual({ id: user.id, name: 'Lea', platform: 'spotify' });
  expect((await call('/me', { method: 'PATCH', token, body: { platform: 'napster' } })).status).toBe(400);
  expect((await call('/profiles/not-a-uuid')).status).toBe(404);
});

test('the account needs a valid session', async () => {
  expect((await call('/me')).status).toBe(401);
  expect((await call('/me', { token: 'nope' })).status).toBe(401);
  expect((await call('/me/social', { method: 'PUT', body: { social: { friends: [], groups: [] }, revision: 0 } })).status).toBe(401);
});

test('logout ends only that session', async () => {
  const email = newEmail();
  const first = await logIn(email);
  const second = await logIn(email);
  expect((await call('/auth/logout', { method: 'POST', token: first.token, body: {} })).status).toBe(200);
  expect((await call('/me', { token: first.token })).status).toBe(401);
  expect((await call('/me', { token: second.token })).status).toBe(200);
});

test('contacts save on top of the revision the app saw, a stale one gets the newer version', async () => {
  const { token } = await logIn();
  expect(await json(await call('/me/social', { token }))).toEqual({ social: { friends: [], groups: [] }, revision: 0 });
  const first = { friends: [{ name: 'Lea', platform: 'spotify' }], groups: [] };
  expect(await json(await call('/me/social', { method: 'PUT', token, body: { social: first, revision: 0 } }))).toEqual({ revision: 1 });
  const second = { friends: [{ name: 'Ben', platform: 'deezer', id: crypto.randomUUID() }], groups: [{ name: 'WG', members: ['Ben'] }] };
  expect(await json(await call('/me/social', { method: 'PUT', token, body: { social: second, revision: 1 } }))).toEqual({ revision: 2 });

  const stale = await call('/me/social', { method: 'PUT', token, body: { social: first, revision: 1 } });
  expect(stale.status).toBe(409);
  expect(await json(stale)).toMatchObject({ social: second, revision: 2 });
  const fresh = await call('/me/social', { method: 'PUT', token, body: { social: first, revision: 0 } });
  expect(fresh.status).toBe(409);
  expect(await json(await call('/me/social', { token }))).toEqual({ social: second, revision: 2 });
});

test('invalid contacts are refused', async () => {
  const { token } = await logIn();
  const bad = { friends: [{ name: '', platform: 'spotify' }], groups: [] };
  expect((await call('/me/social', { method: 'PUT', token, body: { social: bad, revision: 0 } })).status).toBe(400);
});

test('deleting the account removes profile, sessions and contacts at once', async () => {
  const { token, user } = await logIn();
  await call('/me', { method: 'PATCH', token, body: { name: 'Mira', platform: 'deezer' } });
  await call('/me/social', { method: 'PUT', token, body: { social: { friends: [{ name: 'Lea', platform: 'spotify' }], groups: [] }, revision: 0 } });
  expect((await call('/me', { method: 'DELETE', token, body: {} })).status).toBe(200);
  expect(await db.select().from(users).where(eq(users.id, user.id))).toEqual([]);
  expect(await db.select().from(sessions).where(eq(sessions.userId, user.id))).toEqual([]);
  expect(await db.select().from(socials).where(eq(socials.userId, user.id))).toEqual([]);
  expect((await call(`/profiles/${user.id}`)).status).toBe(404);
  expect((await call('/me', { token })).status).toBe(401);
});

test('the email never shows in a profile', async () => {
  const { token, user } = await logIn();
  await call('/me', { method: 'PATCH', token, body: { name: 'Ben', platform: 'tidal' } });
  expect(JSON.stringify(await json(await call(`/profiles/${user.id}`)))).not.toContain('@');
});
