// src/capture.js — error capture + Slack alert path for the Worker.
// Sends a minimal event (name, route, release, environment — never the message, headers or
// body) to the existing Slack webhook when SLACK_WEBHOOK_URL is bound. No new secret is
// required: with the secret absent this is a no-op, and it never throws.

export async function captureError(error, tags, env) {
  try {
    const url = env && env.SLACK_WEBHOOK_URL;
    if (typeof url !== 'string' || url === '') return;
    const t = tags || {};
    const name = error && typeof error.name === 'string' ? error.name : 'Error';
    const text = `status-page error: ${name} on ${t.route} (release ${t.release}, env ${t.environment})`;
    await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text }),
    });
  } catch {
    // never let alerting break the page
  }
}
