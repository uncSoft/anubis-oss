#!/usr/bin/env python3
"""
Refresh the "Key Findings" narrative in analysis.html using live leaderboard data.

What it does
------------
1. Fetches the live leaderboard JSON from the public API.
2. Builds a structured digest of stats (per-chip, per-backend, per-format,
   per-memory-tier, top runs, big-model club, reasoning models, recent
   activity, contributors).
3. Sends the digest plus the existing findings to Claude with a strict
   format spec, asking it to keep what's still accurate and replace what's
   stale (always exactly 5 cards).
4. Writes the new findings between the AI-FINDINGS-START / AI-FINDINGS-END
   markers in analysis.html and bumps the "Findings last updated" date.

The script never commits or pushes. Review the diff yourself before
`git commit`.

Setup
-----
    pip install anthropic
    export ANTHROPIC_API_KEY=sk-ant-...

Usage
-----
    # Default: fetch, call Claude, write to analysis.html
    python scripts/refresh-findings.py

    # Print the new findings to stdout, don't touch the file
    python scripts/refresh-findings.py --dry-run

    # Just print the data digest, no API call
    python scripts/refresh-findings.py --digest-only

    # Pick a different model
    python scripts/refresh-findings.py --model claude-opus-4-7

The default model is claude-sonnet-4-6 — capable enough for narrative
analysis at a fraction of opus cost.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

API_URL = "https://devpadapp.com/anubis/api/leaderboard.php?limit=10000"
ANALYSIS_HTML = Path(__file__).resolve().parent.parent / "analysis.html"
START_MARKER = "<!-- AI-FINDINGS-START -->"
END_MARKER = "<!-- AI-FINDINGS-END -->"

DEFAULT_MODEL = "claude-sonnet-4-6"


# ── Data fetch + digest ──────────────────────────────────────────────


def fetch_entries() -> list[dict]:
    req = urllib.request.Request(API_URL, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status != 200:
            raise SystemExit(f"API returned HTTP {r.status}")
        data = json.load(r)
    entries = data.get("entries") or []
    if not entries:
        raise SystemExit("Leaderboard returned no entries.")
    return entries


def is_valid(e: dict) -> bool:
    """Filter out broken historical rows (impossibly high tok/s from prompt_eval_duration ~ 0)."""
    tps = e.get("tokens_per_second")
    return tps is not None and 0 < tps < 2000


def chip_order(name: str) -> tuple[int, int]:
    if not name:
        return (99, 99)
    m = re.search(r"M(\d+)\s*(Pro|Max|Ultra)?", name, re.I)
    if m:
        gen = int(m.group(1))
        tier = {"": 0, "Pro": 1, "Max": 2, "Ultra": 3}.get(m.group(2) or "", 0)
        return (gen, tier)
    if re.search(r"A\d+", name, re.I):
        return (10, 0)
    return (99, 99)


def parse_param_count(model_name: str | None) -> int | None:
    if not model_name:
        return None
    m = re.search(r"(\d{1,4})\s*[bB]\b", model_name)
    return int(m.group(1)) if m else None


def prefill_tps(e: dict) -> float | None:
    pt = e.get("prompt_tokens")
    pd = e.get("prompt_eval_duration")
    if not pt or not pd or pd <= 0 or pt <= 0:
        return None
    return pt / pd


def reasoning_tps(e: dict) -> float | None:
    rt = e.get("reasoning_tokens")
    rd = e.get("reasoning_duration")
    if not rt or not rd or rd <= 0 or rt <= 0:
        return None
    return rt / rd


def stats_block(values: list[float]) -> dict:
    values = [v for v in values if v is not None]
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "avg": round(statistics.mean(values), 2),
        "median": round(statistics.median(values), 2),
        "max": round(max(values), 2),
        "min": round(min(values), 2),
    }


def build_digest(entries: list[dict]) -> dict:
    valid = [e for e in entries if is_valid(e)]

    # Per-chip
    by_chip: dict[str, list[dict]] = defaultdict(list)
    for e in valid:
        by_chip[e.get("chip_name") or "Unknown"].append(e)

    chips_sorted = sorted(by_chip.keys(), key=chip_order)
    per_chip = []
    for chip in chips_sorted:
        runs = by_chip[chip]
        ttft_ms = [e["time_to_first_token"] * 1000 for e in runs if e.get("time_to_first_token")]
        watts_per_tok = [e["avg_watts_per_token"] for e in runs if e.get("avg_watts_per_token")]
        bandwidth = next((e.get("chip_bandwidth_gbs") for e in runs if e.get("chip_bandwidth_gbs")), None)
        per_chip.append({
            "chip": chip,
            "bandwidth_gbs": bandwidth,
            "tps": stats_block([e["tokens_per_second"] for e in runs]),
            "median_ttft_ms": round(statistics.median(ttft_ms), 1) if ttft_ms else None,
            "avg_watts_per_token": round(statistics.mean(watts_per_tok), 4) if watts_per_tok else None,
        })

    # Per-backend (n>=3)
    by_backend: dict[str, list[float]] = defaultdict(list)
    for e in valid:
        by_backend[e.get("backend") or "unknown"].append(e["tokens_per_second"])
    per_backend = sorted(
        [
            {"backend": k, "n": len(v), "avg_tps": round(statistics.mean(v), 2),
             "median_tps": round(statistics.median(v), 2)}
            for k, v in by_backend.items() if len(v) >= 3
        ],
        key=lambda x: x["avg_tps"],
        reverse=True,
    )

    # Per-format
    fmt_counts = Counter((e.get("model_format") or "unknown").lower() for e in valid)
    fmt_avg = {}
    for fmt in fmt_counts:
        runs = [e["tokens_per_second"] for e in valid if (e.get("model_format") or "unknown").lower() == fmt]
        fmt_avg[fmt] = {"n": len(runs), "avg_tps": round(statistics.mean(runs), 2)}

    # Per-memory-tier
    by_mem: dict[int, list[float]] = defaultdict(list)
    for e in valid:
        if e.get("chip_memory_gb"):
            by_mem[e["chip_memory_gb"]].append(e["tokens_per_second"])
    per_mem = [
        {"memory_gb": k, "n": len(v), "avg_tps": round(statistics.mean(v), 2)}
        for k, v in sorted(by_mem.items())
    ]

    # Top 15 runs (sanitised view)
    top_runs = sorted(valid, key=lambda e: e["tokens_per_second"], reverse=True)[:15]
    top_runs = [{
        "model": e.get("model_name"),
        "chip": e.get("chip_name"),
        "memory_gb": e.get("chip_memory_gb"),
        "tps": round(e["tokens_per_second"], 1),
        "ttft_ms": round(e["time_to_first_token"] * 1000, 0) if e.get("time_to_first_token") else None,
        "watts_per_tok": e.get("avg_watts_per_token"),
        "backend": e.get("backend"),
        "format": e.get("model_format"),
        "quant": e.get("model_quantization"),
    } for e in top_runs]

    # Big-model club (>=100B params)
    big = []
    for e in valid:
        p = parse_param_count(e.get("model_name"))
        if p and p >= 100:
            big.append({
                "model": e.get("model_name"),
                "params_b": p,
                "chip": e.get("chip_name"),
                "memory_gb": e.get("chip_memory_gb"),
                "tps": round(e["tokens_per_second"], 1),
                "quant": e.get("model_quantization"),
                "backend": e.get("backend"),
            })
    big.sort(key=lambda x: x["tps"], reverse=True)
    big = big[:15]

    # Reasoning models (v3.1+ data)
    reasoning = []
    for e in valid:
        rtps = reasoning_tps(e)
        if rtps is None:
            continue
        reasoning.append({
            "model": e.get("model_name"),
            "chip": e.get("chip_name"),
            "memory_gb": e.get("chip_memory_gb"),
            "output_tps": round(e["tokens_per_second"], 1),
            "prefill_tps": round(prefill_tps(e), 1) if prefill_tps(e) else None,
            "reasoning_tps": round(rtps, 1),
            "reasoning_tokens": e.get("reasoning_tokens"),
        })
    reasoning.sort(key=lambda x: x["output_tps"], reverse=True)
    reasoning = reasoning[:10]

    # Prefill leaderboard (v3.1+ data)
    prefill_runs = []
    for e in valid:
        ptps = prefill_tps(e)
        if ptps is None or ptps > 50000:  # filter likely-bogus
            continue
        prefill_runs.append({
            "model": e.get("model_name"),
            "chip": e.get("chip_name"),
            "prefill_tps": round(ptps, 1),
            "output_tps": round(e["tokens_per_second"], 1),
        })
    prefill_runs.sort(key=lambda x: x["prefill_tps"], reverse=True)
    prefill_runs = prefill_runs[:10]

    # Top contributors
    contributors = Counter(e.get("display_name") or "Anonymous" for e in entries)
    top_contributors = [{"name": n, "submissions": c} for n, c in contributors.most_common(8)]

    # Recent activity
    def parse_ts(s: str | None) -> datetime | None:
        if not s:
            return None
        try:
            return datetime.fromisoformat(s.replace(" ", "T")).replace(tzinfo=timezone.utc)
        except Exception:
            return None

    now = datetime.now(timezone.utc)
    recent_7d = sum(1 for e in entries if (parse_ts(e.get("submitted_at")) and (now - parse_ts(e["submitted_at"])).days <= 7))

    versions = Counter((e.get("app_version") or "unknown").split(" ")[0] for e in entries)

    return {
        "totals": {
            "runs": len(entries),
            "valid_runs": len(valid),
            "contributors": len(contributors),
            "models": len({e.get("model_name") for e in entries if e.get("model_name")}),
            "chips": len({e.get("chip_name") for e in entries if e.get("chip_name")}),
            "configs": len({(e.get("chip_name"), e.get("chip_memory_gb")) for e in entries}),
            "submissions_last_7_days": recent_7d,
        },
        "app_versions": dict(versions.most_common()),
        "per_chip": per_chip,
        "per_backend": per_backend,
        "per_format": fmt_avg,
        "per_memory_tier": per_mem,
        "top_15_runs": top_runs,
        "big_model_club_100b_plus": big,
        "reasoning_models_v3_1_plus": reasoning,
        "prefill_top_10_v3_1_plus": prefill_runs,
        "top_contributors": top_contributors,
    }


# ── Prompt + AI call ─────────────────────────────────────────────────


SYSTEM_PROMPT = """You write the "Key Findings" cards for a public Mac LLM benchmark
analysis page. Each card is one short paragraph (1-3 sentences) that surfaces a
concrete, data-backed takeaway from the community benchmarks.

