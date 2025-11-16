#!/usr/bin/env python3
"""
Scan this repository (and its submodules) to:

1. Count number of non-empty lines and files per programming language.
2. Compute percentages of each language by line count.
3. Generate dummy files with random lines for each language, in such a way
   that (approximately) preserves the overall language distribution.

The goal is to make it easy for GitHub's language statistics to reflect the
actual mix of languages in the codebase, including this script itself.

Usage:
    python language_detection/generate_language_representation.py

The script is intentionally dependency-free (standard library only).
"""

from __future__ import annotations

import math
import os
import random
import string
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Tuple


# Root of the repository (this file lives in 01_language_detection/)
# We use sys.argv[0] so the script can be run from the repo root:
#   python 01_language_detection/generate_language_representation.py
SCRIPT_PATH = Path(sys.argv[0]).resolve()
REPO_ROOT = SCRIPT_PATH.parents[1]

# Where to put generated dummy files
GENERATED_DIR = REPO_ROOT / "01_language_detection" / "generated"

# Directories that should not be scanned for language statistics.
EXCLUDE_DIR_NAMES = {
    ".git",
    ".idea",
    ".vscode",
    "__pycache__",
    "node_modules",
    ".venv",
    "venv",
    "env",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    # We don't want previously generated dummy files to influence counts
    # when re-running the script.
    "generated",
}


# Map file extensions to a language label. This does not need to be perfect,
# just close enough to what GitHub Linguist would infer.
EXTENSION_TO_LANGUAGE: Mapping[str, str] = {
    ".py": "Python",
    ".js": "JavaScript",
    ".jsx": "JavaScript",
    ".ts": "TypeScript",
    ".tsx": "TypeScript",
    ".sh": "Shell",
    ".bash": "Shell",
    ".zsh": "Shell",
    ".yml": "YAML",
    ".yaml": "YAML",
    ".json": "JSON",
    ".md": "Markdown",
    ".rst": "reStructuredText",
    ".txt": "Text",
    ".lock": "Text",
    ".proto": "Protocol Buffers",
}


@dataclass
class LanguageStats:
    language: str
    lines: int = 0
    files: int = 0

    @property
    def percentage(self) -> float:
        # To be set later once we know total lines
        return 0.0


def detect_language(path: Path) -> str | None:
    """Return the language name for a given file path, or None if unknown."""
    return EXTENSION_TO_LANGUAGE.get(path.suffix.lower())


def iter_source_files(root: Path) -> Iterable[Path]:
    """Yield all files under root, excluding certain directories."""
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune excluded directories in-place
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIR_NAMES]
        for name in filenames:
            path = Path(dirpath) / name
            # Skip files without a known language
            if detect_language(path) is None:
                continue
            yield path


def count_non_empty_lines(path: Path) -> int:
    """Count non-empty lines in a text file, forgiving encoding issues."""
    lines = 0
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.strip():
                    lines += 1
    except OSError:
        # If we can't read a file for some reason, just skip it.
        return 0
    return lines


def gather_language_stats(root: Path) -> Dict[str, LanguageStats]:
    """Scan the repository and return a mapping of language -> stats."""
    stats: Dict[str, LanguageStats] = {}

    for path in iter_source_files(root):
        lang = detect_language(path)
        if not lang:
            continue
        if lang not in stats:
            stats[lang] = LanguageStats(language=lang, lines=0, files=0)
        file_lines = count_non_empty_lines(path)
        if file_lines == 0:
            continue
        stats[lang].lines += file_lines
        stats[lang].files += 1

    return stats


def choose_dummy_extension_per_language() -> Dict[str, str]:
    """
    For each language, choose a representative extension to use for dummy files.

    If multiple extensions map to the same language, we pick the first one
    encountered in EXTENSION_TO_LANGUAGE.
    """
    mapping: Dict[str, str] = {}
    for ext, lang in EXTENSION_TO_LANGUAGE.items():
        mapping.setdefault(lang, ext)
    return mapping


def comment_prefix_for_extension(ext: str) -> str:
    """Return a simple comment prefix for a given extension."""
    hash_comment_exts = {
        ".py",
        ".sh",
        ".bash",
        ".zsh",
        ".yml",
        ".yaml",
        ".md",
        ".rst",
        ".txt",
        ".proto",
    }
    if ext in hash_comment_exts:
        return "#"
    # Default to C/JS-style comments
    return "//"


def generate_random_words(n: int) -> str:
    """Generate a simple string of n lowercase random 'words'."""
    words: List[str] = []
    for _ in range(n):
        length = random.randint(3, 8)
        word = "".join(random.choices(string.ascii_lowercase, k=length))
        words.append(word)
    return " ".join(words)


