#!/usr/bin/env python3
"""Render the provisioned Grafana dashboard for the timeline run to a PNG (headless Chromium).

Requires:  pip install playwright && playwright install --with-deps chromium
Writes     figures/fig10_grafana_dashboard.png
"""
import os

import pandas as pd
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
GRAFANA = os.environ.get("GRAFANA_URL", "http://127.0.0.1:3000")


def main():
    ph = pd.read_csv(os.path.join(ROOT, "results", "timeline", "phases.csv"))
    t_from = int((ph.start_epoch.min() - 10) * 1000)
    t_to = int((ph.end_epoch.max() + 10) * 1000)
    url = f"{GRAFANA}/d/scenario-a/?orgId=1&from={t_from}&to={t_to}&kiosk&theme=light&refresh="
    out = os.path.join(ROOT, "figures", "fig10_grafana_dashboard.png")
    with sync_playwright() as p:
        b = p.chromium.launch()
        # Grafana scrolls inside its own container, so the viewport must fit the whole dashboard
        page = b.new_page(viewport={"width": 1600, "height": 1220}, device_scale_factor=1)
        page.goto(url, wait_until="networkidle")
        page.wait_for_timeout(6000)
        page.screenshot(path=out, full_page=True)
        b.close()
    print("saved", out)


if __name__ == "__main__":
    main()
