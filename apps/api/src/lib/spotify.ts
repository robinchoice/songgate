import type { Conversion } from '@app/shared';
import { z } from 'zod';
import { clientToken, ResolutionError, type Session } from './providers';

// Spotify has no open catalogue API. Songs and albums are found through ListenBrainz, which maps
// artist and title to Spotify track IDs, and confirmed on Spotify's own pages. Only finding podcasts
// needs the Web API with an app token from the client credentials flow: without SPOTIFY_CLIENT_ID and
// SPOTIFY_CLIENT_SECRET Spotify links are still read from their pages, podcasts on Spotify get a search link.

const listenBrainz = z.array(z.object({ spotify_track_ids: z.array(z.string()).default([]) }));

// The Spotify track IDs ListenBrainz knows for a recording, each once
export async function spotifyTrackIds(artist: string, track: string, limit: number, { get }: Session) {
  const entries = listenBrainz.parse(await get('https://labs.api.listenbrainz.org/spotify-id-from-metadata/json', {
    artist_name: artist, track_name: track, release_name: '',
  }));
  return [...new Set(entries.flatMap(entry => entry.spotify_track_ids))].filter(id => /^[A-Za-z0-9]{22}$/.test(id)).slice(0, limit);
}

const metadataSchema = z.object({
  title: z.string(),
  author_name: z.string().default(''),
  thumbnail_url: z.string().nullable().optional(),
});
const normalizedTitle = (title: string) => title.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();

// Spotify's oEmbed confirms that each track ListenBrainz names still exists and carries the same title
export async function spotifyCandidates(source: { title: string; artist: string }, current: Session) {
  const ids = await spotifyTrackIds(source.artist, source.title, 8, current);
  const candidates: Conversion['candidates'] = [];
  for (let i = 0; i < ids.length; i += 3) {
    const batch = await Promise.all(ids.slice(i, i + 3).map(async id => {
      const url = `https://open.spotify.com/track/${id}`;
      let metadata: z.infer<typeof metadataSchema>;
      try {
        metadata = metadataSchema.parse(await current.get('https://open.spotify.com/oembed', { url }));
      } catch (error) {
        if (error instanceof ResolutionError && error.code === 'SOURCE_UNAVAILABLE') return null;
        throw error;
      }
      if (normalizedTitle(metadata.title) !== normalizedTitle(source.title)) return null;
      return { title: metadata.title, url, artworkUrl: metadata.thumbnail_url?.startsWith('https://') ? metadata.thumbnail_url : null };
    }));
    candidates.push(...batch.filter(candidate => candidate !== null));
  }
  return candidates;
}

// null without a key, so callers fall back to a search link
export async function spotifyApi(path: string, params: Record<string, string>, current: Session): Promise<unknown> {
  const token = await clientToken('https://accounts.spotify.com/api/token', process.env.SPOTIFY_CLIENT_ID, process.env.SPOTIFY_CLIENT_SECRET, current);
  if (!token) return null;
  return (await current.request(`https://api.spotify.com/v1/${path}`, params, { authorization: `Bearer ${token}` })).json();
}
