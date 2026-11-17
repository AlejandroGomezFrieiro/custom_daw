//! Files sent over a connection from the machine a client runs on, into
//! the project's media folder on the instance's, in pieces:
//!
//!   file.begin  { "name": "take.wav", "size": 123456 }  -> upload id
//!   file.chunk  id, "base64…"                             -> bytes so far
//!   file.end    id                                        -> the file's path here
//!
//! What has not ended when the connection closes (or `file.abort` says so)
//! is thrown away. The file is written beside its final name and only
//! takes that name once it is whole, so a half sent file is never imported.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use base64::Engine;
use serde_json::{Value, json};

use crate::rpc::ClientId;

/// The largest file taken: more than any sound file a project holds.
const MAX_SIZE: u64 = 8 << 30;

struct Upload {
    client: ClientId,
    file: std::fs::File,
    /// Where it is written, and the name it takes when whole.
    part: PathBuf,
    path: PathBuf,
    size: u64,
    written: u64,
}

#[derive(Default)]
pub struct Uploads {
    open: HashMap<u64, Upload>,
    next: u64,
}

/// A name for a file from somewhere else: its last part, without anything
/// that would make it a path or hidden.
fn plain_name(name: &str) -> Option<String> {
    let last = name.rsplit(['/', '\\']).next()?.trim();
    let clean: String = last
        .chars()
        .map(|c| if c.is_control() { '_' } else { c })
        .collect();
    let clean = clean.trim_start_matches('.').to_string();
    (!clean.is_empty()).then_some(clean)
}

/// `dir/name`, or `dir/stem-2.ext` and so on when that is taken.
fn free_path(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => (stem, format!(".{ext}")),
        _ => (name, String::new()),
    };
    (2..)
        .map(|n| dir.join(format!("{stem}-{n}{ext}")))
        .find(|path| !path.exists())
        .unwrap_or(first)
}

impl Uploads {
    /// Answer one of the `file.*` calls from `client`; files go into `dir`.
    pub fn call(&mut self, client: ClientId, method: &str, params: &Value, dir: &Path) -> Result<Value, String> {
        let id_of = |value: &Value| value.as_u64().ok_or_else(|| "which upload? its id first".to_string());
        match method {
            "file.begin" => {
                let opts = &params[0];
                let name = opts["name"].as_str().and_then(plain_name).ok_or("the file needs a name")?;
                let size = opts["size"].as_u64().ok_or("the file needs its size in bytes")?;
                if size > MAX_SIZE {
                    return Err(format!("{name} is too big to send: {size} bytes"));
                }
                std::fs::create_dir_all(dir).map_err(|err| format!("creating {}: {err}", dir.display()))?;
                let path = free_path(dir, &name);
                self.next += 1;
                let part = dir.join(format!(".{name}.{}-{}.part", std::process::id(), self.next));
                let file = std::fs::File::create(&part).map_err(|err| format!("writing {}: {err}", part.display()))?;
                self.open.insert(self.next, Upload { client, file, part, path, size, written: 0 });
                Ok(json!(self.next))
            }
            "file.chunk" => {
                let id = id_of(&params[0])?;
                let upload = self.open.get_mut(&id).filter(|u| u.client == client).ok_or("no such upload")?;
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(params[1].as_str().unwrap_or_default())
                    .map_err(|err| format!("not base64: {err}"))?;
                if upload.written + bytes.len() as u64 > upload.size {
                    let gone = self.open.remove(&id);
                    if let Some(gone) = gone {
                        let _ = std::fs::remove_file(&gone.part);
                    }
                    return Err("more was sent than the file's size".into());
                }
                upload.file.write_all(&bytes).map_err(|err| format!("writing {}: {err}", upload.part.display()))?;
                upload.written += bytes.len() as u64;
                Ok(json!(upload.written))
            }
            "file.end" => {
                let id = id_of(&params[0])?;
                if !self.open.get(&id).is_some_and(|u| u.client == client) {
                    return Err("no such upload".into());
                }
                let mut upload = self.open.remove(&id).unwrap();
                if upload.written != upload.size {
                    let _ = std::fs::remove_file(&upload.part);
                    return Err(format!("{} of {} bytes arrived", upload.written, upload.size));
                }
                upload.file.flush().map_err(|err| err.to_string())?;
                // Taken now if another upload got there first.
                let path = free_path(upload.path.parent().unwrap_or(dir), &upload.path.file_name().unwrap().to_string_lossy());
                std::fs::rename(&upload.part, &path).map_err(|err| format!("keeping {}: {err}", path.display()))?;
                Ok(json!(path.to_string_lossy()))
            }
            "file.abort" => {
                let id = id_of(&params[0])?;
                if let Some(upload) = self.open.remove(&id).filter(|u| u.client == client) {
                    let _ = std::fs::remove_file(&upload.part);
                }
                Ok(Value::Null)
            }
            _ => Err(format!("no method `{method}`")),
        }
    }

    /// A connection closed: what it was sending is thrown away.
    pub fn closed(&mut self, client: ClientId) {
        self.open.retain(|_, upload| {
            if upload.client == client {
                let _ = std::fs::remove_file(&upload.part);
            }
            upload.client != client
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_from_elsewhere_stay_names() {
        assert_eq!(plain_name("take.wav").as_deref(), Some("take.wav"));
        assert_eq!(plain_name("/home/me/take.wav").as_deref(), Some("take.wav"));
        assert_eq!(plain_name("..\\..\\x.wav").as_deref(), Some("x.wav"));
        assert_eq!(plain_name("../.hidden").as_deref(), Some("hidden"));
        assert_eq!(plain_name("dir/").as_deref(), None);
        assert_eq!(plain_name("..").as_deref(), None);
    }

    #[test]
    fn a_file_arrives_in_pieces_and_takes_a_free_name() {
        let dir = std::env::temp_dir().join(format!("paw-upload-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("take.wav"), b"old").unwrap();
        let mut uploads = Uploads::default();
        let b64 = |b: &[u8]| json!(base64::engine::general_purpose::STANDARD.encode(b));
        let id = uploads.call(3, "file.begin", &json!([{ "name": "../take.wav", "size": 6 }]), &dir).unwrap();
        assert!(uploads.call(4, "file.chunk", &json!([id, b64(b"abc")]), &dir).is_err(), "another connection's");
        assert_eq!(uploads.call(3, "file.chunk", &json!([id, b64(b"abc")]), &dir).unwrap(), json!(3));
        assert!(uploads.call(3, "file.end", &json!([id]), &dir).is_err(), "not whole yet");
        let id = uploads.call(3, "file.begin", &json!([{ "name": "take.wav", "size": 6 }]), &dir).unwrap();
        uploads.call(3, "file.chunk", &json!([id, b64(b"abc")]), &dir).unwrap();
        uploads.call(3, "file.chunk", &json!([id, b64(b"def")]), &dir).unwrap();
        let path = uploads.call(3, "file.end", &json!([id]), &dir).unwrap();
        assert_eq!(path.as_str().unwrap(), dir.join("take-2.wav").to_string_lossy());
        assert_eq!(std::fs::read(dir.join("take-2.wav")).unwrap(), b"abcdef");
        assert_eq!(std::fs::read(dir.join("take.wav")).unwrap(), b"old");
        // One left half sent goes when its connection does.
        let id = uploads.call(3, "file.begin", &json!([{ "name": "half.wav", "size": 6 }]), &dir).unwrap();
        uploads.call(3, "file.chunk", &json!([id, b64(b"abc")]), &dir).unwrap();
        uploads.closed(3);
        let left: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name()).collect();
        assert_eq!(left.len(), 2, "{left:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
