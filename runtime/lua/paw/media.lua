-- The project's sound files: listing what is missing, relinking it, and
-- copying files from elsewhere into the project's own `media` folder.
-- The work is in the kernel (crates/paw-core/src/session/media.rs).
local api = paw.api
local command = paw.command
local M = {}

require("paw.options").define("copy_imports", false) -- importing copies the file into `media` beside the project

-- Long files are played from the disk, not held in memory: see the
-- options `media_stream` and `media_cache`.
api.media_store(tonumber(paw.opt.media_stream) or 0, tonumber(paw.opt.media_cache) or 16)
paw.on("option.changed", function(e)
  if e.name == "media_stream" then api.media_store(tonumber(e.value) or 0) end
end)

local function name_of(path) return tostring(path):match("([^/]+)$") or tostring(path) end

--- Files the project's clips play that are not there, once each.
function M.missing() return api.media_missing() end

--- Every file the project plays: `{ path, missing, inside }`.
function M.list() return api.media_list() end

--- Make the clips that play `from` play the file `to`, and find the other
--- files that paw cannot find in the folder of `to`. One undo step. Returns
--- `{ clips, found, missing }`.
function M.relink(from, to) return api.media_relink(from, to) end

--- Find in a directory tree each file that paw cannot find. One undo step.
--- Returns `{ found, missing }`.
function M.search(dir) return api.media_search(dir) end

--- Copy every file from outside the project's folder into `media` beside
--- it and point the clips at the copies. One undo step. Returns `{ copied, missing, dir }`.
function M.collect() return api.media_collect() end

local function still(result)
  local n = #(result.missing or {})
  return n == 0 and "nothing is missing now" or string.format("%d still missing", n)
end

