#!/bin/bash
# Heathrow Project Rename Script

cd /home/geir/Claude/Heathrow

echo "Renaming files from Chitt to Heathrow..."

# Rename bin files
[ -f bin/chittd ] && mv bin/chittd bin/heathrowd && echo "✓ bin/chittd → bin/heathrowd"

# Rename lib files
[ -f lib/chitt.rb ] && mv lib/chitt.rb lib/heathrow.rb && echo "✓ lib/chitt.rb → lib/heathrow.rb"
[ -d lib/chitt ] && mv lib/chitt lib/heathrow && echo "✓ lib/chitt/ → lib/heathrow/"

# Rename gemspec
[ -f chitt.gemspec ] && mv chitt.gemspec heathrow.gemspec && echo "✓ chitt.gemspec → heathrow.gemspec"

# Rename database
[ -f chitt.db ] && mv chitt.db heathrow.db && echo "✓ chitt.db → heathrow.db"

# Rename service file
[ -f chittd.service ] && mv chittd.service heathrowd.service && echo "✓ chittd.service → heathrowd.service"

echo ""
echo "File renames complete!"
echo ""
echo "Now run: bash update_references.sh"
