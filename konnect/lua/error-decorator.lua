-- (header_filter) mark upstream error responses so body_filter can add the gateway request ID to the message text
local status = kong.response.get_status()
if status >= 400 then
  local ct = kong.response.get_header("content-type") or ""
  if ct:find("json", 1, true) then
    kong.ctx.plugin.decorate = true
    kong.response.clear_header("Content-Length")
  end
end

-- streaming responses: remember that this is an SSE stream so body_filter can detect a stream that ends without message_stop
local ct2 = kong.response.get_header("content-type") or ""
-- model routes only: MCP/A2A streams never send message_stop
if status < 400 and ct2:find("event-stream", 1, true) and (kong.request.get_path() or ""):find("/v1/messages", 1, true) then kong.ctx.plugin.sse = true; kong.ctx.plugin.est = 0 end
