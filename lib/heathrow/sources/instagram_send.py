#!/usr/bin/env python3
"""Send an Instagram DM by opening the thread in the user's browser.

Usage: instagram_send.py <thread_id> <message>
Outputs JSON: { "success": true/false, "message": "..." }

Since Instagram blocks all non-browser API access, this opens the DM thread
in the user's real browser with the message pre-copied to clipboard.
"""

import json
import os
import subprocess
import sys


def output(success, message):
    print(json.dumps({"success": success, "message": message}))
    sys.exit(0)


def main():
    if len(sys.argv) < 3:
        output(False, "Usage: instagram_send.py <thread_id> <message>")

    thread_id = sys.argv[1]
    message = sys.argv[2]

    if not thread_id or not message.strip():
        output(False, "Thread ID and message are required")

    url = f"https://www.instagram.com/direct/t/{thread_id}/"

    # Copy message to clipboard
    try:
        proc = subprocess.Popen(
            ["xclip", "-selection", "clipboard"],
            stdin=subprocess.PIPE,
        )
        proc.communicate(message.strip().encode())
    except Exception:
        pass

    # Open in browser
    subprocess.Popen(
        ["xdg-open", url],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    output(True, "Opened Instagram DM in browser. Message copied to clipboard (Ctrl+V to paste).")


if __name__ == "__main__":
    main()
