//! What a device takes and gives besides its main stereo pair: whether it
//! listens to a side-chain, as the running instance says.

use daw_engine::Ports;
use serde_json::{Value, json};

use super::Session;
use crate::model::Id;

impl Session {
    /// The ports of a device as it runs; none known for one that is not
    /// running (not made yet, offline, or missing).
    pub fn device_ports(&self, id: Id) -> Ports {
        self.live
            .get(&id)
            .and_then(|live| live.controller.as_ref())
            .map(|controller| controller.ports())
            .unwrap_or_default()
    }
}

pub fn ports_json(ports: &Ports) -> Value {
    json!({ "sidechain": ports.sidechain })
}
