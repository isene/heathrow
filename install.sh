#!/bin/bash

echo "Installing Heathrow dependencies..."
echo ""
echo "This script will install the required Ruby gems."
echo "You may need to use 'sudo' if installing system-wide."
echo ""

# Core dependencies
echo "Installing core dependencies..."
gem install rcurses
gem install sqlite3

echo ""
echo "Installation complete!"
echo ""
echo "To test Heathrow:"
echo "  ruby test_heathrow.rb"
echo ""
echo "To run Heathrow:"
echo "  ./bin/heathrow"
echo ""
echo "To set up test data:"
echo "  ruby setup_test_data.rb"