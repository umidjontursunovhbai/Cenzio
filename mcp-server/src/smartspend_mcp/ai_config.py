"""Server-only OpenRouter configuration. Never include credentials in repr/errors."""

from __future__ import annotations

import json
import os
import re
import stat
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

from .validation import LedgerError

BASE_URL = "https://openrouter.ai/api/v1"
MODEL = "openai/gpt-6-luna"
KEY_PATTERN = re.compile(r"sk-or-v1-[a-zA-Z0-9_-]{20,200}\Z")


@dataclass(frozen=True)
class AIConfig:
    api_key: str = field(repr=False)
    base_url: str = BASE_URL
    model: str = MODEL

    def __post_init__(self) -> None:
        if not isinstance(self.api_key, str) or not KEY_PATTERN.fullmatch(self.api_key):
            raise LedgerError("A valid OpenRouter key is required; enter it privately, never in chat or command arguments")
        # An incorrect base URL must never send this credential to another host.
        if self.base_url != BASE_URL or self.model != MODEL:
            raise LedgerError("This integration requires the OpenRouter endpoint and openai/gpt-6-luna; no automatic model fallback")

    @classmethod
    def from_environment(cls, environment: Mapping[str, str] | None = None) -> AIConfig:
        env = os.environ if environment is None else environment
        return cls(
            api_key=env.get("OPENAI_API_KEY") or env.get("OPENROUTER_API_KEY", ""),
            base_url=env.get("OPENAI_BASE_URL", BASE_URL),
            model=env.get("OPENAI_MODEL", MODEL),
        )

    @classmethod
    def from_private_file(cls, path: Path) -> AIConfig:
        # Open without following symlinks, then validate the opened inode.
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
                info = os.fstat(handle.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
                    raise LedgerError("AI credential file must be an owner-owned regular file with mode 600")
                if info.st_size > 4096:
                    raise LedgerError("AI credential file is too large")
                document = json.loads(handle.read(4097))
        except (OSError, ValueError) as exc:
            if isinstance(exc, LedgerError):
                raise
            raise LedgerError("Cannot read private AI configuration; check path, permissions and JSON format") from None
        if not isinstance(document, dict) or set(document) != {"api_key", "base_url", "model"}:
            raise LedgerError("Private AI configuration must contain api_key, base_url and model only")
        return cls(**document)

    def save_new(self, path: Path) -> None:
        """Exclusive creation: never silently replace a working provider credential."""
        try:
            with open(path, "x", encoding="utf-8", opener=lambda name, flags: os.open(name, flags, 0o600)) as handle:
                os.fchmod(handle.fileno(), 0o600)
                json.dump({"api_key": self.api_key, "base_url": self.base_url, "model": self.model}, handle)
                handle.write("\n")
        except OSError:
            raise LedgerError("Cannot create private AI configuration; parent must exist and target must be a new file") from None
