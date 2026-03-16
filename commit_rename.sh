#!/bin/bash
cd /home/geir/Claude/Heathrow

git add -A
git commit -m "$(cat <<'EOF'
chore: rename project from Chitt to Heathrow

- Renamed directory Chitt → Heathrow
- Renamed bin/chitt → bin/heathrow
- Renamed bin/chittd → bin/heathrowd
- Renamed lib/chitt.rb → lib/heathrow.rb
- Renamed lib/chitt/ → lib/heathrow/
- Renamed chitt.gemspec → heathrow.gemspec
- Renamed chitt.db → heathrow.db
- Renamed chittd.service → heathrowd.service
- Updated all module names: Chitt → Heathrow
- Updated all require statements
- Updated all constants: CHITT_* → HEATHROW_*
- Updated all documentation
- Added screen clear on startup to prevent artifacts

84 files updated across codebase.
Airport metaphor: Heathrow - Where all your messages connect.
EOF
)"

echo "Commit complete!"
git log -1 --oneline
