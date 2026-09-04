#!/usr/bin/env python3
"""Example Island plugin.

A plugin is any executable that prints a JSON array of sessions on stdout.
Island runs it on every poll, so it must be fast and must never block.

This one reads Gemini CLI session logs; adapt `collect()` for your own tool.
Only `nativeID`, `title` and `state` are required.

  state: running | awaitingInput | awaitingApproval | completed | failed
  target: "pid:1234" | "bundle:com.example.App" | "url:https://…" | "file:/path"
"""

import json
import os
import sys
import time
from pathlib import Path

ROOT = Path.home() / ".gemini" / "tmp"
# Anything untouched for longer than this is treated as finished.
LIVENESS_WINDOW = 90


def collect():
    if not ROOT.is_dir():
        return []

    sessions = []
    for log in ROOT.rglob("*.json"):
        try:
            modified = log.stat().st_mtime
        except OSError:
            continue

        # Skip logs that are too old to be interesting.
        if time.time() - modified > 8 * 3600:
            continue

        try:
            data = json.loads(log.read_text())
        except (OSError, ValueError):
            continue

        messages = data.get("messages") or []
        if not messages:
            continue

        last = messages[-1]
        is_fresh = (time.time() - modified) < LIVENESS_WINDOW
        if last.get("role") == "user":
            state = "running" if is_fresh else "completed"
        else:
            state = "awaitingInput" if is_fresh else "completed"

        first_user = next(
            (m.get("content", "") for m in messages if m.get("role") == "user"), ""
        )

        sessions.append({
            "nativeID": log.stem,
            "title": (first_user or log.stem)[:60],
            "workingDirectory": data.get("cwd"),
            "model": data.get("model"),
            "state": state,
            "usage": {
                "input": data.get("inputTokens", 0),
                "output": data.get("outputTokens", 0),
                "cacheRead": 0,
                "cacheWrite": 0,
                "reasoning": 0,
                "contextWindow": 1000000,
            },
            "transcript": [
                {
                    "id": f"{log.stem}-{i}",
                    "role": m.get("role", "assistant"),
                    "text": (m.get("content") or "")[:220],
                    # Island expects ISO 8601.
                    "timestamp": time.strftime(
                        "%Y-%m-%dT%H:%M:%SZ", time.gmtime(modified)
                    ),
                }
                for i, m in enumerate(messages[-4:])
            ],
            "startedAt": time.strftime(
                "%Y-%m-%dT%H:%M:%SZ", time.gmtime(data.get("createdAt", modified))
            ),
            "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(modified)),
            "target": "bundle:com.googlecode.iterm2",
        })

    return sessions


if __name__ == "__main__":
    try:
        json.dump(collect(), sys.stdout)
    except Exception:
        # A plugin that crashes is disabled for that cycle; printing an empty
        # array keeps the notch clean instead of showing an error badge.
        json.dump([], sys.stdout)
