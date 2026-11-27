import { type Database, loginCodes, sessions, socials, users } from '@app/db';
import { loginCodeSchema, profileUpdateSchema, socialUpdateSchema, verifyCodeSchema } from '@app/shared';
import { and, eq, gt, isNull, lt, sql } from 'drizzle-orm';
import { type Context, Hono } from 'hono';
import type { z } from 'zod';
import { altchaChallenge, altchaSolved } from '../lib/altcha';
import { currentUser, generateToken, hashToken, mayLogIn, sessionExpiry, toUser, userColumns } from '../lib/auth';
import { t } from '../lib/i18n';
import { sendMail } from '../lib/mail';
import { clientIp, rateLimit } from '../lib/rate-limit';

const MINUTE = 60 * 1000;
const CODE_ATTEMPTS = 5;
const mailsPerAddress = rateLimit('mails-per-address', 5, 60 * MINUTE);
const mailsPerIp = rateLimit('mails-per-ip', 20, 60 * MINUTE);
const codeChecksPerIp = rateLimit('code-checks-per-ip', 30, 15 * MINUTE);
// The app asks every linked contact at most every 5 minutes, up to 500 of them
const profilesPerIp = rateLimit('profiles-per-ip', 1500, 15 * MINUTE);

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function body<T extends z.ZodType>(c: Context, schema: T): Promise<z.infer<T> | null> {
  const parsed = schema.safeParse(await c.req.json().catch(() => null));
  return parsed.success ? parsed.data : null;
}

export const tooMany = (c: Context) => c.json({ error: t(c).tooManyAttempts }, 429);

