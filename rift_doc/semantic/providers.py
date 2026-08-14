"""Vendor-neutral provider contract, fake provider, and OpenAI-compatible adapter."""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable, Mapping
from dataclasses import dataclass
import json
import os
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .model import EvidencePacket, SemanticReviewTask
from .prompts import PromptRenderer
from .result_validation import SEMANTIC_RESULT_SCHEMA


class LLMProviderError(RuntimeError):
    pass


@dataclass(frozen=True)
class LLMProviderConfig:
    provider: str = "openai-compatible"
    model: str = ""
    endpoint: str = ""
    temperature: float = 0.0
    max_output_tokens: int = 1_024
    timeout_seconds: float = 30.0
    retry_attempts: int = 1
    api_key_environment: str = "RIFT_DOC_LLM_API_KEY"
    local_only: bool = False
    input_cost_per_million: float | None = None
    output_cost_per_million: float | None = None

    @classmethod
    def from_environment(cls, **overrides: Any) -> "LLMProviderConfig":
        values: dict[str, Any] = {
            "provider": os.environ.get("RIFT_DOC_LLM_PROVIDER", "openai-compatible"),
            "model": os.environ.get("RIFT_DOC_LLM_MODEL", ""),
            "endpoint": os.environ.get("RIFT_DOC_LLM_ENDPOINT", ""),
            "temperature": _environment_float("RIFT_DOC_LLM_TEMPERATURE", 0.0),
            "max_output_tokens": _environment_int("RIFT_DOC_LLM_MAX_OUTPUT_TOKENS", 1_024),
            "timeout_seconds": _environment_float("RIFT_DOC_LLM_TIMEOUT", 30.0),
            "retry_attempts": _environment_int("RIFT_DOC_LLM_RETRIES", 1),
            "api_key_environment": os.environ.get("RIFT_DOC_LLM_API_KEY_ENV", "RIFT_DOC_LLM_API_KEY"),
            "local_only": _environment_bool("RIFT_DOC_LLM_LOCAL_ONLY", False),
            "input_cost_per_million": _optional_environment_float("RIFT_DOC_LLM_INPUT_COST_PER_MILLION"),
            "output_cost_per_million": _optional_environment_float("RIFT_DOC_LLM_OUTPUT_COST_PER_MILLION"),
        }
        values.update({key: value for key, value in overrides.items() if value is not None})
        return cls(**values)

    @property
    def is_local_endpoint(self) -> bool:
        hostname = (urlparse(self.endpoint).hostname or "").casefold()
        return hostname in {"localhost", "127.0.0.1", "::1"} or hostname.endswith(".localhost")

    def validate(self) -> None:
        if self.provider not in {"openai-compatible", "fake"}:
            raise ValueError(f"unsupported semantic provider {self.provider!r}")
        if not self.model.strip():
            raise ValueError("semantic model is required")
        parsed = urlparse(self.endpoint)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("semantic endpoint must be an absolute HTTP(S) URL")
        if not self.is_local_endpoint and parsed.scheme != "https":
            raise ValueError("external semantic endpoints must use HTTPS")
        if self.local_only and not self.is_local_endpoint:
            raise ValueError("semantic local-only policy rejects a non-local endpoint")
        if not 0.0 <= self.temperature <= 2.0:
            raise ValueError("semantic temperature must be between 0 and 2")
        if self.max_output_tokens < 1:
            raise ValueError("semantic max output must be positive")
        if self.timeout_seconds <= 0:
            raise ValueError("semantic timeout must be positive")
        if self.retry_attempts < 0:
            raise ValueError("semantic retry attempts cannot be negative")
        for value in (self.input_cost_per_million, self.output_cost_per_million):
            if value is not None and value < 0:
                raise ValueError("semantic provider costs cannot be negative")

    def audit_metadata(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "model": self.model,
            "endpoint": _redacted_endpoint(self.endpoint),
            "temperature": self.temperature,
            "max_output_tokens": self.max_output_tokens,
            "timeout_seconds": self.timeout_seconds,
            "retry_policy": {
                "retry_attempts": self.retry_attempts,
                "max_attempts": self.retry_attempts + 1,
            },
            "api_key_environment": self.api_key_environment,
            "local_only": self.local_only,
            "input_cost_per_million": self.input_cost_per_million,
            "output_cost_per_million": self.output_cost_per_million,
        }


class LLMProvider(ABC):
    config: LLMProviderConfig
    supports_visual_evidence: bool = False

    @abstractmethod
    def review(
        self,
        task: SemanticReviewTask,
        packet: EvidencePacket,
    ) -> str | bytes | Mapping[str, Any]:
        """Review one bounded task without accessing any other audit state."""


