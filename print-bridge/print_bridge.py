#!/usr/bin/env python3
"""Small, dependency-free HTTP to CUPS print bridge for KOReader.

Run this on a Raspberry Pi or any Linux host with CUPS. The only required
software is CUPS (`lp` must be on PATH). EPUB, HTML, Markdown, and text
conversion is optional; install Calibre, LibreOffice, or Pandoc with a PDF
engine if those formats should be converted before printing.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import subprocess
import tempfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


MAX_BYTES = 50 * 1024 * 1024
SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._-]+")
COLOR_MODES = {"color", "monochrome"}
SIDES_MODES = {"one-sided", "two-sided-long-edge", "two-sided-short-edge"}
MEDIA_NAMES = {"na_letter", "iso_a4_210x297mm"}


def safe_name(name: str, default: str) -> str:
    name = Path(name or default).name
    cleaned = SAFE_NAME_RE.sub("_", name).strip("._")
    return cleaned or default


def parse_ranges(value: str | None) -> str | None:
    if not value:
        return None
    ranges = []
    for item in value.split(","):
        match = re.fullmatch(r"\s*(\d+)(?:\s*-\s*(\d+))?\s*", item)
        if not match:
            raise ValueError("page ranges must look like 1-3,7")
        first = int(match.group(1))
        last = int(match.group(2) or first)
        if first < 1 or last < first or last > 65535:
            raise ValueError("page ranges must ascend and use pages 1-65535")
        ranges.append(str(first) if first == last else f"{first}-{last}")
    return ",".join(ranges)


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def find_printer(requested: str | None = None) -> str | None:
    """Choose the configured printer, else the CUPS default, else a single
    advertised printer (when exactly one exists; ambiguous setups demand an
    explicit PRINTER so no job lands on the wrong machine)."""
    requested = requested or os.environ.get("PRINTER")
    if requested:
        return requested
    if not command_exists("lpstat"):
        return None

    default = subprocess.run(["lpstat", "-d"], capture_output=True, text=True)
    match = re.search(r"system default destination:\s*(\S+)", default.stdout or "")
    if match:
        return match.group(1)

    printers = subprocess.run(["lpstat", "-e"], capture_output=True, text=True)
    names = [line.strip() for line in (printers.stdout or "").splitlines() if line.strip()]
    if len(names) == 1:
        return names[0]
    return None


def run_checked(args: list[str]) -> None:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(detail or f"{args[0]} failed")


def pandoc_to_pdf(source: Path, output: Path) -> Path:
    engine = next(
        (name for name in ("weasyprint", "wkhtmltopdf", "xelatex", "pdflatex") if command_exists(name)),
        None,
    )
    if not engine:
        raise RuntimeError(
            "Pandoc needs a PDF engine. Install WeasyPrint with "
            "'sudo apt install weasyprint', or install Calibre for EPUB."
        )
    args = ["pandoc", str(source)]
    if engine in {"weasyprint", "wkhtmltopdf"}:
        args.extend(["-t", "html"])
    args.extend([f"--pdf-engine={engine}", "-o", str(output)])
    run_checked(args)
    return output


def markdown_to_html(source: str, title: str) -> str:
    # This deliberately supports a useful safe subset without requiring a
    # Python Markdown package. Pandoc is preferred when it is installed.
    lines = []
    in_code = False
    for raw in source.splitlines():
        line = html.escape(raw)
        if line.startswith("```"):
            if in_code:
                lines.append("</code></pre>")
            else:
                lines.append("<pre><code>")
            in_code = not in_code
        elif in_code:
            lines.append(line)
        elif line.startswith("# "):
            lines.append(f"<h1>{line[2:]}</h1>")
        elif line.startswith("## "):
            lines.append(f"<h2>{line[3:]}</h2>")
        elif line.startswith("- "):
            lines.append(f"<li>{line[2:]}</li>")
        elif line.strip():
            lines.append(f"<p>{line}</p>")
        else:
            lines.append("")
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{html.escape(title)}</title></head><body>"
        + "\n".join(lines)
        + "</body></html>"
    )


def convert_to_pdf(source: Path, kind: str, workdir: Path) -> Path:
    output = workdir / f"{source.stem}.pdf"
    if kind == "pdf":
        return source

    if kind in {"md", "markdown", "text", "txt"}:
        if command_exists("pandoc"):
            return pandoc_to_pdf(source, output)
        html_path = workdir / f"{source.stem}.html"
        if kind in {"md", "markdown"}:
            content = markdown_to_html(source.read_text(encoding="utf-8", errors="replace"), source.stem)
        else:
            content = (
                "<!doctype html><html><meta charset='utf-8'><body><pre>"
                + html.escape(source.read_text(encoding="utf-8", errors="replace"))
                + "</pre></body></html>"
            )
        html_path.write_text(content, encoding="utf-8")
        source = html_path
        kind = "html"

    if kind in {"epub", "html", "htm"}:
        if kind == "epub" and command_exists("ebook-convert"):
            run_checked(["ebook-convert", str(source), str(output)])
            return output
        if command_exists("libreoffice"):
            run_checked(
                [
                    "libreoffice",
                    "--headless",
                    "--convert-to",
                    "pdf",
                    "--outdir",
                    str(workdir),
                    str(source),
                ]
            )
            generated = workdir / f"{source.stem}.pdf"
            if generated.exists():
                return generated
        if command_exists("pandoc"):
            return pandoc_to_pdf(source, output)

    raise RuntimeError(
        f"Cannot convert .{kind} to PDF. Install pandoc; for EPUB, "
        "Calibre (ebook-convert) or LibreOffice also works."
    )


def print_with_cups(
    source: Path,
    printer: str | None,
    page_ranges: str | None,
    media: str | None,
    copies: int,
    color: str,
    sides: str,
) -> str:
    if not command_exists("lp"):
        raise RuntimeError("CUPS is not installed: the lp command was not found")
    args = ["lp"]
    selected_printer = find_printer(printer)
    if selected_printer:
        args += ["-d", selected_printer]
    if page_ranges:
        args += ["-o", f"page-ranges={page_ranges}"]
    if media:
        args += ["-o", f"media={media}"]
    args += ["-o", f"print-color-mode={color}"]
    args += ["-o", f"sides={sides}"]
    if copies > 1:
        args += ["-n", str(copies)]
    args.append(str(source))
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip() or "lp failed"
        if not selected_printer:
            detail += ". No CUPS printer was selected; run setup_printer.sh or set PRINTER."
        raise RuntimeError(detail)
    return (result.stdout or "Print job submitted").strip()


class PrintHandler(BaseHTTPRequestHandler):
    server_version = "KOReaderPrintBridge/1.0"

    def send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reject(self, status: int, message: str) -> None:
        self.send_json(status, {"ok": False, "error": message})

    def do_GET(self) -> None:
        if urlparse(self.path).path == "/health":
            self.send_json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "service": "koreader-print-bridge",
                    "printer": find_printer(),
                },
            )
        else:
            self.reject(HTTPStatus.NOT_FOUND, "not found")

    def read_body(self) -> bytes:
        raw_length = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_length)
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if length < 0 or length > MAX_BYTES:
            raise ValueError(f"payload exceeds {MAX_BYTES} byte limit")
        body = self.rfile.read(length)
        if len(body) != length:
            raise ValueError("incomplete request body")
        return body

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path not in {"/v1/print/file", "/v1/print/text"}:
            self.reject(HTTPStatus.NOT_FOUND, "not found")
            return
        try:
            if path.endswith("/text"):
                body = self.read_body().decode("utf-8", errors="replace")
                filename = safe_name(self.headers.get("X-File-Name", "koreader-text.md"), "text.md")
                kind = "md" if filename.lower().endswith((".md", ".markdown")) else "text"
            else:
                body = self.read_body()
                filename = safe_name(self.headers.get("X-File-Name", "koreader-document"), "document")
                kind = (self.headers.get("X-File-Type") or Path(filename).suffix.lstrip(".")).lower()

            ranges = parse_ranges(self.headers.get("X-Page-Ranges"))
            color = self.headers.get("X-Color") or os.environ.get("COLOR") or "color"
            sides = self.headers.get("X-Sides") or os.environ.get("SIDES") or "one-sided"
            media = self.headers.get("X-Media") or os.environ.get("MEDIA") or "na_letter"
            if color not in COLOR_MODES:
                raise ValueError("color must be color or monochrome")
            if sides not in SIDES_MODES:
                raise ValueError("sides is not supported")
            if media not in MEDIA_NAMES:
                raise ValueError("media must be Letter or A4")
            copies = max(1, int(self.headers.get("X-Copies") or os.environ.get("COPIES", "1")))
            if copies > 99:
                raise ValueError("copies must be 1-99")
            printer = self.headers.get("X-Printer-Name") or os.environ.get("PRINTER")
            with tempfile.TemporaryDirectory(prefix="koreader-print-") as tmp:
                workdir = Path(tmp)
                source = workdir / filename
                if isinstance(body, str):
                    source.write_text(body, encoding="utf-8")
                else:
                    source.write_bytes(body)
                image_kinds = {"png", "jpg", "jpeg", "webp", "bmp", "image"}
                printable = source if kind in image_kinds else convert_to_pdf(source, kind, workdir)
                message = print_with_cups(
                    printable,
                    printer,
                    ranges,
                    media,
                    copies,
                    color=color,
                    sides=sides,
                )
            self.send_json(HTTPStatus.ACCEPTED, {"ok": True, "message": message})
        except (ValueError, RuntimeError, OSError) as exc:
            self.reject(HTTPStatus.BAD_REQUEST, str(exc))

    def log_message(self, format: str, *args: object) -> None:
        print(f"[print-bridge] {self.address_string()} - {format % args}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), PrintHandler)
    print(f"KOReader print bridge listening on http://{args.host}:{args.port}")
    print("Set PRINTER to a CUPS printer name, or leave it empty for the default printer.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
