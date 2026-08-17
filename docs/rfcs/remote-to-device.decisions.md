---
title: Device RFC blocking decisions
status: draft
type: rfc
created: 2026-08-16
updated: 2026-08-16
---

# Device RFC blocking decisions

> Resolve Settings ownership and foreground-job parity before implementation begins.

## 1. Devices and SSH coexist

**Decision.** Choose **(b)**. `Settings ▸ SSH` owns routes: anything meaningful before `hello_ok`, keyed by an SSH alias, or affecting how OpenSSH resolves and authenticates a connection. `Settings ▸ Devices` owns identities: anything learned after `hello_ok`, keyed by `host_id`, or describing termiod, device lifecycle, and device preferences. Therefore alias reachability stays in SSH; post-handshake device health stays in Devices. A value is never persisted in both places.

**Add Host.** Remove it. `Settings ▸ SSH` remains a read-only projection of OpenSSH's authority plus termio's ephemeral probes. “Open SSH Config” remains the route for adding or changing hosts; termio must not append a `Host` block itself.

**Strongest argument.** An alias can exist before any device is known, and one `host_id` can be reached through several aliases. A single Devices list must either invent device rows for unresolved routes or hide a second route model inside each device; both recreate the two-copies problem under one tab.

**Strongest argument against, accepted.** Two tabs can look like competing machine lists and make users learn the route/identity distinction. The explicit key rule, distinct status labels, and no duplicated persistence are the price of keeping the underlying models honest.

**Cost.** Retain the shipped SSH list, probing, and config-opening action; delete the Add Host writer; add the Devices tab; distinguish route reachability from device health in copy and state; cross-link aliases and learned devices without duplicating either record.

## 2. Foreground-job parity belongs to this RFC

**Decision.** Port `hasForegroundJob` across the wire as a prerequisite to deleting the in-process PTY fork. It may land as a focused implementation change, but it is not a separate product or protocol decision. Make it an optional additive field on the existing session information payload; that does not require a `proto` bump under the protocol's versioning rule.

**Strongest argument.** Removing the local PTY path without this field removes a shipped safety behavior from every local session, not merely from a remote edge case. That regression is caused by this RFC's convergence step, so the RFC must own and gate on its remedy.

**Strongest argument against, accepted.** This expands a vocabulary and UI RFC into a shipped Rust/Swift protocol change with version-skew and race semantics. Accept that scope because separating the patch does not remove the dependency; it only makes the convergence plan falsely claim parity.

**Cost.** Compute the foreground-process-group state in termiod, expose and decode the optional field, obtain fresh enough state when closing, route `closeConfirmationReason` through the daemon-backed session model, and test old-client/new-daemon and new-client/old-daemon combinations. An older daemon's absent field preserves today's no-confirm behavior; it must not trigger a blanket confirmation.

The decisions do not otherwise depend on each other. The ownership rule merely confirms that foreground-job state belongs to the termiod session model, not to SSH settings; foreground-job parity independently gates removal of the local execution fork.