Output rules — these are strict:

1. Output exactly 5 cards in this exact HTML format, nothing else:

   <div class="finding"><strong>Headline.</strong> Body sentence(s).</div>
   <div class="finding green"><strong>Headline.</strong> Body sentence(s).</div>
   <div class="finding orange"><strong>Headline.</strong> Body sentence(s).</div>
   <div class="finding purple"><strong>Headline.</strong> Body sentence(s).</div>
   <div class="finding pink"><strong>Headline.</strong> Body sentence(s).</div>

2. The five color classes (in order: accent (no class), green, orange, purple, pink)
   must be used exactly once each. Headlines end with a period inside the strong tag.

3. Use real numbers from the digest. Cite specific chips, models, tok/s rates.
   Don't fabricate numbers. If a number isn't in the digest, don't claim it.

4. The reader is technical (Mac LLM enthusiasts, Apple Silicon owners).
   Skip throat-clearing. Lead with the surprising or counter-intuitive finding.

5. If an existing finding is still well-supported by the data, you may keep it
   verbatim. If a finding is now stale or contradicted by newer data, replace it.
   If the data shows something interesting that none of the existing cards cover
   (e.g. reasoning model performance, prefill speed trends, new chip showing up),
   prefer that over restating the obvious.

6. No emojis. No markdown. No leading or trailing prose. No <script>, no <style>.
   Just the 5 div elements separated by single newlines.

