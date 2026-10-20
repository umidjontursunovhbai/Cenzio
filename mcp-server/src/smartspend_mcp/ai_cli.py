"""Owner-only text interpreter CLI. Not exposed to MCP clients or the network."""

from __future__ import annotations

import argparse
import getpass
import json
import sys
import warnings
from pathlib import Path

from .ai_config import AIConfig
from .interpreter import interpret
from .store import LedgerStore
from .validation import LedgerError


def main() -> None:
    parser = argparse.ArgumentParser(description="GPT-6 Luna review-only drafts; no expense writes or microphone recording")
    parser.add_argument("--config", type=Path, help="Private mode-600 JSON configuration; otherwise use server environment variables")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("configure", help="Save a NEW private configuration using hidden terminal input, with no API call")
    commands.add_parser("status", help="Validate configuration without contacting OpenRouter or displaying the key")
    draft = commands.add_parser("interpret", help="Read one transcript from stdin and make one billable request")
    draft.add_argument("--db", type=Path, required=True, help="Existing initialized ledger; sends categories/currency only, never expenses")
    draft.add_argument("--reference-date", required=True, help="User-local YYYY-MM-DD")
    draft.add_argument("--time-zone", required=True, help="User IANA timezone")
    draft.add_argument("--send-to-ai", action="store_true", help="Explicit consent to send transcript, category names/IDs, currency, date and timezone")
    args = parser.parse_args()
    try:
        if args.command == "configure":
            if args.config is None:
                raise LedgerError("configure requires --config with a new private file path")
            if not sys.stdin.isatty():
                raise LedgerError("Use an interactive terminal; keys must never be passed in command arguments or pipes")
            # Do not allow getpass's echoing fallback when terminal echo cannot be disabled.
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                config = AIConfig(api_key=getpass.getpass("New OpenRouter API key (hidden): ").strip())
            config.save_new(args.config)
            print("Private GPT-6 Luna configuration saved. No API request was made.")
            return
        config = AIConfig.from_private_file(args.config) if args.config else AIConfig.from_environment()
        if args.command == "status":
            print(json.dumps({"base_url": config.base_url, "model": config.model, "key_configured": True, "network_checked": False}))
            return
        if not args.send_to_ai:
            raise LedgerError("No data sent: interpret requires --send-to-ai after reviewing the cloud disclosure")
        if not args.db.is_file():
            raise LedgerError("An existing initialized ledger is required; no personal data is auto-discovered")
        store = LedgerStore(args.db)
        context = store.context()
        categories = store.categories()["categories"]
        transcript = sys.stdin.read(4001)
        result = interpret(transcript, config=config, categories=categories, currency=context["currency"], reference_date=args.reference_date, time_zone=args.time_zone)
        # Explicit CLI output contains sensitive drafts; the service does not persist/log it.
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    except LedgerError as exc:
        # Only locally authored safe messages, never provider response bodies.
        print(f"SmartSpend AI: {exc}", file=sys.stderr)
        raise SystemExit(1) from None
    except (OSError, getpass.GetPassWarning, EOFError):
        # Avoid echoing errors that could include paths containing secrets or user input.
        print("SmartSpend AI: configuration, input or provider validation failed. No transaction was saved. Check setup/help and retry explicitly.", file=sys.stderr)
        raise SystemExit(1) from None
    except KeyboardInterrupt:
        raise SystemExit(130) from None


if __name__ == "__main__":
    main()
