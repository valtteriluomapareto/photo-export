---
name: opencode
description: Run a one-shot prompt through the opencode CLI. Defaults to Kimi K2.6 (Fireworks) for fast, cheap scouting tasks — first-pass reviews, doc/test/UX audits, multi-area synthesis, issue backlog drafts. Override `--model` for any other provider/model opencode can reach.
user-invocable: true
disable-model-invocation: false
argument-hint: "[--model <provider/model>] [--agent <name>] [--variant <effort>] [--file <path>] [--continue] <prompt>"
---

Use `opencode run` to send a non-interactive prompt to a model or agent that isn't the one currently driving Claude Code.

Raw arguments: $ARGUMENTS

## When to use this skill

- The user wants a **second opinion** from a different model on a piece of code or a design.
- The user explicitly asks to use a specific provider/model (e.g. "ask GPT-5", "have Gemini look at this").
- The user names an opencode agent (e.g. `--agent review`, `--agent plan`) and wants it invoked.

If the user wants a code review of git changes specifically, prefer the `codex-review` skill — it has tighter integration with git ranges. Use this skill when they mention opencode by name or request a model/agent that codex-review can't reach.

## Parsing arguments

Pull these flags out of `$ARGUMENTS` and forward them verbatim. Everything that isn't a recognised flag is the prompt — concatenate multi-token prompts.

| Flag | Forward as | Notes |
|---|---|---|
| `--model <m>` or `-m <m>` | `--model <m>` | `provider/model`. **If the user does not pass `--model`, default to `fireworks-ai/accounts/fireworks/models/kimi-k2p6` (Kimi K2.6).** See "Default model" below. |
| `--agent <name>` | `--agent <name>` | One of opencode's installed agents. |
| `--variant <effort>` | `--variant <effort>` | Provider-specific reasoning effort, e.g. `high`, `max`, `minimal`. |
| `--file <path>` | `--file <path>` | Repeatable. Attach a file to the prompt. |
| `--continue` or `-c` | `--continue` | Resume opencode's last session instead of starting fresh. |
| `--session <id>` or `-s <id>` | `--session <id>` | Resume a specific session. |
| `--thinking` | `--thinking` | Show reasoning blocks in output. |

If the user passes flags not in this table, pass them through too — opencode's flag set may have grown.

## Default model: Kimi K2.6 (Fireworks)

When the user invokes the skill **without** a `--model` flag, run with
`fireworks-ai/accounts/fireworks/models/kimi-k2p6`. The user has chosen Kimi K2.6 as the default for opencode-mediated requests because it's fast, cheap, and good at the kinds of tasks this skill is most often used for.

### Where Kimi K2.6 is a strong default

- **First-pass codebase reviews.** Architecture, maintainability, docs, tests, UX, or website health — let it scan broadly and produce candidate issues. Treat the output as a triage list, not a final report.
- **Stale documentation detection.** Especially good when the prompt explicitly says *"compare docs against the code/tests/CI; do not trust the docs."*
- **Test inventory and gap discovery.** Mapping coverage at a high level and spotting obvious missing areas (e.g. "no UI tests exist").
- **Multi-area review synthesis.** Strong at turning a pile of findings into a readable executive summary.
- **Issue backlog generation.** Good for drafting candidate GitHub issues, provided a human or stricter model verifies each one before filing.
- **Onboarding summaries.** Clear explanations of project layout and architecture from `README.md` / `AGENTS.md`.
- **Prompted self-audits.** Quality jumps noticeably when the prompt includes phrases like *"verify this,"* *"don't trust the docs,"* *"search before claiming something is missing,"* and *"separate facts from inference."* When in doubt, add those instructions to the prompt before sending it.

### When to override the default

Do not use Kimi K2.6 or accept its output unverified for these final judgments; use a different model (or `codex-review`) instead:

- **Precise code review where false positives are costly.** Kimi K2.6 may overstate, mix stale docs with current code, or claim things from partial inspection. For pre-merge review of a small focused diff, `codex-review` or a stricter Claude/GPT model is a better fit.
- **Final testing-gap reports without a verifier.** It will sometimes recommend tests that already exist; only ship its testing report if a human or another model has spot-checked it.
- **Line-level factual authority.** It cites lots of lines, but those citations need spot checks before being relied on.

