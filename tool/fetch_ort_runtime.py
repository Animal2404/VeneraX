#!/usr/bin/env python3
"""
tool/fetch_ort_runtime.py
Downloads, verifies, and installs GPU-capable ONNX Runtime DLLs (DirectML / CUDA)
into the Windows build/debug output directories.

Specification: §1.2.1 in VeneraX AI Translation Implementation Plan.
"""

import argparse
import hashlib
import io
import os
import shutil
import sys
import urllib.request
import zipfile

# Pinned versions and known SHA-256 hashes
KNOWN_PACKAGES = {
    "directml": {
        "ort_version": "1.22.0",
        "ort_pkg_url": "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/1.22.0/microsoft.ml.onnxruntime.directml.1.22.0.nupkg",
        "ort_pkg_sha256": "29f9872d786236b79aa83f94482f3a17c14297e4833768d6d0ed4883ee732e60",
        "ort_dll_sha256": "95366724919f4e95ecc60010912ed538ad9804b6683fbd0aad389749102834b9",
        "dml_version": "1.15.4",
        "dml_pkg_url": "https://api.nuget.org/v3-flatcontainer/microsoft.ai.directml/1.15.4/microsoft.ai.directml.1.15.4.nupkg",
        "dml_pkg_sha256": "4e7cb7ddce8cf837a7a75dc029209b520ca0101470fcdf275c1f49736a3615b9",
        "dml_dll_sha256": "9c9e6d822561c6c41b90e6994b3e8857cf1d66dbfb1e0c4c799c7c89b4e92da1",
    }
}


def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def download_cached(url: str, expected_sha: str, cache_file: str) -> bytes:
    if os.path.exists(cache_file):
        with open(cache_file, "rb") as f:
            data = f.read()
        if sha256_of(data) == expected_sha:
            return data
        print(f"Cached file {cache_file} hash mismatch, re-downloading...")

    print(f"Downloading {url} ...")
    req = urllib.request.Request(url, headers={"User-Agent": "VeneraX-Tool"})
    with urllib.request.urlopen(req) as resp:
        data = resp.read()

    actual_sha = sha256_of(data)
    if expected_sha and actual_sha != expected_sha:
        raise ValueError(
            f"SHA-256 mismatch for {url}!\nExpected: {expected_sha}\nActual:   {actual_sha}"
        )

    os.makedirs(os.path.dirname(cache_file), exist_ok=True)
    with open(cache_file, "wb") as f:
        f.write(data)
    return data


def ensure_lock_file():
    lock_path = os.path.join("tool", "ort_runtime", "LOCK.md")
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    info = KNOWN_PACKAGES["directml"]
    content = f"""# ONNX Runtime & DirectML Lockfile

- **DirectML ORT Version**: `{info['ort_version']}`
  - Package: `{info['ort_pkg_url']}`
  - Package SHA-256: `{info['ort_pkg_sha256']}`
  - onnxruntime.dll SHA-256: `{info['ort_dll_sha256']}`
- **DirectML Library Version**: `{info['dml_version']}`
  - Package: `{info['dml_pkg_url']}`
  - Package SHA-256: `{info['dml_pkg_sha256']}`
  - DirectML.dll SHA-256: `{info['dml_dll_sha256']}`

Minimum OS: Windows 10 Version 1903 (Build 18362) or later (DirectX 12 / WDDM 2.x).
"""
    with open(lock_path, "w", encoding="utf-8") as f:
        f.write(content)


