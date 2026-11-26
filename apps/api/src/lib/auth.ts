import { type Database, sessions, users } from '@app/db';
import { and, eq, gt } from 'drizzle-orm';
import type { Context } from 'hono';

const DAY = 24 * 60 * 60 * 1000;
// Sessions in use slide on, only a year without opening the app logs out
const SESSION_DAYS = 365;

export const generateToken = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('hex');

// Only hashes are stored, so a leaked database holds no usable tokens or codes
export const hashToken = (token: string) => new Bun.CryptoHasher('sha256').update(token).digest('hex');

export const sessionExpiry = () => new Date(Date.now() + SESSION_DAYS * DAY);

export const userColumns = { id: users.id, email: users.email, name: users.name, platform: users.platform };

function bearerToken(c: Context) {
  const header = c.req.header('authorization');
  return header?.startsWith('Bearer ') ? header.slice('Bearer '.length).trim() || undefined : undefined;
}

export async function currentUser(db: Database, c: Context) {
  const token = bearerToken(c);
  if (!token) return null;
  const [row] = await db
    .select({ ...userColumns, sessionId: sessions.id, expiresAt: sessions.expiresAt })
    .from(sessions)
    .innerJoin(users, eq(users.id, sessions.userId))
    .where(and(eq(sessions.tokenHash, hashToken(token)), gt(sessions.expiresAt, new Date())))
    .limit(1);
  if (!row) return null;
  // At most once a day the session runs SESSION_DAYS from now again
  if (row.expiresAt.getTime() - Date.now() < (SESSION_DAYS - 1) * DAY) {
    await db.update(sessions).set({ expiresAt: sessionExpiry() }).where(eq(sessions.id, row.sessionId));
  }
  return { id: row.id, email: row.email, name: row.name, platform: row.platform, sessionId: row.sessionId };
}

const envList = (name: string) => (process.env[name] ?? '').split(',').map(entry => entry.trim().toLowerCase()).filter(Boolean);

// Sign-up stays closed until Robin opens it (SIGNUP_OPEN=true): existing accounts
// log in, new ones only for the addresses in SIGNUP_ALLOWLIST.
export async function mayLogIn(db: Database, email: string) {
  if (process.env.SIGNUP_OPEN === 'true' || envList('SIGNUP_ALLOWLIST').includes(email)) return true;
  const [user] = await db.select({ id: users.id }).from(users).where(eq(users.email, email));
  return !!user;
}
