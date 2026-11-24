#!/bin/bash
# classify-migration-sql.sh [--shared-tables FILE] <file.sql>...   (issue #820)
# Decides whether SQL migration files are PURELY ADDITIVE, so the deployer can satisfy the destructive-migration-approval gate
# itself when the CI skip is unlicensed only because of non-SQL files (agents/deployer.md). Static text analysis only: no network,
# no database. FAIL CLOSED: anything the classifier does not positively recognise as additive is not additive.
#
# One line per file on stdout:
#   <file>: additive (<comma-separated statement kinds>)
#   <file>: NOT additive (<offending statement kind>)
#   <file>: UNPARSEABLE                      (empty file, garbage, unterminated string/comment/quote, unreadable file)
# Exit 0 only when EVERY file is additive; exit 1 otherwise (also: no arguments, unreadable file, classifier crash).
#
# Additive: CREATE TABLE / [UNIQUE] INDEX / [OR REPLACE] FUNCTION / POLICY / [OR REPLACE] VIEW / TRIGGER, ALTER TABLE ... ADD COLUMN
# (nullable, or with a DEFAULT; never NOT NULL without one), ALTER TABLE ... ENABLE ROW LEVEL SECURITY, GRANT. Everything else is not
# additive: DROP, TRUNCATE, DELETE, UPDATE, INSERT, REVOKE, RENAME, ALTER COLUMN, ADD CONSTRAINT, DO blocks, dynamic SQL, BEGIN/COMMIT, SET, ...
# Only what the files passed together create can be touched further (code review of #821):
#   - OR REPLACE of a function / view / trigger, a trigger's EXECUTE FUNCTION target and a POLICY's table must be created in those files;
#   - a policy needs a real condition (no true / 1=1 / empty), and function calls in a new function body, view or policy must be to
#     functions created there or a small builtin list (SAFE_CALLS); anything else is not additive;
#   - GRANT: object created there; grantee service_role / postgres, or anon / authenticated only on a table created there with row level
#     security enabled there and only SELECT/INSERT/UPDATE/DELETE; PUBLIC, other roles, WITH GRANT OPTION: not additive.
# A function body ($tag$ ... $tag$ or a quoted AS body) is scanned too: a destructive keyword anywhere in it is not additive.
# --shared-tables FILE: the risky list (one table name per line, # comments; the base branch's
# .github/migration-policy/shared-tables.txt). A statement that mentions a listed table is not additive. An unreadable list fails closed.
#
# Failures of the tool itself (unreadable file, crash) also record a classify_migration_failed event (release = commit SHA,
# environment, route; no SQL, no paths) and post to the existing SLACK_WEBHOOK_URL (pipeline-lib.sh classify_migration_alert).
# Env (tests): CLASSIFY_MIGRATION_PYTHON replaces python3. bash 3.2 compatible.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/pipeline-lib.sh"
PY=${CLASSIFY_MIGRATION_PYTHON:-python3}

