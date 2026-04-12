#!/usr/bin/env python3
"""Upload a generated file and complete assistant output callback for Miao Chat."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Dict, Optional


DEFAULT_SOURCE = "openclaw_skill"


def _read_json_file(path: str) -> Dict[str, Any]:
    p = pathlib.Path(path)
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _deep_get(payload: Any, candidates: tuple[str, ...]) -> Optional[str]:
    if not isinstance(payload, dict):
        return None
    for key in candidates:
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    for value in payload.values():
        if isinstance(value, dict):
            found = _deep_get(value, candidates)
            if found:
                return found
    return None


def _load_context(args: argparse.Namespace) -> Dict[str, Any]:
    context: Dict[str, Any] = {}
    if args.context_json:
        try:
            context.update(json.loads(args.context_json))
        except Exception as exc:
            raise SystemExit(f"Invalid --context-json: {exc}")
    if args.context_file:
        context.update(_read_json_file(args.context_file))
    return context


def _read_plugin_config(config_path: Optional[str]) -> Dict[str, Any]:
    if not config_path:
        return {}
    return _read_json_file(config_path)

def _resolve_config_path(explicit_config_path: Optional[str]) -> Optional[str]:
    explicit = _resolve_value(explicit_config_path)
    if explicit:
        return explicit
    env_path = _resolve_value(
        os.getenv("MIAOCHAT_FILE_OUTPUT_CONFIG"),
        os.getenv("MIAO_CHAT_SKILL_CONFIG"),
    )
    if env_path:
        return env_path

    script_path = pathlib.Path(__file__).resolve()
    candidates = [
        script_path.with_name("config.json"),
        script_path.parent.parent / "config.json",
        pathlib.Path.cwd() / "config.json",
    ]
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    return str(script_path.parent.parent / "config.json")


def _resolve_value(*values: Optional[str]) -> Optional[str]:
    for value in values:
        if value is None:
            continue
        value = str(value).strip()
        if value:
            return value
    return None


def _compute_file_meta(file_path: pathlib.Path, provided_mime: Optional[str], provided_name: Optional[str]) -> Dict[str, Any]:
    if not file_path.exists() or not file_path.is_file():
        raise SystemExit(f"File not found: {file_path}")

    sha256 = hashlib.sha256()
    size = 0
    with file_path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            sha256.update(chunk)

    mime = _resolve_value(provided_mime)
    if not mime:
        guessed, _ = mimetypes.guess_type(str(file_path))
        mime = guessed or "application/octet-stream"

    file_name = _resolve_value(provided_name) or file_path.name

    return {
        "size": size,
        "mime": mime,
        "sha256": sha256.hexdigest(),
        "file_name": file_name,
    }


def _request_json(method: str, url: str, headers: Dict[str, str], payload: Dict[str, Any]) -> Dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url=url, method=method, data=data)
    request.add_header("Content-Type", "application/json")
    for key, value in headers.items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read().decode("utf-8")
            return json.loads(text)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore")
        raise SystemExit(f"HTTP {exc.code} {url}: {body}")
    except urllib.error.URLError as exc:
        raise SystemExit(f"Request failed {url}: {exc}")


def _upload_file(upload_method: str, upload_url: str, upload_headers: Dict[str, Any], file_path: pathlib.Path) -> None:
    method = (upload_method or "PUT").upper()
    body = file_path.read_bytes()
    request = urllib.request.Request(url=upload_url, method=method, data=body)
    for key, value in (upload_headers or {}).items():
        request.add_header(str(key), str(value))

    try:
        with urllib.request.urlopen(request, timeout=120):
            return
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode("utf-8", errors="ignore")
        raise SystemExit(f"Upload failed HTTP {exc.code}: {body_text}")
    except urllib.error.URLError as exc:
        raise SystemExit(f"Upload failed: {exc}")


def _join_url(api_base: str, path: str) -> str:
    base = api_base.rstrip("/")
    return f"{base}{path}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Send generated file to Miao Chat assistant output")
    parser.add_argument("--conversation-id", help="Conversation ID")
    parser.add_argument("--request-id", help="Request ID, default req_<uuid>")
    parser.add_argument("--file-path", required=True, help="Path of generated file")
    parser.add_argument("--mime", help="MIME type, auto detect by default")
    parser.add_argument("--file-name", help="File name, basename(file-path) by default")
    parser.add_argument("--api-base", help="Backend API base URL, e.g. http://127.0.0.1:8081")
    parser.add_argument("--user-id", help="User id for X-User-Id header")
    parser.add_argument("--token", help="Optional bearer token")
    parser.add_argument("--source", default=DEFAULT_SOURCE, help="Source tag, default openclaw_skill")
    parser.add_argument("--context-json", help="Invoke context json text")
    parser.add_argument("--context-file", help="Invoke context json file path")
    parser.add_argument("--config", help="Optional plugin config json path")
    args = parser.parse_args()

    context = _load_context(args)
    config_path = _resolve_config_path(args.config)
    config = _read_plugin_config(config_path)

    env_api_base = os.getenv("MIAO_CHAT_API_BASE")
    env_user_id = os.getenv("MIAO_CHAT_USER_ID")
    env_token = os.getenv("MIAO_CHAT_TOKEN")

    context_conversation_id = _deep_get(context, ("conversation_id", "conversationId"))
    context_request_id = _deep_get(context, ("request_id", "requestId"))
    context_user_id = _deep_get(context, ("user_id", "userId"))

    api_base = _resolve_value(
        args.api_base,
        str(config.get("apiBase") or ""),
        str(config.get("backendBase") or ""),
        env_api_base,
    )
    if not api_base:
        raise SystemExit(
            "api_base is required "
            "(via --api-base or config apiBase/backendBase or MIAO_CHAT_API_BASE); "
            f"resolved_config={config_path}"
        )

    conversation_id = _resolve_value(context_conversation_id, args.conversation_id)
    if not conversation_id:
        raise SystemExit("conversation_id is required (context > --conversation-id)")

    request_id = _resolve_value(context_request_id, args.request_id) or f"req_{uuid.uuid4().hex[:12]}"

    user_id = _resolve_value(context_user_id, args.user_id, str(config.get("userId") or ""), env_user_id)
    if not user_id:
        raise SystemExit("user_id is required (context > --user-id > config.userId > MIAO_CHAT_USER_ID)")
    token = _resolve_value(args.token, str(config.get("token") or ""), env_token)

    file_path = pathlib.Path(args.file_path).expanduser().resolve()
    meta = _compute_file_meta(file_path, args.mime, args.file_name)

    headers: Dict[str, str] = {"X-User-Id": user_id}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    init_url = _join_url(api_base, "/api/v1/files/init-upload")
    init_payload = {
        "file_name": meta["file_name"],
        "mime": meta["mime"],
        "size": meta["size"],
        "purpose": "assistant_output",
    }
    init_response = _request_json("POST", init_url, headers, init_payload)
    if int(init_response.get("code", -1)) != 0:
        raise SystemExit(f"init-upload failed: {json.dumps(init_response, ensure_ascii=False)}")

    init_data = init_response.get("data") or {}
    _upload_file(
        str(init_data.get("upload_method") or "PUT"),
        str(init_data.get("upload_url") or ""),
        init_data.get("upload_headers") or {},
        file_path,
    )

    complete_url = _join_url(api_base, f"/api/v1/conversations/{urllib.parse.quote(conversation_id)}/assistant-output/complete")
    complete_payload = {
        "request_id": request_id,
        "object_key": init_data.get("object_key"),
        "file_name": meta["file_name"],
        "mime": meta["mime"],
        "size": meta["size"],
        "sha256": meta["sha256"],
        "source": args.source or DEFAULT_SOURCE,
    }
    complete_response = _request_json("POST", complete_url, headers, complete_payload)
    if int(complete_response.get("code", -1)) != 0:
        raise SystemExit(f"assistant-output complete failed: {json.dumps(complete_response, ensure_ascii=False)}")

    complete_data = complete_response.get("data") or {}
    output = {
        "request_id": request_id,
        "conversation_id": conversation_id,
        "file_id": complete_data.get("file_id"),
        "message_id": complete_data.get("message_id"),
        "idempotent": bool(complete_data.get("idempotent")),
        "object_key": init_data.get("object_key"),
    }
    print(json.dumps(output, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
