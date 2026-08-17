---
title: "Remote-access design lessons: sleep reachability, stable domains, identity, monetization"
status: active
type: design
created: 2026-07-05
updated: 2026-07-05
related:
  - 20260705-remote-access-relay-strategy.md
  - 20260628-session-share.md
---

# Remote-access design lessons

> Reusable conclusions from building phone↔Mac remote access: Mac sleep reachability, stable domains, device identity (keypair vs machine code), and how an open-source project turns one feature into a paid one. This is the "why we chose it" record; the wiring details live in [remote-access-relay-strategy.md](20260705-remote-access-relay-strategy.md).

This captures **transferable judgments and their evidence**, not the wiring already in the strategy doc. Each section ends with a one-liner.

---

## 1. Mac sleep reachability: don't fight Apple's wall

"If the Mac just sits idle, can the phone still connect?" — first separate the sleep states; the outcomes differ completely:

| State | Machine | Tunnel / connection | Phone |
|---|---|---|---|
| **Display sleep** (screen off only) | Still running | All alive | ✅ Connects |
| **System idle sleep** | Suspended, processes frozen | Tunnel frozen, sockets dropped, URL dead | ❌ |
| **Clamshell** (lid closed) | Forced sleep | Same | ❌ |

Key facts:

- **Display sleep does not affect reachability** — the common "screen off after 2 min" only turns off the display; the machine keeps running. What actually drops the connection is **whole-system sleep**.
- **A third-party app cannot reliably wake a sleeping Mac via APNs.** Dark-wake exists, but the OS does not guarantee CPU to a third-party app (background pushes are throttled/coalesced); reliable wake is a privilege of Apple's own services (SSH/SMB/screen sharing/Mail). APNs reliably wakes the **phone**, not the Mac.
- **Remote-waking a sleeping Mac is not unsolvable, but every solution needs a second always-on device on the Mac's LAN to fire a Wake-on-LAN magic packet** (TeamViewer relay device / Tailscale + UpSnap on a Pi). A lone sleeping Mac woken purely from the cloud is the one truly unsolvable case: WoL magic packets don't route over the internet, and WoL-over-WiFi is unreliable (radio off during sleep).
- **The industry converges here**: Chrome Remote Desktop tells you to "disable sleep," VS Code Tunnels use `--no-sleep` — **nobody wakes a remote machine via cloud push**.

**Pragmatic answer**: a "keep reachable" toggle that holds `IOPMAssertPreventUserIdleSystemSleep` (= VS Code `--no-sleep`). The display still sleeps (saves power), the machine doesn't idle-sleep, the tunnel stays live; default it to power-adapter only. Lid-closed-on-battery-carried-away is genuinely unsupported — say so.

> One-liner: for sleep reachability, don't "wake the Mac," "keep it awake"; APNs pushing the phone is reliable, pushing the Mac is not.

---

## 2. Stable domains: churn is the pain, a central relay is the fix

- The phone side really **only needs a stable URL**, not a central relay — the pain comes entirely from quick tunnels minting a new random URL on every restart → phone unauthorized → re-pair.
- **The industry does not hand out per-host long-lived public URLs**: TeamViewer/AnyDesk/Tailscale/VS Code Tunnels/sshx are all "central rendezvous broker + both ends outbound + ID/token routing, P2P-first, relay as fallback." cloudflared's ingress **cannot route by token across users** — that job requires a relay process.
- **Cost reality check**: a Cloudflare Named Tunnel is free per tunnel with no bandwidth charge; what costs money is Zero Trust Access seats (which you avoid by authenticating with your own token). At tens of thousands of users the real wall is the **per-zone DNS record quota**, not "price per tunnel."

> One-liner: a stable URL doesn't require a central relay to carry all traffic; for terminal frames only, plain WS relaying suffices — no P2P/TURN needed.

---

## 3. Device identity: use a keypair, not a machine code (the biggest correction this round)

The first instinct for stable domains was "every machine has a machine code, use `hash(machineCode)` as the name." **Research into peers killed it** — serious projects use **no hardware machine code** for device/tunnel identity:

| Project | Stable identity | Machine code? |
|---|---|---|
| **Syncthing** | device ID = `base32(SHA-256(self-signed cert))`, proven via the TLS handshake | ❌ |
| **Tailscale** | curve25519 machine/node key; docs explicitly state it is **not hardware-based** | ❌ |
| **cloudflared / ngrok** | stable name bound to a **server-issued secret credential** (tunnel creds / authtoken) | ❌ |

**Why a keypair beats a machine code:**

