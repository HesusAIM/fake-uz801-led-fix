#!/bin/bash
# =============================================================================
# openstick-leds.sh — status LEDs for OpenStick Debian (MSM8916 4G USB sticks)
# =============================================================================
#
# LED behaviour
#   RED    on while booting, off once fully booted,
#          on again during shutdown and stays on after `halt` (device stopped,
#          still powered = safe to unplug)
#   GREEN  on when the system is fully booted (multi-user.target reached)
#   BLUE   solid = connected to a Wi-Fi network, blinking = not connected
#
# Usage
#   sudo ./openstick-leds.sh install      install and enable (default pins)
#   sudo ./openstick-leds.sh uninstall    remove everything, LEDs off
#   sudo ./openstick-leds.sh status       show service state
#   sudo ./openstick-leds.sh test         blink each LED once
#
#   Override defaults with environment variables, e.g.:
#   sudo GREEN=71 RED=72 BLUE=73 WIFI_IFACE=wlan0 ./openstick-leds.sh install
#
# Requires: gpiod (libgpiod v2 tools)  ->  sudo apt install gpiod
# =============================================================================
set -euo pipefail

CHIP="${CHIP:-gpiochip0}"
GREEN="${GREEN:-71}"
RED="${RED:-72}"
BLUE="${BLUE:-73}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"

CONF=/etc/default/openstick-leds
WIFI_SCRIPT=/usr/local/bin/openstick-led-wifi
UNIT_DIR=/etc/systemd/system
UNITS=(openstick-led-early.service openstick-led-wifi.service openstick-led-booted.service)

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ":: $*"; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 $*)"; }

set_pins() { gpioset -c "$CHIP" -t 0 "$@"; }

preflight() {
    command -v gpioset >/dev/null || die "gpioset not found. Install it: sudo apt install gpiod"
    gpioset --version 2>/dev/null | grep -q 'v2\.' \
        || die "libgpiod v2 required (gpioset --version shows $(gpioset --version 2>&1 | head -1))"
    [ -e "/dev/$CHIP" ] || die "/dev/$CHIP does not exist"
    for p in "$GREEN" "$RED" "$BLUE"; do
        [[ "$p" =~ ^[0-9]+$ ]] || die "pin '$p' is not a number"
        line=$(gpioinfo -c "$CHIP" "$p" 2>/dev/null || true)
        [ -n "$line" ] || die "line $p not found on $CHIP"
        if echo "$line" | grep -q 'consumer=' \
           && ! echo "$line" | grep -q 'consumer="\?gpioset'; then
            die "line $p is already claimed by the kernel: $line
       Pick another pin or free it from the devicetree first."
        fi
    done
}

check_persistence() {
    # This setup sets a pin and exits. Verify the pin keeps its value afterwards.
    # Read the state from debugfs; gpioget would switch the pin to input.
    local dbg=/sys/kernel/debug/gpio
    mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
    if [ ! -r "$dbg" ]; then
        info "debugfs not available, skipping pin persistence check"; return 0
    fi
    set_pins "$RED=1"
    sleep 0.3
    if grep -E "gpio${RED}[[:space:]]*:" "$dbg" | grep -q 'out high'; then
        set_pins "$RED=0"; return 0
    fi
    set_pins "$RED=0"
    echo "WARNING: GPIO $RED did not keep its state after gpioset exited."
    echo "         This set-and-exit method may not work on your board."
}

write_files() {
    cat >"$CONF" <<EOF
# openstick-leds configuration (written by openstick-leds.sh)
CHIP=$CHIP
GREEN=$GREEN
RED=$RED
BLUE=$BLUE
WIFI_IFACE=$WIFI_IFACE
EOF

    cat >"$WIFI_SCRIPT" <<'EOF'
#!/bin/bash
# Blue LED: solid when connected to Wi-Fi, blinking when not.
. /etc/default/openstick-leds
blue() { /usr/bin/gpioset -c "$CHIP" -t 0 "$BLUE=$1"; }
trap 'blue 0; exit 0' TERM INT

connected() {
    if command -v iw >/dev/null; then
        iw dev "$WIFI_IFACE" link 2>/dev/null | grep -q '^Connected to'
    elif command -v nmcli >/dev/null; then
        nmcli -t -f GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | grep -q '(connected)'
    else
        [ "$(cat /sys/class/net/"$WIFI_IFACE"/operstate 2>/dev/null)" = up ]
    fi
}

while true; do
    if connected; then
        blue 1; sleep 2 & wait $!
    else
        blue 1; sleep 0.5 & wait $!
        blue 0; sleep 0.5 & wait $!
    fi
done
EOF
    chmod 755 "$WIFI_SCRIPT"

    cat >"$UNIT_DIR/openstick-led-early.service" <<EOF
[Unit]
Description=OpenStick LED: red while booting
DefaultDependencies=no
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/bin/gpioset -c $CHIP -t 0 $RED=1 $GREEN=0 $BLUE=0

[Install]
WantedBy=sysinit.target
EOF

    cat >"$UNIT_DIR/openstick-led-wifi.service" <<EOF
[Unit]
Description=OpenStick LED: blue Wi-Fi status
After=NetworkManager.service

[Service]
ExecStart=$WIFI_SCRIPT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    cat >"$UNIT_DIR/openstick-led-booted.service" <<EOF
[Unit]
Description=OpenStick LED: green when booted, red on shutdown/halt
After=multi-user.target openstick-led-wifi.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/gpioset -c $CHIP -t 0 $RED=0 $GREEN=1
ExecStop=/usr/bin/gpioset -c $CHIP -t 0 $GREEN=0 $RED=1

[Install]
WantedBy=multi-user.target
EOF
}

do_install() {
    need_root install
    preflight
    check_persistence
    info "Pins: green=$GREEN red=$RED blue=$BLUE on $CHIP, Wi-Fi interface $WIFI_IFACE"
    write_files
    systemctl daemon-reload
    systemctl enable "${UNITS[@]}" >/dev/null
    systemctl start openstick-led-wifi.service openstick-led-booted.service
    info "Installed. Green should be on now, blue solid or blinking."
    info "Use 'sudo systemctl halt' to shut down (red stays on = safe to unplug)."
}

do_uninstall() {
    need_root uninstall
    systemctl disable --now "${UNITS[@]}" 2>/dev/null || true
    for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; done
    # shellcheck disable=SC1090
    [ -f "$CONF" ] && . "$CONF"
    rm -f "$WIFI_SCRIPT" "$CONF"
    systemctl daemon-reload
    set_pins "$GREEN=0" "$RED=0" "$BLUE=0" 2>/dev/null || true
    info "Uninstalled, LEDs off."
}

do_status() {
    [ -f "$CONF" ] && { echo "Config ($CONF):"; sed -n 's/^\([A-Z_]*=.*\)/  \1/p' "$CONF"; }
    for u in "${UNITS[@]}"; do
        printf '  %-32s %s / %s\n' "$u" \
            "$(systemctl is-enabled "$u" 2>/dev/null || true)" \
            "$(systemctl is-active "$u" 2>/dev/null || true)"
    done
}

do_test() {
    need_root test
    preflight
    for c in "GREEN:$GREEN" "RED:$RED" "BLUE:$BLUE"; do
        info "${c%%:*} (GPIO ${c#*:})"
        set_pins "${c#*:}=1"; sleep 1; set_pins "${c#*:}=0"; sleep 0.3
    done
}

case "${1:-}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    test)      do_test ;;
    *) sed -n '/^# LED behaviour/,/^# Requires/s/^# \{0,1\}//p' "$0"; exit 1 ;;
esac
