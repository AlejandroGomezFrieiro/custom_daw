//! A CLAP instrument for tests, built as `libstub_clap.so` by `cargo test
//! -p paw-plugins` (or `cargo build --example stub_clap`). It takes notes as
//! MIDI 2.0 (its preferred dialect), names two of its keys (`note-name`),
//! keeps the last note-on it was given for the test to read
//! (`stub_clap_last`), and while a note sounds puts out the note-on's
//! attribute: its type / 256 on the left, its subclass / 16 on the right.

use std::ffi::{CStr, c_char, c_void};
use std::sync::atomic::{AtomicU32, Ordering::Relaxed};

use clap_sys::entry::clap_plugin_entry;
use clap_sys::events::{CLAP_EVENT_MIDI2, clap_event_header, clap_event_midi2};
use clap_sys::ext::audio_ports::{
    CLAP_AUDIO_PORT_IS_MAIN, CLAP_EXT_AUDIO_PORTS, CLAP_PORT_STEREO, clap_audio_port_info,
    clap_plugin_audio_ports,
};
use clap_sys::ext::note_name::{CLAP_EXT_NOTE_NAME, clap_note_name, clap_plugin_note_name};
use clap_sys::ext::note_ports::{
    CLAP_EXT_NOTE_PORTS, CLAP_NOTE_DIALECT_CLAP, CLAP_NOTE_DIALECT_MIDI2, clap_note_port_info,
    clap_plugin_note_ports,
};
use clap_sys::factory::plugin_factory::{CLAP_PLUGIN_FACTORY_ID, clap_plugin_factory};
use clap_sys::host::clap_host;
use clap_sys::plugin::{clap_plugin, clap_plugin_descriptor};
use clap_sys::process::{CLAP_PROCESS_CONTINUE, clap_process, clap_process_status};
use clap_sys::version::CLAP_VERSION;

/// The two words of the last MIDI 2.0 note-on, and how many came.
static LAST: [AtomicU32; 2] = [AtomicU32::new(0), AtomicU32::new(0)];
static COUNT: AtomicU32 = AtomicU32::new(0);
/// The attribute of the note sounding (type above data), 0 for none.
static SOUNDING: AtomicU32 = AtomicU32::new(0);

/// For tests: the words of the last note-on into `out`; how many came.
///
/// # Safety
/// `out` points to two words.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stub_clap_last(out: *mut u32) -> u32 {
    unsafe {
        *out = LAST[0].load(Relaxed);
        *out.add(1) = LAST[1].load(Relaxed);
    }
    COUNT.load(Relaxed)
}

struct Desc(clap_plugin_descriptor);
unsafe impl Sync for Desc {}
struct Features([*const c_char; 2]);
unsafe impl Sync for Features {}

static FEATURES: Features = Features([c"instrument".as_ptr(), std::ptr::null()]);
static DESC: Desc = Desc(clap_plugin_descriptor {
    clap_version: CLAP_VERSION,
    id: c"dev.paw.stub".as_ptr(),
    name: c"Stub".as_ptr(),
    vendor: c"paw tests".as_ptr(),
    url: c"".as_ptr(),
    manual_url: c"".as_ptr(),
    support_url: c"".as_ptr(),
    version: c"1.0".as_ptr(),
    description: c"".as_ptr(),
    features: FEATURES.0.as_ptr(),
});

unsafe extern "C" fn init(_: *const clap_plugin) -> bool {
    true
}
unsafe extern "C" fn destroy(plugin: *const clap_plugin) {
    drop(unsafe { Box::from_raw(plugin as *mut clap_plugin) });
}
unsafe extern "C" fn activate(_: *const clap_plugin, _: f64, _: u32, _: u32) -> bool {
    true
}
unsafe extern "C" fn nothing(_: *const clap_plugin) {}
unsafe extern "C" fn start(_: *const clap_plugin) -> bool {
    true
}

unsafe extern "C" fn process(_: *const clap_plugin, p: *const clap_process) -> clap_process_status {
    unsafe {
        let p = &*p;
        let events = &*p.in_events;
        let n = events.size.unwrap()(p.in_events);
        for i in 0..n {
            let header: *const clap_event_header = events.get.unwrap()(p.in_events, i);
            if (*header).type_ != CLAP_EVENT_MIDI2 {
                continue;
            }
            let data = (*(header as *const clap_event_midi2)).data;
            match (data[0] >> 20) & 15 {
                0x9 => {
                    LAST[0].store(data[0], Relaxed);
                    LAST[1].store(data[1], Relaxed);
                    COUNT.fetch_add(1, Relaxed);
                    SOUNDING.store((data[0] & 0xff) << 16 | (data[1] & 0xffff), Relaxed);
                }
                0x8 => SOUNDING.store(0, Relaxed),
                _ => {}
            }
        }
        let attr = SOUNDING.load(Relaxed);
        let (left, right) = (
            (attr >> 16) as f32 / 256.0,
            ((attr >> 12) & 15) as f32 / 16.0,
        );
        if p.audio_outputs_count > 0 {
            let out = &*p.audio_outputs;
            for (ch, level) in [left, right]
                .into_iter()
                .enumerate()
                .take(out.channel_count as usize)
            {
                let buf =
                    std::slice::from_raw_parts_mut(*out.data32.add(ch), p.frames_count as usize);
                buf.fill(level);
            }
        }
    }
    CLAP_PROCESS_CONTINUE
}

