# Print bridge for KOReader

The companion service for `koreader-print.koplugin`. It listens on the local
network and submits files to CUPS with `lp`, and it converts EPUB, HTML,
Markdown, and text to PDF before printing.

**Tested on:** a Raspberry Pi driving an Epson ET-2850, printing PDFs and text
from KOReader on a Kindle Paperwhite 5. Any other host with CUPS and Python 3,
and any other CUPS-supported printer, is *expected* to work but untested —
please report your combination in an issue.

Setup is easiest with your printer powered on and on the same network.

## Quick setup (auto-detects an Epson ET-2850, overridable)

From the machine that has this folder checked out:

```sh
scp -r print-bridge USER@HOST:~/
ssh USER@HOST
cd ~/print-bridge
chmod +x setup_printer.sh
./setup_printer.sh
```

`USER@HOST` is any account/host your Linux box is reachable as — use its
username and host name or IP address.

Using a printer that is **not** an Epson ET-2850? The script only uses its
name for auto-detection defaults; point it anywhere:

```sh
PRINTER_URI=ipp://PRINTER-ADDRESS/ipp/print PRINTER_NAME=myprinter \
    MEDIA=iso_a4_210x297mm ./setup_printer.sh
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `PRINTER_URI` | auto-detected ET-2850 | Device URI from `lpinfo -v` to attach |
| `PRINTER_NAME` | `printer` | Name of the CUPS queue that is created |
| `PRINTER_DESC` | the queue name | Human-readable CUPS description |
| `MEDIA` | `na_letter` | Default paper size; `iso_a4_210x297mm` for A4 |
| `BRIDGE_DIR` | `~/koreader-print-bridge` | Where the bridge is installed |

Step by step, `setup_printer.sh`:

1. Installs `cups`, `cups-client`, `avahi-daemon`, `avahi-utils`, `python3`,
   `pandoc`, and `weasyprint` (for Markdown/text/HTML conversion), and
   enables CUPS and Avahi.
2. Installs `print_bridge.py` into `BRIDGE_DIR`.
3. Discovers the printer with `lpinfo -v` (mDNS/IPP network discovery) or
   uses the given `PRINTER_URI`, creates the CUPS queue with the driverless
   `everywhere` model, and makes it the system default.
4. Writes `/etc/default/koreader-print-bridge` plus a systemd unit at
   `/etc/systemd/system/koreader-print-bridge.service`, and starts it.
5. Prints the bridge URL (`http://HOST:8787`) to enter in KOReader under
   **Print → Optional format converter**.

If discovery finds nothing, the script lists the network devices CUPS sees
so you can check the printer's Wi-Fi and pick a URI yourself.

## Manual install

```sh
sudo apt update
sudo apt install cups python3
sudo usermod -aG lpadmin "$USER"
sudo systemctl enable --now cups
```

Add and test the printer with the normal CUPS tools:

```sh
lpstat -p -d
lp -d YOUR_PRINTER some-test.pdf
```

Copy `print_bridge.py` to the machine and start it:

```sh
PRINTER=YOUR_PRINTER python3 print_bridge.py
```

In KOReader, open **Print → Optional format converter** and enter
`http://HOST-NAME-OR-IP:8787`.

## What KOReader asks for

Each print opens native KOReader choices for:

- Page range for PDFs and EPUBs
- Color or black and white
- Single-sided or double-sided
- Letter or A4 paper
- Number of copies

Letter is the default (override with `MEDIA`); color, sides, paper size, and
copies keep their last-used values.

## Bridge API

The plugin talks to the bridge over plain HTTP on the local network:

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/health` | GET | Small JSON status — verify the service with `curl http://HOST:8787/health`. |
| `/v1/print/file` | POST | Prints an uploaded file (PDF, EPUB, Markdown, text, HTML, or an image). |
| `/v1/print/text` | POST | Prints a UTF-8 text body (typed, clipboard, or highlighted text). |

Request headers the bridge understands (all optional except the body length):

| Header | Values |
| --- | --- |
| `X-File-Name` | Original file name (sanitized before saving). |
| `X-File-Type` | File kind, derived from the name when absent (`pdf`, `epub`, `md`, `txt`, `html`, `png`, `jpg`, …). |
| `X-Page-Ranges` | e.g. `1-3,7`. Must ascend; pages 1–65535. |
| `X-Color` | `color` or `monochrome`. |
| `X-Sides` | `one-sided`, `two-sided-long-edge`, or `two-sided-short-edge`. |
| `X-Media` | `na_letter` (Letter) or `iso_a4_210x297mm` (A4). |
| `X-Copies` | 1–99. |
| `X-Printer-Name` | CUPS queue to print to, overriding `PRINTER`. |

Environment variables provide the same defaults when a header is missing:
`PRINTER`, `COLOR`, `SIDES`, `MEDIA`, and `COPIES`. Uploads are limited to
50 MB per job.

Quick manual test from any computer on the LAN:

```sh
curl -X POST --data-binary @test.pdf -H 'X-File-Type: pdf' \
    http://HOST:8787/v1/print/file
```

## Conversion mechanics

PDF and image files print as-is. EPUB, HTML, and Markdown are converted to PDF
first; the bridge tries, in order: Calibre's `ebook-convert`, LibreOffice, and
Pandoc with a PDF engine (WeasyPrint, wkhtmltopdf, XeLaTeX, or pdfLaTeX). The
setup script installs Pandoc + WeasyPrint. Markdown and plain text go through a
small built-in HTML pre-renderer before the PDF step, so they keep working even
without Calibre or LibreOffice. If no PDF converter is installed at all,
affected jobs fail with a clear error naming what to install.

## Run as a service

The setup script already installs and starts the service. To do it manually,
create `/etc/systemd/system/koreader-print-bridge.service` (adjust user and
paths — `~` is the account's home):

```ini
[Unit]
Description=KOReader print bridge
After=network-online.target cups.service
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/koreader-print-bridge
EnvironmentFile=-/etc/default/koreader-print-bridge
ExecStart=/usr/bin/python3 /home/pi/koreader-print-bridge/print_bridge.py --host 0.0.0.0 --port 8787
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Then enable and verify it:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now koreader-print-bridge
curl http://127.0.0.1:8787/health
journalctl -u koreader-print-bridge -f   # watch the logs
```

To remove the bridge and the CUPS queue (default queue name `printer`):

```sh
sudo systemctl disable --now koreader-print-bridge
sudo rm /etc/systemd/system/koreader-print-bridge.service /etc/default/koreader-print-bridge
sudo lpadmin -x printer
rm -rf ~/koreader-print-bridge
sudo systemctl daemon-reload
```

## Security note

The bridge is intended for a trusted home LAN. Do not forward port 8787 to
the internet. If the network is shared or untrusted, place it behind a
firewall or an authenticated reverse proxy before using it.

## License

AGPL-3.0-only, the same license as the plugin — see the main `README.md`
one level up for the terms and link to the full license text.
