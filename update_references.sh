#!/bin/bash
# Update all code references from Chitt to Heathrow

cd /home/geir/Claude/Heathrow

echo "Updating code references from Chitt to Heathrow..."
echo ""

# Function to replace text in a file
replace_in_file() {
    local file="$1"
    if [ -f "$file" ]; then
        # Create backup
        cp "$file" "$file.bak"

        # Replace Chitt with Heathrow (preserving case)
        sed -i 's/Chitt/Heathrow/g' "$file"
        sed -i 's/chitt/heathrow/g' "$file"
        sed -i 's/CHITT/HEATHROW/g' "$file"

        # Check if file changed
        if ! cmp -s "$file" "$file.bak"; then
            echo "✓ Updated: $file"
            rm "$file.bak"
            return 0
        else
            rm "$file.bak"
            return 1
        fi
    fi
}

# Update Ruby files
echo "Updating Ruby files..."
find lib -name "*.rb" -type f | while read file; do
    replace_in_file "$file"
done

# Update bin files
echo ""
echo "Updating executables..."
replace_in_file "bin/heathrow"
replace_in_file "bin/heathrowd"

# Update gemspec
echo ""
echo "Updating gemspec..."
replace_in_file "heathrow.gemspec"

# Update service file
echo ""
echo "Updating service file..."
replace_in_file "heathrowd.service"

# Update README
echo ""
echo "Updating documentation..."
replace_in_file "README.md"

# Update all test files
echo ""
echo "Updating test files..."
find . -name "test_*.rb" -o -name "setup_*.rb" | while read file; do
    replace_in_file "$file"
done

# Update installation script
replace_in_file "install.sh"

# Update any markdown files in docs
if [ -d "docs" ]; then
    find docs -name "*.md" -type f | while read file; do
        replace_in_file "$file"
    done
fi

echo ""
echo "============================================"
echo "Reference update complete!"
echo ""
echo "Next steps:"
echo "1. Review changes: git diff"
echo "2. Test the application: ./bin/heathrow"
echo "3. Commit changes: git add -A && git commit -m 'chore: rename project from Chitt to Heathrow'"
echo "============================================"
