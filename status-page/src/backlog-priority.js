// src/backlog-priority.js — writes the backlog-priority-registry GitHub issue over the GitHub
// REST API. This is the browser-reachable twin of skills/orchestrate/backlog-priority.sh's
// `cmd_set`: same registry repo, same label, same title, same body shape (a JSON array of
// "owner/repo#issue" keys, highest priority first — the exact order backlog-priority.sh's `set`
// command wants and the exact order render.js already displays/prints for that command). It is
// not a new primitive, just a second writer of the one registry issue `backlog-priority.sh`
// already owns.
//
// Workers can't shell out to `gh`, so this talks to the GitHub REST API directly with a
// fine-grained PAT (the GITHUB_TOKEN secret, scoped to Issues: write on this repo only — see
// README.md).

export const REGISTRY_REPO = "jpmoya/claude-agents";
export const REGISTRY_LABEL = "backlog-priority-registry";
export const REGISTRY_TITLE =
  "Backlog priority order (machine-managed; do not edit by hand)";

// Same shape backlog-priority.sh's BP_KEY_RE enforces.
const KEY_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[0-9]+$/;

const GITHUB_API = "https://api.github.com";

/** True if `keys` is a non-empty array of well-formed "owner/repo#issue" strings. */
export function isValidKeyList(keys) {
  return (
    Array.isArray(keys) &&
    keys.length > 0 &&
    keys.length <= 200 &&
    keys.every((k) => typeof k === "string" && KEY_RE.test(k))
  );
}

function ghHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "Content-Type": "application/json",
    "User-Agent": "status-page-worker",
  };
}

/** Finds the open backlog-priority-registry issue; null if none exists (never creates one). */
async function findRegistryIssue(token) {
  const res = await fetch(
    `${GITHUB_API}/repos/${REGISTRY_REPO}/issues?labels=${encodeURIComponent(REGISTRY_LABEL)}&state=open&per_page=1`,
    { headers: ghHeaders(token) },
  );
  if (!res.ok) throw new Error(`GitHub issue lookup failed: ${res.status}`);
  const list = await res.json();
  return Array.isArray(list) && list.length > 0 ? list[0].number : null;
}

/** Creates the registry issue (body "[]") with its label, same as bp_find_issue. */
async function createRegistryIssue(token) {
  const res = await fetch(`${GITHUB_API}/repos/${REGISTRY_REPO}/issues`, {
    method: "POST",
    headers: ghHeaders(token),
    body: JSON.stringify({
      title: REGISTRY_TITLE,
      body: "[]",
      labels: [REGISTRY_LABEL],
    }),
  });
  if (!res.ok) throw new Error(`GitHub issue create failed: ${res.status}`);
  const issue = await res.json();
  return issue.number;
}

async function patchRegistryIssueBody(token, number, keys) {
  const res = await fetch(
    `${GITHUB_API}/repos/${REGISTRY_REPO}/issues/${number}`,
    {
      method: "PATCH",
      headers: ghHeaders(token),
      body: JSON.stringify({ body: JSON.stringify(keys) }),
    },
  );
  if (!res.ok) throw new Error(`GitHub issue update failed: ${res.status}`);
}

/**
 * Writes `keys` (highest priority first, matching backlog-priority.sh's `set` argument order and
 * what the page displays) to the registry issue's body, finding or creating that issue first.
 * Throws on any GitHub API failure — the caller (index.js) turns that into a 502.
 * @returns {Promise<number>} the registry issue number
 */
export async function setBacklogPriority(token, keys) {
  let number = await findRegistryIssue(token);
  if (number === null) number = await createRegistryIssue(token);
  await patchRegistryIssueBody(token, number, keys);
  return number;
}
