#!/usr/bin/env python3
"""Offline Neurokõne (TartuNLP TransformerTTS) CLI for ezeesti.

Usage:
  neurokone_synthesize.py --text "Ma lähen poodi." --out /tmp/out.wav [--speaker mari] [--speed 1.0]
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def _bootstrap_paths(worker_root: Path) -> None:
    sys.path.insert(0, str(worker_root))
    sys.path.insert(0, str(worker_root / "TransformerTTS"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Synthesize Estonian speech with Neurokõne / TransformerTTS")
    parser.add_argument("--text", required=True, help="Estonian text to speak")
    parser.add_argument("--out", required=True, help="Output WAV path")
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

    worker_root = Path(args.worker_root).expanduser() if args.worker_root else None
    if worker_root is None or not worker_root.exists():
        # Default: repo .cache next to Scripts/
        here = Path(__file__).resolve().parent
        candidate = here.parent / ".cache" / "text-to-speech-worker"
        worker_root = candidate

    if not worker_root.exists():
        print(f"TTS worker not found at {worker_root}. Run Scripts/setup-neurokone.sh", file=sys.stderr)
        return 1

    model_dir = Path(args.model_dir).expanduser() if args.model_dir else None
    if model_dir is None or not model_dir.exists():
        model_dir = Path.home() / "Library/Application Support/Ezeesti/Models/tts/multispeaker"

    if not (model_dir / "model_weights.hdf5").exists():
        print(f"Model weights missing under {model_dir}. Run Scripts/fetch-models.sh", file=sys.stderr)
        return 1

    # Worker expects models/<name>/ relative layout; ensure symlink exists.
    worker_models = worker_root / "models" / "multispeaker"
    worker_models.parent.mkdir(parents=True, exist_ok=True)
    if not worker_models.exists():
        worker_models.symlink_to(model_dir, target_is_directory=True)

    _bootstrap_paths(worker_root)

    from tts_worker.config import ModelConfig
    from tts_worker.schemas import Request
    from tts_worker.synthesizer import Synthesizer

    speakers = {
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
    if args.speaker not in speakers:
        print(f"Unknown speaker {args.speaker}. Choose from: {', '.join(speakers)}", file=sys.stderr)
        return 1

    config = ModelConfig(
        model_name="multispeaker",
        model_path=str(worker_models),
        frontend="est",
        speakers=speakers,
    )

    print(f"Loading Neurokõne ({args.speaker})…", file=sys.stderr)
    # Cap input length to skip the worker's slow probe loop on every cold start.
    synth = Synthesizer(config, max_input_length=180)
    request = Request(text=args.text, speaker=args.speaker, speed=args.speed)
    response = synth.process_request(request)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(response.content.audio)
    print(str(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
