#!/usr/bin/python3 -I
"""Serve the web UI with waitress on LISTEN_PORT (default 8080)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import waitress  # noqa: E402

from app import app_password, create_app  # noqa: E402


def main():
    os.umask(0o077)
    app = create_app()
    if not os.environ.get("APP_PASSWORD"):
        app_password()   # create it now, so it can be read before the first login
        print("[web] No APP_PASSWORD set: the app password is in /config/app-password "
              "(docker exec mega-backup cat /config/app-password).", flush=True)
    port = int(os.environ.get("LISTEN_PORT", "8080"))
    print(f"[web] Listening on port {port}.", flush=True)
    waitress.serve(app, host="0.0.0.0", port=port, threads=4, ident="",
                   clear_untrusted_proxy_headers=True)


if __name__ == "__main__":
    main()
