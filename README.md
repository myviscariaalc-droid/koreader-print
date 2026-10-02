# KOReader Print

Print documents, text, and images from KOReader to a network printer in two
ways:

- **Directly over IPP** — works with any network printer that advertises a
  format the plugin can send (JPEG almost everywhere; PDF and PostScript on
  many laser printers; more depending on the model).
- **Through the optional converter bridge** — a tiny HTTP service running on
  a Raspberry Pi or any Linux machine with CUPS. It converts PDF, EPUB,
  Markdown, plain text, and HTML to PDF before printing, so anything KOReader
  can open can come out on paper, on any printer CUPS can drive.

Works on every KOReader platform (Kobo, Kindle, PocketBook, reMarkable,
Android, Cervantes, and the desktop build). Plugin version 1.9.2.

## Install the plugin

1. Copy the whole `koreader-print.koplugin` folder — `main.lua`, `_meta.lua`,
   and `print-test.jpg` must all be present — into KOReader's plugin folder
   (over USB, cloud sync, or however you manage files on the device):

   | Device | Plugin folder |
   | --- | --- |
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` on the USB drive |
   | PocketBook | `applications/koreader/plugins/` |
   | reMarkable | `koreader/plugins/` |
   | Android | `koreader/plugins/` in the app's shared storage |
   | Desktop builds | `~/.config/koreader/plugins/` |

2. Restart KOReader.
3. Open the top menu's **Tools** tab (the wrench icon 🛠): **Print** is a
   top-level entry there.

## First-time setup

1. **Find your printer's IPP address.** Most modern network printers answer
   IPP on port 631. Common address shapes:
   - `http://PRINTER-ADDRESS:631/ipp/print` (IPP Everywhere / driverless
     printers, most Epsons, HPs, and Brothers)
   - `https://PRINTER-ADDRESS:631/ipp/print` (some models only accept the
     encrypted variant — the plugin connects without certificate validation,
     which is fine on a trusted home network)
   - `ipp://PRINTER-ADDRESS:631/ipp/print` (accepted too; rewritten to HTTP
     for the actual exchange)
   - A printer shared by a CUPS server: `http://SERVER:631/printers/NAME`

   Find the printer's address on its front-panel or web status page, or in
   your router's device list. Reserving the address in the router's DHCP
   settings stops it from changing.
2. **Set the printer address**: top menu → 🛠 **Tools** → **Print** →
   **Printer settings**, type the address, tap **Save**. You only do this
   once — it is remembered between sessions. To change it later, open the
   same entry and overwrite it.
3. **Print → Print JPEG test page** to prove the connection and that the
   printer accepts `image/jpeg`. If this prints, the pipeline works.
4. **Print → Check printer capabilities** for a live report of what the
   printer advertises: accepted formats, paper sizes, color modes, sides,
   and the copy range — and which of your file types print directly versus
   need the converter.

## How it decides what to print

Before every job, the plugin queries the printer's advertised capabilities
and behaves accordingly:

- A format the printer advertises (JPEG on most, PDF on many lasers, text on
  some) is sent directly.
