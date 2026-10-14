// vrx-manage's pieces, host-testable: the request parser and its checks,
// the JSON API's sources, the page's files, the update upload's checks.
// main.rs is the server.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]
#![deny(unsafe_code)]

pub mod api;
pub mod files;
pub mod http;
pub mod upload;
