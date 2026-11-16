//! The kernel of the DAW: the project model, the engine it drives, and the Lua
//! state that everything user-facing is written in.

pub mod api;
pub mod audio;
pub mod grid;
pub mod history;
pub mod io;
pub mod kernel;
pub mod measure;
pub mod model;
pub mod peaks;
pub mod remote;
pub mod resample;
pub mod rpc;
pub mod safe;
pub mod session;
pub mod sync;
pub mod tempo_api;
pub mod watchdog;

pub use kernel::{Frontend, InputEvent, Kernel, KernelMsg, KernelOpts};
