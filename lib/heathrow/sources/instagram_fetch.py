#!/usr/bin/env python3
"""Fetch Instagram DM inbox via Firefox Marionette.

Connects to Firefox Marionette on port 2828, finds the Instagram tab,
and executes a fetch() call to get inbox data. Outputs JSON to stdout.
Debug info goes to stderr.
"""

import json
import sys

def main():
    client = None
    try:
        from marionette_driver.marionette import Marionette

        print("Connecting to Marionette...", file=sys.stderr)
        client = Marionette(host='127.0.0.1', port=2828)
        client.start_session()

        # Find the Instagram tab
        ig_found = False
        for h in client.window_handles:
            client.switch_to_window(h)
            url = client.get_url()
            if 'instagram.com' in url:
                ig_found = True
                print(f"Found Instagram tab: {url}", file=sys.stderr)
                break

        if not ig_found:
            print("No Instagram tab found in Firefox", file=sys.stderr)
            json.dump({"error": "No Instagram tab found in Firefox", "inbox": {"threads": []}}, sys.stdout)
            return

        # Fetch inbox data via the Instagram private API
        js = (
            'let resolve = arguments[arguments.length - 1];'
            'fetch("/api/v1/direct_v2/inbox/?limit=20&thread_message_limit=10", {'
            '  credentials: "include",'
            '  headers: {"x-ig-app-id": "936619743392459", "x-requested-with": "XMLHttpRequest"}'
            '})'
            '.then(function(r) { return r.text(); })'
            '.then(function(text) { resolve(text); })'
            '.catch(function(e) { resolve("ERROR: " + e.message); });'
        )

        print("Fetching inbox...", file=sys.stderr)
        result = client.execute_async_script(js, script_timeout=15000)

        if result is None:
            print("Marionette returned None", file=sys.stderr)
            json.dump({"error": "No response from Instagram API", "inbox": {"threads": []}}, sys.stdout)
            return

        if isinstance(result, str) and result.startswith("ERROR:"):
            print(f"Fetch error: {result}", file=sys.stderr)
            json.dump({"error": result, "inbox": {"threads": []}}, sys.stdout)
            return

        # Parse the JSON response
        try:
            data = json.loads(result)
        except json.JSONDecodeError as e:
            print(f"JSON parse error: {e}", file=sys.stderr)
            print(f"Raw response (first 500 chars): {result[:500]}", file=sys.stderr)
            json.dump({"error": f"JSON parse error: {e}", "inbox": {"threads": []}}, sys.stdout)
            return

        # Check for API errors
        status = data.get("status", "")
        if status != "ok":
            msg = data.get("message", f"API returned status: {status}")
            if "login" in msg.lower() or "login" in str(data).lower():
                msg = "Instagram login required. Please log in to Instagram in Firefox."
            print(f"API error: {msg}", file=sys.stderr)
            json.dump({"error": msg, "inbox": {"threads": []}}, sys.stdout)
            return

        # Success: output the full response
        threads = data.get("inbox", {}).get("threads", [])
        print(f"Fetched {len(threads)} threads", file=sys.stderr)
        json.dump(data, sys.stdout)

    except ImportError:
        json.dump({"error": "marionette_driver not installed (pip install marionette-driver)", "inbox": {"threads": []}}, sys.stdout)
    except ConnectionRefusedError:
        json.dump({"error": "Cannot connect to Firefox Marionette on port 2828. Start Firefox with --marionette.", "inbox": {"threads": []}}, sys.stdout)
    except Exception as e:
        print(f"Unexpected error: {type(e).__name__}: {e}", file=sys.stderr)
        json.dump({"error": f"{type(e).__name__}: {e}", "inbox": {"threads": []}}, sys.stdout)
    finally:
        if client is not None:
            try:
                client.delete_session()
                print("Session closed.", file=sys.stderr)
            except Exception:
                pass

if __name__ == '__main__':
    main()
