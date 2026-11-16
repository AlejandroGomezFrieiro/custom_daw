-- The standard dialect: LSP's own shapes, which a server speaks unless its
-- config names another adapter (`daw.lsp.adapter`).
--
--   initialize                     capabilities.daw = { subjects, annotations, analysis }
--   textDocument/didOpen           { textDocument = { uri, languageId, version, text = the subject as JSON } }
--   textDocument/didChange         full text each time
--   textDocument/didClose
--   textDocument/publishDiagnostics  diagnostics[i].data = { location = { uri, selector }, fixes = { { title, edit = { changes } } } }
--   daw/publishAnnotations         { uri, annotations = { { location, label, kind } } }
--   daw/publishAnalysis            { uri, chords, keys, key } in project beats
--   textDocument/hover             params.daw.location: what is asked about
--   textDocument/codeAction        params.daw.location; answered { title, edit = { daw = changes } } or { title, command }
--   textDocument/completion        params.daw = { location, at }; items' data = { notes, velocities, controls }
--   workspace/applyEdit            from the server: { edit = { daw = changes }, label }
--
-- A server run in-process (`server = table`) is sent the subject as a table
-- (`textDocument.data`) instead of JSON text.
local rpc = require("daw.lsp.rpc")
local A = daw.address

local M = { name = "standard" }

local function text_document(client, doc)
  local td = { uri = doc.uri, languageId = doc.language, version = doc.version }
  if client.transport == "lua" then td.data = doc.data else td.text = rpc.encode(doc.data) end
  return td
end

function M.initialize(_, offer) return offer end

function M.capabilities(_, result)
  local raw = type(result.capabilities) == "table" and result.capabilities or {}
  local daw_caps = type(raw.daw) == "table" and raw.daw or {}
  local completion = raw.completionProvider
  return {
    subjects = daw_caps.subjects,
    diagnostics = true,
    hover = raw.hoverProvider and true or false,
    actions = raw.codeActionProvider and true or false,
    completion = completion and { lanes = type(completion) == "table" and completion.lanes or { "notes" } } or nil,
    annotations = daw_caps.annotations and true or false,
    analysis = daw_caps.analysis,
    commands = type(raw.executeCommandProvider) == "table" and raw.executeCommandProvider.commands or nil,
    raw = raw,
  }
end

function M.initialized() return "initialized", rpc.object() end

function M.open(client, doc) return "textDocument/didOpen", { textDocument = text_document(client, doc) } end

function M.change(client, doc)
  local change = client.transport == "lua" and { data = doc.data } or { text = rpc.encode(doc.data) }
  return "textDocument/didChange", { textDocument = { uri = doc.uri, version = doc.version }, contentChanges = { change } }
end

function M.close(_, doc) return "textDocument/didClose", { textDocument = { uri = doc.uri } } end

local function location_of(doc, data)
  local loc = type(data) == "table" and data.location
  if type(loc) == "string" then loc = { uri = loc } end
  return loc or { uri = doc.address }
end

M.handlers = {}

M.handlers["textDocument/publishDiagnostics"] = function(client, params, lsp)
  local doc = lsp.document(client, params.uri)
  if not doc then return end
  local list = {}
  for _, d in ipairs(params.diagnostics or {}) do
    local data = type(d.data) == "table" and d.data or {}
    list[#list + 1] = {
      location = location_of(doc, data), severity = d.severity, message = d.message,
      rule = d.code, source = d.source or client.name, fixes = data.fixes, data = data,
    }
  end
  lsp.publish(client, doc, list)
end

M.handlers["daw/publishAnnotations"] = function(client, params, lsp)
  local doc = lsp.document(client, params.uri)
  if not doc then return end
  local list = {}
  for _, a in ipairs(params.annotations or {}) do
    list[#list + 1] = { location = location_of(doc, a), label = a.label, kind = a.kind, tooltip = a.tooltip }
  end
  lsp.annotate(client, doc, list)
end

M.handlers["daw/publishAnalysis"] = function(client, params, lsp)
  local doc = lsp.document(client, params.uri)
  if doc then lsp.analysis(client, doc, params) end
end

local function about(doc, location)
  return { textDocument = { uri = doc.uri }, position = { line = 0, character = 0 }, daw = { location = location } }
end

function M.hover(_, doc, location)
  return "textDocument/hover", about(doc, location), function(result)
    if type(result) ~= "table" then return {} end
    local contents = result.contents
    if type(contents) == "table" and contents.value then contents = contents.value end
    if type(contents) == "table" then
      local parts = {}
      for _, c in ipairs(contents) do parts[#parts + 1] = type(c) == "table" and c.value or tostring(c) end
      contents = table.concat(parts, "\n")
    end
    local out = {}
    for line in (tostring(contents or "") .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
    if out[#out] == "" then out[#out] = nil end
    return out
  end
end

function M.actions(client, doc, location, lsp)
  local params = about(doc, location)
  params.range = { start = params.position, ["end"] = params.position }
  params.context = { diagnostics = {} }
  return "textDocument/codeAction", params, function(result)
    local out = {}
    for _, a in ipairs(type(result) == "table" and result or {}) do
      local changes = type(a.edit) == "table" and a.edit.daw
      local command = a.command and (type(a.command) == "table" and a.command or { command = a.command })
      if changes or command then
        out[#out + 1] = { title = a.title, edit = changes, run = command and function()
          lsp.request(client, "workspace/executeCommand", { command = command.command, arguments = command.arguments })
        end or nil }
      end
    end
    return out
  end
end

function M.complete(_, doc, ctx)
  local params = about(doc, { uri = A.clip(ctx.clip), selector = { time = { ctx.at or 0, ctx.at or 0 } } })
  params.daw.at, params.daw.selection = ctx.at, ctx.selection
  params.context = { triggerKind = ctx.trigger == "auto" and 3 or 1 }
  return { { method = "textDocument/completion", params = params, translate = function(result)
    local items = type(result) == "table" and (result.items or result) or {}
    local out = {}
    for _, item in ipairs(items) do
      local data = type(item.data) == "table" and item.data or {}
      out[#out + 1] = { label = item.label, detail = item.detail, notes = data.notes or {}, velocities = data.velocities,
        controls = data.controls, edit = data.edit }
    end
    return out
  end } }
end

return M
