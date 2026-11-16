//! MIDI output to hardware and other programs, through the ALSA sequencer.
//!
//! A track can send what it plays to a port. The audio thread makes no
//! system calls, so it stamps each message with when it is to be heard, on
//! the clock of [`clock_ns`], and pushes it into a lock-free queue. A thread
//! of its own reads the queue and hands each message to the sequencer,
//! scheduled on a sequencer queue at that time in real time: it leaves on
//! time however late the thread itself wakes. The audio is heard later than
//! it is made (the output's latency, and the delay that lines plugins up),
//! so the messages are stamped that much later too, and an instrument on
//! the port sounds together with the tracks.
//!
//! The thread remembers the notes it has sent on, and when a track stops or
//! jumps (an `AllNotesOff` from the engine) it ends them with note-offs and
//! an All Notes Off on each channel that had one.
//!
//! It can also make ports of its own that other programs read from
//! ([`MidiOutputs::open_port`]): what a track sends there goes to whoever
//! is subscribed, a synth in another program for one.

use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::Instant;

use anyhow::Result;
use rtrb::Consumer;

use crate::event::EventKind;
use crate::midi::PortInfo;

/// Messages that may wait between the audio thread and the sender.
pub const MIDI_OUT_CAPACITY: usize = 4096;

/// A message for a port: when it is to be heard, on [`clock_ns`]; the
/// port's [`port_key`](crate::midi::port_key); and the message, on the
/// channel it goes out on.
#[derive(Clone, Copy, Debug)]
pub struct MidiOut {
    pub at: u64,
    pub port: u32,
    pub kind: EventKind,
}

/// Nanoseconds on a clock shared by the audio thread and the sender: a
/// monotonic one, from the first time it is asked.
pub fn clock_ns() -> u64 {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    EPOCH.get_or_init(Instant::now).elapsed().as_nanos() as u64
}

/// The same message on another channel, from 0; as it is with `None`.
pub fn on_channel(kind: EventKind, ch: Option<u8>) -> EventKind {
    let Some(to) = ch else { return kind };
    match kind {
        EventKind::NoteOn { key, vel, .. } => EventKind::NoteOn { key, vel, ch: to },
        EventKind::NoteOff { key, .. } => EventKind::NoteOff { key, ch: to },
        EventKind::Control { ctl, value, .. } => EventKind::Control { ctl, value, ch: to },
        EventKind::NoteControl {
            key, ctl, value, ..
        } => EventKind::NoteControl {
            key,
            ctl,
            value,
            ch: to,
        },
        EventKind::Program { program, bank, .. } => EventKind::Program {
            program,
            bank,
            ch: to,
        },
        EventKind::AllNotesOff => EventKind::AllNotesOff,
    }
}

enum Command {
    /// Read messages from this queue from now on: a new engine's.
    Queue(Consumer<MidiOut>),
    /// Make a port of our own for others to read, or take it away.
    Open(String),
    Close(String),
    Stop,
}

/// The running MIDI output thread. Dropping it ends every note it started.
pub struct MidiOutputs {
    ports: Arc<Mutex<Vec<PortInfo>>>,
    commands: Sender<Command>,
    thread: Option<JoinHandle<()>>,
}

impl MidiOutputs {
    pub fn start() -> Result<Self> {
        let ports = Arc::new(Mutex::new(Vec::new()));
        let (commands, rx) = channel();
        let thread = imp::start(ports.clone(), rx)?;
        Ok(Self {
            ports,
            commands,
            thread: Some(thread),
        })
    }

    /// Every port that can be sent MIDI, and ours that others read from
    /// (`own`).
    pub fn ports(&self) -> Vec<PortInfo> {
        self.ports.lock().map(|p| p.clone()).unwrap_or_default()
    }

    /// Send what arrives in this queue: the one an engine fills (see
    /// [`EngineHandle::midi_output`](crate::EngineHandle::midi_output)).
    pub fn set_queue(&self, queue: Consumer<MidiOut>) {
        let _ = self.commands.send(Command::Queue(queue));
    }

    /// Make a port of this program's that other programs read MIDI from,
    /// shown to them as `daw out: <name>`; tracks send to it by `name`.
    pub fn open_port(&self, name: &str) {
        let _ = self.commands.send(Command::Open(name.to_string()));
    }

    /// Take away a port made by `open_port`, ending the notes sent there.
    pub fn close_port(&self, name: &str) {
        let _ = self.commands.send(Command::Close(name.to_string()));
    }
}

impl Drop for MidiOutputs {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(feature = "midi")]
mod imp {
    use std::collections::HashMap;
    use std::ffi::{CStr, CString, c_int};
    use std::time::Duration;

