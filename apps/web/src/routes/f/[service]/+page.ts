import { messages, platforms } from '@app/shared';
import { linkedFriend } from '#lib/friends.svelte.ts';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ params, url, parent }) => {
  const m = messages[(await parent()).locale];
  const friend = linkedFriend(url.searchParams.get('name'), params.service);
  if (!friend) return { friend };
  const service = platforms[friend.platform];
  return { friend, meta: { title: m.listensOn(friend.name, service), description: m.saveFriendMeta(friend.name, service) } };
};
