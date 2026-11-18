# About language servers

A text editor shows the problems in code where the code is, with fixes. A
language server finds the problems, and the editor shows them. Neovim does
this with `vim.lsp` and `vim.diagnostic`. paw does the same for music and
for the mix. A server finds a parallel fifth, a fader that clips, or a
master that is too loud. Each view shows the problem on the thing.

## Four layers

The design has four layers. No layer knows a server by its name.

1. **Addresses.** Each thing that a server can talk about has a URI.
2. **Subjects.** A subject is what a server gets: a part of the project as
   plain data.
3. **Clients.** A client starts a server and speaks to it.
4. **Features.** Diagnostics, labels, hover, actions and suggestions. paw
   keeps them by location, and each view draws them where they belong.

So a new server needs no change in the views, and a new view shows the
diagnostics of every server. MIDI LSP, which comes with paw as an
extension, is one server of many. `extensions/mixdiag` is another server,
in the kernel process.

## Why addresses use ids

A fix must change the correct thing after other edits. Before, paw found a
note again by its pitch and start, but a move of the note broke the link.
Now each note has an id from the time paw makes it, and the id stays with
the note through every move. A diagnostic on `paw://clip/7/note/41` stays
on that note, and its fix changes that note.

## Why subjects are projections

A server must not know the internal model of paw. A subject is a stable
view of a part of the project. Examples are a clip in the format of MIDI
LSP, a track, the mix and a render. When the model changes, only the
projection changes, and the servers continue to work.

A server says what it wants to see. With
`focus`, it gets only what a person looks at. Then a large project does
not send all its clips.

## Why the protocol is LSP

LSP has clients and libraries in many languages, and it has free `data`
fields. paw puts its locations and workspace edits in these fields. So a
server is a usual LSP server with a small extension, and a server that
speaks a different protocol needs only an adapter.

## Why a workspace edit is one undo step

A fix can change many things: a fader and a device, or many notes. paw
checks all the changes first and then applies them together. One `u`
removes the full fix, and a fix that is not valid changes nothing.

See [Language servers and diagnostics](../reference/language-servers.md)
for the reference, and
[How to write a language server](../how-to/write-a-language-server.md).