--- Select a file for a file that paw cannot find, or a directory where paw finds all of them.
function M.relink_pick()
  local missing = api.media_missing()
  if #missing == 0 then return paw.notify("no media is missing") end
  local items = { { label = "Search a directory for all of them…", search = true } }
  for _, path in ipairs(missing) do items[#items + 1] = { label = name_of(path) .. "  " .. path, path = path } end
  paw.pick.open({
    title = string.format("Missing media (%d)", #missing),
    items = items,
    format = function(item) return item.label end,
    on_choose = function(item)
      if item.search then
        return paw.pick.file({
          title = "Search for missing media", directory = true,
          on_choose = function(dir)
            local result = api.media_search(dir)
            paw.notify(string.format("found %d file%s; %s", result.found, result.found == 1 and "" or "s", still(result)))
          end,
        })
      end
      local ext = item.path:match("%.([^./]+)$")
      paw.pick.file({
        title = "Find " .. name_of(item.path),
        extensions = ext and { ext } or nil,
        on_choose = function(path)
          local ok, result = pcall(api.media_relink, item.path, path)
          if not ok then return paw.notify(tostring(result), "error") end
          paw.notify(string.format("%s: %d clip%s relinked, %d other file%s found; %s", name_of(path),
            result.clips, result.clips == 1 and "" or "s", result.found, result.found == 1 and "" or "s", still(result)))
        end,
      })
    end,
  })
end

command("media.relink", function(ctx)
  local a, b = ctx.args[1], ctx.args[2]
  if a and b then
    local result = api.media_relink(tostring(a), tostring(b))
    return paw.notify(string.format("%d clip%s relinked; %s", result.clips, result.clips == 1 and "" or "s", still(result)))
  elseif a then
    local result = api.media_search(tostring(a))
    return paw.notify(string.format("found %d file%s; %s", result.found, result.found == 1 and "" or "s", still(result)))
  end
  M.relink_pick()
end, { desc = "Find missing media: alone, choose a file or a directory; `media.relink <dir>` searches it; `media.relink <old> <new>`" })

command("media.collect", function()
  local result = api.media_collect()
  local n = #result.missing
  paw.notify(string.format("copied %d file%s into %s%s", result.copied, result.copied == 1 and "" or "s", result.dir,
    n > 0 and string.format(" (%d missing, not copied)", n) or ""))
end, { desc = "Copy every sound file from outside the project's folder into its `media` folder" })

command("collect", function()
  if not api.project_get("path") then return paw.notify("the project has no folder yet: `:w song` saves it first", "warn") end
  local tracks, chains = api.track_collect()
  local clips = api.clip_collect()
  local result = api.media_collect()
  local n = #result.missing
  local parts = {}
  if tracks > 0 then parts[#parts + 1] = string.format("%d track%s, ", tracks, tracks == 1 and "" or "s") end
  if chains > 0 then parts[#parts + 1] = string.format("%d chain%s, ", chains, chains == 1 and "" or "s") end
  paw.notify(string.format("%s%d clip%s and %d sound file%s are now the project's own%s; `:w` writes them into its folder",
    table.concat(parts), clips, clips == 1 and "" or "s", result.copied, result.copied == 1 and "" or "s",
    n > 0 and string.format(" (%d missing, not copied)", n) or ""))
end, { desc = "Copy every file from outside the project's folder into it: tracks, chains of devices, MIDI clip files and sound files" })

--- A path with the home folder as `~`.
local function tilde(path)
  local home = os.getenv("HOME")
  if home and path:sub(1, #home + 1) == home .. "/" then return "~" .. path:sub(#home + 1) end
  return path
end

-- The first edit of a clip that refers to a file outside the project.
paw.on("clip.copied", function(e)
  paw.notify(string.format("%s is now this project's own copy (was %s)", e.name, tilde(tostring(e.origin))))
end)
-- The first edit of a track or a chain from outside the project.
paw.on("track.copied", function(e)
  paw.notify(string.format("the track %s is now this project's own copy (was %s)", e.name, tilde(tostring(e.origin))))
end)
paw.on("chain.copied", function(e)
  paw.notify(string.format("the devices of %s are now this project's own copy (was %s)", e.name, tilde(tostring(e.origin))))
end)

command("media.missing", function()
  local missing = api.media_missing()
  if #missing == 0 then return paw.notify("no media is missing") end
  local names = {}
  for i, path in ipairs(missing) do names[i] = name_of(path) end
  paw.notify(string.format("%d missing: %s; :media.relink finds them", #missing, table.concat(names, ", ")), "warn")
end, { desc = "List the sound files the project plays that are not there" })

-- Audio clip operations that leave the source file alone ---------------------

local function need_audio_clip()
  local clip = paw.cursor.clip()
  if not clip then paw.notify("no clip under the cursor", "warn") return nil end
  if clip.kind ~= "audio" then paw.notify("not an audio clip", "warn") return nil end
  return clip
end

local function id_of(clip) return type(clip) == "table" and clip.id or clip end

--- Play an audio clip backwards: a `reverse` in its edit list, which leaves
--- its file as it is (a second reverse takes it away). Returns `{ edits }`.
function M.reverse(clip) return api.clip_reverse(id_of(clip)) end

--- A gain of `db` on a part of an audio clip, from `from` to `to` seconds
--- of what it plays, in its edit list. Returns how many edits it has.
function M.gain_part(clip, from, to, db)
  return api.clip_edit_add(id_of(clip), { kind = "gain", from = from, to = to, db = db })
end

--- Samples drawn over an audio clip's (a pencil fix), from `at` seconds of
--- what it plays, in one channel (0 or 1) or both, in its edit list.
--- Returns how many edits it has.
function M.pencil(clip, at, values, channel)
  return api.clip_edit_add(id_of(clip), { kind = "pencil", at = at, values = values, channel = channel })
end

--- An audio clip's edit list: `{ { kind, ... } }`.
function M.edits(clip) return api.clip_edits(id_of(clip)) end

--- Take away an audio clip's edit list. Returns how many edits it had.
function M.clear_edits(clip) return api.clip_edits_clear(id_of(clip)) end

--- Bring the loudest sample an audio clip plays to `level` dB (0) by its gain.
--- Returns the new gain.
function M.normalize(clip, level) return api.clip_normalize(type(clip) == "table" and clip.id or clip, level) end

--- Join audio clips of one track into one clip that plays a new file. With
--- a list, join the given clips. With one clip, join it and each audio clip
--- that touches or overlaps it. Returns { id, file, glued }.
function M.glue(clips)
  local ids = {}
  for i, c in ipairs(type(clips) == "table" and clips.id == nil and clips or { clips }) do
    ids[i] = type(c) == "table" and c.id or c
  end
  return api.clip_glue(ids)
end

command("clip.reverse", function()
  local clip = need_audio_clip()
  if not clip then return end
  local done = M.reverse(clip)
  paw.notify(string.format("reversed %s (%d edit%s in its list; the file stays as it is)", clip.name, done.edits, done.edits == 1 and "" or "s"))
end, { desc = "Play the audio clip under the cursor backwards: an edit in its list; the file stays as it is" })

command("clip.gain", function(ctx)
  local clip = need_audio_clip()
  if not clip then return end
  local from, to, db = tonumber(ctx.args[1]), tonumber(ctx.args[2]), tonumber(ctx.args[3])
  if not (from and to and db) then return paw.notify("usage: clip.gain <from> <to> <dB>, in seconds of the clip: `clip.gain 1.2 1.3 -12`", "warn") end
  local ok, n = pcall(M.gain_part, clip, from, to, db)
  if not ok then return paw.notify(tostring(n):gsub("^[^:]*:%d+: ", ""), "error") end
  paw.notify(string.format("%s: %+g dB from %g s to %g s (%d edit%s in its list)", clip.name, db, from, to, n, n == 1 and "" or "s"))
end, { desc = "A gain on a part of the audio clip under the cursor, in seconds of the clip: `clip.gain 1.2 1.3 -12`" })

command("clip.edits", function()
  local clip = need_audio_clip()
  if not clip then return end
  local list = M.edits(clip)
  if #list == 0 then return paw.notify(clip.name .. " has no edits: it plays its file") end
  local lines = {}
  for i, e in ipairs(list) do
    if e.kind == "reverse" then
      lines[i] = string.format("%d. backwards", i)
    elseif e.kind == "gain" then
      lines[i] = string.format("%d. %+g dB from %.3f s to %.3f s of the sound", i, e.db, e.from, e.to)
    else
      lines[i] = string.format("%d. %d samples drawn at %.3f s%s", i, #e.values, e.at, e.channel and (" in channel " .. e.channel) or "")
    end
  end
  paw.ui.page("Edits of " .. clip.name, lines)
end, { desc = "List the edit list of the audio clip under the cursor" })

command("clip.edits.clear", function()
  local clip = need_audio_clip()
  if not clip then return end
  local n = M.clear_edits(clip)
  paw.notify(n == 0 and (clip.name .. " has no edits") or string.format("%s plays its file again (%d edit%s taken away)", clip.name, n, n == 1 and "" or "s"))
end, { desc = "Take away the edit list of the audio clip under the cursor: it plays its file again" })

command("clip.normalize", function(ctx)
  local clip = need_audio_clip()
  if not clip then return end
  local gain = M.normalize(clip, tonumber(ctx.args[1]) or 0)
  paw.notify(string.format("%s: clip gain %+.1f dB", clip.name, gain))
end, { desc = "Bring the audio clip's loudest sample to a level by its gain: `clip.normalize -1`" })

command("clip.glue", function()
  local clip = need_audio_clip()
  if not clip then return end
  local result = M.glue(clip)
  paw.notify(string.format("glued %d clips into %s", result.glued, name_of(result.file)))
end, { desc = "Join the audio clip under the cursor and those touching it into one clip (a new file)" })

return M
