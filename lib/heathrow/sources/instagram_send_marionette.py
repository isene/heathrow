#!/usr/bin/env python3
"""Send an Instagram DM via Firefox Marionette.

Connects to Firefox, finds the Instagram tab, navigates to the DM thread,
types the message and presses Enter.

Usage: instagram_send_marionette.py <thread_id> <message>
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
        output(False, "Usage: instagram_send_marionette.py <thread_id> <message>")

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

        # Find Instagram tab
        ig_handle = None
        for h in client.window_handles:
            client.switch_to_window(h)
            if 'instagram.com' in client.get_url():
                ig_handle = h
                break

        if not ig_handle:
            output(False, "No Instagram tab found in Firefox")

        # Navigate to DM thread
        client.navigate(f"https://www.instagram.com/direct/t/{thread_id}/")

        # Wait for message input to appear
        for _ in range(20):
            found = client.execute_script("""
                var el = document.querySelector('textarea[placeholder]')
                      || document.querySelector('[role="textbox"][contenteditable="true"]');
                return el ? el.tagName : null;
            """)
            if found:
                break
            time.sleep(0.5)
        else:
            output(False, "Could not find message input")

        # Find and interact with the input
        from marionette_driver.by import By
        time.sleep(0.3)

        # Try textarea first, then contenteditable
        try:
            el = client.find_element(By.CSS_SELECTOR, 'textarea[placeholder]')
        except Exception:
            el = client.find_element(By.CSS_SELECTOR, '[role="textbox"][contenteditable="true"]')

        el.click()
        time.sleep(0.2)

        # Use clipboard to paste (avoids character interpretation issues with <, > etc.)
        import subprocess
        proc = subprocess.Popen(["xclip", "-selection", "clipboard"], stdin=subprocess.PIPE)
        proc.communicate(message.encode())

        el.send_keys(Keys.CONTROL + "v")
        time.sleep(0.3)
        el.send_keys(Keys.ENTER)

        output(True, "Message sent via Instagram")

    except Exception as e:
        output(False, f"Instagram send error: {e}")
    finally:
        if client:
            try:
                client.delete_session()
            except Exception:
                pass


if __name__ == '__main__':
    main()
