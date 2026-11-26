import { createCipheriv, createHash, randomBytes } from 'node:crypto';
import { type Database, phoneCodes, users } from '@app/db';
import { discoverEvaluateSchema, phoneSchema, phoneVerifySchema } from '@app/shared';
import { and, eq, gt, isNotNull, lt, ne, sql } from 'drizzle-orm';
import { type Context, Hono } from 'hono';
import { currentUser, hashToken, toUser, userColumns } from '../lib/auth';
import { t } from '../lib/i18n';
import { blindEvaluate, oprfReady, phoneKey } from '../lib/oprf';
import { clientIp, rateLimit } from '../lib/rate-limit';
import { sendSms, smsReady } from '../lib/sms';
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
// Against trying out numbers: a confirmed number checks this many a day, on
// whichever account it is confirmed
const numbersPerDay = rateLimit('discover-numbers', 1000, DAY);

const derive = (label: string, key: Buffer) => createHash('sha256').update(label).update(key).digest();

// One entry per discoverable account. Only who knows the number, and so holds
// its OPRF output, finds the entry by its tag and can open the box with id,
// name and service: the list reveals nobody to the app and the app's matches
// to nobody. The app does the same in lib/features/account/discover.dart.
function directoryEntry(phoneKeyHex: string, profile: { id: string; name: string; platform: string }) {
  const output = Buffer.from(phoneKeyHex, 'hex');
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', derive('Songgate discover box', output), nonce);
  const sealed = Buffer.concat([nonce, cipher.update(JSON.stringify(profile)), cipher.final(), cipher.getAuthTag()]);
  return { tag: derive('Songgate discover tag', output).subarray(0, 16).toString('hex'), box: sealed.toString('base64') };
}

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
    return { phoneKey: user.phoneKey };
  };

  return new Hono()
    .post('/me/phone', async c => {
      const user = await currentUser(db, c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      if (!oprfReady() || !smsReady()) return unavailable(c);
      const input = await body(c, phoneSchema);
      if (!input) return c.json({ error: t(c).phoneInvalid }, 400);
      if (!(await smsPerIp.hit(db, clientIp(c))) || !(await smsPerUser.hit(db, user.id))) return tooMany(c);
      const key = await phoneKey(input.phone);
      if (!(await smsPerNumber.hit(db, key))) return tooMany(c);
      // Expired codes go, so their keys don't outlive the confirmation
      await db.delete(phoneCodes).where(lt(phoneCodes.expiresAt, new Date()));
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

    // The code counts only for the number it was sent to. The newest
    // confirmation wins: a number confirmed by another account before moves
    // to this one, since only one phone receives its SMS now.
    .post('/me/phone/verify', async c => {
      const user = await currentUser(db, c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      if (!(await phoneChecksPerUser.hit(db, user.id))) return tooMany(c);
      const input = await body(c, phoneVerifySchema);
      if (!input || !oprfReady()) return c.json({ error: t(c).codeWrong }, 400);
      const key = await phoneKey(input.phone);
      const updated = await db.transaction(async tx => {
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${key}, 0))`);
        const [account] = await tx.select({ id: users.id }).from(users).where(eq(users.id, user.id)).for('no key update');
        if (!account) return null;
        const open = await tx
          .update(phoneCodes)
          .set({ attempts: sql`${phoneCodes.attempts} + 1` })
          .where(and(eq(phoneCodes.userId, user.id), eq(phoneCodes.phoneKey, key), gt(phoneCodes.expiresAt, new Date()), lt(phoneCodes.attempts, CODE_ATTEMPTS)))
          .returning({ codeHash: phoneCodes.codeHash });
        const codeHash = hashToken(input.code);
        if (!open.some(row => row.codeHash === codeHash)) return null;
        await tx.delete(phoneCodes).where(eq(phoneCodes.userId, user.id));
        await tx.update(users).set({ phoneKey: null }).where(and(eq(users.phoneKey, key), ne(users.id, user.id)));
        const [row] = await tx.update(users).set({ phoneKey: key, updatedAt: new Date() }).where(eq(users.id, user.id)).returning(userColumns);
        return row!;
      });
      if (!updated) return c.json({ error: t(c).codeWrong }, 400);
      return c.json({ user: toUser(updated) });
    })

    // Open codes go too, so none of them switches discovery back on
    .delete('/me/phone', async c => {
      const user = await currentUser(db, c);
      if (!user) return c.json({ error: t(c).loginRequired }, 401);
      const updated = await db.transaction(async tx => {
        const [row] = await tx.update(users).set({ phoneKey: null, updatedAt: new Date() }).where(eq(users.id, user.id)).returning(userColumns);
        await tx.delete(phoneCodes).where(eq(phoneCodes.userId, user.id));
        return row;
      });
      if (!updated) return c.json({ error: t(c).loginRequired }, 401);
      return c.json({ user: toUser(updated) });
    })

    // The app blinds the numbers of its address book, the API only applies its key
    .post('/discover/evaluate', async c => {
      const { phoneKey: own, error } = await discoverer(c);
      if (error) return error;
      const input = await body(c, discoverEvaluateSchema);
      if (!input) return c.json({ error: t(c).feedbackIncomplete }, 400);
      if (!(await numbersPerDay.hit(db, own, input.blinded.length))) return c.json({ error: t(c).discoverLimit }, 429);
      try {
        const evaluated = await blindEvaluate(input.blinded.map(element => Buffer.from(element, 'base64')));
        return c.json({ evaluated: evaluated.map(element => Buffer.from(element).toString('base64')) });
      } catch {
        return c.json({ error: t(c).feedbackIncomplete }, 400);
      }
    })

    // All of it, so the app compares on the phone and the API learns neither
    // numbers of people without Songgate nor who is in whose address book
    .get('/discover/directory', async c => {
      const { phoneKey: own, error } = await discoverer(c);
      if (error) return error;
      const rows = await db
        .select({ phoneKey: users.phoneKey, id: users.id, name: users.name, platform: users.platform })
        .from(users)
        .where(and(isNotNull(users.phoneKey), isNotNull(users.name), isNotNull(users.platform), ne(users.phoneKey, own)));
      c.header('Cache-Control', 'no-store');
      return c.json({
        entries: rows.map(({ phoneKey: key, id, name, platform }) => directoryEntry(key!, { id, name: name!, platform: platform! })),
      });
    });
}
