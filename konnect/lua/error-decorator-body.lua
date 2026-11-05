-- SSE: if the stream ends WITHOUT message_stop the provider/connection dropped mid-answer: append an Anthropic-format error event
-- and mark the request as a failure (with an estimate of the output that was delivered) so logs/metrics don't count it as a success.
if kong.ctx.plugin.sse then
  local ch, fin = ngx.arg[1] or "", ngx.arg[2]
  if ch:find("message_stop", 1, true) then kong.ctx.plugin.stopped = true end
  if ch:find("event: error", 1, true) then
    ch = ch:gsub('mid%-stream"', 'mid-stream (gateway request ID: ' .. (ngx.var.kong_request_id or "") .. ')"')
    ngx.arg[1] = ch
    kong.ctx.plugin.errored = true
    pcall(kong.log.set_serialize_value, "micron_stream_failed", true)
    pcall(kong.log.set_serialize_value, "micron_stream_est_tokens", math.floor((kong.ctx.plugin.est or 0) / 8))
  end
  kong.ctx.plugin.est = (kong.ctx.plugin.est or 0) + #ch
  if fin and not kong.ctx.plugin.stopped and not kong.ctx.plugin.errored then
    local rid = ngx.var.kong_request_id or ""
    pcall(kong.log.set_serialize_value, "micron_stream_failed", true)
    pcall(kong.log.set_serialize_value, "micron_stream_est_tokens", math.floor(kong.ctx.plugin.est / 8))
    ngx.arg[1] = ch .. 'event: error\ndata: {"type":"error","error":{"type":"api_error","message":"The model response was interrupted before it finished (the provider connection dropped mid-stream). Partial output above is incomplete. Retry the request. (gateway request ID: ' .. rid .. ')"}}\n\n'
  end
  return
end
-- (body_filter) append "(gateway request ID: X)" to Anthropic-format error messages from providers; Bedrock/other bodies get request_id too
if kong.ctx.plugin.decorate then
  local cjson = require "cjson.safe"
  local chunk, eof = ngx.arg[1], ngx.arg[2]
  kong.ctx.plugin.buf = (kong.ctx.plugin.buf or "") .. (chunk or "")
  if not eof then ngx.arg[1] = nil; return end
  local rid = ngx.var.kong_request_id or ""
  local body = cjson.decode(kong.ctx.plugin.buf)
  if type(body) == "table" then
    -- name the security check that refused the request (guard plugins answer with terse generic messages)
    local raw = (type(body.error) == "table" and body.error.message) or body.message
    local status = kong.response.get_status()
    local check
    if raw == "prompt pattern is blocked." then
      check = "ai-prompt-guard"
      body = { type = "error", error = { type = "invalid_request_error", message = "Blocked by security check AI Prompt Guard: the prompt matches a prohibited pattern (prompt injection, or sensitive data such as an API key or ID number). Nothing was sent to the model." } }
    elseif raw == "bad request" and status == 400 then
      check = "ai-semantic-prompt-guard"
      body = { type = "error", error = { type = "invalid_request_error", message = "Blocked by security check AI Semantic Prompt Guard: the prompt is semantically close to a prohibited instruction (prompt injection). Nothing was sent to the model." } }
    elseif type(raw) == "string" and raw:find("Blocked by security check CrowdStrike", 1, true) then
      check = "crowdstrike-aidr"
      body = { type = "error", error = { type = "invalid_request_error", message = raw } }
    elseif type(raw) == "string" and raw:lower():find("guardrail", 1, true) and status >= 500 then
      check = "crowdstrike-aidr-unavailable"
      body = { type = "error", error = { type = "api_error", message = "Security service unavailable: the CrowdStrike AIDR check could not be reached and this route is configured to fail closed, so the request was refused. Try again shortly." } }
    end
    if check then pcall(kong.log.set_serialize_value, "micron_security_check", check) end
    if type(body.error) == "table" and type(body.error.message) == "string" then
      if not body.error.message:find("gateway request ID", 1, true) then
        body.error.message = body.error.message .. " (gateway request ID: " .. rid .. ")"
      end
    elseif type(body.message) == "string" then
      body = { type = "error", error = { type = "api_error", message = body.message .. " (gateway request ID: " .. rid .. ")" } }
    end
    body.gateway_request_id = rid
    ngx.arg[1] = cjson.encode(body)
  else
    ngx.arg[1] = kong.ctx.plugin.buf
  end
end
