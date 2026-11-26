import { EvaluationRequest, Oprf, OPRFServer } from '@cloudflare/voprf-ts';
import { CryptoNoble } from '@cloudflare/voprf-ts/crypto-noble';

// Contact discovery by phone number (RFC 9497, OPRF mode, P256-SHA256). The
// input is the number in E.164 as UTF-8. Apps blind the numbers of their
// address book, the API applies OPRF_KEY without seeing them, the apps unblind
// and compare with the keys of discoverable accounts. The database holds only
// those keys, never a number; without OPRF_KEY they cannot be computed back.
const suite = Oprf.Suite.P256_SHA256;
// @noble/curves is about ten times faster than the default provider: some 4 ms per number
const ELEMENT = 33;

let server: OPRFServer | undefined;

function oprf() {
  const key = process.env.OPRF_KEY;
  if (!key) return null;
  server ??= new OPRFServer(suite, Buffer.from(key, 'hex'), CryptoNoble);
  return server;
}

export const oprfReady = () => oprf() !== null;

// The key of a verified number, hex
export async function phoneKey(phone: string) {
  return Buffer.from(await oprf()!.evaluate(new TextEncoder().encode(phone))).toString('hex');
}

// Compressed SEC1 points in, the same out with the key applied. Throws on an invalid point.
export async function blindEvaluate(blinded: Uint8Array[]) {
  if (blinded.some(element => element.length !== ELEMENT)) throw new Error('invalid element');
  const count = Buffer.alloc(2);
  count.writeUInt16BE(blinded.length);
  const request = EvaluationRequest.deserialize(suite, Buffer.concat([count, ...blinded]), CryptoNoble);
  const evaluation = await oprf()!.blindEvaluate(request);
  return evaluation.evaluated.map(element => element.serialize(true));
}