- A format the printer does not advertise goes through the converter when one
  is configured — the status messages say so explicitly ("converting it with
  the converter and printing it now…", then "Converted and sent: … is now
  printing via the converter.").
- With no converter configured, the plugin explains the limitation and offers
  to set the converter up instead of sending a job the printer would reject.
- `application/octet-stream` is treated as **best-effort only** even when the
  printer advertises it: the printer has to guess the file type, which often
  produces nothing. The plugin never substitutes it automatically.
- Typed, clipboard, and highlighted text print through the converter when one
  is configured; otherwise the plugin explains that the printer does not
  accept `text/plain` instead of sending a job that will not print.

## Menu reference (Tools → Print)

| Entry | What it does |
| --- | --- |
| Print current document | Page-range dialog first (PDF/EPUB), then color, sides, paper, and copies. |
| Quick print current document | Prints the whole open document with the last-used options. |
| Print a file | Pick a supported file (long-press it, then Choose), then set options. |
| Print clipboard | Prints the clipboard text through the converter. |
| Print typed text or Markdown | Opens a text box; the text prints through the converter. |
| Print JPEG test page | Prints the bundled test image; separates connection problems from format problems. |
| Check printer capabilities | Queries the printer and reports accepted formats, paper sizes, color modes, sides, copies. |
| Printer settings | Sets the printer's IPP address. |
| Optional format converter | Sets the converter bridge address, or clears it. |

Selecting **Print selected text** from a highlight's dialog sends the
selection through the same text-printing flow.

## What it supports

- PDF and EPUB files, with page ranges such as `1-3,7`
- Markdown, plain text, and HTML files
- PNG, JPEG, WebP, and BMP images
- Text from the KOReader clipboard
- Text selected with KOReader's highlight tool
- Text or Markdown typed directly in KOReader
- A small built-in JPEG test page (**Print JPEG test page**)
- Native choices for color mode, sides, paper size (Letter/A4, or whatever the
  printer advertises — mismatches are substituted and reported), and copies

Color mode, sides, paper size, and copies are remembered between jobs.
**Quick print current document** uses the remembered options; **Print current
document** asks for a page range first.

## Job reporting

Every direct IPP job reports:

- the detected document format and job name,
- the printer's own job state: **accepted** (queued), **processing**
  (printing has started), **completed**, **aborted**, or **canceled** —
  an unrecognized state is reported as such, not as "still printing",
- the page count counted by the printer (marked as provisional while the job
  is still processing),
- the printer's own reason codes for failures, translated into a next step
  (for example `document-unprintable-error` → "convert with the converter,
  or print as JPEG").

After acceptance the plugin polls briefly (~16 s) so a job reported as
processing can reach a final state. "Completed" always means the printer
finished the job — check the tray for the physical output; a job reported as
completed with zero pages is called out explicitly. An ambiguous job is never
silently resent: the plugin explains the uncertainty and asks before
retrying or converting.

## Troubleshooting

| Symptom | Meaning and fix |
| --- | --- |
| Test page prints, documents do not | The connection is fine; that document's format needs the converter bridge. |
| Report says **aborted** with `document-unprintable-error` or `document-format-error` | The printer rejected the format. Tap **Convert & print**, or set up the converter first. |
| Report says **accepted** or **processing** | The printer has the job but has not finished; do not resend — the status poll returns a final answer within about 16 seconds. |
| "Could not connect to the printer or print bridge" | Check the address in Printer settings, that both devices share the network, and that the printer is awake. |
| `IPP 0x040A document format not supported` | That format needs the converter (typically PDF, EPUB, Markdown, plain text). |
| `IPP 0x0400 bad request` | Update the plugin: older builds sent a non-standard page-range encoding that strict printers reject. |
| "completed" with zero pages counted, nothing in the tray | The printer finished without printing; check its display and queue, then print via the converter. |
| Nothing happens when printing | Nothing may be set up yet: enter the printer's IPP address under Print → Printer settings. |

## Optional: the converter bridge (Raspberry Pi or any Linux host)

Set this up when the printer rejects the formats you want, or to print
EPUB/HTML/Markdown/text as formatted PDFs. Copy the bridge folder to the
host and run its setup script:

```sh
scp -r raspberry-pi-print-bridge USER@HOST:~/
ssh USER@HOST
cd ~/raspberry-pi-print-bridge
chmod +x setup_et2850.sh
./setup_et2850.sh   # or: PRINTER_URI=ipp://ADDRESS/ipp/print PRINTER_NAME=myprinter ./setup_et2850.sh
```

The script installs CUPS, discovers the printer (or takes `PRINTER_URI=...`
explicitly), installs the bridge as a systemd service, and prints the bridge
URL. Enter that URL in KOReader under **Print → Optional format converter**.
Full details are in
[`raspberry-pi-print-bridge/README.md`](raspberry-pi-print-bridge/README.md).

The bridge is designed for a trusted LAN — it has no authentication, so do
not port-forward it to the internet.

## Printer notes: Epson ET-2850 (tested model)

The ET-2850's IPP endpoint advertises `image/jpeg`, `image/urf`,
`image/pwg-raster`, Epson's ESC/P-R, and (best-effort)
`application/octet-stream` — so it prints JPEG directly, while PDF and plain
text need the converter bridge. Advertising `image/jpeg` still only means the
printer accepts the format request, not that every file prints; the test page
and the job report are the honest check. If your model behaves differently,
**Check printer capabilities** shows its actual advertised list.

## License

This project — the plugin, the print bridge, and the setup script — is
licensed under the **GNU Affero General Public License, version 3.0 only
(AGPL-3.0-only)**. See <https://www.gnu.org/licenses/agpl-3.0.txt> for the
full text. In short: you may use, copy, modify, and share it freely, and if
you run a modified copy as a network service (such as the print bridge) the
source must be made available to its users.
