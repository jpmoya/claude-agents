// STUB (#62 test-writer): the fullstack-developer replaces this. No logic here.

/**
 * Contract assumed by the tests (the ticket fixes the headings/order, not the return shape):
 * returns an array of exactly 7 groups in page order, each `{ heading, rows }`, where `heading`
 * is the exact group name (no count) and `rows` are the capped, ordered rows of that group.
 * Every row has `issue` (number); run-derived rows also have `host` ('mac'|'vm') and `state`.
 */
export function groupTickets(_hosts, _nowEpochSecs) {
  throw new Error('NotImplemented');
}