7. Use HTML entities for special characters (&mdash; for em-dash, &amp; for &, etc.).

You will get the existing 5 cards (for tone reference) and a JSON digest of the
current leaderboard data. Return only the new 5 cards."""


def call_claude(model: str, existing_findings: str, digest: dict) -> str:
    try:
        from anthropic import Anthropic
    except ImportError:
        raise SystemExit(
            "The 'anthropic' package is required. Install with: pip install anthropic"
        )

    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise SystemExit("ANTHROPIC_API_KEY not set in environment.")

    client = Anthropic()
    user_msg = (
        "EXISTING FINDINGS (current 5 cards on the page):\n\n"
        f"{existing_findings}\n\n"
        "LIVE LEADERBOARD DIGEST (JSON):\n\n"
        f"```json\n{json.dumps(digest, indent=2)}\n```\n\n"
        "Return the new 5 cards. Output only the HTML."
    )

    resp = client.messages.create(
        model=model,
        max_tokens=2048,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_msg}],
    )

    # Extract text content
    parts = [b.text for b in resp.content if getattr(b, "type", None) == "text"]
    text = "\n".join(parts).strip()

    # Strip code fences if the model wrapped them
    if text.startswith("```"):
        text = re.sub(r"^```\w*\s*\n?", "", text)
        text = re.sub(r"\n?```\s*$", "", text)

    return text.strip()


# ── HTML splice ──────────────────────────────────────────────────────


def extract_existing(html: str) -> str:
    s = html.find(START_MARKER)
    e = html.find(END_MARKER)
    if s == -1 or e == -1:
        raise SystemExit(f"Could not find {START_MARKER} / {END_MARKER} in analysis.html")
    return html[s + len(START_MARKER):e].strip()


def splice_new(html: str, new_findings: str) -> str:
    s = html.find(START_MARKER)
    e = html.find(END_MARKER)
    today = datetime.now().strftime("%Y-%m-%d")
    block = (
        f"\n    {new_findings.strip()}\n\n"
        f"    <div class=\"meta-stamp\">Findings last updated: {today} &middot; "
        f"Data above is live; narrative is human-curated and refreshed on a monthly cadence.</div>\n    "
    )
    return html[: s + len(START_MARKER)] + block + html[e:]


# ── CLI ──────────────────────────────────────────────────────────────


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--dry-run", action="store_true", help="Print new findings, don't write file")
    p.add_argument("--digest-only", action="store_true", help="Print data digest, no API call")
    p.add_argument("--model", default=DEFAULT_MODEL, help=f"Claude model (default: {DEFAULT_MODEL})")
    args = p.parse_args()

    print(f"Fetching leaderboard from {API_URL}…", file=sys.stderr)
    entries = fetch_entries()
    print(f"  {len(entries)} entries received.", file=sys.stderr)

    digest = build_digest(entries)

    if args.digest_only:
        print(json.dumps(digest, indent=2))
        return 0

    html = ANALYSIS_HTML.read_text()
    existing = extract_existing(html)

    print(f"Calling {args.model}…", file=sys.stderr)
    new_findings = call_claude(args.model, existing, digest)

    # Sanity check the model output
    finding_divs = new_findings.count('<div class="finding')
    if finding_divs != 5:
        print(
            f"WARNING: model returned {finding_divs} 'finding' divs (expected 5). "
            "Output may be malformed.",
            file=sys.stderr,
        )

    if args.dry_run:
        print(new_findings)
        print(
            "\n# Dry run — analysis.html not modified. "
            "Re-run without --dry-run to write.",
            file=sys.stderr,
        )
        return 0

    new_html = splice_new(html, new_findings)
    ANALYSIS_HTML.write_text(new_html)
    print(
        f"\n✓ analysis.html updated. "
        f"Review with: git diff analysis.html",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
