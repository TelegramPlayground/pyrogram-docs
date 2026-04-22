#!/bin/bash

# Define your input source and output compilation target
INPUT_FILE="input.tsv"
OUTPUT_FILE="output.tsv"

# Optional: Set this if you hit GitHub API rate limits
# Highly recommended to use a token now, as we are making up to 5 API calls per repository (unauthenticated is 60/hr)
# GITHUB_TOKEN="your_personal_access_token_here"

# 2. Write the TSV Header Row to the output file
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "Fork Name" "Layer" "Compatible with BOT API" "Download / Upload Speed" \
    "Python Version" "TgCrypto Python Version" "Stars" "Forks" "Used By" > "$OUTPUT_FILE"

# 3. Read the TSV file line by line
while IFS=$'\t' read -r slug url name tsv_layer bot speed tsv_py tg suffix; do
    
    # Skip empty lines or lines starting with a comment (#)
    if [ -z "$slug" ] || [[ "$slug" == \#* ]]; then continue; fi

    echo "Processing $slug..."
    final_layer="$tsv_layer" # Fallback to TSV layer by default
    final_py="$tsv_py"       # Fallback to TSV Python version by default
    
    # Build base curl command for GitHub API
    CURL_CMD="curl -s -f -H \"Accept: application/vnd.github.v3+json\""
    if [ -n "$GITHUB_TOKEN" ]; then
        CURL_CMD="$CURL_CMD -H \"Authorization: token $GITHUB_TOKEN\""
    fi

    # --- 1. DETERMINE THE BEST REFERENCE (RELEASE TAG, NORMAL TAG, OR BRANCH) ---
    
    target_ref=""
    
    # Attempt to fetch the latest release tag
    # We remove the '-f' flag here temporarily so curl doesn't crash the loop on a 404 (no releases)
    CURL_NO_FAIL="${CURL_CMD/-f/}" 
    release_response=$(eval "$CURL_NO_FAIL https://api.github.com/repos/$slug/releases/latest")
    tag_name=$(echo "$release_response" | jq -r '.tag_name // empty')
    
    if [ -n "$tag_name" ] && [ "$tag_name" != "null" ]; then
        target_ref="$tag_name"
        echo "  -> Found latest release: $target_ref"
    else
        # Fallback 1: Attempt to fetch the latest normal tag (if no formal release exists)
        tags_response=$(eval "$CURL_NO_FAIL https://api.github.com/repos/$slug/tags")
        # We check if it's an array to avoid jq errors if GitHub returns an error object, then grab the first tag
        latest_tag=$(echo "$tags_response" | jq -r 'if type=="array" then .[0].name // empty else empty end')
        
        if [ -n "$latest_tag" ] && [ "$latest_tag" != "null" ]; then
            target_ref="$latest_tag"
            echo "  -> No release found. Using latest tag: $target_ref"
        else
            # Fallback 2: Extract the branch name from the URL (e.g., from .../tree/dev/ to "dev")
            target_ref=$(echo "$url" | awk -F'/tree/' '{print $2}' | cut -d'/' -f1)
            if [ -n "$target_ref" ]; then
                echo "  -> No release or tag found. Using branch from URL: $target_ref"
            fi
        fi
    fi

    # --- 2. DYNAMIC LAYER FETCHING ---
    
    if [ -n "$target_ref" ]; then
        # Construct the raw GitHub URL for the main_api.tl file using raw.githubusercontent.com
        TL_URL="https://raw.githubusercontent.com/${slug}/${target_ref}/compiler/api/source/main_api.tl"
        
        # Fetch the file, find the LAYER line, get the 3rd word, and strip carriage returns
        fetched_layer=$(curl -s -f "$TL_URL" | grep "// LAYER" | tail -n 1 | awk '{print $3}' | tr -d '\r')
        
        # Validate that we actually got a number
        if [[ "$fetched_layer" =~ ^[0-9]+$ ]]; then
            final_layer="$fetched_layer"
            echo "  -> Successfully extracted Layer: $final_layer"
        else
            echo "  -> Failed to parse layer from .tl file. Falling back to TSV data ($final_layer)."
        fi
    else
        echo "  -> Could not determine a release, tag, or branch. Falling back to TSV data ($final_layer)."
    fi

    # --- 3. DYNAMIC PYTHON VERSION FETCHING ---
    
    if [ -n "$target_ref" ]; then
        PYPROJECT_URL="https://raw.githubusercontent.com/${slug}/${target_ref}/pyproject.toml"
        SETUP_URL="https://raw.githubusercontent.com/${slug}/${target_ref}/setup.py"

        # Fetch the configuration file (Try pyproject.toml first, fallback to setup.py)
        config_content=$(curl -s -f "$PYPROJECT_URL")
        if [ -z "$config_content" ]; then
            config_content=$(curl -s -f "$SETUP_URL")
        fi

        if [ -n "$config_content" ]; then
            # 1. Extract the minimum required version (e.g., ">=3.9" or "~=3.7")
            min_py=$(echo "$config_content" | grep -E "requires-python|python_requires" | head -n 1 | awk -F'["'\'']' '{print $2}')
            
            # 2. Extract the maximum tested version from the classifiers array
            # - Matches "Programming Language :: Python :: 3.X"
            # - Uses sed to isolate just the "3.X" portion
            # - Strips any lingering quotes or commas
            # - Uses version sort (-V) to order them numerically, and grabs the highest one
            max_py=$(echo "$config_content" | grep "Programming Language :: Python :: 3\." | sed 's/.*Python :: \([0-9\.]*\).*/\1/' | tr -d " ',\"" | sort -V | tail -n 1)

            # Combine them if both successfully extracted
            if [ -n "$min_py" ] && [ -n "$max_py" ]; then
                final_py="${min_py},<=${max_py}"
                echo "  -> Successfully extracted Python version matrix: $final_py"
            elif [ -n "$min_py" ]; then
                final_py="$min_py"
                echo "  -> Extracted minimum Python version only: $final_py"
            else
                echo "  -> Failed to parse Python versions from config files. Falling back to TSV data ($final_py)."
            fi
        else
            echo "  -> Could not fetch pyproject.toml or setup.py. Falling back to TSV data ($final_py)."
        fi
    fi

    # --- 4. GITHUB STATS FETCHING ---
    
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
    
    # Append the formatted TSV row directly to the output file using printf for precise tab insertion
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$link" "$final_layer" "$bot" "$speed" "$final_py" "$tg" "$stars" "$forks" "$used_by" >> "$OUTPUT_FILE"

done < "$INPUT_FILE"

echo "Update complete! Compiled TSV written to $OUTPUT_FILE"