class FakeLLMProvider(LLMProvider):
    """Deterministic provider used by unit tests and local harnesses."""

    def __init__(
        self,
        responses: list[str | bytes | Mapping[str, Any] | Exception]
        | Callable[[SemanticReviewTask, EvidencePacket], str | bytes | Mapping[str, Any]],
        *,
        model: str = "fake-semantic-model",
        retry_attempts: int = 1,
        supports_visual_evidence: bool = False,
    ) -> None:
        self.responses = responses
        self.config = LLMProviderConfig(
            provider="fake",
            model=model,
            endpoint="http://localhost/fake",
            retry_attempts=retry_attempts,
            local_only=True,
        )
        self.supports_visual_evidence = supports_visual_evidence
        self.calls: list[tuple[SemanticReviewTask, EvidencePacket]] = []
        self._index = 0

    def review(
        self,
        task: SemanticReviewTask,
        packet: EvidencePacket,
    ) -> str | bytes | Mapping[str, Any]:
        self.calls.append((task, packet))
        if callable(self.responses):
            return self.responses(task, packet)
        if self._index >= len(self.responses):
            raise LLMProviderError("fake provider has no configured response")
        response = self.responses[self._index]
        self._index += 1
        if isinstance(response, Exception):
            raise response
        return response


class OpenAICompatibleProvider(LLMProvider):
    """HTTP adapter for OpenAI-compatible chat-completions endpoints."""

    def __init__(
        self,
        config: LLMProviderConfig,
        *,
        prompt_renderer: PromptRenderer | None = None,
    ) -> None:
        config.validate()
        if config.provider != "openai-compatible":
            raise ValueError("OpenAICompatibleProvider requires provider='openai-compatible'")
        self.config = config
        self.prompt_renderer = prompt_renderer or PromptRenderer()

    def review(
        self,
        task: SemanticReviewTask,
        packet: EvidencePacket,
    ) -> str:
        prompt = self.prompt_renderer.render(task, packet)
        payload = {
            "model": self.config.model,
            "temperature": self.config.temperature,
            "max_tokens": self.config.max_output_tokens,
            "messages": [
                {"role": "system", "content": prompt.system},
                {"role": "user", "content": prompt.user},
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "semantic_result",
                    "strict": True,
                    "schema": SEMANTIC_RESULT_SCHEMA,
                },
            },
        }
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "rift-capstone-doc-tooling/semantic",
        }
        api_key = os.environ.get(self.config.api_key_environment, "")
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        elif not self.config.is_local_endpoint:
            raise LLMProviderError(
                f"semantic API key environment {self.config.api_key_environment!r} is not set"
            )
        request = Request(
            self.config.endpoint,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with build_opener(_NoRedirectHandler).open(
                request,
                timeout=self.config.timeout_seconds,
            ) as response:
                raw = response.read()
        except HTTPError as exc:
            raise LLMProviderError(f"semantic provider returned HTTP {exc.code}") from exc
        except (URLError, TimeoutError, OSError) as exc:
            raise LLMProviderError(f"semantic provider request failed: {type(exc).__name__}") from exc
        try:
            response_payload = json.loads(raw.decode("utf-8"))
            content = response_payload["choices"][0]["message"]["content"]
        except (UnicodeDecodeError, json.JSONDecodeError, KeyError, IndexError, TypeError) as exc:
            raise LLMProviderError("semantic provider response has no chat-completion content") from exc
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            text_parts = [
                str(item.get("text", ""))
                for item in content
                if isinstance(item, dict) and item.get("text")
            ]
            if text_parts:
                return "".join(text_parts)
        raise LLMProviderError("semantic provider returned unsupported message content")


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, request: Any, file_pointer: Any, code: int, message: str, headers: Any, new_url: str) -> None:
        return None


def _environment_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value in (None, ""):
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"environment variable {name} must be an integer") from exc


def _environment_float(name: str, default: float) -> float:
    value = os.environ.get(name)
    if value in (None, ""):
        return default
    try:
        return float(value)
    except ValueError as exc:
        raise ValueError(f"environment variable {name} must be a number") from exc


def _optional_environment_float(name: str) -> float | None:
    value = os.environ.get(name)
    if value in (None, ""):
        return None
    try:
        return float(value)
    except ValueError as exc:
        raise ValueError(f"environment variable {name} must be a number") from exc


def _environment_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value in (None, ""):
        return default
    normalized = value.casefold()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"environment variable {name} must be a boolean")


def _redacted_endpoint(value: str) -> str:
    parsed = urlparse(value)
    if not parsed.scheme or not parsed.netloc:
        return value
    host = parsed.hostname or ""
    if parsed.port is not None:
        host += f":{parsed.port}"
    return parsed._replace(netloc=host, query="", fragment="").geturl()
