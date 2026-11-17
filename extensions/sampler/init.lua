-- paw's sample player: SFZ and Decent Sampler instruments played by the
-- extension's own CLAP plugin (`native/`), a kind of track for them, and
-- an instrument picker that lets each one be heard. See README.md.
paw.option.define("sampler_plugin_dir", "") -- where paw-sampler.clap is; `clap/` beside the extension when empty
paw.option.define("sampler_libraries", "")  -- folders of instruments, separated by `:`

local sampler = require("sampler")
package.loaded["paw.sampler"] = sampler

-- The plugin this extension ships, found like any installed one.
local dir = sampler.plugin_dir()
if dir and paw.plugins and paw.plugins.add_dir then paw.plugins.add_dir(dir) end

require("sampler.commands")
