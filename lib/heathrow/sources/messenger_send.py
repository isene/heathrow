#!/usr/bin/env python3
"""Send a Messenger DM via Firefox Marionette.

Connects to Firefox, finds the Messenger tab, navigates to the thread,
types the message and presses Enter.

Usage: messenger_send.py <thread_id> <message>
Outputs JSON: { "success": true/false, "message": "..." }
"""

import json
import sys
import time


def output(success, message):
    print(json.dumps({"success": success, "message": message}))
    sys.exit(0)


def main():
    if len(sys.argv) < 3:
        output(False, "Usage: messenger_send.py <thread_id> <message>")

    thread_id = sys.argv[1]
    message = sys.argv[2].strip()

    if not thread_id or not message:
        output(False, "Thread ID and message are required")

    try:
        from marionette_driver.marionette import Marionette
        from marionette_driver.keys import Keys
    except ImportError:
        output(False, "marionette_driver not installed")

    client = None
    try:
        client = Marionette(host='127.0.0.1', port=2828)
        client.start_session()

        # Find Messenger tab
        msng_handle = None
        for h in client.window_handles:
            client.switch_to_window(h)
            if 'messenger.com' in client.get_url():
                msng_handle = h
                break

        if not msng_handle:
            output(False, "No Messenger tab found in Firefox")

        # Navigate to thread
        client.navigate(f"https://www.messenger.com/t/{thread_id}")

        # Wait for message input to appear
        for _ in range(20):
            found = client.execute_script("""
                var el = document.querySelector('[role="textbox"][contenteditable="true"]');
                return el ? true : false;
            """)
            if found:
                break
            time.sleep(0.5)
        else:
            output(False, "Could not find message input")

        # Focus the input and set text via DOM, then press Enter
        from marionette_driver.by import By
        client.execute_script("""
            var el = document.querySelector('[role="textbox"][contenteditable="true"]');
            el.focus();
        """)
        time.sleep(0.2)

        # Use clipboard to paste the message (avoids character interpretation issues)
        import subprocess
        proc = subprocess.Popen(["xclip", "-selection", "clipboard"], stdin=subprocess.PIPE)
        proc.communicate(message.encode())

        el = client.find_element(By.CSS_SELECTOR, '[role="textbox"][contenteditable="true"]')
        # Ctrl+V to paste, then Enter to send
        el.send_keys(Keys.CONTROL + "v")
        time.sleep(0.3)
        el.send_keys(Keys.ENTER)

        output(True, "Message sent via Messenger")

    except Exception as e:
        output(False, f"Messenger send error: {e}")
    finally:
        if client:
            try:
                client.delete_session()
            except Exception:
                pass


if __name__ == '__main__':
    main()