    use alsa_sys::*;

    use super::*;
    use crate::midi::port_key;
    use crate::ump;

    const OPEN_OUTPUT: c_int = 1;
    const CAP_READ: u32 = 1 << 0;
    const CAP_WRITE: u32 = 1 << 1;
    const CAP_SUBS_READ: u32 = 1 << 5;
    const CAP_SUBS_WRITE: u32 = 1 << 6;
    const CAP_NO_EXPORT: u32 = 1 << 7;
    const TYPE_MIDI_GENERIC: u32 = 1 << 1;
    const TYPE_APPLICATION: u32 = 1 << 20;
    const SYSTEM_CLIENT: c_int = 0;
    /// Sent at once rather than through a queue.
    const QUEUE_DIRECT: u8 = 253;
    /// The destination that stands for every subscriber of the source.
    const SUBSCRIBERS: u8 = 254;
    const UNKNOWN: u8 = 253;
    /// A time stamp in real time, from the queue's start.
    const TIME_STAMP_REAL: u8 = 1;
    /// How often the list of ports is read again.
    const REFRESH: Duration = Duration::from_secs(1);
    /// The catch-all input of this program's MIDI input, which would send
    /// what it is sent straight back to the tracks that send it.
    const OWN_INPUT: &str = "daw: input";

    type Addr = (i32, i32);

    struct Seq(*mut snd_seq_t);

    // The handle is used by the one thread that owns the client.
    unsafe impl Send for Seq {}

    impl Drop for Seq {
        fn drop(&mut self) {
            unsafe {
                snd_seq_close(self.0);
            }
        }
    }

    fn check(code: c_int, what: &str) -> Result<c_int> {
        if code < 0 {
            anyhow::bail!("{what}: ALSA error {code}");
        }
        Ok(code)
    }

    pub fn start(
        ports: Arc<Mutex<Vec<PortInfo>>>,
        rx: Receiver<Command>,
    ) -> Result<JoinHandle<()>> {
        let mut client = unsafe {
            let mut handle = std::ptr::null_mut();
            check(
                snd_seq_open(&mut handle, c"default".as_ptr(), OPEN_OUTPUT, 0),
                "opening the sequencer",
            )?;
            let seq = Seq(handle);
            check(
                snd_seq_set_client_name(seq.0, c"daw out".as_ptr()),
                "naming the client",
            )?;
            let port = check(
                snd_seq_create_simple_port(
                    seq.0,
                    c"output".as_ptr(),
                    CAP_READ,
                    TYPE_MIDI_GENERIC | TYPE_APPLICATION,
                ),
                "making the output port",
            )?;
            let queue = check(
                snd_seq_alloc_named_queue(seq.0, c"daw".as_ptr()),
                "making a queue",
            )?;
            check(
                snd_seq_control_queue(
                    seq.0,
                    queue,
                    SND_SEQ_EVENT_START as c_int,
                    0,
                    std::ptr::null_mut(),
                ),
                "starting the queue",
            )?;
            snd_seq_drain_output(seq.0);
            Client {
                me: check(snd_seq_client_id(seq.0), "asking the client's id")?,
                seq,
                port,
                queue,
                started: clock_ns(),
                rx: None,
                own: Vec::new(),
                dests: HashMap::new(),
                held: HashMap::new(),
                ports,
                refreshed: None,
            }
        };
        client.refresh();
        let thread = std::thread::Builder::new()
            .name("daw-midi-out".into())
            .spawn(move || client.run(rx))?;
        Ok(thread)
    }

    struct Client {
        seq: Seq,
        me: i32,
        /// The port messages to other programs' ports are sent from.
        port: i32,
        queue: c_int,
        /// When the queue started, on [`clock_ns`].
        started: u64,
        rx: Option<Consumer<MidiOut>>,
        /// Ports of our own that others read from: number and name.
        own: Vec<(i32, String)>,
        /// Other programs' ports, by key.
        dests: HashMap<u32, Addr>,
        /// Notes on, by port key and channel.
        held: HashMap<u32, [u128; 16]>,
        ports: Arc<Mutex<Vec<PortInfo>>>,
        refreshed: Option<Instant>,
    }

