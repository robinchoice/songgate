import { z } from 'zod';

const answerSchema = z.looseObject({ success: z.string() });

// Through seven.io (Kiel). Without SEVEN_API_KEY the SMS goes to the log, so
// local dev and tests need no account. Code 100 means accepted by the gateway.
export async function sendSms(to: string, text: string) {
  const key = process.env.SEVEN_API_KEY;
  if (!key) {
    console.log(`[sms] To ${to}: ${text}`);
    return;
  }
  const response = await fetch('https://gateway.seven.io/api/sms', {
    method: 'POST',
    headers: { 'X-Api-Key': key, Accept: 'application/json' },
    body: new URLSearchParams({ to, text, from: 'Songgate' }),
    signal: AbortSignal.timeout(10_000),
  });
  const answer = answerSchema.safeParse(await response.json().catch(() => null));
  if (!response.ok || answer.data?.success !== '100') throw new Error(`SMS not accepted: HTTP ${response.status}, code ${answer.data?.success ?? 'none'}`);
}
