//! The plugin as a host sees it: made through its entry, an instrument
//! loaded with preset-load, notes sent as MIDI 2.0 packets with their
//! attribute, key names, the state, and paw's `describe`.

use clap_sys::events::*;
use clap_sys::ext::note_name::*;
use clap_sys::ext::note_ports::*;
use clap_sys::ext::preset_load::*;
use clap_sys::ext::state::*;
use clap_sys::factory::plugin_factory::*;
use clap_sys::factory::preset_discovery::CLAP_PRESET_DISCOVERY_LOCATION_FILE;
use clap_sys::host::clap_host;
use clap_sys::plugin::clap_plugin;
use clap_sys::process::*;
use clap_sys::stream::*;
use clap_sys::version::CLAP_VERSION;
use clap_sys::audio_buffer::clap_audio_buffer;
use paw_sampler::plugin::{PAW_EXT_CALL, clap_entry, paw_plugin_call};
use std::ffi::{CStr, CString, c_char, c_void};
use std::ptr::{null, null_mut};

unsafe extern "C" fn no_extension(_: *const clap_host, _: *const c_char) -> *const c_void {
    null()
}
unsafe extern "C" fn nothing(_: *const clap_host) {}

static HOST: clap_host = clap_host {
    clap_version: CLAP_VERSION,
    host_data: null_mut(),
    name: c"test".as_ptr(),
    vendor: c"".as_ptr(),
    url: c"".as_ptr(),
    version: c"0".as_ptr(),
    get_extension: Some(no_extension),
    request_restart: Some(nothing),
    request_process: Some(nothing),
    request_callback: Some(nothing),
};

struct Plugin(*const clap_plugin);

impl Plugin {
    fn new() -> Plugin {
        unsafe {
            assert!(clap_entry.init.unwrap()(c"".as_ptr()));
            let factory = clap_entry.get_factory.unwrap()(CLAP_PLUGIN_FACTORY_ID.as_ptr()) as *const clap_plugin_factory;
            assert_eq!((*factory).get_plugin_count.unwrap()(factory), 1);
            let desc = (*factory).get_plugin_descriptor.unwrap()(factory, 0);
            assert_eq!(CStr::from_ptr((*desc).id), c"dev.paw.sampler");
            let plugin = (*factory).create_plugin.unwrap()(factory, &HOST, (*desc).id);
            assert!((*plugin).init.unwrap()(plugin));
            Plugin(plugin)
        }
    }

    fn ext<T>(&self, id: &CStr) -> &T {
        unsafe { &*((*self.0).get_extension.unwrap()(self.0, id.as_ptr()) as *const T) }
    }

    fn load(&self, path: &std::path::Path) -> bool {
        let ext: &clap_plugin_preset_load = self.ext(CLAP_EXT_PRESET_LOAD);
        let path = CString::new(path.to_str().unwrap()).unwrap();
        unsafe { ext.from_location.unwrap()(self.0, CLAP_PRESET_DISCOVERY_LOCATION_FILE, path.as_ptr(), null()) }
    }

    fn call(&self, method: &CStr) -> (bool, String) {
        unsafe extern "C" fn write(out: *mut c_void, data: *const u8, size: usize) {
            unsafe { (*(out as *mut Vec<u8>)).extend_from_slice(std::slice::from_raw_parts(data, size)) };
        }
        let ext: &paw_plugin_call = self.ext(PAW_EXT_CALL);
        let mut out = Vec::<u8>::new();
        let ok = unsafe { ext.call.unwrap()(self.0, method.as_ptr(), null(), 0, &mut out as *mut _ as *mut c_void, Some(write)) };
        (ok, String::from_utf8(out).unwrap())
    }

