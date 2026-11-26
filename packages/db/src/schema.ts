import type { FeedbackContext, Social } from '@app/shared';
import { sql } from 'drizzle-orm';
import { check, customType, index, integer, jsonb, pgTable, text, timestamp, uuid, varchar } from 'drizzle-orm/pg-core';

const bytea = customType<{ data: Buffer }>({ dataType: () => 'bytea' });

// Bug reports and ideas from the feedback button, also mailed. Feedback needs
// no account: the email is optional and the only way to reach the tester.
export const feedback = pgTable(
  'feedback',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    kind: varchar('kind', { length: 10 }).notNull(),
    message: text('message').notNull(),
    email: varchar('email', { length: 255 }),
    screenshot: bytea('screenshot'),
    context: jsonb('context').$type<FeedbackContext & { api: string }>().notNull(),
    createdAt: timestamp('created_at').defaultNow().notNull(),
  },
  (table) => [check('feedback_kind', sql`${table.kind} in ('bug', 'idea')`)],
);

// Counters of lib/rate-limit.ts in the API
export const rateLimits = pgTable(
  'rate_limits',
  {
    key: varchar('key', { length: 300 }).primaryKey(),
    count: integer('count').notNull(),
    resetAt: timestamp('reset_at').notNull(),
  },
  (table) => [check('rate_limits_count', sql`${table.count} >= 1`)],
);

// Accounts exist in the app only. Name and platform are the public profile,
// set after the first login; the email never leaves the API.
export const users = pgTable(
  'users',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    // Stored lowercase, see emailSchema in @app/shared
    email: varchar('email', { length: 255 }).notNull().unique(),
    name: varchar('name', { length: 40 }),
    platform: varchar('platform', { length: 20 }),
    createdAt: timestamp('created_at').defaultNow().notNull(),
    updatedAt: timestamp('updated_at').defaultNow().notNull(),
  },
  (table) => [check('users_platform', sql`${table.platform} in ('appleMusic', 'youtubeMusic', 'spotify', 'deezer', 'tidal', 'amazonMusic')`)],
);

// A 6-digit code by mail is the only way to log in
export const loginCodes = pgTable(
  'login_codes',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    email: varchar('email', { length: 255 }).notNull(),
    codeHash: varchar('code_hash', { length: 64 }).notNull(),
    attempts: integer('attempts').default(0).notNull(),
    expiresAt: timestamp('expires_at').notNull(),
    usedAt: timestamp('used_at'),
    createdAt: timestamp('created_at').defaultNow().notNull(),
  },
  (table) => [index('login_codes_email').on(table.email), check('login_codes_attempts', sql`${table.attempts} >= 0`)],
);

// Only token hashes are stored, so a leaked database holds no usable sessions
export const sessions = pgTable('sessions', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id')
    .references(() => users.id, { onDelete: 'cascade' })
    .notNull(),
  tokenHash: varchar('token_hash', { length: 64 }).notNull().unique(),
  expiresAt: timestamp('expires_at').notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});

// The saved friends and groups of an account as one document. Every save
// raises the revision; a client that saw an older one gets a conflict.
export const socials = pgTable(
  'socials',
  {
    userId: uuid('user_id')
      .primaryKey()
      .references(() => users.id, { onDelete: 'cascade' }),
    data: jsonb('data').$type<Social>().notNull(),
    revision: integer('revision').notNull(),
    updatedAt: timestamp('updated_at').defaultNow().notNull(),
  },
  (table) => [check('socials_revision', sql`${table.revision} >= 1`)],
);

// Keys the API generates on first use, so every instance shares them.
// `altcha` signs the challenges of lib/altcha.ts.
export const serverSecrets = pgTable('server_secrets', {
  name: varchar('name', { length: 50 }).primaryKey(),
  value: varchar('value', { length: 128 }).notNull(),
});
