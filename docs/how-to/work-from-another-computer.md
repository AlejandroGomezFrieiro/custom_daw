# How to work on paw from another computer

<!-- tags: on-another-machine remote -->

This guide shows you how to connect a terminal or a graphical window to a
paw instance on another computer. In this guide, `studio` is the computer
that runs the instance. The other computer is the client.

## Connect over the network

1. On `studio`, start the instance with `--listen-tcp`:

   ```sh
   paw --listen-tcp 0.0.0.0:7700
   ```

   To accept connections only from `studio` itself, use `127.0.0.1:7700`.
   To start it without a terminal interface, add `--headless`.
2. Find the fingerprint in the start message: `listening on … certificate 9f1c:…`.
3. Copy `~/.local/state/paw/token` from `studio` to the client, for example as `studio.token`.
4. On the client, connect a terminal:

   ```sh
   paw attach --connect studio:7700 --token-file studio.token
   ```

   Or connect a graphical window:

   ```sh
   paw-gui --connect studio:7700 --token-file studio.token
   ```

5. At the first connection, compare the fingerprint that the client shows
   with the fingerprint from step 2.

Sometimes the client refuses the certificate after an earlier connection.
Then the instance has a new certificate, or a different computer answers. If you
know that the instance made a new certificate, add `--accept-certificate`.

On a network that you trust, you can use no encryption. Add `--no-tls` to
the instance and to each client.

## Connect through SSH

You can connect through an SSH tunnel to the socket of the instance. The
instance needs no option for this.

```sh
ssh -N -L /tmp/studio.sock:/run/user/1000/paw.sock studio &
paw attach --socket /tmp/studio.sock
```

## Bring a sound file from the client

Import and Open show the files of `studio`. To import a sound file from
the client, do one of these:

- Drop the file on a graphical window that is connected to `studio`.
- Choose the file in the Import dialog of a connected graphical window.
- Type `:upload ~/take.wav` in a connected terminal.

paw sends the file to the `media` folder of the project on `studio`, and
imports it on a new track. If the project has no file yet, paw uses a
scratch folder.

## Hear the sound on the client

The sound plays on `studio`. To hear it on the client too, do one of these:

- Start the client with `--listen-audio`.
- Type `:listen` in a connected terminal. Type it again to stop.
- In a connected graphical window, choose "Hear it on this machine" in the engine menu.

To write the sound to a file on the client, start the client with
`paw attach --listen-audio-to heard.wav`.

The sound arrives a quarter of a second late, or more. Use it to monitor a
mix, not to play with the song.

## Leave

Type `:detach` in an attached terminal. The instance continues to run.

## See also

- [About seats](../explanation/about-seats.md): what each frontend has of its own, and why the network is safe.
- [The programs and their options](../reference/programs.md).