    /// Processes one block with these MIDI 2.0 packets (frame, two words).
    fn process(&self, frames: usize, packets: &[(u32, u32, u32)]) -> Vec<f32> {
        let mut events: Vec<clap_event_midi2> = packets
            .iter()
            .map(|&(time, w0, w1)| clap_event_midi2 {
                header: clap_event_header {
                    size: std::mem::size_of::<clap_event_midi2>() as u32,
                    time,
                    space_id: CLAP_CORE_EVENT_SPACE_ID,
                    type_: CLAP_EVENT_MIDI2,
                    flags: 0,
                },
                port_index: 0,
                data: [w0, w1, 0, 0],
            })
            .collect();
        unsafe extern "C" fn size(list: *const clap_input_events) -> u32 {
            unsafe { (*((*list).ctx as *const Vec<clap_event_midi2>)).len() as u32 }
        }
        unsafe extern "C" fn get(list: *const clap_input_events, i: u32) -> *const clap_event_header {
            unsafe { &(&*((*list).ctx as *const Vec<clap_event_midi2>))[i as usize].header }
        }
        let input = clap_input_events { ctx: &mut events as *mut _ as *mut c_void, size: Some(size), get: Some(get) };
        let (mut left, mut right) = (vec![0.0f32; frames], vec![0.0f32; frames]);
        let mut channels = [left.as_mut_ptr(), right.as_mut_ptr()];
        let mut out = clap_audio_buffer {
            data32: channels.as_mut_ptr(),
            data64: null_mut(),
            channel_count: 2,
            latency: 0,
            constant_mask: 0,
        };
        let process = clap_process {
            steady_time: -1,
            frames_count: frames as u32,
            transport: null(),
            audio_inputs: null(),
            audio_outputs: &mut out,
            audio_inputs_count: 0,
            audio_outputs_count: 1,
            in_events: &input,
            out_events: null(),
        };
        unsafe { assert_eq!((*self.0).process.unwrap()(self.0, &process), CLAP_PROCESS_CONTINUE) };
        left
    }
}

impl Drop for Plugin {
    fn drop(&mut self) {
        unsafe {
            (*self.0).deactivate.unwrap()(self.0);
            (*self.0).destroy.unwrap()(self.0);
        }
    }
}

fn fixtures(test: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("paw-sampler-clap-{}-{test}", std::process::id()));
    paw_sampler::fixtures::write(&dir).unwrap();
    dir
}

/// A MIDI 2.0 note-on: group 0, channel 0, velocity, attribute type and data.
fn note_on(key: u8, vel: u16, attr_type: u8, attr: u16) -> (u32, u32) {
    (0x4090_0000 | (key as u32) << 8 | attr_type as u32, (vel as u32) << 16 | attr as u32)
}

fn note_off(key: u8) -> (u32, u32) {
    (0x4080_0000 | (key as u32) << 8, 0)
}

fn crossings(x: &[f32]) -> usize {
    x.windows(2).filter(|w| w[0] < 0.0 && w[1] >= 0.0).count()
}

