# plugstate

Many plugins keep a part of their sound outside their parameters. Examples
are the model of an amp simulator, the impulse response of a cabinet or a
room, and the instrument file of a sampler. This extension gives you that
part without the window of the plugin.

You choose a model or a file with
keys or commands. You step through a folder of them, or find them by
words. You keep named snapshots of the whole state of a device, and switch
between them. Each change is one undo step, and the project keeps all of
it.

```
extensions/plugstate/
  init.lua, lua/plugstate/   the adapters, the library, snapshots, commands
  tests.lua                  tests with real plugins (Neural Amp Modeler, LSP, sfizz,
                             TONE3000, Soundshed Guitar)
```

## Try it

1. Add Neural Amp Modeler to a guitar track: `:device.add neural amp`.
2. Put some `.nam` models in `~/.local/share/paw/models`.
3. Open the device panel and put its row on the amp. Press `]m`. paw loads
   the first model of the folder and says its name and what the model
   file says of itself.
4. Press `]m` again. The next model plays. Press `u`. paw loads the
   model before again.
5. Press `\s`. paw keeps the state as snapshot A. Load another model and
   press `\s` again for snapshot B. Now `[v` and `]v` switch between A and B.

## How to

### How to load a model or a file by name

Type `:plugstate.load` with a file, or with words that find it:
`:plugstate.load ~/nam/deluxe.nam`, `:plugstate.load deluxe clean`. When
the words find more than one file, a picker opens with them. When the
selection stays on a file, paw loads it for a trial, and you hear it with
what the track plays. Enter keeps it. Escape puts back what was there.

### How to add a folder of models or impulse responses

Add the folder to `paw.opt.plugstate_folders`. Separate folders with `:`.
paw also looks in `~/.local/share/paw/models` and in the folder of the
file that the plugin holds now.

### How to change the preset of an amp plugin

For TONE3000 and Soundshed Guitar, the first slot is the preset. `]m`
and `[m` step through the presets, and `:plugstate.load bogner` finds one
by its name. paw finds the factory presets that come with the plugin. Put
your own presets (`.t3kpreset`, `.soundshed.presets` packs and `.json`
presets) in a folder of `paw.opt.plugstate_folders`. For a guide, see
[How to switch amp models and presets from paw](../../docs/how-to/switch-amp-models-and-presets.md).

### How to find a model in TONE3000's library

TONE3000 (www.tone3000.com) is a library of amp models and impulse
responses that its users share. plugstate finds them and loads them into
TONE3000, Neural Amp Modeler and the impulse response plugins of LSP.