// App only, with the session token as bearer. The email stays inside the API:
// others see an account's name and service, and only by its random id.
export function accountRoutes(db: Database) {
  const authed = async (c: Context) => currentUser(db, c);

  return new Hono()
    .get('/altcha', async c => {
      c.header('Cache-Control', 'no-store');
      return c.json(await altchaChallenge(db));
    })

    // Checked before the rate limits, so bots can't use up the limits of an address
    .post('/auth/code', async c => {
      const input = await body(c, loginCodeSchema);
      if (!input) return c.json({ error: t(c).invalidEmail }, 400);
      if (!(await altchaSolved(db, input.altcha))) return c.json({ error: t(c).altchaFailed }, 403);
      if (!(await mailsPerIp.hit(db, clientIp(c))) || !(await mailsPerAddress.hit(db, input.email))) return tooMany(c);
      if (!(await mayLogIn(db, input.email))) return c.json({ error: t(c).signupClosed }, 403);
      // Expired codes go, so the table doesn't keep every code ever sent
      await db.delete(loginCodes).where(lt(loginCodes.expiresAt, new Date()));
      const code = String(crypto.getRandomValues(new Uint32Array(1))[0]! % 1_000_000).padStart(6, '0');
      await db.insert(loginCodes).values({ email: input.email, codeHash: hashToken(code), expiresAt: new Date(Date.now() + 15 * MINUTE) });
      await sendMail({ to: input.email, subject: t(c).loginCodeSubject(code), text: t(c).loginCodeText(code) });
      return c.json({ ok: true });
    })

    .post('/auth/code/verify', async c => {
      if (!(await codeChecksPerIp.hit(db, clientIp(c)))) return tooMany(c);
      const input = await body(c, verifyCodeSchema);
      if (!input) return c.json({ error: t(c).codeWrong }, 400);
      // Every guess counts against all open codes of the address before the
      // comparison, so parallel requests get no more than CODE_ATTEMPTS tries
      const open = await db
        .update(loginCodes)
        .set({ attempts: sql`${loginCodes.attempts} + 1` })
        .where(and(eq(loginCodes.email, input.email), isNull(loginCodes.usedAt), gt(loginCodes.expiresAt, new Date()), lt(loginCodes.attempts, CODE_ATTEMPTS)))
        .returning({ id: loginCodes.id, codeHash: loginCodes.codeHash });
      const match = open.find(row => row.codeHash === hashToken(input.code));
      if (!match) return c.json({ error: t(c).codeWrong }, 400);
      const [used] = await db
        .update(loginCodes)
        .set({ usedAt: new Date() })
        .where(and(eq(loginCodes.id, match.id), isNull(loginCodes.usedAt)))
        .returning({ id: loginCodes.id });
      if (!used) return c.json({ error: t(c).codeWrong }, 400);
      // Access may have been withdrawn since the code was sent
      if (!(await mayLogIn(db, input.email))) return c.json({ error: t(c).signupClosed }, 403);
      await db.insert(users).values({ email: input.email }).onConflictDoNothing();
      const [user] = await db.select(userColumns).from(users).where(eq(users.email, input.email));
      const token = generateToken();
      await db.insert(sessions).values({ userId: user!.id, tokenHash: hashToken(token), expiresAt: sessionExpiry() });
      return c.json({ token, user: toUser(user!) });
    })

    .post('/auth/logout', async c => {
      const user = await authed(c);
      if (user) await db.delete(sessions).where(eq(sessions.id, user.sessionId));
      return c.json({ ok: true });
    })

    .get('/me', async c => {
      const user = await authed(c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      return c.json({ user: toUser(user) });
    })

    .patch('/me', async c => {
      const user = await authed(c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      const input = await body(c, profileUpdateSchema);
      if (!input) return c.json({ error: t(c).feedbackIncomplete }, 400);
      const [updated] = await db
        .update(users)
        .set({ ...input, updatedAt: new Date() })
        .where(eq(users.id, user.id))
        .returning(userColumns);
      return c.json({ user: toUser(updated!) });
    })

    // Sessions and the saved contacts go with it (on delete cascade)
    .delete('/me', async c => {
      const user = await authed(c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      await db.delete(users).where(eq(users.id, user.id));
      return c.json({ ok: true });
    })

    .get('/me/social', async c => {
      const user = await authed(c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      const [saved] = await db.select().from(socials).where(eq(socials.userId, user.id));
      c.header('Cache-Control', 'no-store');
      return c.json(saved ? { social: saved.data, revision: saved.revision } : { social: { friends: [], groups: [] }, revision: 0 });
    })

    // Saves only on top of the revision the app last saw. Otherwise another
    // device was faster: the answer carries its version, and the app takes it.
    .put('/me/social', async c => {
      const user = await authed(c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      const input = await body(c, socialUpdateSchema);
      if (!input) return c.json({ error: t(c).feedbackIncomplete }, 400);
      const revision = input.revision + 1;
      const saved =
        input.revision === 0
          ? await db.insert(socials).values({ userId: user.id, data: input.social, revision }).onConflictDoNothing().returning({ revision: socials.revision })
          : await db
              .update(socials)
              .set({ data: input.social, revision, updatedAt: new Date() })
              .where(and(eq(socials.userId, user.id), eq(socials.revision, input.revision)))
              .returning({ revision: socials.revision });
      if (saved.length) return c.json({ revision });
      const [current] = await db.select().from(socials).where(eq(socials.userId, user.id));
      return c.json({ error: t(c).socialConflict, social: current?.data ?? { friends: [], groups: [] }, revision: current?.revision ?? 0 }, 409);
    })

    // What an invite already shows: name and service. Asked by apps that saved
    // the account from its invite, with or without an account of their own.
    .get('/profiles/:id', async c => {
      if (!(await profilesPerIp.hit(db, clientIp(c)))) return tooMany(c);
      const id = c.req.param('id');
      if (!uuid.test(id)) return c.json({ error: t(c).notFound }, 404);
      const [profile] = await db.select({ id: users.id, name: users.name, platform: users.platform }).from(users).where(eq(users.id, id));
      if (!profile?.name || !profile.platform) return c.json({ error: t(c).notFound }, 404);
      return c.json(profile);
    });
}
