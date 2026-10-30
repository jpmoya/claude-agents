#!/bin/bash
# Stop hook: JP's hard rule — never give JP a ticket, issue or PR number without a 3-5 word
# description of what it is (e.g. "#1184 (remove technician self-revert)"). Blocks (once) a final
# message that cites a bare ticket/PR/issue number with no nearby description so Claude rewrites
# it. Interactive sessions only.
[ -n "${PIPELINE_AGENT:-}" ] && exit 0
IN=$(cat)
[ "$(printf '%s' "$IN" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
T=$(printf '%s' "$IN" | jq -r '.transcript_path // empty')
[ -f "$T" ] || exit 0
MSG=$(jq -rs '[.[]|select(.type=="assistant")]|last|.message.content|map(select(.type=="text")|.text)|join("\n")' "$T" 2>/dev/null)
[ -n "$MSG" ] || exit 0

BARE=$(printf '%s' "$MSG" | python3 -c "
import re
import sys

text = sys.stdin.read()

# Strip fenced code blocks and inline code spans first — a hex color or identifier written as
# code ('\`#1a2b3c\`', a fenced snippet) is not a ticket/PR/issue reference and must not trip this.
text = re.sub(r'\`\`\`.*?\`\`\`', ' ', text, flags=re.DOTALL)
text = re.sub(r'\`[^\`\n]*\`', ' ', text)

# Reduce a markdown link to its link text ('[#1184](url)' -> '#1184') and drop emphasis markers
# ('**#1184**' -> '#1184') so formatting around a reference doesn't hide an adjacent description.
text = re.sub(r'\[([^\]\n]*)\]\([^)\n]*\)', r'\1', text)
text = re.sub(r'[*_]+', '', text)

# Ticket/PR/issue refs: an optional 'owner/repo' prefix, then '#', then 1-6 digits. A markdown
# header ('# Heading', '## Sub') never matches — there is always a space between the hashes and
# the heading text, never a digit right after the last '#'. A hex color (#1a2b3c) or an anchor
# with letters (#issuecomment-123) also won't match '#' + digits-only.
ref_re = re.compile(r'(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]{1,6}\b')


def word_count_at_least_2(phrase):
    return len(phrase.strip().split()) >= 2


def word_count_ok(phrase):
    words = phrase.strip().split()
    return 2 <= len(words) <= 8


def has_nearby_description(line, start, end):
    after = line[end:end + 80]
    before = line[max(0, start - 80):start]

    # '#1184 (remove technician self-revert)' — JP's own example: parenthetical right after.
    m = re.match(r'\s*\(([^()]{3,80})\)', after)
    if m and word_count_ok(m.group(1)):
        return True

    # '#1184: remove technician self-revert' or '#1184 — remove technician self-revert'
    m = re.match(r'\s*[:–—-]\s*([A-Za-z][^.!?\n]{2,80})', after)
    if m and word_count_ok(m.group(1)):
        return True

    # 'the remove-technician-self-revert fix (#1184)' or '... (scheduler #1184)' — the ref sits
    # inside parens, optionally with up to two short label words first (a repo name, 'PR',
    # 'issue'); the description is the phrase before the opening paren, same status-card shape
    # JP's own template uses: '<Ticket title> (<repo> #<issue>)'. The phrase is a pre-existing
    # title, not a description written for this rule, so only its presence (>= 2 words) matters
    # — not an upper bound: a long ticket title or a long lead-in sentence must still pass.
    if after.lstrip().startswith(')'):
        m = re.search(
            r'([A-Za-z][^()\n]{3,80}?)\(\s*(?:[A-Za-z0-9][\w.-]{0,20}\s+){0,2}\$',
            before,
        )
        if m and word_count_at_least_2(m.group(1)):
            return True

    return False


def status_card_pr_ref_covered(line, start):
    # 'Title (repo #1184) — PR #1190 · release ...' — JP's own mandated status-card template
    # names the ticket once; the 'PR #<n>' right after doesn't need its own separate
    # description. Only this exact shape is exempted (not any earlier ref on the line in
    # general) so 'Filed #1959 (fix) and #1960.' still flags #1960.
    head = line[:start]
    m = re.search(r'([A-Za-z][^()\n]*?)\(([^()]*)\)\s*[–—-]\s*PR\s+\$', head)
    return bool(m and word_count_at_least_2(m.group(1)) and ref_re.search(m.group(2)))


bare = []
for line in text.split('\n'):
    seen = set()
    for m in ref_re.finditer(line):
        ref = m.group(0)
        if ref in seen:
            continue
        if has_nearby_description(line, m.start(), m.end()):
            continue
        if status_card_pr_ref_covered(line, m.start()):
            continue
        seen.add(ref)
        bare.append(ref)

print('\n'.join(bare))
" 2>/dev/null)

[ -n "$BARE" ] || exit 0
LIST=$(printf '%s' "$BARE" | tr '\n' ' ')
echo "JP's hard rule: never give him a ticket, issue or PR number without a 3-5 word description of what it is (e.g. \"#1184 (remove technician self-revert)\"). Rewrite your last message so each of these carries one: $LIST. Do not mention this rule." >&2
exit 2