1. Give paw a token of your TONE3000 account. See
   [TONE3000 tokens](#tone3000-tokens).
2. In the device panel, put the row on the plugin and press `\t`. Type
   words, for example `plexi crunch`, and press Enter. Or type
   `:plugstate.search plexi crunch`.
3. A list of tones opens, 25 at a time. The pane at the side shows the
   author, the license and the description. `Alt-n` and `Alt-p` show the
   next page and the page before.
4. Press Enter on a tone. If the tone has more than one model, a second
   list opens. Press Enter on a model.

paw downloads the model one time, and loads it as one undo step. To find
only one kind of tone, add `gear=`, `type=` or `by=`:
`:plugstate.search gear=pedal by=someone fuzz`.

### How to set a plugin that holds more than one file

Give the file a name with `slot=`: `:plugstate.load slot=ifn1 hall.wav`.
`:plugstate.info` lists the names. A slot can also hold a value, for
example the scene of a Soundshed preset: `:plugstate.load slot=scene solo`.

### How to switch sounds while you play

Keep each sound as a snapshot (`:plugstate.snapshot crunch`), then use
`]v` and `[v` or `:plugstate.recall crunch`. A snapshot holds the whole
state of the plugin and its parameters, also the parts that no parameter
shows.

### How to teach plugstate another plugin

Add an adapter from your configuration or extension:

```lua
local plugstate = require("paw.plugstate")
plugstate.adapter({
  name = "my-amp",
  desc = "My Amp: its model",
  matches = function(d) return d.plugin and d.plugin.id == "com.example.amp" end,
  slots = function(id, d)
    return { { key = "model", label = "Model", what = "model", kind = "file", types = { "nam" }, value = nil } }
  end,
  -- What `paw.api.device_load` takes: a call to the plugin, or a new state.
  load = function(id, d, slot, path)
    return { call = { method = "preset.load", data = "file:" .. path } }
  end,
})
```

An LV2 plugin that lists its files as properties needs no adapter: the
`lv2` adapter finds them. See [Adapters](#adapters).

## Reference

### Keys

These keys are in the device panel. They act on the device of the row.

| Key | Effect |
| --- | --- |
| `]m` `[m` | loads the next or the previous file of the folder (a count skips more) |
| `\m` | opens the picker of the files that the plugin takes |
| `\s` | keeps the state of the device as a snapshot (A, B, C and so on) |
| `\v` | opens the picker of the snapshots |
| `\t` | asks for words, then searches TONE3000's library (`:plugstate.search_prompt`) |
| `]v` `[v` | brings back the next or the previous snapshot |

### Commands

| Command | Effect |
| --- | --- |
| `:plugstate.load [slot=<key>] [file or words]` | loads a file into the plugin. With words, the one file that they find, else the picker |
| `:plugstate.next`, `:plugstate.prev` | loads the next or the previous file of the folder |
| `:plugstate.files [words]` | lists the files that the plugin takes, in the library folders |
| `:plugstate.info` | tells which files the plugin holds, what the files say of themselves, and the snapshots |
| `:plugstate.snapshot [name]` | keeps the whole state of the device and its parameters under a name |
| `:plugstate.recall [name]` | brings back a snapshot. With no name, the picker |
| `:plugstate.recall_next`, `:plugstate.recall_prev` | brings back the next or the previous snapshot |
| `:plugstate.forget <name>` | removes a snapshot |
| `:plugstate.adapters` | lists the kinds of plugin that plugstate knows |
| `:plugstate.search [gear=<gear>] [type=nam\|ir] [by=<user>] [sort=<order>] [arch=<n>] [slot=<key>] [words]` | searches TONE3000's library and opens a picker of the tones. Enter on a tone shows its models, and Enter on a model loads it |
| `:plugstate.search_more` | shows the next page of the last search (a count skips more) |
| `:plugstate.search_prompt` | asks for words, then does `:plugstate.search` |

- The commands act on the device of the row of the device panel when
  plugstate knows it. Else, they act on the first device of the cursor
  track that plugstate knows.
- A load and a recall are each one undo step. The parameters of the device
  stay as they are on a load. A recall sets the parameters of the snapshot.
- The project keeps the snapshots in `meta.plugstate` of the device. A
  project with snapshots opens and plays without the extension.
- `:checkhealth plugstate` lists the adapters and the folders.

### Options

| Option | Default | Effect |
| --- | --- | --- |
| `plugstate_folders` | `""` | the folders of models and impulse responses, separated by `:` |
| `plugstate_tone3000_token_file` | `""` | a file that holds a TONE3000 access token on its first line. paw uses it only if its mode is 600 or 400 |
| `plugstate_tone3000_plugin_session` | `false` | when `true`, paw also uses the session of the TONE3000 plugin (see [TONE3000 tokens](#tone3000-tokens)) |
| `plugstate_tone3000_api` | `""` | another address of the API. Empty: `https://www.tone3000.com/api/v1` |

### The search of TONE3000

- `gear=` is `amp`, `amp-cab`, `pedal`, `outboard`, `cab`, `space` or
  `experimental`. `type=` is `nam` (models) or `ir` (impulse responses).
  `by=` is the user name of the author. `sort=` is `best-match`,
  `newest`, `oldest`, `trending` or `downloads-all-time`. Without words,
  TONE3000 gives the tones that are popular now.
- paw asks only for the kinds of file that the device takes. For the
  TONE3000 plugin, paw asks for the models of the second architecture
  (A2), as the window of the plugin does. `arch=1` asks for the others.
- A model goes into the slot named by `slot=`. Else, a `.nam` model goes
  into the first slot of a model, and a `.wav` impulse response into the
  first slot of an impulse response.
- paw keeps each file that it downloads in
  `$XDG_CACHE_HOME/paw/tone3000/<model id>/<model name>.<nam or wav>`, and
  does not download it again. You can delete the folder at any time.
- The project keeps the file as the adapter does (TONE3000 keeps its bytes,
  Neural Amp Modeler keeps its path), and keeps the tone in
  `meta.plugstate.tone3000.<slot>` of the device: `tone_id`, `tone`,
  `model_id`, `model`, `author`, `license` and `url`. So the project opens
  and plays without the network.
- Each request is a `curl` process with a time limit: 20 s for a search,
  120 s for a download. A key never waits for the network. paw tells when
  you are not signed in, when TONE3000 limits the rate of requests, and
  when the computer is offline.
- `:checkhealth plugstate.tone3000` tells if curl is there, where the
  token comes from, and the folder of the downloads.

### TONE3000 tokens

TONE3000 needs a token of your account to download a model. paw looks for
the token in this order, and uses the first one that it finds:

1. The environment variable `TONE3000_TOKEN`.
2. The file that `paw.opt.plugstate_tone3000_token_file` names. Only you
   can read the file: `chmod 600 <file>`.
3. The keyring, through `secret-tool`. Keep the token there with
   `secret-tool store --label="TONE3000 for paw" application paw service tone3000`.
4. Only when `paw.opt.plugstate_tone3000_plugin_session` is `true`: the
   session of the TONE3000 plugin, from the `t3k_tokens` value in
   `~/.config/TONE3000/ui-preferences.settings`. paw only reads this
   file. When the session expires, open the window of the plugin one time.
   paw does not renew it.

paw sends the token to curl on its standard input. The token is not on a
command line, in a log, in a project or in a file that paw writes.

### The terms of TONE3000

The API of TONE3000 has terms of use (https://www.tone3000.com/api/terms).
paw obeys them in these ways:

- paw downloads a model only when you choose it. It does not download
  the library, and it does not write the results of a search to a file.
- paw shows the author and the license of each tone, and keeps them in
  the project.
- The pane of the picker says "Powered by TONE3000" and gives the address
  of the tone.
- paw asks for one page when you ask for it. TONE3000 permits 100 requests
  in a minute, and fewer for the search.
- Do not share the models that you download in a way that their license
  does not permit.

### Adapters

| Adapter | Plugins | How it sets the file |
| --- | --- | --- |
| `nam` | Neural Amp Modeler (LV2) | its `model` property. `:plugstate.info` shows the name, the kind of network, the gear and the loudness that the `.nam` file gives |
| `lsp-ir` | LSP Impulse Responses and LSP Impulse Reverb (LV2) | their impulse response properties (`ifn0`, `ifn1` and so on). The picker shows audio files |
| `sfizz` | sfizz (VST3) | sfizz has no properties as a VST3 plugin. The adapter writes the SFZ file into the saved state of the plugin, and paw loads that state |
| `lv2` | each other LV2 plugin with properties (`patch:writable`) | the property, with a message to the plugin as from its own window |
| `tone3000` | TONE3000 (CLAP, VST3, LV2) | it writes the state of the plugin. Slots: `preset` (a `.t3kpreset` file: its chain and the values of its parameters), and `block1` to `block5`, `right1` to `right5` (the blocks of the two rows of the chain). A `.nam` or `.wav` file goes into a block with its bytes, as a file that you drop on the block in the window. The name of a model that the block holds switches to that model |
| `soundshed` | Soundshed Guitar (VST3, LV2) | it writes the JSON state of the plugin. Slots: `preset` (a preset of a `.soundshed.presets` pack, or a `.json` preset), `scene` (the title or the number of a scene), and the blocks of the scene that take a file (`amp1`, `fx1`, `cab1` and other), set by the path of the file |

### The Lua module

`require("paw.plugstate")` gives these functions:

| Function | Result |
| --- | --- |
| `adapter(def)` | adds an adapter. An adapter added later is asked first |
| `adapter_of(id)` | the adapter for a device, and the device |
| `slots(id)` | the files and values of a device: `{ key, label, what, kind, types, value }`. A slot can also give `folders` (more folders to look in) or `list(roots)` (its own choices, as `{ path, name, folder }`) |
| `set(id, key, value)` | sets a slot (nil for the first) as one undo step. Returns `true`, or nil and the reason |
| `files(slot, roots)` | the files that a slot takes in the library folders: `{ path, name, folder }` |
| `search(slot, words)` | the files whose name or folder has each word |
| `neighbour(slot, n)` | the file `n` places after the current one in its folder |
| `snapshot(id, name)`, `recall(id, name)`, `step(id, n)`, `forget(id, name)` | the snapshots |
| `snapshots(id)`, `current(id)` | the snapshots of a device, and the name of the last one recalled or kept |
| `share_dirs(sub)` | the folders `share/<sub>` of the packages in the plugin folders (`CLAP_PATH`, `VST3_PATH`, `LV2_PATH`, the Nix profiles), for factory presets |

An adapter can also give `name_of(path)`: the name of a choice in the
messages.

The extension sends the events `plugstate.loaded` (`device`, `slot`,
`value`) and `plugstate.recalled` (`device`, `name`).

### What the core gives

- `paw.api.device_call(id, "properties")` lists the properties of an LV2
  plugin as JSON: `uri`, `key`, `label`, `type` (`path`, `string`,
  `number`, `integer`, `boolean` or `other`), `writable`, `readable`,
  `file_types` and the `value` that the plugin told last.
- `paw.api.device_call(id, "property.set", '{"property": "model", "value": "/abs/path.nam"}')`
  sets one. The property is its URI, its key or its label. A path must be
  absolute, and the file must be there.
- `paw.api.device_load(id, { call = { method =, data = } })` makes a call
  that changes the state of the plugin one undo step, and the project
  keeps the state after it.

### Limits

- A snapshot holds the whole state. paw does not blend two snapshots,
  because the state of a plugin is not a set of numbers.
- An automation lane does not change a model. Snapshots change with keys
  and commands only.
- A plugin keeps the path of a file. When the file moves, the plugin does
  not find it.
- The `sfizz` adapter reads the state of sfizz 1.2. Another version of
  sfizz can write its state in another way.
- The `tone3000` adapter reads the state of TONE3000 0.0.12, and the
  `soundshed` adapter the state of Soundshed Guitar 1.7.1.
- A program change in a clip does not change the preset of TONE3000 or
  Soundshed Guitar in paw. The scene parameters of Soundshed Guitar do not
  change its scene. So an automation lane cannot switch their presets.
- TONE3000 loads its models in the background. A rendered file starts
  with less than a second of sound without the model.
- Soundshed Guitar keeps the path of a file. paw copies the files of a
  preset of a pack to `~/.local/share/paw/plugstate/<pack>`.
- The search of TONE3000 needs curl. paw does not sign in to TONE3000
  itself: it uses a token that you give (see [TONE3000 tokens](#tone3000-tokens)).
  paw loads models (`nam`) and impulse responses (`ir`), not the other
  formats of TONE3000 (`aida-x`, `proteus`, `aa-snapshot`).
- TONE3000 and Soundshed Guitar keep their own files in `~/.config`
  (`TONE3000`, `Soundshed Guitar`), also when `XDG_CONFIG_HOME` names
  another folder.
