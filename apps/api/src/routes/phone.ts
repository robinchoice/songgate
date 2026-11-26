import { type Database, phoneCodes, users } from '@app/db';
import { discoverEvaluateSchema, discoverProfilesSchema, phoneSchema, phoneVerifySchema } from '@app/shared';
import { and, eq, gt, inArray, isNotNull, isNull, lt, ne, sql } from 'drizzle-orm';
import { type Context, Hono } from 'hono';
import { currentUser, hashToken, toUser, userColumns } from '../lib/auth';
import { t } from '../lib/i18n';
import { blindEvaluate, oprfReady, phoneKey } from '../lib/oprf';
import { clientIp, rateLimit } from '../lib/rate-limit';
import { sendSms } from '../lib/sms';
import { captureException } from '../monitoring';
import { body, tooMany } from './accounts';

const MINUTE = 60 * 1000;
const DAY = 24 * 60 * MINUTE;
const CODE_ATTEMPTS = 5;
// Each SMS costs money and reaches a person: few per account, per number and per address
const smsPerUser = rateLimit('sms-per-user', 3, 60 * MINUTE);
const smsPerNumber = rateLimit('sms-per-number', 3, 60 * MINUTE);
const smsPerIp = rateLimit('sms-per-ip', 10, 60 * MINUTE);
const phoneChecksPerUser = rateLimit('phone-checks-per-user', 10, 15 * MINUTE);
// Against trying out numbers: an account with a confirmed number checks this many a day
const numbersPerDay = rateLimit('discover-numbers', 1000, DAY);
const profilesPerDay = rateLimit('discover-profiles', 1000, DAY);

// Accounts confirm their own number by SMS and then find people from their
// address book who did the same, see lib/oprf.ts. Numbers are never stored.
export function phoneRoutes(db: Database) {
  const unavailable = (c: Context) => c.json({ error: t(c).discoverUnavailable }, 503);

  // Discovery only for accounts that confirmed a number: every account that
  // can try out numbers costs an SMS to a real phone.
  const discoverer = async (c: Context) => {
    const user = await currentUser(db, c);
    if (!user) return { error: c.json({ error: t(c).loginRequired }, 401) };
    if (!user.phoneKey) return { error: c.json({ error: t(c).phoneRequired }, 403) };
    if (!oprfReady()) return { error: unavailable(c) };
    return { user };
  };

  return new Hono()
    .post('/me/phone', async c => {
      const user = await currentUser(db, c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      if (!oprfReady()) return unavailable(c);
      const input = await body(c, phoneSchema);
      if (!input) return c.json({ error: t(c).phoneInvalid }, 400);
      const key = await phoneKey(input.phone);
      if (!(await smsPerIp.hit(db, clientIp(c))) || !(await smsPerUser.hit(db, user.id)) || !(await smsPerNumber.hit(db, key))) return tooMany(c);
      const code = String(crypto.getRandomValues(new Uint32Array(1))[0]! % 1_000_000).padStart(6, '0');
      await db.insert(phoneCodes).values({ userId: user.id, phoneKey: key, codeHash: hashToken(code), expiresAt: new Date(Date.now() + 15 * MINUTE) });
      try {
        await sendSms(input.phone, t(c).phoneCodeText(code));
      } catch (error) {
        captureException(error);
        return c.json({ error: t(c).smsFailed }, 502);
      }
      return c.json({ ok: true });
    })

    // The newest confirmation wins: a number confirmed by another account
    // before moves to this one, since only one phone receives its SMS now.
    .post('/me/phone/verify', async c => {
      const user = await currentUser(db, c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      if (!(await phoneChecksPerUser.hit(db, user.id))) return tooMany(c);
      const input = await body(c, phoneVerifySchema);
      if (!input) return c.json({ error: t(c).codeWrong }, 400);
      const open = await db
        .update(phoneCodes)
        .set({ attempts: sql`${phoneCodes.attempts} + 1` })
        .where(and(eq(phoneCodes.userId, user.id), isNull(phoneCodes.usedAt), gt(phoneCodes.expiresAt, new Date()), lt(phoneCodes.attempts, CODE_ATTEMPTS)))
        .returning({ id: phoneCodes.id, codeHash: phoneCodes.codeHash, phoneKey: phoneCodes.phoneKey });
      const match = open.find(row => row.codeHash === hashToken(input.code));
      if (!match) return c.json({ error: t(c).codeWrong }, 400);
      const updated = await db.transaction(async tx => {
        const [used] = await tx
          .update(phoneCodes)
          .set({ usedAt: new Date() })
          .where(and(eq(phoneCodes.id, match.id), isNull(phoneCodes.usedAt)))
          .returning({ id: phoneCodes.id });
        if (!used) return null;
        await tx.update(users).set({ phoneKey: null }).where(and(eq(users.phoneKey, match.phoneKey), ne(users.id, user.id)));
        const [row] = await tx.update(users).set({ phoneKey: match.phoneKey, updatedAt: new Date() }).where(eq(users.id, user.id)).returning(userColumns);
        return row!;
      });
      if (!updated) return c.json({ error: t(c).codeWrong }, 400);
      return c.json({ user: toUser(updated) });
    })

    .delete('/me/phone', async c => {
      const user = await currentUser(db, c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      const [updated] = await db.update(users).set({ phoneKey: null, updatedAt: new Date() }).where(eq(users.id, user.id)).returning(userColumns);
      return c.json({ user: toUser(updated!) });
    })

    // The app blinds the numbers of its address book, the API only applies its key
    .post('/discover/evaluate', async c => {
      const { user, error } = await discoverer(c);
      if (error) return error;
      const input = await body(c, discoverEvaluateSchema);
      if (!input) return c.json({ error: t(c).feedbackIncomplete }, 400);
      if (!(await numbersPerDay.hit(db, user.id, input.blinded.length))) return c.json({ error: t(c).discoverLimit }, 429);
      try {
        const evaluated = await blindEvaluate(input.blinded.map(element => Buffer.from(element, 'base64')));
        return c.json({ evaluated: evaluated.map(element => Buffer.from(element).toString('base64')) });
      } catch {
        return c.json({ error: t(c).feedbackIncomplete }, 400);
      }
    })

    // Every discoverable key, so the app compares on the phone and the API
    // learns nothing about numbers of people without Songgate
    .get('/discover/keys', async c => {
      const { error } = await discoverer(c);
      if (error) return error;
      const rows = await db
        .select({ key: users.phoneKey })
        .from(users)
        .where(and(isNotNull(users.phoneKey), isNotNull(users.name), isNotNull(users.platform)));
      c.header('Cache-Control', 'no-store');
      return c.json({ keys: rows.map(row => row.key) });
    })

    .post('/discover/profiles', async c => {
      const { user, error } = await discoverer(c);
      if (error) return error;
      const input = await body(c, discoverProfilesSchema);
      if (!input) return c.json({ error: t(c).feedbackIncomplete }, 400);
      if (!(await profilesPerDay.hit(db, user.id, input.keys.length))) return c.json({ error: t(c).discoverLimit }, 429);
      const rows = await db
        .select({ key: users.phoneKey, id: users.id, name: users.name, platform: users.platform })
        .from(users)
        .where(and(inArray(users.phoneKey, input.keys), isNotNull(users.name), isNotNull(users.platform), ne(users.id, user.id)));
      return c.json({ profiles: rows });
    });
}
