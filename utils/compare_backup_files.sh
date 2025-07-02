#!/bin/bash

DIR1="$1"
DIR2="$2"

FILES=("variables_backup.json" "connections_backup.json" "pools_backup.json")

for file in "${FILES[@]}"; do
    echo "🔍 Comparing $file"
    
    jq -S . "${DIR1}/${file}" > "/tmp/${file}.1.sorted"
    jq -S . "${DIR2}/${file}" > "/tmp/${file}.2.sorted"

    if diff -q "/tmp/${file}.1.sorted" "/tmp/${file}.2.sorted" > /dev/null; then
        echo "✅ No difference in $file"
    else
        echo "❌ Difference found in $file"a
        diff "/tmp/${file}.1.sorted" "/tmp/${file}.2.sorted"
    fi
    echo "---------------------------------"
done