def allocate_dummy_lines_per_language(
    stats: Mapping[str, LanguageStats],
    total_dummy_lines: int,
) -> Dict[str, int]:
    """
    Decide how many dummy lines to create per language.

    We allocate lines proportional to the existing line counts so that,
    when the dummy files are added, the overall language distribution
    remains (approximately) the same.
    """
    line_counts = {lang: s.lines for lang, s in stats.items() if s.lines > 0}
    total_lines = sum(line_counts.values())
    if total_lines == 0 or total_dummy_lines <= 0:
        return {lang: 0 for lang in stats.keys()}

    # First pass: real-valued allocation
    allocations: Dict[str, float] = {}
    for lang, lines in line_counts.items():
        allocations[lang] = (lines / total_lines) * total_dummy_lines

    # Second pass: round to integers while preserving total
    int_allocations: Dict[str, int] = {}
    # Sort by fractional part descending to distribute rounding error fairly
    frac_sorted: List[Tuple[str, float]] = sorted(
        ((lang, alloc - math.floor(alloc)) for lang, alloc in allocations.items()),
        key=lambda x: x[1],
        reverse=True,
    )

    # Floor everything
    for lang, alloc in allocations.items():
        int_allocations[lang] = int(math.floor(alloc))

    current_total = sum(int_allocations.values())
    deficit = total_dummy_lines - current_total

    # Distribute remaining lines starting with largest fractional parts
    for lang, _frac in frac_sorted:
        if deficit <= 0:
            break
        int_allocations[lang] += 1
        deficit -= 1

    # Ensure all languages are represented (even if 0)
    for lang in stats.keys():
        int_allocations.setdefault(lang, 0)

    return int_allocations


def write_dummy_files(
    stats: Mapping[str, LanguageStats],
    total_dummy_lines: int = 2000,
) -> None:
    """
    Generate dummy files under language_detection/generated/ for each language.

    Each language gets some number of lines proportional to its current share
    of the codebase. Lines are simple random comment lines.
    """
    if not stats:
        print("No language statistics found; nothing to generate.")
        return

    GENERATED_DIR.mkdir(parents=True, exist_ok=True)

    lang_to_ext = choose_dummy_extension_per_language()
    lang_to_lines = allocate_dummy_lines_per_language(stats, total_dummy_lines)

    random.seed(42)  # Deterministic "random" content for reproducibility

    for index, (lang, lang_stats) in enumerate(sorted(stats.items()), start=1):
        num_lines = lang_to_lines.get(lang, 0)
        if num_lines <= 0:
            continue

        ext = lang_to_ext.get(lang, ".txt")
        comment_prefix = comment_prefix_for_extension(ext)

        slug = "".join(
            c.lower() if c.isalnum() else "_" for c in lang
        ).strip("_") or "unknown"
        filename = f"{index:02d}_{slug}_language_representation{ext}"
        target = GENERATED_DIR / filename

        with target.open("w", encoding="utf-8") as f:
            header_lines = [
                f"{comment_prefix} File used for language distribution visualization for {lang}.\n",
                f"{comment_prefix} This repository includes multiple languages; this file\n",
                f"{comment_prefix} contributes {lang} lines so that language statistics remain representative.\n",
                f"{comment_prefix} Total dummy lines requested in this file group: {total_dummy_lines}\n",
            ]
            for hl in header_lines:
                f.write(hl)

            remaining = max(0, num_lines - len(header_lines))
            for _ in range(remaining):
                # We keep the content trivial but slightly varied.
                word_count = random.randint(3, 8)
                words = generate_random_words(word_count)
                line = f"{comment_prefix} {lang} dummy line: {words}\n"
                f.write(line)


def print_summary(stats: Mapping[str, LanguageStats]) -> None:
    """Pretty-print a summary of language statistics."""
    if not stats:
        print("No languages detected.")
        return

    total_lines = sum(s.lines for s in stats.values())

    print("Language statistics (by non-empty line):")
    print("-" * 60)
    print(f"{'Language':20} {'Lines':>10} {'Files':>10} {'Percent':>10}")
    print("-" * 60)
    for lang, s in sorted(stats.items(), key=lambda item: item[1].lines, reverse=True):
        percent = (s.lines / total_lines * 100.0) if total_lines else 0.0
        print(f"{lang:20} {s.lines:10d} {s.files:10d} {percent:9.2f}%")
    print("-" * 60)
    print(f"{'TOTAL':20} {total_lines:10d}")


def main() -> None:
    # Ensure the working directory is the repo root (one level above this script),
    # so any relative paths behave as if the script was run from the root.
    os.chdir(REPO_ROOT)

    print(f"Scanning repository under: {REPO_ROOT}")
    stats = gather_language_stats(REPO_ROOT)
    print_summary(stats)

    # You can tune this if you want more/less synthetic content.
    total_dummy_lines = 2000
    print(f"\nGenerating approximately {total_dummy_lines} dummy lines across languages...")
    write_dummy_files(stats, total_dummy_lines=total_dummy_lines)
    print(f"Dummy files written under: {GENERATED_DIR}")


if __name__ == "__main__":
    main()
