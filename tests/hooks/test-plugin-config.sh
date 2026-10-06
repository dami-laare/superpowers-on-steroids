#!/usr/bin/env bash
# plugin.json userConfig: role-keyed model + effort fields with real defaults.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "plugin config tests"

if node -e '
const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).userConfig;
const fail = (m) => { console.error("  [FAIL] " + m); process.exit(1); };
const expectedOrder = ["mode","implementer_mechanical_model","implementer_judgment_model","implementer_effort","reviewer_model","reviewer_effort","investigator_model","investigator_effort","final_reviewer_model","final_reviewer_effort"];
const keys = Object.keys(cfg);
if (JSON.stringify(keys) !== JSON.stringify(expectedOrder)) fail("keys/order: " + keys.join(","));
const defaults = { mode: "standard", implementer_mechanical_model: "haiku", implementer_judgment_model: "sonnet", implementer_effort: "low", reviewer_model: "sonnet", reviewer_effort: "medium", investigator_model: "sonnet", investigator_effort: "medium", final_reviewer_model: "opus", final_reviewer_effort: "high" };
for (const [k, v] of Object.entries(defaults)) {
  if (cfg[k].type !== "string") fail(`${k}.type`);
  if (cfg[k].default !== v) fail(`${k}.default = ${cfg[k].default}, want ${v}`);
  if (!cfg[k].title) fail(`${k}.title missing`);
  const envName = "SUPERPOWERS_" + k.toUpperCase();
  if (!cfg[k].description.includes(envName)) fail(`${k}.description lacks ${envName}`);
}
if (JSON.stringify(cfg.mode.options) !== JSON.stringify(["standard","fast"])) fail("mode.options");
for (const k of keys.filter((k) => k.endsWith("_effort"))) {
  if (JSON.stringify(cfg[k].options) !== JSON.stringify(["low","medium","high"])) fail(`${k}.options`);
  if (!cfg[k].description.includes("fast mode only")) fail(`${k}.description lacks "fast mode only"`);
  if (!cfg[k].description.includes("maxEffortLevel")) fail(`${k}.description lacks maxEffortLevel clamp note`);
}
const agentOf = { implementer: "caveman-implementer-", reviewer: "caveman-reviewer-", investigator: "caveman-investigator-", final_reviewer: "caveman-final-reviewer-" };
for (const [role, agent] of Object.entries(agentOf)) {
  for (const k of keys.filter((k) => k.startsWith(role + "_"))) {
    if (!cfg[k].description.includes(agent)) fail(`${k}.description lacks ${agent}`);
  }
}
for (const k of keys.filter((k) => k.endsWith("_model"))) {
  if (JSON.stringify(cfg[k].options) !== JSON.stringify(["haiku","sonnet","opus","fable"])) fail(`${k}.options`);
  if (!cfg[k].description.includes("Agent-tool alias")) fail(`${k}.description lacks "Agent-tool alias"`);
}
for (const legacy of ["model_cheap","model_standard","model_capable"]) if (legacy in cfg) fail(`legacy key ${legacy} still present`);
if (Object.keys(cfg.mode).includes("options") === false) fail("mode has no options");
' "$REPO_ROOT/.claude-plugin/plugin.json"; then
    echo "  [PASS] userConfig has the ten role-keyed fields with defaults, options, and env names"
    echo "STATUS: PASSED"
else
    echo "STATUS: FAILED (1 failure(s))"
    exit 1
fi
