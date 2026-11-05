-- Edge guard (global pre-function): clear, Anthropic-format errors BEFORE OIDC/ACL, plus the group header for model lists.
-- NOTE: decodes the bearer JWT WITHOUT verifying the signature; it only chooses a friendly error / list. Real authentication
-- (signature, expiry, audience) and authorization (model ACLs) are enforced by the OIDC strategy and model ACLs.
local cjson = require "cjson.safe"
ngx.req.clear_header("X-Micron-Group")
ngx.req.clear_header("X-Micron-Caller")
ngx.req.clear_header("X-Micron-Team")
ngx.req.set_header("X-Micron-Skip-Rag", "0")      -- 1 = skip embedding-based policies (big message, attachment, count_tokens)
ngx.req.set_header("X-Micron-Embed", "1")
ngx.req.set_header("X-Micron-Cache", "off")       -- eng | fin | ds | off  (selects the per-team semantic cache)
ngx.req.set_header("X-Micron-Rag", "0")

local function fail(status, typ, msg)
  pcall(function() local sp = kong.tracing.active_span(); if sp then sp:set_attribute("micron.error_source", "gateway-guard") end end)
  local rid = ngx.var.kong_request_id or kong.request.get_header("x-request-id") or ""
  return kong.response.exit(status,
    { type = "error", error = { type = typ, message = msg .. " (gateway request ID: " .. rid .. ")" }, request_id = rid },
    { ["Content-Type"] = "application/json", ["X-Request-Id"] = rid })
end

local auth = kong.request.get_header("authorization")
if not auth then return end
local tok = auth:match("^[Bb]earer%s+(.+)$")
if tok == "ACCESS-REMOVED" then   -- emitted by clients/okta_token.py when the IdP refuses to refresh (access removed)
  return fail(403, "permission_error", "Access removed: your account no longer has access to the AI Gateway (membership removed or sessions revoked). Contact your administrator.")
end
local b64 = tok and tok:match("^[^.]+%.([^.]+)%.")
if not b64 then return end
b64 = b64:gsub("-", "+"):gsub("_", "/")
local pad = #b64 % 4
if pad > 0 then b64 = b64 .. string.rep("=", 4 - pad) end
local raw = ngx.decode_base64(b64)
local c = raw and cjson.decode(raw)
if not c then return end
if c.agent == "" or type(c.agent) ~= "string" then c.agent = nil end   -- humans carry an empty agent claim

