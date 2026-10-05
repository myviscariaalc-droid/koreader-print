#!/bin/sh
set -eu

# One-time print-bridge setup: installs CUPS, attaches a network printer with
# driverless IPP (no vendor driver needed when the printer advertises itself),
# and installs the bridge as a service. By default it auto-detects an Epson
# ET-2850 on the same Wi-Fi; override it for any other printer:
#   PRINTER_URI=ipp://printer-address/ipp/print PRINTER_NAME=myprinter ./setup_printer.sh

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BRIDGE_DIR=${BRIDGE_DIR:-"$HOME/koreader-print-bridge"}
SERVICE_USER=${SUDO_USER:-"$USER"}

echo "Installing CUPS, printer discovery, and PDF conversion tools..."
sudo apt-get update
sudo apt-get install -y cups cups-client avahi-daemon avahi-utils python3 pandoc weasyprint
sudo systemctl enable --now cups
sudo systemctl enable --now avahi-daemon || true

sudo install -d -m 0755 "$BRIDGE_DIR"
sudo install -m 0755 "$SCRIPT_DIR/print_bridge.py" "$BRIDGE_DIR/print_bridge.py"
sudo chown -R "$SERVICE_USER":"$(id -gn "$SERVICE_USER")" "$BRIDGE_DIR"

PRINTER_NAME=${PRINTER_NAME:-printer}
PRINTER_DESC=${PRINTER_DESC:-$PRINTER_NAME}
PRINTER_URI=${PRINTER_URI:-}
MEDIA=${MEDIA:-na_letter}

if [ -z "$PRINTER_URI" ]; then
    echo "Auto-detecting an Epson ET-2850 on the local network (the default target)..."
    echo "For another printer, pass it explicitly, e.g.:"
    echo "  PRINTER_URI=ipp://printer-address/ipp/print PRINTER_NAME=myprinter ./setup_printer.sh"
    PRINTER_URI=$(lpinfo -v | awk '
        tolower($0) ~ /et[-_ ]?2850|epson/ { print $2; exit }
    ')
fi

if [ -z "$PRINTER_URI" ]; then
    echo "No printer was auto-detected."
    echo "Make sure the printer is powered on and connected to the same Wi-Fi,"
    echo "or pass PRINTER_URI=ipp://printer-address/ipp/print explicitly."
    echo
    echo "Available network devices:"
    lpinfo -v | sed -n '/network/p' || true
    exit 1
fi

echo "Using printer URI: $PRINTER_URI"
sudo lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
sudo lpadmin \
    -p "$PRINTER_NAME" \
    -E \
    -v "$PRINTER_URI" \
    -m everywhere \
    -D "$PRINTER_DESC"
sudo lpoptions -d "$PRINTER_NAME"

sudo tee /etc/default/koreader-print-bridge >/dev/null <<EOF
PRINTER=$PRINTER_NAME
MEDIA=$MEDIA
EOF

sudo tee /etc/systemd/system/koreader-print-bridge.service >/dev/null <<EOF
[Unit]
Description=KOReader print bridge
After=network-online.target cups.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$BRIDGE_DIR
EnvironmentFile=-/etc/default/koreader-print-bridge
ExecStart=/usr/bin/python3 $BRIDGE_DIR/print_bridge.py --host 0.0.0.0 --port 8787
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now koreader-print-bridge

BRIDGE_HOST=$(hostname -I | awk '{print $1}')
echo
echo "$PRINTER_NAME ($PRINTER_URI) is configured as the CUPS default printer."
echo "Bridge health: http://$BRIDGE_HOST:8787/health"
echo "In KOReader (Tools > Print > Optional format converter), set the bridge URL to:"
echo "  http://$BRIDGE_HOST:8787"