1. **Identity and proof are unified**: the name is `hash(pubkey)` (public, doesn't matter), and ownership is self-proven by signing the relay's challenge with the private key. No separate owner_key field, no relay-side state (preimage resistance).
2. **identifier ≠ secret** (the classic security pitfall): a machine code is readable by any local process, and once `hash(machineCode)` is in the URL it is public — so it can **name** but cannot be the credential that "proves I am this machine." In licensing too, the machine code only identifies the seat; the authority comes from the server-signed license.
3. **Cross-platform is actually simpler**: keygen/signing is one pure-Rust path (`ed25519-dalek`), zero `#[cfg]` across platforms; a machine code means reading macOS `IOPlatformUUID` / Linux `/etc/machine-id` / Windows `MachineGuid` (three code paths) plus a fallback file in containers — strictly more complex.
4. **Privacy is clean**: no hardware fingerprint, dodging the GDPR/PECR "device fingerprinting without consent" landmine. Matters especially for an open-source project.

**A machine code isn't useless** — it survives config deletion / OS reinstall and is naturally one-per-machine, which **suits license seat counting** (is this the same physical machine?). But that and tunnel identity are **two orthogonal concerns; don't mix them**: seats use the machine code, tunnel identity uses the keypair (stored in macOS Keychain, which also survives reinstall).

> One-liner: naming can derive from anything, but **the ownership proof must be a key**; a machine code is an identifier, not a secret — leave it to seat counting.

---

## 4. Cross-platform machine identity (if you really must use a machine code)

If some place genuinely needs a machine fingerprint (e.g. seat counting), the standard cross-platform sources:

```
macOS    IOPlatformUUID        (ioreg -rd1 -c IOPlatformExpertDevice)
Linux    /etc/machine-id       (fallback /var/lib/dbus/machine-id)
Windows  HKLM\...\Cryptography\MachineGuid
```

- Use the `machine-uid` crate to hide the three-platform difference; don't hand-roll it (Windows needs winreg, macOS needs IOKit FFI).
- **Container / cloned-VM trap**: `/etc/machine-id` is often empty or identical → you must fall back: if unreadable, generate and persist a random UUID in the config dir.
- **Never send the raw machine code over the wire or into a URL** — only an **app-salted hash** (prevents cross-app correlation).
- Hardware IDs (MAC/CPU/BIOS) are unreliable in VMs; don't use them. OS-native UUID is the pick, always HMAC'd / salted.

> One-liner: a machine code means OS-native UUID + salted hash + container fallback, with one crate absorbing the three platforms.

---

## 5. How an open-source project makes a feature paid: "open the code, gate the service"

The requirement: stable domains only for paying users, but tunelo is MIT open source and the client binary is runnable by anyone.

**Iron rule: you cannot lock anything inside an open-source client.** `--stable`, keygen, signing are all open code that anyone can fork/patch; an `if paid` check in the client is bypassed by deleting one line.

**What is scarce and chargeable is not that code, but "your relay agreeing to grant it a stable name."** So the gate has exactly one home — **the relay requires a backend-issued entitlement token before granting a stable registration**:

```
Backend (holds an Ed25519 private key, reuses the Lemon Squeezy license backend)
  POST /relay-token → verify license/trial → sign { pubkey_hash, tier, exp≤1h }
client:  Register { owner_pubkey, auth_token }
relay :  verify sig (embedded public key) + check exp + token.pubkey_hash == hash(owner_pubkey) + the existing challenge self-proof
         all pass → grant stable name, else → fall back to random / UNAUTHORIZED
```

Points:

- **Embedding the public key in the open-source relay is safe** — the private key lives only in your backend; a fork still can't sign a valid token, so open-sourcing leaks nothing.
- **Bind the token to `pubkey_hash`**: even if a paying user extracts their own token, it's useless to others (no matching private key → fails the challenge). Short exp + per-account tunnel cap crush abuse; App Attest is overkill.
- **Don't cripple open-source tunnel in the process**: make the entitlement check a relay **config flag, off by default** (`--entitlement-key <pubkey>`). Self-hosters get stable names free out of the box; only your tunelo.net turns the flag on. **You only protect your own relay's bandwidth and paywall.**
- **Tiering**: free = random name + rate/tunnel-count limits; paid = stable name + unrestricted. Gate only stable registration, preserving tunelo's free value.
- This is exactly **ngrok's reserved-domain** model: the agent is free and open source; the reserved domain is paid, enforced server-side by the account/authtoken.

> One-liner: the chargeable point isn't client logic but **whether the server honors the token**; the token is issued only to paying users, bound to the identity pubkey, and verified by the relay's embedded public key — with the self-host flag off by default.

---

## Transferable principles (across topics)

1. **Look at how mature peers do it before you build** — this round's three decisions ("keypair vs machine code," "does a stable name need a central relay," "how to prevent freeloading") were all corrected against precedent from Syncthing/Tailscale/cloudflared/ngrok/TeamViewer.
2. **identifier ≠ secret**: naming/identification can be public; authorization/ownership must rest on a key or a server signature.
3. **Put the trust boundary on the end you control**: the client is untrusted (open source especially), so the enforcement point belongs on the server.
4. **Don't fight a platform's hard limits** (Apple sleep-wake, DNS quotas) — build the reliable 80% and mark the 20% unsupported, gracefully.
5. **Open source and monetization don't conflict**: open the code, gate the **service / hosted resource**; keep the self-host switch off by default and you keep both reputation and revenue.
