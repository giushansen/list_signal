#!/usr/bin/env bash
set -e
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
cd "/Users/guillaumefourret/Projects/list_signal/marketing/charts/out"
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --default-background-color=FFFFFFFF --window-size=910,820 --screenshot="/Users/guillaumefourret/Projects/list_signal/marketing/charts/out/chart1_tech.png" "file:///Users/guillaumefourret/Projects/list_signal/marketing/charts/out/chart1_tech.html" >/dev/null 2>&1 && echo "  chart1_tech.png"
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --default-background-color=FFFFFFFF --window-size=910,582 --screenshot="/Users/guillaumefourret/Projects/list_signal/marketing/charts/out/chart2_apps.png" "file:///Users/guillaumefourret/Projects/list_signal/marketing/charts/out/chart2_apps.html" >/dev/null 2>&1 && echo "  chart2_apps.png"
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --default-background-color=FFFFFFFF --window-size=910,684 --screenshot="/Users/guillaumefourret/Projects/list_signal/marketing/charts/out/chart3_email.png" "file:///Users/guillaumefourret/Projects/list_signal/marketing/charts/out/chart3_email.html" >/dev/null 2>&1 && echo "  chart3_email.png"
