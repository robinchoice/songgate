import { z } from 'zod';
import { inviteSlugs, platformSchema, platforms, type Friend } from '@app/shared';
import { t } from '#lib/i18n.ts';
import { toast, toastError } from '#lib/toast.svelte.ts';

// Friends stay in this browser. Nothing about them reaches our server.
type Saved = { friends: Friend[]; groups: { name: string; members: string[] }[]; me: Friend | null };
const KEY = 'musiclink-friends';
const friendSchema = z.object({ name: z.string(), platform: platformSchema });
const groupSchema = z.object({
  name: z.string(),
  members: z.array(z.unknown()).transform(members => members.filter((member): member is string => typeof member === 'string')),
});
const savedSchema = z.object({
  friends: z.array(z.unknown()).catch([]),
  groups: z.array(z.unknown()).catch([]),
  me: z.unknown(),
});

export const social = $state<Saved>({ friends: [], groups: [], me: null });

export function loadFriends() {
  try {
    const saved = savedSchema.safeParse(JSON.parse(localStorage.getItem(KEY) ?? '{}')).data;
    if (!saved) return;
    social.friends = saved.friends.flatMap(friend => friendSchema.safeParse(friend).data ?? []);
    social.groups = saved.groups.flatMap(group => groupSchema.safeParse(group).data ?? []);
    social.me = friendSchema.safeParse(saved.me).data ?? null;
  } catch {}
}

function save() {
  try { localStorage.setItem(KEY, JSON.stringify(social)); } catch {}
}

export function addFriend(friend: Friend) {
  social.friends = [...social.friends.filter(other => other.name !== friend.name), friend];
  save();
}

export function removeFriend(name: string) {
  social.friends = social.friends.filter(friend => friend.name !== name);
  social.groups = social.groups.map(group => ({ ...group, members: group.members.filter(member => member !== name) })).filter(group => group.members.length);
  save();
}

// Renaming keeps the contact's place and its groups
export function updateFriend(previous: string, friend: Friend) {
  social.friends = social.friends.flatMap(other => other.name === previous ? [friend] : other.name === friend.name ? [] : [other]);
  social.groups = social.groups.map(group => ({ ...group, members: [...new Set(group.members.map(member => member === previous ? friend.name : member))] }));
  save();
}

export function removeGroup(name: string) {
  social.groups = social.groups.filter(group => group.name !== name);
  save();
}

export function addGroup(name: string, members: string[]) {
  social.groups = [...social.groups.filter(group => group.name !== name), { name, members }];
  save();
}

function setMe(me: Friend) {
  social.me = me;
  save();
}

export const inviteUrl = (origin: string, me: Friend) => `${origin}/f/${inviteSlugs[me.platform]}?name=${encodeURIComponent(me.name)}`;

// Saves who one is and sends one's own invite, copied where the browser cannot share; false when not sent
export async function shareInvite(origin: string, me: Friend, copied: string) {
  setMe(me);
  const url = inviteUrl(origin, me);
  const text = t().inviteText(platforms[me.platform]);
  try {
    if (typeof navigator.share === 'function') await navigator.share({ text, url });
    else { await navigator.clipboard.writeText(`${text}\n${url}`); toast(copied); }
    return true;
  } catch (e) {
    if (!(e instanceof DOMException && e.name === 'AbortError')) toastError(t().shareFailed);
    return false;
  }
}

// Who a link names: an invite (/f/<service>?name=…) or the sender of a share page (?from=…&service=…).
// The name is capped like the fields that save one.
export function linkedFriend(name: string | null, slug: string | null | undefined): Friend | null {
  const trimmed = (name ?? '').trim().slice(0, 40);
  const platform = platformSchema.options.find(platform => inviteSlugs[platform] === slug);
  return trimmed && platform ? { name: trimmed, platform } : null;
}
