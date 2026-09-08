#!/usr/bin/env python3
"""
Upload exported models to GitHub Releases tag 'models' and generate
checksum / URL catalog entries for translation_models.dart and ASSETS.md.

Prerequisites:
    gh auth login (GitHub CLI authenticated with write access)

Usage:
    python tool/model_export/publish.py --repo Owner/VeneraX dist/*.onnx
"""

import argparse
import hashlib
import os
import subprocess
import sys


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Upload models to GitHub release and print asset records.")
    parser.add_argument("files", nargs="+", help="Model files to upload (.onnx, .txt)")
    parser.add_argument("--repo", default=None, help="GitHub repository (owner/repo). Defaults to git remote.")
    parser.add_argument("--tag", default="models", help="Release tag name (default: 'models')")
    parser.add_argument("--dry-run", action="store_true", help="Print actions and checksums without uploading")
    args = parser.parse_args()

    files = [f for f in args.files if os.path.isfile(f)]
    if not files:
        print("No valid files found to upload.", file=sys.stderr)
        sys.exit(1)

    print(f"Target release tag: {args.tag}")
    if args.repo:
        print(f"Target repository: {args.repo}")

    records = []
    for f in files:
        size = os.path.getsize(f)
        sha = sha256_file(f)
        basename = os.path.basename(f)
        records.append({
            "name": basename,
            "path": f,
            "size": size,
            "sha256": sha,
        })

    print("\n--- Model Assets Summary ---")
    for r in records:
        print(f"File: {r['name']} ({r['size']:,} bytes)")
        print(f"  SHA-256: {r['sha256']}")

    if args.dry_run:
        print("\nDry run completed. No files uploaded.")
        return

    # Check if gh cli is installed
    cmd = ["gh", "release", "upload", args.tag]
    if args.repo:
        cmd.extend(["--repo", args.repo])
    cmd.extend([r["path"] for r in records])
    cmd.append("--clobber")

    print(f"\nExecuting: {' '.join(cmd)}")
    try:
        subprocess.run(cmd, check=True)
        print("\nUpload completed successfully!")
    except FileNotFoundError:
        print("ERROR: 'gh' CLI was not found. Please install the GitHub CLI.", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"ERROR: Upload failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
