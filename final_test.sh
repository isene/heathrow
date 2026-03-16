#!/bin/bash

echo "Running Chitt and capturing initial screen..."
(sleep 1; echo q) | script -q -c "ruby bin/chitt" /tmp/chitt_output.txt

echo "Extracting visible text..."
cat /tmp/chitt_output.txt | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -E "Chitt|Messages|Aug|quit" | head -10

echo ""
echo "Checking for key elements:"
if grep -q "Chitt" /tmp/chitt_output.txt; then
  echo "✓ Top bar rendered (contains 'Chitt')"
else
  echo "✗ Top bar NOT rendered"
fi

if grep -q "Aug\|21 Aug" /tmp/chitt_output.txt; then
  echo "✓ Messages rendered in left pane"
else
  echo "✗ Messages NOT rendered"
fi

if grep -q "\[.*\]" /tmp/chitt_output.txt; then
  echo "✓ Message count rendered"
else
  echo "✗ Message count NOT rendered"
fi