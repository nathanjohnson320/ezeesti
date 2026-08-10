#!/usr/bin/env python3
"""Offline Neurokõne (TartuNLP TransformerTTS) CLI for ezeesti.

Usage:
  # One-shot (cold-loads models every call — slow):
  neurokone_synthesize.py --text "Ma lähen poodi." --out /tmp/out.wav [--speaker mari]

  # Persistent worker (load once; JSON lines on stdin):
  neurokone_synthesize.py --serve [--speaker mari]
  # Then send: {"text":"…","out":"/tmp/out.wav","speaker":"mari","speed":1.0}
  # Reply:     {"ok":true,"out":"/tmp/out.wav"}  or  {"ok":false,"error":"…"}
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def _bootstrap_paths(worker_root: Path) -> None:
    sys.path.insert(0, str(worker_root))
    sys.path.insert(0, str(worker_root / "TransformerTTS"))


def _resolve_paths(worker_root_arg: str, model_dir_arg: str) -> tuple[Path, Path]:
    worker_root = Path(worker_root_arg).expanduser() if worker_root_arg else None
    if worker_root is None or not worker_root.exists():
        here = Path(__file__).resolve().parent
        worker_root = here.parent / ".cache" / "text-to-speech-worker"

    if not worker_root.exists():
        raise FileNotFoundError(
            f"TTS worker not found at {worker_root}. Run Scripts/setup-neurokone.sh"
        )

    model_dir = Path(model_dir_arg).expanduser() if model_dir_arg else None
    if model_dir is None or not model_dir.exists():
        model_dir = Path.home() / "Library/Application Support/Ezeesti/Models/tts/multispeaker"

    if not (model_dir / "model_weights.hdf5").exists():
        raise FileNotFoundError(
            f"Model weights missing under {model_dir}. Run Scripts/fetch-models.sh"
        )

    worker_models = worker_root / "models" / "multispeaker"
    worker_models.parent.mkdir(parents=True, exist_ok=True)
    if not worker_models.exists():
        worker_models.symlink_to(model_dir, target_is_directory=True)

    return worker_root, worker_models


SPEAKERS = {
    "albert": 1,
    "indrek": 2,
    "kalev": 3,
    "kylli": 4,
    "liivika": 5,
    "mari": 6,
    "meelis": 7,
    "peeter": 8,
    "tambet": 9,
    "vesta": 10,
}


def _make_synth(worker_root: Path, worker_models: Path):
    _bootstrap_paths(worker_root)
    from tts_worker.config import ModelConfig
    from tts_worker.synthesizer import Synthesizer

    config = ModelConfig(
        model_name="multispeaker",
        model_path=str(worker_models),
        frontend="est",
        speakers=SPEAKERS,
    )
    # Cap input length to skip the worker's slow probe loop on every cold start.
    return Synthesizer(config, max_input_length=180)


def _synthesize(synth, text: str, out_path: Path, speaker: str, speed: float) -> Path:
    from tts_worker.schemas import Request

    if speaker not in SPEAKERS:
        raise ValueError(f"Unknown speaker {speaker}. Choose from: {', '.join(SPEAKERS)}")

    request = Request(text=text, speaker=speaker, speed=speed)
    response = synth.process_request(request)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(response.content.audio)
    return out_path


def serve(synth, default_speaker: str, default_speed: float) -> int:
    print("READY", flush=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            if req.get("cmd") == "ping":
                print(json.dumps({"ok": True, "pong": True}), flush=True)
                continue
            text = req.get("text") or ""
            out = req.get("out") or ""
            if not text or not out:
                raise ValueError("Request needs text and out")
            speaker = req.get("speaker") or default_speaker
            speed = float(req.get("speed") if req.get("speed") is not None else default_speed)
            path = _synthesize(synth, text, Path(out), speaker, speed)
            print(json.dumps({"ok": True, "out": str(path)}), flush=True)
        except Exception as exc:  # noqa: BLE001 — surface to Swift client
            print(json.dumps({"ok": False, "error": str(exc)}), flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Synthesize Estonian speech with Neurokõne / TransformerTTS")
    parser.add_argument("--serve", action="store_true", help="Keep models loaded; read JSON lines from stdin")
    parser.add_argument("--text", default="", help="Estonian text to speak (one-shot mode)")
    parser.add_argument("--out", default="", help="Output WAV path (one-shot mode)")
    parser.add_argument("--speaker", default="mari", help="Speaker id (albert, mari, vesta, ...)")
    parser.add_argument("--speed", type=float, default=1.0, help="Speaking rate multiplier")
    parser.add_argument(
        "--worker-root",
        default=os.environ.get("EZEESTI_TTS_WORKER_ROOT", ""),
        help="Path to text-to-speech-worker checkout",
    )
    parser.add_argument(
        "--model-dir",
        default=os.environ.get("EZEESTI_TTS_MODEL_DIR", ""),
        help="Directory containing config.yaml + model_weights.hdf5",
    )
    args = parser.parse_args()

    try:
        worker_root, worker_models = _resolve_paths(args.worker_root, args.model_dir)
    except FileNotFoundError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.speaker not in SPEAKERS:
        print(f"Unknown speaker {args.speaker}. Choose from: {', '.join(SPEAKERS)}", file=sys.stderr)
        return 1

    print(f"Loading Neurokõne ({args.speaker})…", file=sys.stderr)
    try:
        synth = _make_synth(worker_root, worker_models)
    except Exception as exc:  # noqa: BLE001
        print(f"Failed to load Neurokõne: {exc}", file=sys.stderr)
        return 1

    if args.serve:
        return serve(synth, args.speaker, args.speed)

    if not args.text or not args.out:
        print("One-shot mode requires --text and --out (or use --serve).", file=sys.stderr)
        return 1

    try:
        path = _synthesize(synth, args.text, Path(args.out), args.speaker, args.speed)
    except Exception as exc:  # noqa: BLE001
        print(str(exc), file=sys.stderr)
        return 1
    print(str(path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