def main():
    parser = argparse.ArgumentParser(description="Fetch and install GPU-capable ONNX Runtime DLLs")
    parser.add_argument("--target-dir", required=True, help="Target build output directory")
    parser.add_argument("--edition", choices=["directml", "cuda", "cpu"], default="directml", help="Runtime edition")
    parser.add_argument("--version", default="1.22.0", help="ORT version")
    parser.add_argument("--cache-dir", default=os.path.join(".cache", "ort"), help="Cache directory")
    parser.add_argument("--apply", action="store_true", help="Apply file replacements")
    parser.add_argument("--dry-run", action="store_true", help="Dry run only")
    parser.add_argument("--allow-fallback-cpu", action="store_true", help="Allow fallback to CPU if download fails")

    args = parser.parse_args()

    if args.edition == "cpu":
        print("Edition is CPU: skipping ONNX Runtime replacement (retaining default).")
        return 0

    ensure_lock_file()

    if args.edition != "directml":
        print(f"Edition '{args.edition}' is not yet pre-configured. Use directml for standard GPU acceleration.")
        return 1

    cfg = KNOWN_PACKAGES["directml"]
    packages_dir = os.path.join(args.cache_dir, "packages")
    headers_dir = os.path.join(args.cache_dir, "headers")
    os.makedirs(headers_dir, exist_ok=True)

    try:
        ort_pkg_file = os.path.join(packages_dir, f"ort_directml_{cfg['ort_version']}.nupkg")
        ort_data = download_cached(cfg["ort_pkg_url"], cfg["ort_pkg_sha256"], ort_pkg_file)

        dml_pkg_file = os.path.join(packages_dir, f"directml_{cfg['dml_version']}.nupkg")
        dml_data = download_cached(cfg["dml_pkg_url"], cfg["dml_pkg_sha256"], dml_pkg_file)
    except Exception as e:
        if args.allow_fallback_cpu:
            print(f"WARNING: Failed to download GPU runtime ({e}). --allow-fallback-cpu is set, proceeding with CPU runtime.")
            return 0
        print(f"ERROR: Failed to fetch ONNX Runtime DirectML packages: {e}", file=sys.stderr)
        return 1

    # Extract required binaries and headers in memory
    ort_zip = zipfile.ZipFile(io.BytesIO(ort_data))
    dml_zip = zipfile.ZipFile(io.BytesIO(dml_data))

    ort_dll_bytes = ort_zip.read("runtimes/win-x64/native/onnxruntime.dll")
    ort_shared_bytes = ort_zip.read("runtimes/win-x64/native/onnxruntime_providers_shared.dll")
    dml_dll_bytes = dml_zip.read("bin/x64-win/DirectML.dll")
    header_bytes = ort_zip.read("build/native/include/onnxruntime_c_api.h")

    # Cache headers for gen_ort_api.dart
    header_out = os.path.join(headers_dir, "onnxruntime_c_api.h")
    with open(header_out, "wb") as f:
        f.write(header_bytes)

    target_dir = args.target_dir
    os.makedirs(target_dir, exist_ok=True)

    files_to_install = {
        "onnxruntime.dll": ort_dll_bytes,
        "onnxruntime_providers_shared.dll": ort_shared_bytes,
        "DirectML.dll": dml_dll_bytes,
    }

    print(f"Target directory: {target_dir}")
    for fname, content in files_to_install.items():
        dst_path = os.path.join(target_dir, fname)
        new_sha = sha256_of(content)

        if os.path.exists(dst_path):
            curr_sha = sha256_file(dst_path)
            if curr_sha == new_sha:
                print(f"  [OK] {fname} already up-to-date ({new_sha[:8]}).")
                continue
            else:
                print(f"  [OVERWRITE] {fname} (current: {curr_sha[:8]} -> new DirectML: {new_sha[:8]})")
        else:
            print(f"  [NEW] {fname} ({new_sha[:8]})")

        if args.apply:
            try:
                with open(dst_path, "wb") as f:
                    f.write(content)
                print(f"  -> Written {dst_path}")
            except PermissionError:
                print(
                    f"ERROR: Cannot write to {dst_path}. The file may be in use by a running venera.exe.\n"
                    f"Please terminate venera.exe / flutter run and try again.",
                    file=sys.stderr,
                )
                return 1

    if not args.apply:
        print("\nDry run completed. Pass --apply to perform file copy.")
    else:
        print("\nSuccessfully updated ONNX Runtime DirectML binaries.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