    impl Client {
        fn run(mut self, rx: Receiver<Command>) {
            loop {
                while let Ok(command) = rx.try_recv() {
                    match command {
                        Command::Queue(queue) => self.rx = Some(queue),
                        Command::Open(name) => self.open_own(name),
                        Command::Close(name) => self.close_own(&name),
                        Command::Stop => {
                            let keys: Vec<u32> = self.held.keys().copied().collect();
                            for key in keys {
                                self.release(key, None);
                            }
                            unsafe {
                                snd_seq_drain_output(self.seq.0);
                            }
                            return;
                        }
                    }
                }
                if self.refreshed.is_none_or(|at| at.elapsed() >= REFRESH) {
                    self.refresh();
                }
                let mut sent = false;
                while let Some(message) = self.rx.as_mut().and_then(|rx| rx.pop().ok()) {
                    self.send(message);
                    sent = true;
                }
                if sent {
                    unsafe {
                        snd_seq_drain_output(self.seq.0);
                    }
                }
                std::thread::sleep(Duration::from_millis(1));
            }
        }

        /// Where a port's messages go from, and to: one of ours sends to its
        /// subscribers, another program's is sent to from our output port.
        fn route(&self, key: u32) -> Option<(i32, (u8, u8))> {
            if let Some((port, _)) = self.own.iter().find(|(_, name)| port_key(name) == key) {
                return Some((*port, (SUBSCRIBERS, UNKNOWN)));
            }
            let (client, port) = *self.dests.get(&key)?;
            Some((self.port, (client as u8, port as u8)))
        }

        fn send(&mut self, message: MidiOut) {
            let Some(route) = self.route(message.port) else {
                return;
            };
            let held = self.held.entry(message.port).or_insert([0; 16]);
            match message.kind {
                EventKind::AllNotesOff => return self.release(message.port, Some(message.at)),
                EventKind::NoteOn { key, ch, .. } => held[(ch & 15) as usize] |= 1 << (key & 127),
                EventKind::NoteOff { key, ch } => held[(ch & 15) as usize] &= !(1 << (key & 127)),
                _ => {}
            }
            ump::midi1(message.kind, |bytes, _| {
                self.output(route, bytes, Some(message.at))
            });
        }

        /// End every note held on a port, at a time or now, with an All
        /// Notes Off on each channel that had one.
        fn release(&mut self, key: u32, at: Option<u64>) {
            let Some(route) = self.route(key) else {
                self.held.remove(&key);
                return;
            };
            let Some(held) = self.held.get_mut(&key) else {
                return;
            };
            let held = std::mem::replace(held, [0; 16]);
            for (ch, mut keys) in held.into_iter().enumerate() {
                if keys == 0 {
                    continue;
                }
                while keys != 0 {
                    let note = keys.trailing_zeros() as u8;
                    keys &= !(1 << note);
                    self.output(route, [0x80 | ch as u8, note, 0], at);
                }
                self.output(route, [0xB0 | ch as u8, 123, 0], at);
            }
        }

        /// Put one MIDI 1.0 message out, scheduled at `at` on [`clock_ns`]
        /// when that is still to come, else at once.
        fn output(&self, (source, dest): (i32, (u8, u8)), bytes: [u8; 3], at: Option<u64>) {
            unsafe {
                let mut ev: snd_seq_event_t = std::mem::zeroed();
                let ch = bytes[0] & 15;
                let (type_, data) = match bytes[0] & 0xF0 {
                    0x90 => (SND_SEQ_EVENT_NOTEON, note(ch, bytes[1], bytes[2])),
                    0x80 => (SND_SEQ_EVENT_NOTEOFF, note(ch, bytes[1], 0)),
                    0xA0 => (SND_SEQ_EVENT_KEYPRESS, note(ch, bytes[1], bytes[2])),
                    0xB0 => (
                        SND_SEQ_EVENT_CONTROLLER,
                        control(ch, bytes[1] as u32, bytes[2] as i32),
                    ),
                    0xC0 => (SND_SEQ_EVENT_PGMCHANGE, control(ch, 0, bytes[1] as i32)),
                    0xD0 => (SND_SEQ_EVENT_CHANPRESS, control(ch, 0, bytes[1] as i32)),
                    0xE0 => (
                        SND_SEQ_EVENT_PITCHBEND,
                        control(ch, 0, (bytes[1] as i32 | (bytes[2] as i32) << 7) - 8192),
                    ),
                    _ => return,
                };
                ev.type_ = type_ as u8;
                ev.data = data;
                ev.source.port = source as u8;
                ev.dest.client = dest.0;
                ev.dest.port = dest.1;
                match at.filter(|at| *at > clock_ns()) {
                    Some(at) => {
                        let from_start = at.saturating_sub(self.started);
                        ev.queue = self.queue as u8;
                        ev.flags = TIME_STAMP_REAL;
                        ev.time.time.tv_sec = (from_start / 1_000_000_000) as u32;
                        ev.time.time.tv_nsec = (from_start % 1_000_000_000) as u32;
                    }
                    None => ev.queue = QUEUE_DIRECT,
                }
                snd_seq_event_output(self.seq.0, &mut ev);
            }
        }

