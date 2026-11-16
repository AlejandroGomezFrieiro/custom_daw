//! TLS over the network: a connection's two directions used from two
//! threads, and the client's side, which trusts an instance's certificate
//! the first time it sees it and holds it to that certificate afterwards
//! (as SSH does with a host key). The instance makes its own certificate:
//! see `daw_core::tls`.

use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, anyhow, bail};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};

use crate::{hex, sha256};

/// The cryptography everything here uses: ring's, which is pure Rust and
/// assembly, with no OpenSSL.
pub fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// How a certificate is named to a person: the SHA-256 of it, in
/// hexadecimal, in groups of four so that two can be compared by eye.
pub fn fingerprint(der: &[u8]) -> String {
    let digits = hex(&sha256(der));
    let groups: Vec<&str> = (0..digits.len()).step_by(4).map(|i| &digits[i..i + 4]).collect();
    groups.join(":")
}

/// One end of a TLS connection, shared by the thread that reads and the
/// one that writes. Neither holds the lock while it waits on the socket,
/// so a side that is busy sending never keeps the other from reading.
struct Shared {
    tls: Mutex<rustls::Connection>,
    /// Taken before `tls` is let go by whoever has records to send, and held
    /// while they are written, so that records reach the socket in order.
    sending: Mutex<TcpStream>,
}

impl Shared {
    /// Write out what TLS has to send. Called with `tls` locked; lets go of it
    /// before waiting on the socket.
    fn send(&self, mut tls: std::sync::MutexGuard<'_, rustls::Connection>) -> io::Result<()> {
        if !tls.wants_write() {
            return Ok(());
        }
        let mut records = Vec::new();
        while tls.wants_write() {
            tls.write_tls(&mut records)?;
        }
        let mut socket = self.sending.lock().unwrap();
        drop(tls);
        socket.write_all(&records)?;
        socket.flush()
    }
}

/// The plaintext coming in over a TLS connection.
pub struct TlsReader {
    shared: Arc<Shared>,
    socket: TcpStream,
    /// Bytes from the socket that TLS has not taken in yet.
    raw: Vec<u8>,
}

impl Read for TlsReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            let mut tls = self.shared.tls.lock().unwrap();
            match tls.reader().read(buf) {
                Ok(n) => return Ok(n),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => {}
                Err(err) => return Err(err),
            }
            if !self.raw.is_empty() {
                let taken = tls.read_tls(&mut &self.raw[..])?;
                self.raw.drain(..taken);
                tls.process_new_packets()
                    .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
                // An answer TLS owes the other side (a new key, an alert).
                self.shared.send(tls)?;
                continue;
            }
            drop(tls);
            let mut chunk = [0u8; 16 * 1024];
            let n = self.socket.read(&mut chunk)?;
            if n == 0 {
                return Ok(0);
            }
            self.raw.extend_from_slice(&chunk[..n]);
        }
    }
}

/// The plaintext going out over a TLS connection.
pub struct TlsWriter {
    shared: Arc<Shared>,
}

impl Write for TlsWriter {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        // TLS takes as much as its buffer holds; that much goes out before
        // `write_all` comes back with the rest.
        let mut tls = self.shared.tls.lock().unwrap();
        let taken = tls.writer().write(data)?;
        self.shared.send(tls)?;
        Ok(taken)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Run the handshake on `socket` (within its read timeout), then hand back
/// the two directions of the connection.
pub fn split(mut tls: rustls::Connection, mut socket: TcpStream) -> io::Result<(TlsReader, TlsWriter)> {
    while tls.is_handshaking() {
        tls.complete_io(&mut socket)?;
    }
    // Whatever was sent after the handshake, in the same packets, is not
    // lost: complete_io only reads what TLS asks for.
    let reader_socket = socket.try_clone()?;
    let shared = Arc::new(Shared {
        tls: Mutex::new(tls),
        sending: Mutex::new(socket),
    });
    Ok((
        TlsReader {
            shared: shared.clone(),
            socket: reader_socket,
            raw: Vec::new(),
        },
        TlsWriter { shared },
    ))
}

/// What the client knows of the instances it has connected to: one line
/// each, the address as it was given and its certificate's fingerprint.
pub fn known_path() -> PathBuf {
    crate::state_dir().join("known_instances")
}

/// The fingerprint remembered for `address` in `file`.
pub fn known(file: &Path, address: &str) -> Option<String> {
    let text = std::fs::read_to_string(file).ok()?;
    text.lines().find_map(|line| {
        let (name, print) = line.split_once(' ')?;
        (name == address).then(|| print.trim().to_string())
    })
}

/// Remember `print` for `address` in `file`, in place of what was there.
pub fn remember(file: &Path, address: &str, print: &str) -> Result<()> {
    let text = std::fs::read_to_string(file).unwrap_or_default();
    let mut lines: Vec<String> = text
        .lines()
        .filter(|line| line.split_once(' ').is_none_or(|(name, _)| name != address))
        .map(str::to_string)
        .collect();
    lines.push(format!("{address} {print}"));
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    std::fs::write(file, lines.join("\n") + "\n").with_context(|| format!("writing {}", file.display()))
}

/// How a network connection is made.
#[derive(Clone, Debug)]
pub enum Wire {
    /// In TLS, holding the instance to the certificate remembered for its
    /// address in `known` (remembering it the first time).
    Tls {
        known: PathBuf,
        /// Take the certificate shown in place of one remembered that differs.
        accept_new: bool,
    },
    /// In the clear, for an instance started with `--no-tls`.
    Plain,
}

impl Default for Wire {
    fn default() -> Self {
        Wire::Tls {
            known: known_path(),
            accept_new: false,
        }
    }
}

/// Accepts the certificate the instance shows as long as it is the one
/// remembered (or none is), and checks the handshake is signed with it.
#[derive(Debug)]
struct Pinned {
    expected: Option<String>,
    accept_new: bool,
    shown: Mutex<Option<String>>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let print = fingerprint(end_entity);
        *self.shown.lock().unwrap() = Some(print.clone());
        match &self.expected {
            Some(expected) if *expected != print && !self.accept_new => {
                Err(rustls::Error::General("not the certificate remembered".into()))
            }
            _ => Ok(ServerCertVerified::assertion()),
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// Notes the first byte the other side sends: an instance that speaks
/// first in the clear (`{`) is one without TLS.
struct Sniff<'a> {
    socket: &'a mut TcpStream,
    first: Option<u8>,
}

impl Read for Sniff<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.socket.read(buf)?;
        if n > 0 && self.first.is_none() {
            self.first = Some(buf[0]);
        }
        Ok(n)
    }
}

