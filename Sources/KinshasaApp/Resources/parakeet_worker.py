#!/usr/bin/env python3
"""
Persistent Parakeet worker.

Protocol: JSON lines over stdin/stdout.
Request:
  {"id": 1, "command": "transcribe", "audio_path": "/tmp/file.wav"}
Response:
  {"type": "result", "id": 1, "text": "..."}
  {"type": "error", "id": 1, "message": "..."}
"""

from __future__ import annotations

import argparse
import gc
import json
import sys
import tempfile
import wave
from pathlib import Path

import mlx.core as mx
from parakeet_mlx import from_pretrained


def emit(message: dict) -> None:
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Persistent local Parakeet worker")
    parser.add_argument("--model", required=True)
    parser.add_argument("--cache-dir", default=None)
    parser.add_argument("--fp32", action="store_true")
    return parser.parse_args()


def create_silence_wav(seconds: int = 1) -> Path:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temp_file:
        temp_path = Path(temp_file.name)

    with wave.open(str(temp_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(16000)
        wf.writeframes(b"\x00\x00" * (16000 * seconds))

    return temp_path


def run_startup_warmup(model, dtype, warmup_audio_path: Path) -> None:
    _ = model.transcribe(warmup_audio_path, dtype=dtype)


def compact_runtime_memory() -> None:
    try:
        gc.collect()
    except Exception:
        pass

    try:
        clear_cache = getattr(mx, "clear_cache", None)
        if callable(clear_cache):
            clear_cache()
    except Exception:
        pass

    try:
        metal = getattr(mx, "metal", None)
        if metal is not None:
            metal_clear_cache = getattr(metal, "clear_cache", None)
            if callable(metal_clear_cache):
                metal_clear_cache()
    except Exception:
        pass


def main() -> int:
    args = parse_args()
    dtype = mx.float32 if args.fp32 else mx.bfloat16
    warmup_audio_path = None
    handled_requests = 0

    try:
        model = from_pretrained(args.model, dtype=dtype, cache_dir=args.cache_dir)
        warmup_audio_path = create_silence_wav(seconds=1)
        run_startup_warmup(model, dtype, warmup_audio_path)
    except Exception as exc:
        emit({"type": "fatal", "message": f"Failed to load model: {exc}"})
        return 1

    emit({"type": "ready"})

    try:
        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue

            request_id = None
            try:
                request = json.loads(line)
                request_id = request.get("id")
            except Exception:
                emit({"type": "error", "id": request_id, "message": "Invalid JSON request"})
                continue

            command = request.get("command")
            if command == "shutdown":
                emit({"type": "bye"})
                return 0

            if command == "warmup":
                try:
                    if warmup_audio_path is None:
                        raise RuntimeError("Warmup audio is unavailable.")
                    _ = model.transcribe(warmup_audio_path, dtype=dtype)
                    handled_requests += 1
                    if handled_requests % 8 == 0:
                        compact_runtime_memory()
                    emit({"type": "warmed", "id": request_id})
                except Exception as exc:
                    emit({"type": "error", "id": request_id, "message": str(exc)})
                continue

            if command != "transcribe":
                emit({"type": "error", "id": request_id, "message": f"Unsupported command: {command}"})
                continue

            audio_path = request.get("audio_path")
            if not audio_path:
                emit({"type": "error", "id": request_id, "message": "Missing audio_path"})
                continue

            try:
                result = model.transcribe(Path(audio_path), dtype=dtype)
                text = (result.text or "").strip()
                handled_requests += 1
                if handled_requests % 8 == 0:
                    compact_runtime_memory()
                emit({"type": "result", "id": request_id, "text": text})
            except Exception as exc:
                emit({"type": "error", "id": request_id, "message": str(exc)})

        return 0
    finally:
        if warmup_audio_path is not None:
            try:
                warmup_audio_path.unlink(missing_ok=True)
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