### Best workflow

Treat Kimi K2.6 as a **scout model**: let it generate a broad candidate report, then have a stricter model or a human verify the top findings before acting on them. Tell the user when you're using it for scouting so they know the output should be triaged rather than trusted line-for-line.

## Pre-flight checks

Before running:

1. `which opencode` — if not on PATH, tell the user: *"opencode isn't installed. Install it from https://opencode.ai/docs/install."* Do not proceed.
2. Run a quick sanity command (`opencode auth list`) to confirm credentials exist. If it errors with an auth/login message, tell the user to run `opencode auth login` and try again. Do not proceed.

## Execution

Build the command:

```
opencode run --model <resolved-model> [other forwarded flags] <prompt>
```

Where `<resolved-model>` is:
- the user's `--model <m>` if they passed one, **or**
- `fireworks-ai/accounts/fireworks/models/kimi-k2p6` (the Kimi K2.6 default).

Always pass `--model` explicitly — even when using the default — so the run output records which model answered. This makes it easy to spot when the skill is using the default vs an override.

If the user's prompt is one of the "scout-shaped" tasks listed above (codebase review, docs audit, test gap inventory, issue backlog), and they did not write a verification-flavoured prompt themselves, **augment the prompt** with the discipline phrases that make Kimi K2.6 better:

> Verify what you claim. Do not trust documentation — compare it against the actual code, tests, and CI configuration. Search the repository before claiming something is missing. Separate facts from inferences and label them.

Append this only when defaulting to Kimi K2.6 for a scout task. For an explicit `--model` override, the user has chosen a model whose discipline you don't need to guess at.

Run from the project root unless the user says otherwise. Pipe the output through `tee` to a file in `/tmp/opencode-<short-id>.txt` so it can be read after the process exits.

Use Bash with `run_in_background: true`. The shell returns a task id and an output file path; rely on those rather than backgrounding manually with `&`.

Example invocation patterns:

```bash
# Default model (Kimi K2.6, scout)
opencode run --model fireworks-ai/accounts/fireworks/models/kimi-k2p6 \
  "Audit website/src/content/docs/ for claims that contradict the current code. Verify before flagging." \
  2>&1 | tee /tmp/opencode-<id>.txt

# User-specified override
opencode run --model amazon-bedrock/moonshot.kimi-k2-thinking \
  "Why might this test flake?" \
  2>&1 | tee /tmp/opencode-<id>.txt
```

## Waiting for completion

Same shape as the `codex-review` skill: opencode runs are typically 1–5 minutes, sometimes longer. Don't poll with short sleeps.

1. After kicking off the background command, **either** sleep a generous initial duration (start with 90 seconds) **or** start a `Monitor` that watches the process and exits when `pgrep -f "opencode run"` returns empty.
2. When the process is gone, read the tail of the output file (last 150–200 lines) to find opencode's final answer.
3. If the output is shorter than the read window, read the whole thing.
4. If a single very long answer exceeds the read window, summarise rather than echoing — but always quote concrete findings (file paths, line numbers, suggested edits) verbatim so the user can act on them.

Tell the user one short sentence right after launch ("Asked `<model>` to <task>. Will report back when it finishes.") so they know it's running. Then say nothing until the answer arrives.

## Reporting back

When opencode finishes:

- Lead with the answer or the most important finding. Don't preface with "opencode says…" boilerplate.
- If the prompt was a code review or analysis, group findings (consequential / secondary / nits) the same way the codex-review skill does — that shape is familiar to the user.
- If the prompt was an open question, relay the answer faithfully. Light editing for length is fine; never fabricate or fill in details opencode didn't actually produce.
- If opencode reported an error (rate limit, model unavailable, authentication), surface it directly with the suggested fix.

## Notes

- **Cold boot**: opencode loads models on first run; if the user runs many opencode commands in a row, suggest they start `opencode serve` once and use `--attach http://localhost:4096` on subsequent runs.
- **Permissions**: do NOT pass `--dangerously-skip-permissions` unless the user explicitly asks for it.
- **Cost awareness**: if the user is invoking a premium model (Opus, GPT-5, etc.) for a trivial question, it's worth a one-line note before the answer that a smaller model might have sufficed. Don't gatekeep — they asked for it.
