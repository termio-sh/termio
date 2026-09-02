//! Internal library for the `termiod` and `termio` binaries.
//!
//! Nothing here is a supported interface: every module is exported so the
//! binaries in `src/bin/` can share one implementation, and nothing carries
//! a stability promise. `publish = false` keeps the crate off the registry;
//! it does not stop a path dependency, so the visibility is convenience for
//! this repository, not a contract.
//!
//! One seam to respect when adding a binary: several paths assume the
//! current executable IS the daemon — `client::connect`'s auto-start spawns
//! `current_exe()` with `serve`, `lifecycle`'s handoff defaults to it,
//! `service` installs it, and `remote::shipped_binary()` deploys it to Mac
//! targets. A client binary must resolve the daemon binary explicitly
//! before reaching any of them.
//!
//! Dependency discipline (docker-lessons RFC §6): the runtime core — PTY
//! host, session lifecycle, framed protocol — must not import from the
//! planes (`files`, `git`, `resource`, `agent`). Planes may depend on the
//! core; the core compiles without them. If this ever needs teeth it becomes
//! a `termiod-core` crate boundary, the same move as `termiod-vt`.

pub mod agent;
pub mod api;
pub mod app_socket;
pub mod channel;
pub mod client;
pub mod daemon;
pub mod files;
pub mod git;
pub mod handoff;
pub mod id;
pub mod keep_awake;
pub mod lifecycle;
pub mod log;
pub mod paths;
pub mod proc;
pub mod protocol;
pub mod protocol_schema;
pub mod pty;
pub mod remote;
pub mod resource;
pub mod service;
pub mod session;
pub mod tombstone;
pub mod version;
pub mod wss;
