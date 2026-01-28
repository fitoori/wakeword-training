#!/usr/bin/env python3
import argparse
import json
import os
import random
from pathlib import Path


AUDIO_EXTS = {".wav", ".flac", ".mp3", ".ogg", ".m4a"}


def parse_sources(raw_sources: str) -> list[str]:
    if not raw_sources:
        return []
    return [s.strip() for s in raw_sources.split(",") if s.strip()]


def collect_files(sources: list[str]) -> dict[str, list[str]]:
    collected: dict[str, list[str]] = {}
    for source in sources:
        path = Path(source).expanduser()
        if path.is_file():
            collected[source] = [str(path)]
            continue
        if not path.exists():
            collected[source] = []
            continue
        files = [
            str(p)
            for p in path.rglob("*")
            if p.is_file() and p.suffix.lower() in AUDIO_EXTS
        ]
        collected[source] = files
    return collected


def distribute_diverse(
    collected: dict[str, list[str]],
    max_total: int | None,
    min_per_source: int,
    rng: random.Random,
) -> list[str]:
    sources = [s for s, files in collected.items() if files]
    if not sources:
        return []

    per_source_files = {}
    for source in sources:
        files = list(collected[source])
        rng.shuffle(files)
        per_source_files[source] = files

    selection: list[str] = []
    for source in sources:
        if min_per_source <= 0:
            continue
        files = per_source_files[source]
        take = min(min_per_source, len(files))
        selection.extend(files[:take])
        per_source_files[source] = files[take:]

    if max_total is not None:
        remaining_slots = max(0, max_total - len(selection))
    else:
        remaining_slots = None

    while True:
        if remaining_slots is not None and remaining_slots <= 0:
            break
        made_progress = False
        for source in sources:
            if remaining_slots is not None and remaining_slots <= 0:
                break
            files = per_source_files[source]
            if not files:
                continue
            selection.append(files.pop(0))
            made_progress = True
            if remaining_slots is not None:
                remaining_slots -= 1
        if not made_progress:
            break

    return selection


def write_list(path: Path, entries: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for item in entries:
            handle.write(f"{item}\n")


def parse_int(value: str, label: str) -> int | None:
    if value is None or value == "":
        return None
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{label} must be an integer") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError(f"{label} must be >= 0")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate a diversified dataset manifest for wakeword training."
    )
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--wake-phrase", required=True)
    parser.add_argument("--positive-sources", required=True)
    parser.add_argument("--negative-sources", required=True)
    parser.add_argument("--max-positives", default="")
    parser.add_argument("--max-negatives", default="")
    parser.add_argument("--min-per-source", default="")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    positive_sources = parse_sources(args.positive_sources)
    negative_sources = parse_sources(args.negative_sources)

    if not positive_sources:
        raise SystemExit("No positive sources provided.")
    if not negative_sources:
        raise SystemExit("No negative sources provided.")

    max_positives = parse_int(args.max_positives, "max-positives")
    max_negatives = parse_int(args.max_negatives, "max-negatives")
    min_per_source = parse_int(args.min_per_source, "min-per-source") or 0

    rng = random.Random(args.seed)

    positive_collected = collect_files(positive_sources)
    negative_collected = collect_files(negative_sources)

    positives = distribute_diverse(
        positive_collected, max_positives, min_per_source, rng
    )
    negatives = distribute_diverse(
        negative_collected, max_negatives, min_per_source, rng
    )

    manifest = {
        "wake_phrase": args.wake_phrase,
        "positives": positives,
        "negatives": negatives,
        "summary": {
            "positive_sources": {
                source: len(files) for source, files in positive_collected.items()
            },
            "negative_sources": {
                source: len(files) for source, files in negative_collected.items()
            },
            "selected_positives": len(positives),
            "selected_negatives": len(negatives),
            "min_per_source": min_per_source,
            "max_positives": max_positives,
            "max_negatives": max_negatives,
        },
    }

    manifest_path = output_dir / "dataset.json"
    with manifest_path.open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")

    write_list(output_dir / "positives.txt", positives)
    write_list(output_dir / "negatives.txt", negatives)

    print(json.dumps(manifest["summary"], indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