#[test]
fn notes_arrive_as_midi2_with_their_attribute() {
    let dir = fixtures("midi2");
    let p = Plugin::new();
    let ports: &clap_plugin_note_ports = p.ext(CLAP_EXT_NOTE_PORTS);
    let mut info: clap_note_port_info = unsafe { std::mem::zeroed() };
    unsafe { assert!(ports.get.unwrap()(p.0, 0, true, &mut info)) };
    assert_eq!(info.preferred_dialect, CLAP_NOTE_DIALECT_MIDI2);
    assert_eq!(info.supported_dialects & CLAP_NOTE_DIALECT_CLAP, 0, "CLAP notes would lose the attribute");

    assert!(p.load(&dir.join("ks.sfz")));
    unsafe { assert!((*p.0).activate.unwrap()(p.0, 48000.0, 1, 4800)) };
    // A second of staccato (11.0) by attribute: 660 Hz.
    let (w0, w1) = note_on(69, 0xC000, 0x11, 0x0000);
    let x = p.process(4800, &[(0, w0, w1)]);
    let heard = crossings(&x[480..]) as f64 / (4320.0 / 48000.0);
    assert!((heard - 660.0).abs() < 25.0, "staccato by attribute: {heard} Hz");
    let (w0, w1) = note_off(69);
    p.process(4800, &[(0, w0, w1)]);
    // Without an attribute: the default, 440 Hz.
    let (w0, w1) = note_on(69, 0xC000, 0, 0);
    let x = p.process(4800, &[(0, w0, w1)]);
    let heard = crossings(&x[480..]) as f64 / (4320.0 / 48000.0);
    assert!((heard - 440.0).abs() < 25.0, "the default: {heard} Hz");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn keyswitches_are_named_and_described() {
    let dir = fixtures("names");
    let p = Plugin::new();
    assert!(p.load(&dir.join("ks.sfz")));
    let names: &clap_plugin_note_name = p.ext(CLAP_EXT_NOTE_NAME);
    unsafe {
        assert_eq!(names.count.unwrap()(p.0), 2);
        let mut n: clap_note_name = std::mem::zeroed();
        assert!(names.get.unwrap()(p.0, 1, &mut n));
        assert_eq!((n.key, CStr::from_ptr(n.name.as_ptr()).to_str().unwrap()), (25, "Staccato"));
    }
    let (ok, json) = p.call(c"describe");
    assert!(ok);
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(v["format"], "sfz");
    assert_eq!(v["range"], serde_json::json!([48, 96]));
    assert_eq!(v["keyswitches"], serde_json::json!([{ "pitch": 24, "name": "Sustain" }, { "pitch": 25, "name": "Staccato" }]));
    assert_eq!(v["articulations"][1]["m2"], "11.0");
    assert_eq!(v["articulations"][0]["default"], true);
    assert_eq!(v["params"][0]["key"], "gain");
    let (ok, why) = p.call(c"frobnicate");
    assert!(!ok && why.contains("frobnicate"));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_state_keeps_the_instrument_and_the_parameters() {
    let dir = fixtures("state");
    let p = Plugin::new();
    assert!(p.load(&dir.join("rr.dspreset")));
    let state: &clap_plugin_state = p.ext(CLAP_EXT_STATE);
    unsafe extern "C" fn write(s: *const clap_ostream, data: *const c_void, size: u64) -> i64 {
        unsafe { (*((*s).ctx as *mut Vec<u8>)).extend_from_slice(std::slice::from_raw_parts(data as *const u8, size as usize)) };
        size as i64
    }
    let mut saved = Vec::<u8>::new();
    let out = clap_ostream { ctx: &mut saved as *mut _ as *mut c_void, write: Some(write) };
    unsafe { assert!(state.save.unwrap()(p.0, &out)) };
    let text = String::from_utf8(saved.clone()).unwrap();
    assert!(text.contains("rr.dspreset") && text.contains("\"polyphony\":128"), "{text}");

    let q = Plugin::new();
    unsafe extern "C" fn read(s: *const clap_istream, buffer: *mut c_void, size: u64) -> i64 {
        unsafe {
            let (data, at) = &mut *((*s).ctx as *mut (Vec<u8>, usize));
            let n = (data.len() - *at).min(size as usize);
            std::ptr::copy_nonoverlapping(data[*at..].as_ptr(), buffer as *mut u8, n);
            *at += n;
            n as i64
        }
    }
    let mut source = (saved, 0usize);
    let input = clap_istream { ctx: &mut source as *mut _ as *mut c_void, read: Some(read) };
    let state: &clap_plugin_state = q.ext(CLAP_EXT_STATE);
    unsafe { assert!(state.load.unwrap()(q.0, &input)) };
    let (_, json) = q.call(c"describe");
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!((v["format"].as_str(), v["round_robin"].as_u64()), (Some("dspreset"), Some(3)));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_missing_instrument_is_reported_and_kept() {
    let p = Plugin::new();
    assert!(!p.load(std::path::Path::new("/nowhere/strings.sfz")));
    let (_, json) = p.call(c"describe");
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(v["path"], "/nowhere/strings.sfz");
    assert!(v["error"].as_str().unwrap().contains("strings.sfz"));
}
