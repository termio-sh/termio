---
name: review-copy
description: Review and fix user-facing copy against termio's voice guide (VOICE.md), scoring each pass and iterating until it holds. Covers UI strings, landing site, docs, release notes, and PR or issue text. Use when the user says 'review this copy', 'does this sound like us', 'check the wording', 'audit the settings text', 'fix this copy', '这段文案看一下', '读起来像不像我们写的', '改改措辞'.
---

# Review copy

Score a piece of user-facing copy against `VOICE.md`, fix what fails, then verify
the fixes actually landed. The loop exists because a single pass reliably misses
things and reliably claims fixes it didn't make.

**Target**: `$ARGUMENTS` — a file, a directory of Swift views, a docs page, a PR
body, or pasted text.

## Before anything

Read `VOICE.md` at the repo root. It is the standard; this skill is only the
loop that applies it. If the two ever disagree, `VOICE.md` wins.

**Never calibrate against neighbouring strings in this repo.** Most of them were
written with AI assistance, so "it matches the file around it" is evidence of
nothing. For UI copy, the reference is the macOS System Settings pane that does
the same job — read Apple's wording, then write termio's.

## The loop

```
score → fix the failures → re-score to verify → repeat until it holds
```

State lives in a tracker file under the scratchpad so a second pass doesn't
re-discover the same issues or trust an unverified claim:

**Path**: `<scratchpad>/copy-review-<name>.md`

```markdown
# Copy review: [target]

| ID  | String / line        | Issue            | Status         | Round |
| --- | -------------------- | ---------------- | -------------- | ----- |
| 1   | Settings.swift:214   | subject is "you" | pending        | 1     |
| 2   | page.tsx:80          | "seamlessly"     | verified-fixed | 1     |
| 3   | FileNode.swift:31    | mechanism copy   | wont-fix       | 2     |

## Rounds
### Round 1 — Voice 6/10, Accuracy 8/10 (14/20)
```

Status values: `pending` · `fixed` (claimed, unverified) · `verified-fixed` ·
`not-fixed` · `wont-fix` (intentional, out of scope, or a false positive).

## Step 0 — The mechanical pass

Cheap, exact, and it clears the noise before anyone reads for tone. Run these
over the target first and fix every hit; none of them need judgment.

```sh
# straight apostrophes in user-facing strings — should be curly (’)
grep -rnE "\"[^\"]*[a-zA-Z]'(t|s|re|ll|ve|m|d)\b[^\"]*\"" <target> | grep -v 'Log\.\|logger\|// '

# "could not" where a contraction belongs (skip log strings and matched tool output)
grep -rn '"[^"]*[Cc]ould not' <target>

# Title Case on what is a sentence, not a feature name
grep -rnE '"(Can|Couldn|Cannot|Unable)[^"]*[a-z] [A-Z][a-z]+' <target>

# emoji in copy
grep -rnP '"[^"]{3,}"' <target> | grep -P "[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]"

# trailing gerunds — every hit is a candidate, neutral ones included
grep -rnE '"[^"]*, [a-z]+ing\b[^"]*"' <target>
```

Rewriting apostrophes across a tree is safe only inside string literals. Check
first that no match sits in a shell command being built for execution, then
operate on quoted substrings rather than whole lines, so comments and
identifiers are left alone.

## Step 1 — Score

Two dimensions, 0–10 each. Score them separately; they fail for different
reasons and get fixed by different means.

**VOICE** — does it read like a person wrote it?

Check in this order; the first two catch the most and are the easiest to miss
because the result reads fine.

1. **Trailing gerunds** — grep the target for `, [a-z]+ing\b`. Every hit is a
   candidate: "allowing you to", "making it easy to", "ensuring". Neutral ones
   count.
2. **Regression to the mean** — has a specific fact been smoothed into a
   generic? "helps you review your agents' work" where the truth was "shows
   changes, a file tree, and the transcript".
3. One idea per sentence, whatever its length
4. Honest: says what the control won't do or what it costs
5. Empty states and errors name the next action
6. Rhythm: do the sentences vary in length, or all run the same?
7. Fixed vocabulary (Group with / Ungroup / Close Session, lowercase `termio`)
8. Sentence case for sentences, Title Case for feature names; curly
   apostrophes; `Couldn't` over `Could not`
9. Remaining AI tells (hollow importance, rule of three, promotional
   adjectives, negation parallelism, emoji), no AI attribution
10. Nothing implying termio is paid

**ACCURACY** — is it true?

This is the dimension that matters most for termio and the one a style pass
skips. A subtext that describes behavior is a claim about the code.

- Read the code behind the string. Does the control do what the string says?
- Does a named path, flag, or command still exist and still spell that way?
- Is a capability described as shipped actually shipped, and on the release
  channel rather than only on dev?
- Do landing-site claims match `Sources/`? (Recurring failure — see the
  `termio-capabilities` history: copy outran the code twice.)

For a wide sweep (a whole settings tab, the landing site), score VOICE and
ACCURACY in separate passes rather than one — a single pass reading for both
consistently under-reports accuracy.

Write every failure into the tracker with its file and line. A finding without
a location can't be verified later.

## Step 2 — Report and choose

Show the user the scores and the issue table, then ask which they want:

- **improve** — fix the pending issues, then re-score
- **complete** — fix everything and exit without another round
- **done** — stop here

Do not silently continue looping. Copy changes are the user's call; a score is
an opinion, not a mandate.

## Step 3 — Fix

Fix **only** the issues in the tracker. Do not rewrite adjacent strings that
weren't flagged, do not expand a subtext into two, do not add new copy.

For an accuracy fix, read the source that backs the claim first and write what
the code actually does — never patch the wording to sound plausible.

Mark each fixed issue `fixed`, not `verified-fixed`. Only a re-score promotes it.

## Step 4 — Verify

Re-score. This pass has three jobs, in order:

1. **Verify** every `fixed` issue actually changed, and changed correctly.
   A fix that didn't land becomes `not-fixed` — this is the whole reason the
   loop exists.
2. **Score** both dimensions again.
3. **Flag** only new issues. Never re-raise a `wont-fix`.

## When it's done

The copy holds when both dimensions score 9+ and every issue is
`verified-fixed` or `wont-fix`. Report the final table and what changed; don't
claim a score you didn't re-run.

If the change touches shipped UI strings, it needs a real run — rebuild with
`macos-rebuild-dev` and read the window with `app-screenshot-debug`. A subtext
that reads well in source can still wrap to three lines in the pane.

## Notes

- Swift UI strings live mostly in `Sources/termio/Settings/`,
  `Sources/termio/Welcome/`, and each feature's views. Menu labels are in the
  feature that owns them plus `App/MenuBarController.swift`.
- Landing copy is in `web/landing/src/`; the download URL and product strings
  are centralized in `src/lib/site.ts`.
- Release notes come from PR bodies' `Release Notes:` sections, so reviewing a
  PR body is reviewing next release's copy.
