#!/usr/bin/env python3
"""A tiny stand-in for the open-meteo API, for the test suites.

Serves the two endpoints the weather plugin uses, with fixed data, so the tests
never depend on the network or on today's real forecast:

    python3 test/fake-weather-server.py --port 0 --print-port
    # → prints the chosen port; baseUrl is http://127.0.0.1:<port>/forecast

    GET /forecast?...   → current + hourly + daily, canned
    GET /geocode?name=… → one result, canned

Anything else returns 404, so a wrong URL fails loudly instead of hanging.
"""
from __future__ import annotations

import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse
from datetime import datetime, timedelta

# The values the tests assert on.
CURRENT_TEMPERATURE = 21.5
CURRENT_CODE = 2                      # partly cloudy
DAILY_HIGH = 27.0
DAILY_LOW = 14.0


def forecast_payload() -> dict:
    now = datetime.now().replace(minute=0, second=0, microsecond=0)
    hours = [(now + timedelta(hours=offset)) for offset in range(24)]
    days = [(now + timedelta(days=offset)) for offset in range(5)]
    return {
        "latitude": 1.0,
        "longitude": 2.0,
        "timezone": "Etc/UTC",
        "current": {
            "time": now.strftime("%Y-%m-%dT%H:%M"),
            "temperature_2m": CURRENT_TEMPERATURE,
            "relative_humidity_2m": 63.0,
            "apparent_temperature": 20.0,
            "is_day": 1,
            "weather_code": CURRENT_CODE,
            "wind_speed_10m": 7.5,
        },
        "hourly": {
            "time": [hour.strftime("%Y-%m-%dT%H:%M") for hour in hours],
            "temperature_2m": [CURRENT_TEMPERATURE + (index % 5) for index in range(24)],
            "weather_code": [CURRENT_CODE] * 24,
        },
        "daily": {
            "time": [day.strftime("%Y-%m-%d") for day in days],
            "weather_code": [3, 61, 0, 2, 71],
            "temperature_2m_max": [DAILY_HIGH] * 5,
            "temperature_2m_min": [DAILY_LOW] * 5,
        },
    }


def geocode_payload() -> dict:
    return {
        "results": [
            {
                "name": "Testville",
                "latitude": 1.0,
                "longitude": 2.0,
                "country_code": "TV",
                "timezone": "Etc/UTC",
            }
        ]
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        parsed = urlparse(self.path)
        if parsed.path.startswith("/forecast"):
            body = forecast_payload()
        elif parsed.path.startswith("/geocode"):
            body = geocode_payload()
            name = parse_qs(parsed.query).get("name", [""])[0]
            language = parse_qs(parsed.query).get("language", ["en"])[0]
            if "-" in language:
                body = {"results": []}  # Provider accepts ISO language, not locale.
            elif name:
                localized = {"Chengdu": "成都", "Tokyo": "东京", "Shanghai": "上海"}
                body["results"][0]["name"] = localized.get(name, name) if language == "zh" else name
        elif parsed.path.startswith("/locate"):
            body = {"latitude": 1.0, "longitude": 2.0, "city": "Testville", "country_code": "TV"}
        else:
            self.send_error(404, "unknown path")
            return
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *args) -> None:  # keep the test output clean
        pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--print-port", action="store_true")
    args = parser.parse_args()

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    port = server.server_address[1]
    if args.print_port:
        print(port, flush=True)
    else:
        print(f"fake weather API on http://127.0.0.1:{port}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
