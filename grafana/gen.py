#!/usr/bin/env python3
"""Generate the provisioned Grafana dashboards -> ConfigMap grafana-dashboards."""
import json, subprocess
LOKI = {"type": "loki", "uid": "loki"}; PROM = {"type": "prometheus", "uid": "prometheus"}; TEMPO = {"type": "tempo", "uid": "tempo"}
BASE = '{app="kong-access"} | json'
FILTER = ' | request_id=~"$request_id" | user=~"$user"'
pid = [0]
def nid(): pid[0] += 1; return pid[0]
def stat(title, expr, x, w=4, unit="short", color="blue", ds=LOKI, thresholds=None):
    return {"id": nid(), "type": "stat", "title": title, "datasource": ds, "gridPos": {"x": x, "y": 1, "w": w, "h": 4},
            "targets": [{"expr": expr, "refId": "A", "queryType": "range", "legendFormat": ""}],
            "options": {"colorMode": "background", "graphMode": "area", "reduceOptions": {"calcs": ["sum"]}, "textMode": "value"},
            "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "fixed", "fixedColor": color}, "thresholds": thresholds or {"mode": "absolute", "steps": [{"color": color, "value": None}]}}}}
def ts(title, expr, x, y, w=12, h=8, unit="short", legend="{{__auto}}", stack=False, ds=LOKI, overrides=None):
    return {"id": nid(), "type": "timeseries", "title": title, "datasource": ds, "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "targets": [{"expr": expr, "refId": "A", "legendFormat": legend}],
            "fieldConfig": {"defaults": {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": 25 if stack else 8, "stacking": {"mode": "normal" if stack else "none"}, "showPoints": "never"}}, "overrides": overrides or []},
            "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["sum"]}, "tooltip": {"mode": "multi"}}}
def row(title, y): return {"id": nid(), "type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}}
def logs(title, expr, y, h=12): return {"id": nid(), "type": "logs", "title": title, "datasource": LOKI, "gridPos": {"x": 0, "y": y, "w": 24, "h": h},
            "targets": [{"expr": expr, "refId": "A"}], "options": {"showTime": True, "wrapLogMessage": True, "enableLogDetails": True, "sortOrder": "Descending"}}
def color_override(name, color): return {"matcher": {"id": "byName", "options": name}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": color}}]}

C = lambda e: f"sum(count_over_time({e} [$__auto]))"
panels = [row("Health at a glance", 0),
  stat("Requests", f'sum(count_over_time({BASE}{FILTER} [$__range]))', 0, color="blue"),
  stat("Errors (4xx/5xx)", f'sum(count_over_time({BASE} | status >= 400{FILTER} [$__range]))', 4, color="orange"),
  stat("Gateway-origin errors", f'sum(count_over_time({BASE} | error_source="gateway"{FILTER} [$__range]))', 8, color="purple"),
  stat("Provider-origin errors", f'sum(count_over_time({BASE} | error_source="provider"{FILTER} [$__range]))', 12, color="red"),
  stat("Cost (USD)", f'sum(sum_over_time({BASE} | unwrap cost{FILTER} [$__range]))', 16, unit="currencyUSD", color="green"),
  stat("p95 request latency", f'quantile_over_time(0.95, {BASE} | unwrap request_latency_ms{FILTER} [$__range])', 20, unit="ms", color="teal"),
  row("Errors: gateway vs provider", 5),
  ts("Errors by origin", f'sum by (error_source) (count_over_time({{app="kong-access", status_class=~"4xx|5xx"}} | json{FILTER} [$__auto]))', 0, 6, stack=True,
     overrides=[color_override("gateway", "purple"), color_override("provider", "red")]),
  ts("Requests by status class", f'sum by (status_class) (count_over_time({{app="kong-access"}} | json{FILTER} [$__auto]))', 12, 6, stack=True,
     overrides=[color_override("2xx", "green"), color_override("4xx", "orange"), color_override("5xx", "red")]),
  ts("Errors by status code", f'sum by (status) (count_over_time({BASE} | status >= 400{FILTER} [$__auto]))', 0, 14),
  ts("Errors by provider / model", f'sum by (provider, model) (count_over_time({BASE} | status >= 400 | provider != ""{FILTER} [$__auto]))', 12, 14),
  row("Usage and cost", 22),
  ts("Requests by model", f'sum by (model) (count_over_time({BASE} | model != ""{FILTER} [$__auto]))', 0, 23, stack=True),
  ts("Cost by department (USD)", f'sum by (dept) (sum_over_time({BASE} | unwrap cost | __error__="" {FILTER.replace(" | request_id", " | request_id")} [$__auto]))', 12, 23, unit="currencyUSD", stack=True),
  ts("Tokens: prompt vs completion", f'sum(sum_over_time({BASE} | unwrap prompt_tokens | __error__="" [$__auto]))', 0, 31),
  ts("Gateway added latency (kong_latency_ms, avg)", f'avg(avg_over_time({BASE} | unwrap kong_latency_ms | __error__="" [$__auto]))', 12, 31, unit="ms"),
  row("Request lookup (use the variables above: request ID, user)", 39),
  logs("Matching requests", f'{BASE}{FILTER}', 40, 12),
  {"id": nid(), "type": "table", "title": "Traces for the request ID (click a trace ID)", "datasource": TEMPO, "gridPos": {"x": 0, "y": 52, "w": 24, "h": 8},
   "targets": [{"refId": "A", "queryType": "traceql", "query": '{ span.kong.request.id =~ "$request_id" }', "limit": 20}]},
  row("Caching, RAG and routing", 62),
  ts("Semantic cache: hits vs misses", f'sum by (cache_status) (count_over_time({BASE} | cache_status != "" | cache_status != "null"{FILTER} [$__auto]))', 0, 63, stack=True, overrides=[color_override("hit", "green"), color_override("miss", "orange")]),
  ts("RAG-injected requests (Engineering handbook)", f'sum(count_over_time({BASE} | rag_injected="true"{FILTER} [$__auto]))', 12, 63),
  ts("Provider mix (failover / split)", f'sum by (provider) (count_over_time({BASE} | provider != "" | status = 200{FILTER} [$__auto]))', 0, 71, stack=True),
  ts("Routed model (claude-auto picks)", f'sum by (model) (count_over_time({BASE} | model != ""{FILTER} [$__auto]))', 12, 71, stack=True),
  row("Agents and MCP", 79),
  ts("Calls by agent", f'sum by (agent) (count_over_time({BASE} | agent != "" | agent != "null"{FILTER} [$__auto]))', 0, 80, stack=True),
  ts("Cost by agent (USD)", f'sum by (agent) (sum_over_time({BASE} | agent != "" | agent != "null" | unwrap cost | __error__=""{FILTER} [$__auto]))', 12, 80, unit="currencyUSD", stack=True),
  row("Security decisions (which check decided)", 88),
  ts("Security decisions by check", 'sum by (decision, check) (count_over_time({app="kong-security"} | json [$__auto]))', 0, 89, stack=True),
  ts("Gateway refusals by security check", f'sum by (security_check) (count_over_time({{app="kong-access", security_check!="none"}} | json [$__auto]))', 12, 89, stack=True),
  logs("Security decision log (CrowdStrike broker)", '{app="kong-security"} | json', 97, 10),
  row("Gateway error log (Kong error log via OpenTelemetry)", 108),
  logs("Gateway log lines", '{service_name="micron-aigw"} | request_id=~"$request_id"', 109, 10),
]

# ---- Usage by user (inserted after "Usage and cost"; later panels move down by USER_H)
def q(refid, expr): return {"refId": refid, "expr": expr, "queryType": "instant", "format": "table"}
UF = ' | user != "" | user != "null"' + FILTER
USER_H = 16
user_panels = [
  {"id": nid(), "type": "table", "title": "Usage by user (selected time range)", "datasource": LOKI, "gridPos": {"x": 0, "y": 39, "w": 24, "h": 8},
   "targets": [q("A", f'sum by (user) (count_over_time({BASE}{UF} [$__range]))'),
               q("B", f'sum by (user) (count_over_time({BASE} | status >= 400{UF} [$__range]))'),
               q("C", f'sum by (user) (sum_over_time({BASE} | unwrap prompt_tokens | __error__=""{UF} [$__range]))'),
               q("D", f'sum by (user) (sum_over_time({BASE} | unwrap completion_tokens | __error__=""{UF} [$__range]))'),
               q("E", f'sum by (user) (sum_over_time({BASE} | unwrap cost | __error__=""{UF} [$__range]))')],
   "transformations": [{"id": "joinByField", "options": {"byField": "user", "mode": "outer"}},
                       {"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"user": "User", "Value #A": "Requests", "Value #B": "Errors", "Value #C": "Prompt tokens", "Value #D": "Completion tokens", "Value #E": "Cost (USD)"}}},
                       {"id": "sortBy", "options": {"sort": [{"field": "Cost (USD)", "desc": True}]}}],
   "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": [
     {"matcher": {"id": "byName", "options": "Cost (USD)"}, "properties": [{"id": "unit", "value": "currencyUSD"}, {"id": "decimals", "value": 4}, {"id": "custom.cellOptions", "value": {"type": "color-background"}}]},
     {"matcher": {"id": "byName", "options": "Errors"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}, {"id": "custom.cellOptions", "value": {"type": "color-text"}}]}]},
   "options": {"showHeader": True, "cellHeight": "sm"}},
  ts("Requests by user", f'sum by (user) (count_over_time({BASE}{UF} [$__auto]))', 0, 47, stack=True),
  ts("Cost by user (USD)", f'sum by (user) (sum_over_time({BASE} | unwrap cost | __error__=""{UF} [$__auto]))', 12, 47, unit="currencyUSD", stack=True),
]
i = next(n for n, x in enumerate(panels) if x.get("title", "").startswith("Request lookup"))
for x in panels[i:]: x["gridPos"]["y"] += USER_H
panels[i:i] = user_panels
dash = {"uid": "micron-ops", "title": "Micron AI Gateway - Operations", "tags": ["micron"], "schemaVersion": 39, "version": 1, "refresh": "10s",
        "time": {"from": "now-1h", "to": "now"}, "timezone": "browser", "panels": panels, "graphTooltip": 1,
        "templating": {"list": [
          {"name": "request_id", "type": "textbox", "label": "Request ID", "query": ".*", "current": {"text": ".*", "value": ".*"}},
          {"name": "user", "type": "textbox", "label": "User (email)", "query": ".*", "current": {"text": ".*", "value": ".*"}}]}}
cm = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "grafana-dashboards", "namespace": "micron-aigw"}, "data": {"micron-ops.json": json.dumps(dash)}}
json.dump(cm, open("k8s/90-dashboards.json", "w"))
print("panels:", len(panels))