impl Write for Sniff<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.socket.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.socket.flush()
    }
}

/// What came of connecting in TLS: the two directions, and the
/// certificate's fingerprint when it was remembered for the first time
/// (or again, in place of another).
pub struct Opened {
    pub reader: TlsReader,
    pub writer: TlsWriter,
    pub trusted_now: Option<String>,
}

/// Make a TLS connection over `socket` to the instance at `address`,
/// holding it to the certificate remembered in `known`.
pub fn connect(address: &str, mut socket: TcpStream, known_file: &Path, accept_new: bool) -> Result<Opened> {
    let provider = provider();
    let expected = known(known_file, address);
    let pinned = Arc::new(Pinned {
        expected: expected.clone(),
        accept_new,
        shown: Mutex::new(None),
        provider: provider.clone(),
    });
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .dangerous()
        .with_custom_certificate_verifier(pinned.clone())
        .with_no_client_auth();
    // The name is not checked (the certificate is held to its fingerprint
    // instead), but TLS wants one.
    let host = address.rsplit_once(':').map_or(address, |(host, _)| host);
    let host = host.trim_start_matches('[').trim_end_matches(']');
    let name = ServerName::try_from(host.to_string())
        .or_else(|_| ServerName::try_from("daw-instance".to_string()))
        .map_err(|err| anyhow!("{err}"))?;
    let mut tls: rustls::Connection = rustls::ClientConnection::new(Arc::new(config), name)?.into();
    let mut sniff = Sniff {
        socket: &mut socket,
        first: None,
    };
    let mut handshake = || -> io::Result<()> {
        while tls.is_handshaking() {
            tls.complete_io(&mut sniff)?;
        }
        Ok(())
    };
    if let Err(err) = handshake() {
        let shown = pinned.shown.lock().unwrap().clone();
        if let (Some(expected), Some(shown)) = (&expected, &shown)
            && expected != shown
        {
            bail!(
                "the instance at {address} shows another certificate than the one remembered:\n  \
                 remembered: {expected}\n  shown now:  {shown}\n\
                 If the instance made a new one (its state directory was lost, or it moved \
                 machine), check the fingerprint it prints when it starts and connect again \
                 with --accept-certificate. Otherwise something between here and there is \
                 pretending to be it. (Remembered in {}.)",
                known_file.display()
            );
        }
        if sniff.first == Some(b'{') {
            bail!(
                "the instance at {address} speaks without encryption: it is older than this \
                 program, or was started with --no-tls. Connect with --no-tls if the network \
                 is one you trust."
            );
        }
        return Err(anyhow!(err).context(format!("no TLS with the instance at {address}")));
    }
    let shown = pinned.shown.lock().unwrap().clone().context("the instance showed no certificate")?;
    let trusted_now = if expected.as_deref() != Some(shown.as_str()) {
        remember(known_file, address, &shown)?;
        Some(shown)
    } else {
        None
    };
    let (reader, writer) = split(tls, socket)?;
    Ok(Opened {
        reader,
        writer,
        trusted_now,
    })
}