# Exit codes of the python half: 0 every file additive, 10 a verdict of not additive, 3 an unreadable file or risky list, anything
# else (1 included: a syntax error, an uncaught exception, a kill) is a crash. Only 0 with one `additive` line per file is an approval.
out=$("$PY" -I - "$@" <<'PY'
import os, re, sys

class Unparseable(Exception):
    pass

WORD = re.compile(r"[A-Za-z_0-9\x80-\U0010ffff][A-Za-z_0-9$\x80-\U0010ffff]*")
DOLLAR = re.compile(r"\$([A-Za-z_\x80-\U0010ffff][A-Za-z_0-9\x80-\U0010ffff]*)?\$")

def tokenize(text):
    """-> list of (type, value). types: w word (upper-cased), s string content, q quoted identifier content,
    d dollar-quoted body (raw text), p one punctuation char. Comments are dropped. Raises Unparseable."""
    toks, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif text.startswith("/*", i):
            depth, i = 1, i + 2
            while depth:
                a, b = text.find("/*", i), text.find("*/", i)
                if b < 0:
                    raise Unparseable("unterminated block comment")
                if 0 <= a < b:
                    depth, i = depth + 1, a + 2
                else:
                    depth, i = depth - 1, b + 2
        elif c == "'":
            s, i = read_string(text, i, False)
            toks.append(("s", s))
        elif c == '"':
            out, i = [], i + 1
            while True:
                j = text.find('"', i)
                if j < 0:
                    raise Unparseable("unterminated quoted identifier")
                out.append(text[i:j])
                if text.startswith('""', j):
                    out.append('"')
                    i = j + 2
                    continue
                i = j + 1
                break
            toks.append(("q", "".join(out)))
        elif c == "$":
            m = DOLLAR.match(text, i)
            if m:
                end = text.find(m.group(0), m.end())
                if end < 0:
                    raise Unparseable("unterminated dollar quote")
                toks.append(("d", text[m.end():end]))
                i = end + len(m.group(0))
            else:
                toks.append(("p", c))      # $1 parameters
                i += 1
        elif WORD.match(text, i):
            m = WORD.match(text, i)
            w = m.group(0)
            if w.upper() in ("E", "U") and text.startswith("'", m.end()) or (w.upper() == "U" and text.startswith("&'", m.end())):
                if w.upper() == "U" and text.startswith("&'", m.end()):
                    i = m.end() + 1
                else:
                    i = m.end()
                s, i = read_string(text, i, w.upper() == "E")
                toks.append(("s", s))
            else:
                toks.append(("w", w.upper()))
                i = m.end()
        else:
            toks.append(("p", c))
            i += 1
    return toks

def read_string(text, i, escapes):
    out, i = [], i + 1
    n = len(text)
    while True:
        if i >= n:
            raise Unparseable("unterminated string")
        c = text[i]
        if escapes and c == "\\":
            out.append(text[i:i + 2])
            i += 2
        elif c == "'":
            if text.startswith("''", i):
                out.append("'")
                i += 2
            else:
                return "".join(out), i + 1
        else:
            out.append(c)
            i += 1

def split_statements(toks):
    stmts, cur, depth = [], [], 0
    for t in toks:
        if t == ("p", ";") and depth == 0:
            if cur:
                stmts.append(cur)
            cur = []
            continue
        if t == ("p", "("):
            depth += 1
        elif t == ("p", ")"):
            depth -= 1
            if depth < 0:
                raise Unparseable("unbalanced parenthesis")
        cur.append(t)
    if depth != 0:
        raise Unparseable("unbalanced parenthesis")
    if cur:
        stmts.append(cur)
    return stmts

def top_level(toks):
    """tokens at paren depth 0; each parenthesised group collapses to one ('g', [inner tokens]) item."""
    out, stack = [], []
    cur = out
    for t in toks:
        if t == ("p", "("):
            g = ("g", [])
            cur.append(g)
            stack.append(cur)
            cur = g[1]
        elif t == ("p", ")"):
            cur = stack.pop()
        else:
            cur.append(t)
    return out

def all_words(toks, strings_after_as=False):
    """every word at any depth, plus (recursively) the words inside $$ bodies; with strings_after_as also the quoted body
    that directly follows an AS word (AS '...')."""
    words = []
    prev = None
    for t in toks:
        if t[0] == "w":
            words.append(t[1])
        elif t[0] == "d":
            words.extend(all_words(tokenize(t[1]), True))
        elif t[0] == "s" and strings_after_as and prev == ("w", "AS"):
            words.extend(all_words(tokenize(t[1]), True))
        prev = t
    return words

BODY_BAD = {"DROP", "DELETE", "UPDATE", "TRUNCATE", "INSERT", "ALTER", "REVOKE", "GRANT", "RENAME", "EXECUTE", "COPY",
            "DO", "MERGE", "REINDEX", "VACUUM", "CLUSTER", "LOCK", "CALL", "DISABLE", "REFRESH"}
KNOWN_VERBS = {"DROP", "TRUNCATE", "DELETE", "UPDATE", "INSERT", "ALTER", "REVOKE", "GRANT", "DO", "CREATE", "COMMENT", "SET",
               "RESET", "BEGIN", "COMMIT", "ROLLBACK", "SELECT", "WITH", "VACUUM", "COPY", "LOCK", "REINDEX", "CLUSTER",
               "REFRESH", "NOTIFY", "LISTEN", "UNLISTEN", "CALL", "EXECUTE", "PERFORM", "ANALYZE", "DISCARD", "MERGE", "EXPLAIN",
               "SAVEPOINT", "RELEASE", "START", "END", "IMPORT", "SECURITY", "REASSIGN", "PREPARE", "DEALLOCATE", "DECLARE",
               "FETCH", "MOVE", "CHECKPOINT", "LOAD", "VALUES", "TABLE", "ABORT", "CLOSE", "SHOW"}

def norm_name(parts):
    parts = [p.lower() for p in parts]
    if len(parts) > 1 and parts[0] == "public":
        parts = parts[1:]
    return ".".join(parts)

def parse_name(items, i):
    """items[i:] starts a possibly schema-qualified name -> (normalised name, next index). Raises Unparseable."""
    parts = []
    while True:
        if i >= len(items) or items[i][0] not in ("w", "q"):
            raise Unparseable("name expected")
        parts.append(items[i][1])
        i += 1
        if i + 1 < len(items) and items[i] == ("p", ".") and items[i + 1][0] in ("w", "q"):
            i += 1
            continue
        break
    return norm_name(parts), i

def is_w(item, *ws):
    return item is not None and item[0] == "w" and item[1] in ws

def at(items, i):
    return items[i] if 0 <= i < len(items) else None

def kw(items, i, *ws):
    """items[i:i+len(ws)] are exactly these words."""
    return all(is_w(at(items, i + k), w) for k, w in enumerate(ws))

class NotAdditive(Exception):
    def __init__(self, kind):
        Exception.__init__(self, kind)
        self.kind = kind

def words_of(items, n=2):
    out = []
    for it in items:
        if it[0] != "w":
            break
        out.append(it[1].lower())
        if len(out) >= n:
            break
    return " ".join(out)

def classify_alter_table(items, created, record):
    i = 2
    if kw(items, i, "IF", "EXISTS"):
        i += 2
    if kw(items, i, "ONLY"):
        i += 1
    name, i = parse_name(items, i)
    if at(items, i) == ("p", "*"):
        i += 1
    rest = items[i:]
    if not rest:
        raise Unparseable("ALTER TABLE without action")
    actions, cur = [], []
    for it in rest:
        if it == ("p", ","):
            actions.append(cur)
            cur = []
        else:
            cur.append(it)
    actions.append(cur)
    kinds = []
    for a in actions:
        if not a:
            raise Unparseable("empty ALTER TABLE action")
        if kw(a, 0, "ENABLE", "ROW", "LEVEL", "SECURITY") and len(a) == 4:
            kinds.append("alter table enable row level security")
            record.add(("rls", name))
            continue
        if kw(a, 0, "ADD"):
            j = 1
            if kw(a, j, "COLUMN"):
                j += 1
            elif at(a, j) and at(a, j)[0] == "w" and at(a, j)[1] in ("CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "EXCLUDE", "LIKE"):
                raise NotAdditive("alter table add " + a[j][1].lower())
            if kw(a, j, "IF", "NOT", "EXISTS"):
                j += 3
            if at(a, j) is None or a[j][0] not in ("w", "q"):
                raise Unparseable("column name expected")
            col = a[j:]
            has_default = any(is_w(x, "DEFAULT", "GENERATED") for x in col)
            not_null = any(is_w(col[k], "NOT") and is_w(at(col, k + 1), "NULL") for k in range(len(col))) \
                or any(is_w(col[k], "PRIMARY") and is_w(at(col, k + 1), "KEY") for k in range(len(col)))
            if not_null and not has_default:
                raise NotAdditive("alter table add column not null without default")
            kinds.append("alter table add column")
            continue
        w = words_of(a, 2)
        if kw(a, 0, "ALTER") and any(is_w(x, "TYPE") for x in a):
            raise NotAdditive("alter table alter column type")
        if kw(a, 0, "ALTER") and any(is_w(a[k], "SET") and is_w(at(a, k + 1), "NOT") for k in range(len(a))):
            raise NotAdditive("alter table alter column set not null")
        raise NotAdditive("alter table " + (w or "unrecognised action"))
    return kinds

def split_commas(items):
    parts, cur = [], []
    for it in items:
        if it == ("p", ","):
            parts.append(cur)
            cur = []
        else:
            cur.append(it)
    parts.append(cur)
    return parts

ROW_PRIVS = {"SELECT", "INSERT", "UPDATE", "DELETE"}
SERVER_ROLES = {"service_role", "postgres"}
API_ROLES = {"anon", "authenticated"}

def classify_grant(items, created):
    # GRANT <privileges> ON [TABLE|SEQUENCE|FUNCTION|SCHEMA|TYPE] <names> TO <grantees>
    # Object side: only objects created in the files passed together. Grantee side: service_role / postgres for anything; anon and
    # authenticated only on a TABLE created here whose row level security is enabled here, and only with row privileges
    # (SELECT/INSERT/UPDATE/DELETE; ALL, TRUNCATE, TRIGGER and REFERENCES are not governed by RLS); PUBLIC and every other role: not additive.
    on = next((k for k, x in enumerate(items) if is_w(x, "ON")), None)
    if on is None:
        raise NotAdditive("grant role membership")
    privs = [x[1] for x in items[1:on] if x[0] == "w"]
    j = on + 1
    kind = "relation"
    if at(items, j) and at(items, j)[0] == "w" and items[j][1] in ("TABLE", "FUNCTION", "SCHEMA", "TYPE", "SEQUENCE"):
        kind = {"TABLE": "relation", "FUNCTION": "function", "SCHEMA": "schema", "TYPE": "type", "SEQUENCE": "sequence"}[items[j][1]]
        j += 1
    elif at(items, j) and at(items, j)[0] == "w" and items[j][1] in ("ALL", "DOMAIN", "DATABASE", "LANGUAGE", "FOREIGN", "LARGE", "PARAMETER", "TABLESPACE"):
        raise NotAdditive("grant on pre-existing objects")
    to = next((k for k in range(j, len(items)) if is_w(items[k], "TO")), None)
    if to is None:
        raise Unparseable("GRANT without TO")
    names = []
    for t in split_commas(items[j:to]):
        name, k = parse_name(t, 0)
        if kind == "function" and k < len(t) and t[k][0] == "g":
            k += 1
        if k != len(t):
            raise Unparseable("GRANT target")
        if kind == "sequence" or (kind, name) not in created:
            raise NotAdditive("grant on pre-existing object")
        names.append(name)
    rest = items[to + 1:]
    end = next((k for k, x in enumerate(rest) if is_w(x, "WITH", "GRANTED")), len(rest))
    if end != len(rest):
        raise NotAdditive("grant with grant option or granted by")
    grantees = []
    for t in split_commas(rest[:end]):
        if len(t) != 1 or t[0][0] not in ("w", "q"):
            raise NotAdditive("grant to an unrecognised grantee")
        grantees.append(t[0][1].lower())
    if not grantees:
        raise Unparseable("GRANT without grantee")
    for g in grantees:
        if g in SERVER_ROLES:
            continue
        if g in API_ROLES:
            if kind != "relation" or any(("table", n) not in created or ("rls", n) not in created for n in names):
                raise NotAdditive("grant to " + g + " on an object without row level security")
            if not privs or any(x not in ROW_PRIVS for x in privs):
                raise NotAdditive("grant to " + g + " beyond row privileges")
            continue
        raise NotAdditive("grant to " + ("public" if g == "public" else "an unlisted role"))
    return ["grant"]

def classify_create(items, created, record, shared):
    i = 1
    or_replace = kw(items, i, "OR", "REPLACE")
    if or_replace:
        i += 2
    unique = False
    if kw(items, i, "UNIQUE"):
        unique = True
        i += 1
    obj = at(items, i)
    if obj is None or obj[0] != "w":
        raise Unparseable("CREATE what?")
    o = obj[1]
    i += 1
    if o == "TABLE" and not or_replace and not unique:
        ine = kw(items, i, "IF", "NOT", "EXISTS")
        if ine:
            i += 3
        name, i = parse_name(items, i)
        if at(items, i) is None or at(items, i)[0] != "g":
            raise NotAdditive("create table as select" if is_w(at(items, i), "AS") else "create table form")
        if any(is_w(x, "AS") for x in items[i + 1:]):
            raise NotAdditive("create table as select")
        if not ine:
            record.add(("relation", name))
            record.add(("table", name))
        return "create table"
    if o == "INDEX" and not or_replace:
        if kw(items, i, "CONCURRENTLY"):
            i += 1
        if kw(items, i, "IF", "NOT", "EXISTS"):
            i += 3
        if not kw(items, i, "ON"):
            _, i = parse_name(items, i)
        if not kw(items, i, "ON"):
            raise Unparseable("CREATE INDEX without ON")
        return "create unique index" if unique else "create index"
    if unique:
        raise NotAdditive("create unique " + o.lower())
    if o == "FUNCTION":
        name, i = parse_name(items, i)
        if at(items, i) is None or at(items, i)[0] != "g":
            raise Unparseable("CREATE FUNCTION without parameter list")
        if or_replace and ("function", name) not in created:
            raise NotAdditive("create or replace function on a function not created here")
        if not or_replace:
            record.add(("function", name))
        return "create or replace function" if or_replace else "create function"
    if o == "VIEW":
        name, i = parse_name(items, i)
        if or_replace and ("relation", name) not in created:
            raise NotAdditive("create or replace view on a view not created here")
        if not or_replace:
            record.add(("relation", name))
        return "create or replace view" if or_replace else "create view"
    if o == "TRIGGER":
        tname, i = parse_name(items, i)
        ex = next((k for k, x in enumerate(items) if k >= i and is_w(x, "EXECUTE")), None)
        if ex is None or not any(is_w(x, "ON") for x in items[i:ex]) or not (is_w(at(items, ex + 1), "FUNCTION", "PROCEDURE")):
            raise Unparseable("CREATE TRIGGER shape")
        fname, _ = parse_name(items, ex + 2)
        if ("function", fname) not in created:
            raise NotAdditive("create trigger calling a function not created here")
        if or_replace and ("trigger", tname) not in created:
            raise NotAdditive("create or replace trigger on a trigger not created here")
        if not or_replace:
            record.add(("trigger", tname))
        return "create or replace trigger" if or_replace else "create trigger"
    if o == "POLICY" and not or_replace:
        _, i = parse_name(items, i)
        if not kw(items, i, "ON"):
            raise Unparseable("CREATE POLICY without ON")
        tbl, _ = parse_name(items, i + 1)
        if ("table", tbl) not in created:
            raise NotAdditive("create policy on a table not created here")
        return "create policy"
    raise NotAdditive("create " + (words_of([obj] + items[i:], 2) or "unrecognised"))

NOT_CALLS = {"IF", "ELSIF", "ELSEIF", "WHEN", "WHERE", "AND", "OR", "NOT", "ON", "USING", "OVER", "FILTER", "RETURN", "RETURNS", "AS",
             "SELECT", "THEN", "ELSE", "IN", "FROM", "JOIN", "VALUES", "EXISTS", "ANY", "ALL", "SOME", "LATERAL", "CASE", "BETWEEN", "LIKE",
             "ILIKE", "WITH", "BY", "HAVING", "UNION", "INTERSECT", "EXCEPT", "LIMIT", "OFFSET", "ORDER", "GROUP", "DISTINCT", "WHILE",
             "LOOP", "FOR", "FOREACH", "IS", "ROW", "ARRAY", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "CHECK", "DEFAULT", "NULL",
             "VARCHAR", "CHAR", "CHARACTER", "NUMERIC", "DECIMAL", "TIMESTAMP", "TIMESTAMPTZ", "TIME", "TIMETZ", "BIT", "VARBIT",
             "FLOAT", "INTERVAL", "RETURNING", "EXCEPTION", "RAISE", "BEGIN", "END", "DECLARE", "OR", "TO", "SIMILAR", "OPERATOR"}
SAFE_CALLS = {"now", "clock_timestamp", "statement_timestamp", "transaction_timestamp", "current_timestamp", "gen_random_uuid",
              "uuid_generate_v4", "coalesce", "nullif", "greatest", "least", "lower", "upper", "length", "char_length", "trim", "btrim",
              "ltrim", "rtrim", "concat", "concat_ws", "format", "substr", "substring", "replace", "position", "left", "right", "split_part",
              "count", "sum", "min", "max", "avg", "abs", "round", "floor", "ceil", "ceiling", "random", "extract", "date_trunc", "age",
              "to_char", "to_date", "to_timestamp", "date", "array_length", "array_agg", "unnest", "string_agg", "cardinality",
              "to_json", "to_jsonb", "json_build_object", "jsonb_build_object", "jsonb_build_array", "row_to_json", "jsonb_agg",
              "json_agg", "jsonb_array_elements", "jsonb_extract_path_text", "jsonb_typeof", "current_setting", "auth.uid", "auth.jwt",
              "auth.role", "md5", "regexp_replace", "regexp_match", "mod", "power", "sqrt", "cast"}

def call_name(parts):
    n = ".".join(p.lower() for p in parts)
    for pre in ("public.", "pg_catalog."):
        if n.startswith(pre):
            n = n[len(pre):]
    return n

def check_calls(toks, created, what):
    """every NAME( in these tokens must be a keyword/type, a small safe builtin, or a function created in the same files."""
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        if t[0] in ("w", "q"):
            parts, j = [t[1]], i + 1
            while j + 1 < n and toks[j] == ("p", ".") and toks[j + 1][0] in ("w", "q"):
                parts.append(toks[j + 1][1])
                j += 2
            if j < n and toks[j] == ("p", "(") and not (len(parts) == 1 and t[0] == "w" and t[1] in NOT_CALLS):
                name = call_name(parts)
                if name not in SAFE_CALLS and ("function", name) not in created:
                    raise NotAdditive(what + " calls " + name)
            i = j
        else:
            i += 1

def body_streams(toks, after_as_only=True):
    """token lists of every function body in a statement: $tag$ bodies (nested ones too) and a quoted body right after AS."""
    prev = None
    for t in toks:
        if t[0] == "d" or (t[0] == "s" and prev == ("w", "AS")):
            inner = tokenize(t[1])
            yield inner
            for deeper in body_streams(inner):
                yield deeper
        prev = t

def check_policy(toks, created):
    exprs, k = [], 0
    for k, t in enumerate(toks):
        if t in (("w", "USING"), ("w", "CHECK")) and k + 1 < len(toks) and toks[k + 1] == ("p", "("):
            depth, j, inner = 0, k + 1, []
            while j < len(toks):
                if toks[j] == ("p", "("):
                    depth += 1
                elif toks[j] == ("p", ")"):
                    depth -= 1
                    if depth == 0:
                        break
                inner.append(toks[j])
                j += 1
            exprs.append(inner[1:])
    if not exprs:
        raise NotAdditive("create policy without a condition")
    for e in exprs:
        words = [t[1] for t in e if t[0] == "w"]
        if "TRUE" in words:
            raise NotAdditive("create policy with an unconditional clause")
        if not [w for w in words if w not in ("FALSE", "NULL", "NOT", "AND", "OR", "IS") and not w[0].isdigit()] and not any(t[0] == "q" for t in e):
            raise NotAdditive("create policy with an unconditional clause")
        check_calls(e, created, "create policy")

def classify_statement(toks, created, record, shared):
    """-> list of statement kinds (usually one). Raises NotAdditive / Unparseable."""
    items = top_level(toks)
    head = at(items, 0)
    if head is None or head[0] != "w":
        raise Unparseable("statement does not start with a keyword")
    v = head[1]
    # the risky list: any mention of a listed table (word or quoted identifier, bodies included) stops here
    if shared:
        for t in flat(toks):
            if t[0] in ("w", "q") and norm_name([t[1]]) in shared:
                raise NotAdditive("risky list: shared table " + t[1].lower())
    if v not in KNOWN_VERBS:
        raise Unparseable("unknown statement")
    if v == "CREATE":
        kind = classify_create(items, created, record, shared)
        if kind.endswith("function") or kind.endswith("view"):
            bad = sorted(set(all_words(toks, True)) & BODY_BAD)
            if bad:
                raise NotAdditive(kind + " body contains " + bad[0].lower())
            if kind.endswith("function"):
                if any(is_w(x, "ATOMIC") for x in items):
                    raise NotAdditive(kind + " with an unquoted body")
                for body in body_streams(toks):
                    check_calls(body, created, kind + " body")
            else:
                a = next((k for k, x in enumerate(toks) if x == ("w", "AS")), None)
                if a is None:
                    raise Unparseable("CREATE VIEW without AS")
                check_calls(toks[a + 1:], created, kind)
        if kind == "create policy":
            check_policy(toks, created)
        return [kind]
    if v == "ALTER" and kw(items, 1, "TABLE"):
        return classify_alter_table(items, created, record)
    if v == "GRANT":
        return classify_grant(items, created)
    if v == "DROP":
        n = at(items, 1)
        raise NotAdditive("drop " + (n[1].lower() if n and n[0] == "w" else "object"))
    if v == "DO":
        raise NotAdditive("do block")
    if v == "ALTER":
        raise NotAdditive("alter " + (words_of(items[1:], 1) or "object") + (" rename" if any(is_w(x, "RENAME") for x in items) else ""))
    if v == "SELECT" or v == "WITH":
        raise NotAdditive(v.lower() + " statement")
    raise NotAdditive(v.lower())

def flat(toks):
    out = []
    for t in toks:
        if t[0] == "d":
            out.extend(flat(tokenize(t[1])))
        else:
            out.append(t)
    return out

def parse_file(path):
    with open(path, "rb") as f:
        raw = f.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Unparseable("not utf-8")
    if "\x00" in text:
        raise Unparseable("NUL byte")
    stmts = split_statements(tokenize(text))
    if not stmts:
        raise Unparseable("no statements")
    return stmts

def load_shared(path):
    names = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip().lower()
            if line:
                names.add(line)
    return names

def main(argv):
    shared = None
    args = list(argv)
    if args[:1] == ["--shared-tables"]:
        if len(args) < 2:
            return 10, 0
        try:
            shared = load_shared(args[1])
        except (OSError, UnicodeDecodeError):
            print("--shared-tables: UNPARSEABLE (risky list unreadable)")
            return 10, 1
        if not shared:
            print("--shared-tables: UNPARSEABLE (risky list empty)")
            return 10, 1
        args = args[2:]
    if not args:
        print("usage: classify-migration-sql.sh [--shared-tables FILE] <file.sql>...", file=sys.stderr)
        return 10, 0
    parsed, results, unreadable = {}, {}, 0
    for p in args:
        try:
            parsed[p] = parse_file(p)
        except Unparseable:
            results[p] = "UNPARSEABLE"
        except OSError:
            results[p] = "UNPARSEABLE"
            unreadable += 1
    created = set()
    while True:                               # pass 1: everything the PR creates (a GRANT may name a later file's table), to a fixed point
        before = len(created)
        for p, stmts in parsed.items():
            for s in stmts:
                rec = set()
                try:
                    classify_statement(s, created, rec, None)
                except (NotAdditive, Unparseable):
                    pass
                created |= rec
        if len(created) == before:
            break
    for p, stmts in parsed.items():           # pass 2: the verdicts
        kinds = []
        try:
            for s in stmts:
                for k in classify_statement(s, created, set(), shared):
                    if k not in kinds:
                        kinds.append(k)
            results[p] = "additive (" + ", ".join(kinds) + ")"
        except NotAdditive as e:
            results[p] = "NOT additive (" + e.kind + ")"
        except Unparseable:
            results[p] = "UNPARSEABLE"
    ok = True
    for p in args:
        print("%s: %s" % (p, results[p]))
        ok = ok and results[p].startswith("additive")
    return (0 if ok else 10), unreadable

try:
    rc, unreadable = main(sys.argv[1:])
except Exception as e:                        # a crash is never an approval
    sys.stderr.write("classify-migration-sql.sh: internal error (%s)\n" % type(e).__name__)
    sys.exit(70)
sys.exit(3 if unreadable else rc)
PY
)
rc=$?
case "$rc" in
  0)
    # exit 0 is an approval, so it must be backed by exactly one additive verdict line per file argument
    want=0; skip=0
    for a in "$@"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      if [ "$a" = --shared-tables ]; then skip=1; continue; fi
      want=$((want + 1))
    done
    got=$(printf '%s\n' "$out" | grep -c ': additive (')
    if [ "$want" -gt 0 ] && [ "$got" = "$want" ] && [ "$(printf '%s\n' "$out" | grep -c .)" = "$want" ]; then
      printf '%s\n' "$out"; exit 0
    fi
    classify_migration_alert "classifier output did not match its exit code"; exit 1 ;;
  10) printf '%s\n' "$out"; exit 1 ;;
  3) printf '%s\n' "$out"; classify_migration_alert "unreadable file"; exit 1 ;;
  *) classify_migration_alert "classifier crash (exit $rc)"; exit 1 ;;
esac
