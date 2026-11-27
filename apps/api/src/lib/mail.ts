import { APP_NAME } from '@app/shared';
import nodemailer from 'nodemailer';

const port = Number(process.env.SMTP_PORT || 587);

// Without SMTP_HOST mails go to the log, so local dev needs no mail account.
const transport = process.env.SMTP_HOST
  ? nodemailer.createTransport({
      host: process.env.SMTP_HOST,
      port,
      secure: port === 465,
      requireTLS: port !== 465,
      dnsTimeout: 5000,
      connectionTimeout: 5000,
      greetingTimeout: 5000,
      socketTimeout: 10_000,
      auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS },
    })
  : null;

const from = process.env.EMAIL_FROM || `${APP_NAME} <noreply@localhost>`;

type Mail = {
  to: string;
  subject: string;
  text: string;
  replyTo?: { name: string; address: string };
  attachments?: { filename: string; content: Buffer }[];
};

export async function sendMail({ to, subject, text, replyTo, attachments }: Mail) {
  if (!transport) {
    // In production the log would hand out login codes
    if (process.env.NODE_ENV === 'production') throw new Error('SMTP_HOST is required in production, otherwise login codes would end up in the log');
    console.log(`[mail] To ${to}: ${subject}\n${text}`);
    return;
  }
  await transport.sendMail({ from, to, subject, text, replyTo, attachments });
}
