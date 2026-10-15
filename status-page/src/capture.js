// STUB (issue #273) — error capture + Slack alert path for the Worker.
// Contract: captureError(error, { release, environment, route }, env) -> Promise<void>;
// a no-op (never throws, no network) when the alert secret is absent from env.
export async function captureError(_error, _tags, _env) {
  throw new Error('NotImplemented');
}
