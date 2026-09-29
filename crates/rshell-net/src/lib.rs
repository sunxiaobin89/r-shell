//! Connection primitives shared between the Tauri shell and a future GPUI
//! shell.
//!
//! This crate exists so both shells depend on the same code rather than a
//! copy of it. It holds only pieces with no dependency on the rest of the
//! backend: how to reach a host through a proxy, and how to expand `~/` in
//! a remote key path.
//!
//! Anything that needs the terminal grid, the session store, or Tauri
//! itself does not belong here — that coupling is exactly what this
//! extraction is meant to eliminate.

pub mod os_keypath;
pub mod proxy;