        fn open_own(&mut self, name: String) {
            if self.own.iter().any(|(_, known)| *known == name) {
                return;
            }
            let Ok(text) = CString::new(name.as_str()) else {
                return;
            };
            let port = unsafe {
                snd_seq_create_simple_port(
                    self.seq.0,
                    text.as_ptr(),
                    CAP_READ | CAP_SUBS_READ,
                    TYPE_MIDI_GENERIC | TYPE_APPLICATION,
                )
            };
            if port >= 0 {
                self.own.push((port, name));
                self.refresh();
            }
        }

        fn close_own(&mut self, name: &str) {
            let Some(at) = self.own.iter().position(|(_, known)| known == name) else {
                return;
            };
            self.release(port_key(name), None);
            unsafe {
                snd_seq_drain_output(self.seq.0);
            }
            let (port, _) = self.own.remove(at);
            unsafe {
                snd_seq_delete_simple_port(self.seq.0, port);
            }
            self.refresh();
        }

        /// List the ports that can be written to now, and ours.
        fn refresh(&mut self) {
            self.refreshed = Some(Instant::now());
            let mut found = Vec::new();
            let text = |ptr: *const std::ffi::c_char| {
                if ptr.is_null() {
                    "?".to_string()
                } else {
                    unsafe { CStr::from_ptr(ptr) }
                        .to_string_lossy()
                        .into_owned()
                }
            };
            unsafe {
                let mut client = std::ptr::null_mut();
                let mut port = std::ptr::null_mut();
                if snd_seq_client_info_malloc(&mut client) < 0 {
                    return;
                }
                if snd_seq_port_info_malloc(&mut port) < 0 {
                    snd_seq_client_info_free(client);
                    return;
                }
                snd_seq_client_info_set_client(client, -1);
                while snd_seq_query_next_client(self.seq.0, client) >= 0 {
                    let id = snd_seq_client_info_get_client(client);
                    if id == SYSTEM_CLIENT || id == self.me {
                        continue;
                    }
                    let client_name = text(snd_seq_client_info_get_name(client));
                    snd_seq_port_info_set_client(port, id);
                    snd_seq_port_info_set_port(port, -1);
                    while snd_seq_query_next_port(self.seq.0, port) >= 0 {
                        let caps = snd_seq_port_info_get_capability(port);
                        let writable = CAP_WRITE | CAP_SUBS_WRITE;
                        if caps & writable != writable || caps & CAP_NO_EXPORT != 0 {
                            continue;
                        }
                        let name = format!(
                            "{client_name}: {}",
                            text(snd_seq_port_info_get_name(port))
                        );
                        if name == OWN_INPUT {
                            continue;
                        }
                        found.push(((id, snd_seq_port_info_get_port(port)), name));
                    }
                }
                snd_seq_port_info_free(port);
                snd_seq_client_info_free(client);
            }
            self.dests = found
                .iter()
                .map(|(addr, name)| (port_key(name), *addr))
                .collect();
            if let Ok(mut ports) = self.ports.lock() {
                *ports = found
                    .into_iter()
                    .map(|((client, port), name)| PortInfo {
                        id: format!("{client}:{port}"),
                        name,
                        open: true,
                        own: false,
                    })
                    .chain(self.own.iter().map(|(port, name)| PortInfo {
                        id: format!("{}:{port}", self.me),
                        name: name.clone(),
                        open: true,
                        own: true,
                    }))
                    .collect();
            }
        }
    }

    fn note(channel: u8, note: u8, velocity: u8) -> snd_seq_event_data_t {
        let mut data: snd_seq_event_data_t = unsafe { std::mem::zeroed() };
        data.note = snd_seq_ev_note_t {
            channel,
            note,
            velocity,
            off_velocity: 0,
            duration: 0,
        };
        data
    }

    fn control(channel: u8, param: u32, value: i32) -> snd_seq_event_data_t {
        let mut data: snd_seq_event_data_t = unsafe { std::mem::zeroed() };
        data.control = snd_seq_ev_ctrl_t {
            channel,
            unused: [0; 3],
            param,
            value,
        };
        data
    }
}

#[cfg(not(feature = "midi"))]
mod imp {
    use super::*;

    pub fn start(
        _ports: Arc<Mutex<Vec<PortInfo>>>,
        _rx: Receiver<Command>,
    ) -> Result<JoinHandle<()>> {
        anyhow::bail!("built without MIDI support")
    }
}
