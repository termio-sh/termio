---
title: Mac retention analytics (no app changes)
status: draft
type: design
created: 2026-07-15
updated: 2026-07-15
related:
  - 20260705-remote-access-relay-strategy.md
---

# Mac retention analytics (no app changes)

> Measure whether Mac users keep coming back, using only the Sparkle appcast
> check-ins we already collect at Cloudflare — no in-app SDK, no new network
> surface — by extending the daily download-stats GitHub Action.

## Constraint

The explicit constraint is **do not instrument the app**. No SDK, no new
outbound call from Termio itself. That leaves exactly one passive heartbeat the
Mac already emits and we already receive: **Sparkle's periodic `GET`
of `downloads.termio.sh/appcast.xml`**.

- Every installed Mac runs Sparkle, which checks the appcast on launch and every
  `SUScheduledCheckInterval` (default 86400s ≈ daily).
- So "did install X hit the appcast on day D" ≈ "was install X alive on day D" —
  precisely the daily check-in a retention model needs.
- We already have these requests in the Cloudflare zone logs (the download-stats
  Action queries them today for the active-Mac count).

## The identity problem

Retention tracks whether the **same install** returns across days. Without an
app change, the only per-request discriminator in an appcast hit is:

| Field | Usable as identity? |
| --- | --- |
| client IP | The only option — but **not stable** (dynamic IPs, NAT). |
| User-Agent | App version + Sparkle version only; **not unique**. |
| Sparkle system profiling | Needs `SUEnableSystemProfiling` (an Info.plist change = "app change", excluded), and still not unique. |

**Conclusion: with no app change, identity can only be the client IP.** This is
the hard ceiling of this route and must be stated honestly wherever the numbers
are reported.

## Data model

The shipped Action stores only the daily *count* of unique appcast IPs. Cohort
retention needs the daily *set* of identities so days can be intersected.

- For each day, write `days/<YYYY-MM-DD>.txt` on the orphan `stats` branch, one
  `sha256(ip + SALT)` per line.
  - Hash, don't store raw IPs — keeps the ledger privacy-preserving while still
    letting "same IP across days" be matched. `SALT` lives in a GitHub Secret.
- Lives alongside the existing `downloads.csv` on the `stats` branch, so `dev`
  history stays clean.

## Retention computation

- **Cohort(W)** = the set of hashed IPs whose *first-ever* appearance falls in
  week W.
- **RetentionN(W)** = `|Cohort(W) ∩ ActiveIPs(W+N)| / |Cohort(W)|`.
- A weekly Action reads all `days/*.txt`, computes the cohort table, and posts it
  to Telegram (same channel as the daily digest).
- Retention only accumulates from the day set-logging begins — the table is
  meaningless for the first few weeks and needs runtime to fill in.

## What it can and cannot tell you

Reliable enough to act on:

- Active-install trend (WAU / MAU over time) — "is the active base growing?"
- DAU/MAU stickiness ratio — an engagement proxy less sensitive to the identity
  problem than cohort retention.
- The qualitative *shape* of retention — "do people come back at all?"

Do **not** treat as precise:

- Exact D7 / D30 retention percentages. Two uncontrollable biases:
  - **Dynamic IP** — a retained user on a new IP looks like one churn + one new
    user → retention **under**-estimated.
  - **NAT / shared IP** — several Macs behind one egress IP collapse into one
    identity → retention **over**-estimated (that IP is always "present").

## Scale caveat

At ~50 users a weekly cohort is ~10–20 IPs, so **one user ≈ 5–10 percentage
points**. Combined with IP bias, retention *percentages* are statistically
meaningless at this size — and this is **not** specific to the IP method: an
in-app SDK would be equally noisy, because the cohort is too small. What is
legible now is the qualitative "do people return" trend; precise curves have to
wait for more users.

## Architecture

Everything reuses what already ships — no app change, no new dependency, no new
network surface:

```
Daily Action (exists today)
  └─ besides writing count, dump the day's hashed-IP set → stats:days/<date>.txt
Weekly Action (new)
  └─ read all days/*.txt → compute cohort retention table → post to Telegram
```

## When to switch to the app route (not now)

Only a stable per-install id (an in-app SDK such as TelemetryDeck) yields
accurate per-install retention. Adopt it only when **both** hold: (a) you
genuinely need precise per-install retention, and (b) the user base is large
enough for percentages to be statistically meaningful. Until then the IP proxy
is sufficient and adds zero cost and zero new privacy surface. Kept in the back
pocket, deliberately undesigned here.

## Recommendation

Add the **daily hashed-IP set** layer now (a small extension of the existing
Action); it immediately starts accumulating the raw material for retention.
Compute a weekly retention proxy + stickiness ratio, and read the numbers as
*direction*, not *precision*. Revisit an in-app SDK when the user base and the
need for precise per-install retention both arrive.