unsafe extern "C" fn audio_count(_: *const clap_plugin, is_input: bool) -> u32 {
    if is_input { 0 } else { 1 }
}
unsafe extern "C" fn audio_get(
    _: *const clap_plugin,
    index: u32,
    is_input: bool,
    info: *mut clap_audio_port_info,
) -> bool {
    if is_input || index > 0 {
        return false;
    }
    unsafe {
        (*info).id = 0;
        (*info).flags = CLAP_AUDIO_PORT_IS_MAIN;
        (*info).channel_count = 2;
        (*info).port_type = CLAP_PORT_STEREO.as_ptr();
        (*info).in_place_pair = u32::MAX;
    }
    true
}
static AUDIO_PORTS: clap_plugin_audio_ports = clap_plugin_audio_ports {
    count: Some(audio_count),
    get: Some(audio_get),
};

unsafe extern "C" fn note_count(_: *const clap_plugin, is_input: bool) -> u32 {
    is_input as u32
}
unsafe extern "C" fn note_get(
    _: *const clap_plugin,
    index: u32,
    is_input: bool,
    info: *mut clap_note_port_info,
) -> bool {
    if !is_input || index > 0 {
        return false;
    }
    unsafe {
        (*info).id = 0;
        (*info).supported_dialects = CLAP_NOTE_DIALECT_CLAP | CLAP_NOTE_DIALECT_MIDI2;
        (*info).preferred_dialect = CLAP_NOTE_DIALECT_MIDI2;
    }
    true
}
static NOTE_PORTS: clap_plugin_note_ports = clap_plugin_note_ports {
    count: Some(note_count),
    get: Some(note_get),
};

const NAMES: [(i16, &CStr); 2] = [(24, c"Sustain"), (26, c"Staccato")];
unsafe extern "C" fn names_count(_: *const clap_plugin) -> u32 {
    NAMES.len() as u32
}
unsafe extern "C" fn names_get(
    _: *const clap_plugin,
    index: u32,
    name: *mut clap_note_name,
) -> bool {
    let Some((key, text)) = NAMES.get(index as usize) else {
        return false;
    };
    unsafe {
        let name = &mut *name;
        for (to, from) in name.name.iter_mut().zip(text.to_bytes_with_nul()) {
            *to = *from as c_char;
        }
        name.port = -1;
        name.channel = -1;
        name.key = *key;
    }
    true
}
static NOTE_NAMES: clap_plugin_note_name = clap_plugin_note_name {
    count: Some(names_count),
    get: Some(names_get),
};

unsafe extern "C" fn get_extension(_: *const clap_plugin, id: *const c_char) -> *const c_void {
    let id = unsafe { CStr::from_ptr(id) };
    if id == CLAP_EXT_AUDIO_PORTS {
        &AUDIO_PORTS as *const _ as *const c_void
    } else if id == CLAP_EXT_NOTE_PORTS {
        &NOTE_PORTS as *const _ as *const c_void
    } else if id == CLAP_EXT_NOTE_NAME {
        &NOTE_NAMES as *const _ as *const c_void
    } else {
        std::ptr::null()
    }
}

unsafe extern "C" fn plugin_count(_: *const clap_plugin_factory) -> u32 {
    1
}
unsafe extern "C" fn plugin_descriptor(
    _: *const clap_plugin_factory,
    index: u32,
) -> *const clap_plugin_descriptor {
    if index == 0 {
        &DESC.0
    } else {
        std::ptr::null()
    }
}
unsafe extern "C" fn create_plugin(
    _: *const clap_plugin_factory,
    _: *const clap_host,
    id: *const c_char,
) -> *const clap_plugin {
    if unsafe { CStr::from_ptr(id) } != c"dev.paw.stub" {
        return std::ptr::null();
    }
    Box::into_raw(Box::new(clap_plugin {
        desc: &DESC.0,
        plugin_data: std::ptr::null_mut(),
        init: Some(init),
        destroy: Some(destroy),
        activate: Some(activate),
        deactivate: Some(nothing),
        start_processing: Some(start),
        stop_processing: Some(nothing),
        reset: Some(nothing),
        process: Some(process),
        get_extension: Some(get_extension),
        on_main_thread: Some(nothing),
    }))
}
static FACTORY: clap_plugin_factory = clap_plugin_factory {
    get_plugin_count: Some(plugin_count),
    get_plugin_descriptor: Some(plugin_descriptor),
    create_plugin: Some(create_plugin),
};

unsafe extern "C" fn entry_init(_: *const c_char) -> bool {
    true
}
unsafe extern "C" fn entry_deinit() {}
unsafe extern "C" fn get_factory(id: *const c_char) -> *const c_void {
    if unsafe { CStr::from_ptr(id) } == CLAP_PLUGIN_FACTORY_ID {
        &FACTORY as *const _ as *const c_void
    } else {
        std::ptr::null()
    }
}

#[unsafe(no_mangle)]
#[allow(non_upper_case_globals)]
pub static clap_entry: clap_plugin_entry = clap_plugin_entry {
    clap_version: CLAP_VERSION,
    init: Some(entry_init),
    deinit: Some(entry_deinit),
    get_factory: Some(get_factory),
};
