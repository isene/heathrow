#!/bin/bash
echo "Testing chitt output..."
timeout 0.5 ruby bin/chitt 2>&1 | cat -A | head -20