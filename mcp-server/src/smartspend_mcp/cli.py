"""Owner operations use explicit paths; AI tools cannot choose filesystem paths."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .store import LedgerStore
from .validation import LedgerError


def main() -> None:
    parser = argparse.ArgumentParser(description="SmartSpend local-only MCP and reviewed iPhone file exchange")
    parser.add_argument("--db", default=os.environ.get("SMARTSPEND_MCP_DB"), help="Explicit private SQLite file, or SMARTSPEND_MCP_DB")
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="MCP stdio only; no HTTP listener")
    serve.add_argument("--allow-writes", action="store_true", help="Allow connected clients to mutate the private server mirror; iPhone still requires patch review")
    ingest = commands.add_parser("import-snapshot", help="Initialize/reconcile an explicitly supplied app snapshot")
    ingest.add_argument("file", type=Path)
    ingest.add_argument("--expected-revision", type=int)
    output = commands.add_parser("export-operations", help="Export pending operations for explicit app review; does not clear the queue")
    output.add_argument("file", type=Path)
    commands.add_parser("status", help="Show ledger metadata, not expense contents")
    args = parser.parse_args()
    if not args.db:
        parser.error("--db or SMARTSPEND_MCP_DB is required; personal files are never auto-discovered")
    try:
        store = LedgerStore(args.db)
        if args.command == "serve":
            from .server import create_server
            create_server(store, allow_writes=args.allow_writes).run(transport="stdio")
        elif args.command == "import-snapshot":
            if args.file.stat().st_size > 50 * 1024 * 1024:
                raise LedgerError("Snapshot exceeds the 50 MiB import limit")
            result = store.import_snapshot(json.loads(args.file.read_text(encoding="utf-8")), args.expected_revision)
            print(json.dumps(result, ensure_ascii=False))
        elif args.command == "export-operations":
            document = store.export_operations()
            # Exclusive creation prevents silently overwriting an owner's prior patch/backup.
            with open(args.file, "x", encoding="utf-8", opener=lambda path, flags: os.open(path, flags, 0o600)) as handle:
                json.dump(document, handle, ensure_ascii=False, indent=2, allow_nan=False)
                handle.write("\n")
            print(json.dumps({"file": str(args.file.resolve()), "operationCount": len(document["operations"])}))
        elif args.command == "status":
            print(json.dumps(store.context(), ensure_ascii=False))
    except (LedgerError, OSError, json.JSONDecodeError) as exc:
        print(f"SmartSpend: {exc}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
