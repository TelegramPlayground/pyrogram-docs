#!/bin/bash

# Define your input source and output compilation target
INPUT_FILE="input.tsv"
OUTPUT_FILE="output.tsv"

# Optional: Set this if you hit GitHub API rate limits
# GITHUB_TOKEN="your_personal_access_token_here"

# 2. Write the TSV Header Row to the output file
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "Fork Name" "Layer" "Compatible with BOT API" "Download / Upload Speed" \
    "Python Version" "TgCrypto Python Version" "Stars" "Forks" "Used By" > "$OUTPUT_FILE"

# 3. Read the TSV file line by line
while IFS=$'\t' read -r slug url name tsv_layer bot speed py tg suffix; do
    
    # Skip empty lines or lines starting with a comment (#)
    if [ -z "$slug" ] || [[ "$slug" == \#* ]]; then continue; fi

    echo "Processing $slug..."
    
    # --- 1. DYNAMIC LAYER FETCHING ---
    
    # Extract the branch name from the URL (e.g., from .../tree/dev/ to "dev")
    branch=$(echo "$url" | awk -F'/tree/' '{print $2}' | cut -d'/' -f1)
    final_layer="$tsv_layer" # Fallback to TSV layer by default
    
    if [ -n "$branch" ]; then
        TL_URL="https://raw.githubusercontent.com/${slug}/${branch}/compiler/api/source/main_api.tl"
        
        # Fetch the file, find the LAYER line, get the 3rd word, and strip carriage returns
        fetched_layer=$(curl -s -f "$TL_URL" | grep "// LAYER" | tail -n 1 | awk '{print $3}' | tr -d '\r')
        
        # Validate that we actually got a number
        if [[ "$fetched_layer" =~ ^[0-9]+$ ]]; then
            final_layer="$fetched_layer"
            echo "  -> Found Layer: $final_layer"
        else
            echo "  -> Failed to parse layer from .tl file. Falling back to TSV data ($final_layer)."
        fi
    else
        echo "  -> Could not extract branch from URL. Falling back to TSV data ($final_layer)."
    fi

    # --- 2. GITHUB STATS FETCHING ---
    
    CURL_CMD="curl -s -f -H \"Accept: application/vnd.github.v3+json\""
    if [ -n "$GITHUB_TOKEN" ]; then
        CURL_CMD="$CURL_CMD -H \"Authorization: token $GITHUB_TOKEN\""
    fi
    
    # Execute the request
    response=$(eval "$CURL_CMD https://api.github.com/repos/$slug")

    # Extract data with jq if successful
    if [ $? -eq 0 ]; then
        stars=$(echo "$response" | jq '.stargazers_count')
        forks=$(echo "$response" | jq '.forks_count')
        # Map the GitHub network_count to your used_by variable
        used_by=$(echo "$response" | jq '.network_count')
    else
        echo "  -> Failed to fetch stats. Defaulting to 0."
        stars=0
        forks=0
        used_by=0
    fi

    # Format the Sphinx link, attaching the suffix if it exists
    link="\`$name <$url>\`_$suffix"
    
    # Append the formatted TSV row directly to the output file
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$link" "$final_layer" "$bot" "$speed" "$py" "$tg" "$stars" "$forks" "$used_by" >> "$OUTPUT_FILE"

done < "$INPUT_FILE"

echo "Update complete! Compiled TSV written to $OUTPUT_FILE"