-- WRONG-ISSUER: a token from another Okta authorization server (e.g. the workshop's /oauth2/default) can never verify here.
-- Say so, with the exact settings to use, instead of the generic "invalid signature / Unauthorized".
do
  local EXPECTED = "__OKTA_ISSUER__"
  if type(c.iss) == "string" and c.iss ~= EXPECTED then
    return fail(401, "authentication_error", "Wrong identity-provider settings: this token was issued by " .. c.iss .. ". The Micron gateway only accepts tokens from " .. EXPECTED .. " (client ID __OKTA_CLIENT_ID__). In Claude Desktop set Issuer URL and Client ID to those values; do not use the workshop /oauth2/default values.")
  end
end
-- tag the trace with the caller (unverified decode is fine here: OIDC verifies the same token)
pcall(function()
  local span = kong.tracing.active_span()
  if span and c.email then span:set_attribute("enduser.id", c.email) end
  if span and type(c.groups) == "table" then span:set_attribute("enduser.group", table.concat(c.groups, ",")) end
end)
if c.email then ngx.req.set_header("X-Micron-Caller", c.email) end
-- 1. group header for GET /v1/models selection
local have = {}
if type(c.groups) == "table" then for _, g in ipairs(c.groups) do have[g] = true end end
local grp
for _, g in ipairs({ "Demo-Engineering", "Demo-DataScience", "Demo-Finance" }) do
  if have[g] then grp = g; break end
end
if grp then
  ngx.req.set_header("X-Micron-Group", grp)
  ngx.req.set_header("X-Micron-Team", (grp == "Demo-Engineering" and "Engineering") or (grp == "Demo-DataScience" and "DataScience") or "Finance")
end


-- ===== MCP tool-level ACLs (server + tool, by group; plus per-agent limits). JSON-RPC errors name the user AND the agent. =====
local path0 = kong.request.get_path()
local server = path0:match("^/mcp/([%w%-]+)")
if server and kong.request.get_method() == "POST" then
  local MCP_GROUPS = {          -- server -> tool -> groups allowed ("*" = every tool of the server)
    ["ticketing"]   = { ["*"] = { "Demo-Engineering" } },
    ["code-search"] = { ["*"] = { "Demo-Engineering" } },
    ["hr-records"]  = { ["*"] = {} },                       -- no group is allowed on HR records (incl. get_employee_salary)
  }
  local AGENT_TOOLS = {         -- agent -> server -> allowed tools
    ["ticket-triage-agent"] = { ["ticketing"] = { list_tickets = true, get_ticket = true, set_ticket_priority = true } },
    ["release-notes-agent"] = { ["code-search"] = { search_code = true, get_file = true, list_merged_prs = true } },
  }
  local MCP_BLOCKED = {         -- maintained by the ops watcher: tools whose description changed since they were approved
    -- MCPBLOCK-BEGIN
    -- MCPBLOCK-END
  }
  local rpc = kong.request.get_body()
  if type(rpc) == "table" and rpc.method == "tools/call" and type(rpc.params) == "table" then
    local tool = tostring(rpc.params.name)
    local who = c.email or c.sub or "unknown"
    local via = c.agent and (" via " .. c.agent) or ""
    local function deny(msg)
      local rid = ngx.var.kong_request_id or ""
      pcall(function() local sp = kong.tracing.active_span(); if sp then sp:set_attribute("micron.error_source", "gateway-guard"); sp:set_attribute("micron.mcp_denied_tool", server .. "/" .. tool) end end)
      pcall(kong.log.set_serialize_value, "micron_security_check", "mcp-tool-acl")
      kong.log.notice("[mcp-acl] DENIED ", who, via, " -> ", server, "/", tool)
      return kong.response.exit(200, { jsonrpc = "2.0", id = rpc.id, error = { code = -32001,
        message = "Tool denied: " .. who .. via .. " may not call '" .. tool .. "' on MCP server '" .. server .. "'. " .. msg .. " (gateway request ID: " .. rid .. ")" } },
        { ["Content-Type"] = "application/json", ["X-Request-Id"] = rid })
    end
    if MCP_BLOCKED[server .. "/" .. tool] then
      return deny("Tool blocked: its description changed since it was approved (possible tool poisoning). A security review is required before it can be used.")
    end
    local acl = MCP_GROUPS[server]
    if acl then
      local allowed_groups = acl[tool] or acl["*"] or {}
      local ok = false
      for _, g in ipairs(allowed_groups) do if have[g] then ok = true end end
      if not ok then return deny("Your group is not allowed to use this tool.") end
    end
    if c.agent then
      local a = AGENT_TOOLS[c.agent]
      if not a or not a[server] or not a[server][tool] then return deny("This agent is not permitted to use this tool.") end
    end
  end
end

local path = kong.request.get_path()
local npath = path:gsub("^/sandbox", "")   -- /sandbox/anthropic = the Sandbox route (Data Science); same model entities, same aliases
if path:match("^/bedrock/") and kong.request.get_method() == "POST" then      -- record the Bedrock service tier (flex/priority/standard) in the access log
  local b = kong.request.get_body()
  local tier = type(b) == "table" and type(b.serviceTier) == "table" and b.serviceTier.type or "standard"
  pcall(kong.log.set_serialize_value, "micron_service_tier", tier)
end
if not npath:match("^/anthropic/v1/messages") then return end

if npath:match("count_tokens$") then ngx.req.set_header("X-Micron-Skip-Rag", "1") end
-- 2. expired token
if c.exp and c.exp < ngx.time() then
  return fail(401, "authentication_error", "Your sign-in has expired. Sign in again (token expired " .. (ngx.time() - c.exp) .. "s ago).")
end
-- 3. urgent gateway-side revoke list (rewritten by scripts/revoke-user.sh)
local DENIED = {
  -- DENYLIST-BEGIN
  -- DENYLIST-END
}
local who = c.email or c.sub
if who and DENIED[who] then
  return fail(403, "permission_error", "Access removed: your account has been disabled for the AI Gateway. Contact your administrator.")
end
-- 4. no demo group at all = membership removed
if not grp then
  return fail(403, "permission_error", "Access removed: you are no longer a member of a group that can use the AI Gateway. Contact your administrator.")
end
-- 4b. Sandbox route is for Data Science only; everyone else uses /anthropic
local on_sandbox = path:find("^/sandbox") ~= nil
if on_sandbox and grp ~= "Demo-DataScience" then
  return fail(403, "permission_error", "Wrong route: /sandbox/anthropic is the Sandbox route for the Data Science group. Use https://micron.kong-sales-engineering.com/anthropic (your group: " .. grp .. ").")
end
if grp == "Demo-DataScience" and not on_sandbox and npath == "/anthropic/v1/messages" then
  return fail(403, "permission_error", "Wrong route: Data Science uses the Sandbox route. Set the base URL to https://micron.kong-sales-engineering.com/sandbox/anthropic.")
end
-- 5. model not allowed for this group (families; ACLs still enforce independently)
if kong.request.get_method() == "POST" and npath == "/anthropic/v1/messages" then
  local len = tonumber(kong.request.get_header("content-length") or "0") or 0
  if len >= 3900000 then ngx.req.set_header("X-Micron-Skip-Rag", "1") end   -- big bodies are attachments (PDFs/images): RAG injector can't handle them
  if len < 3900000 then
    local body = kong.request.get_body()
    local m = type(body) == "table" and body.model
    if type(body) == "table" and type(body.messages) == "table" then
      for _, msg in ipairs(body.messages) do
        if type(msg.content) == "table" then
          for _, blk in ipairs(msg.content) do
            if type(blk) == "table" and (blk.type == "document" or blk.type == "image" or blk.type == "tool_result") then ngx.req.set_header("X-Micron-Skip-Rag", "1") end
          end
        end
      end
    end
    if type(m) == "string" then
      -- the request body's model name is the ONLY thing the gateway routes on: say so clearly when it matches nothing
      local KNOWN = { ["claude-opus-5-5"]=1, ["claude-opus-5"]=1, ["claude-opus-4-8"]=1, ["claude-opus-4-7"]=1, ["claude-opus-4-6"]=1, ["claude-opus-4-5-20251101"]=1, ["claude-opus"]=1,
        ["claude-sonnet-5-5"]=1, ["claude-sonnet-5"]=1, ["claude-sonnet-4-6"]=1, ["claude-sonnet-4-5-20250929"]=1, ["claude-sonnet"]=1,
        ["claude-haiku-5-5"]=1, ["claude-haiku-4-5-20251001"]=1, ["claude-haiku"]=1,
        ["claude-auto"]=1, ["claude-sonnet-split"]=1, ["claude-sonnet-bedrock"]=1, ["gpt-4o"]=1 }
      if not KNOWN[m] then
        local avail = have["Demo-Engineering"] and "claude-opus-5-5, claude-sonnet-5-5, claude-haiku-5-5" or "claude-sonnet-5-5, claude-haiku-5-5"
        return fail(404, "not_found_error", "model: " .. m .. " is not available through this gateway. Models for your group: " .. avail .. ". (Claude Code: set ANTHROPIC_MODEL / ANTHROPIC_DEFAULT_*_MODEL to one of these.)")
      end
      local allowed = (m:find("opus", 1, true) and have["Demo-Engineering"])
        or (m:find("sonnet", 1, true) and true) or (m:find("haiku", 1, true) and true)
      if m:find("opus", 1, true) == nil and m:find("sonnet", 1, true) == nil and m:find("haiku", 1, true) == nil then allowed = true end
      if m:find("gpt-", 1, true) then allowed = have["Demo-DataScience"] and true or false end
      if m == "claude-auto" and not have["Demo-Engineering"] then allowed = false end
      if not allowed then
        return fail(403, "permission_error", "Model not allowed: your group (" .. grp .. ") cannot use '" .. m .. "'. Ask your administrator for access.")
      end
      -- embedding-based policies (semantic guard / cache / RAG) cannot embed huge inputs: skip them when the last message is too long
      if type(body.messages) == "table" and #body.messages > 0 then
        local lastm = body.messages[#body.messages]; local n = 0   -- last message too long?
        if type(lastm.content) == "string" then n = #lastm.content
        elseif type(lastm.content) == "table" then for _, blk in ipairs(lastm.content) do if type(blk) == "table" then n = n + #(blk.text or "") + #(type(blk.content) == "string" and blk.content or "") end end end
        if n > 20000 then ngx.req.set_header("X-Micron-Skip-Rag", "1") end
      end
      -- knowledge-source ACL: the Engineering handbook is Engineering-only
      if not have["Demo-Engineering"] and type(body.messages) == "table" then
        local last = body.messages[#body.messages]
        local txt = ""
        if last and type(last.content) == "string" then txt = last.content
        elseif last and type(last.content) == "table" then
          for _, blk in ipairs(last.content) do if type(blk) == "table" and type(blk.text) == "string" then txt = txt .. " " .. blk.text end end
        end
        if txt:lower():find("engineering handbook", 1, true) then
          return fail(403, "permission_error", "Access denied: the Engineering handbook is a knowledge source restricted to the Engineering group (your group: " .. grp .. ").")
        end
      end
    end
  end
end

-- FINALIZE-POLICY-FLAGS: reduce the policy conditions to single header comparisons
do
  local skip = kong.request.get_header("x-micron-skip-rag") == "1"
  local ua = kong.request.get_header("user-agent") or ""
  local coding = ua:find("claude-cli", 1, true) ~= nil
  ngx.req.set_header("X-Micron-Embed", skip and "0" or "1")
  local team = kong.request.get_header("x-micron-team")
  if not skip and not coding then
    if team == "Engineering" then ngx.req.set_header("X-Micron-Cache", "eng"); ngx.req.set_header("X-Micron-Rag", "1") end
  end
end
