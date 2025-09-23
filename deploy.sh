#!/usr/bin/env bash

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Source configuration files
if [ -f ~/.localtailscalerc ]; then
    source ~/.localtailscalerc
fi

if [ -f ~/.localhetznerrc ]; then
    source ~/.localhetznerrc
fi

# ============================================================================
# COMMON UTILITY FUNCTIONS (DRY)
# ============================================================================

# Function to log with timestamp
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Generic function to generate Tailscale serve configuration
generate_tailscale_serve_config() {
    local hostname="$1"
    local proxy_target="$2"
    local output_file="$3"
    local tailnet="${4:-$TAILNET}"
    
    cat > "$output_file" << EOF
{
  "TCP": {
    "443": {
      "HTTPS": true
    }
  },
  "Web": {
    "${hostname}.${tailnet}.ts.net:443": {
      "Handlers": {
        "/": {
          "Proxy": "${proxy_target}"
        }
      }
    }
  },
  "AllowFunnel": {
    "${hostname}.${tailnet}.ts.net:443": true
  }
}
EOF
}

# Generic function to validate Tailscale connection
validate_tailscale_connection() {
    local container_name="$1"
    local max_attempts=3
    local attempt=1
    
    log "${BLUE}🔍 Validating Tailscale connection for $container_name...${NC}"
    log "Container logs available for troubleshooting with: docker logs $container_name"
    
    while [ $attempt -le $max_attempts ]; do
        log "Attempt $attempt/$max_attempts: Checking Tailscale status..."
        
        # Wait for container to initialize
        sleep 10
        
        # Check if container is running
        if ! docker ps --format "table {{.Names}}" | grep -q "^$container_name$"; then
            log "${RED}❌ Tailscale container $container_name is not running${NC}"
            return 1
        fi
        
        # NEW: Direct status check for long-running containers
        log "Checking Tailscale connection status directly..."
        if docker exec "$container_name" tailscale status &>/dev/null; then
            if docker exec "$container_name" tailscale serve status 2>&1 | grep -q "proxy"; then
                log "${GREEN}✅ Tailscale connection validated via status check for $container_name${NC}"
                return 0
            else
                log "${YELLOW}⚠️  Tailscale connected but serve not configured for $container_name${NC}"
                # Continue to log pattern checking for further diagnosis
            fi
        else
            log "${YELLOW}⚠️  Tailscale status check failed, checking logs for details...${NC}"
            # Continue to existing log pattern checking
        fi
        
        # Check container logs for common error patterns
        local logs=$(docker logs "$container_name" --tail 50 2>&1)
        
        if echo "$logs" | grep -q "node not found\|404.*not found\|registration .*failed\|key rejected"; then
            log "${YELLOW}⚠️  Detected stale Tailscale state in $container_name${NC}"
            log "Error details from logs:"
            echo "$logs" | grep -E "(node not found|404.*not found|registration .*failed|key rejected)" | sed -E 's/(auth[a-zA-Z]*[=:])[a-zA-Z0-9_-]+/\1***REDACTED***/gi; s/(key[=:])[a-zA-Z0-9_-]+/\1***REDACTED***/gi; s/^/   /'
            
            if [ $attempt -lt $max_attempts ]; then
                log "${BLUE}🔄 Clearing stale Tailscale state and retrying...${NC}"
                return 2  # Special code to indicate retry needed
            else
                log "${RED}❌ Failed to establish Tailscale connection after $max_attempts attempts${NC}"
                return 1
            fi
        elif echo "$logs" | grep -q "serve config loaded\|serve config applied\|listening\|authenticated\|Listening on\|ready\|Startup complete\|magicsock.*connected\|client connected\|tunnel established\|serve.*started\|proxy.*ready\|health check.*ok\|tailscaled.*started\|login.*successful"; then
            log "${GREEN}✅ Tailscale connection validated for $container_name${NC}"
            return 0
        else
            log "${YELLOW}⚠️  Tailscale container logs unclear, waiting longer...${NC}"
            sleep 10
            attempt=$((attempt + 1))
        fi
    done
    
    log "${RED}❌ Tailscale validation failed after $max_attempts attempts${NC}"
    return 1
}

# Generic function to clear Tailscale state
clear_tailscale_state() {
    local container_name="$1"
    local volume_name="${2:-}"
    local compose_file="${3:-}"
    local service_name="${4:-tailscale}"
    
    log "Stopping Tailscale container..."
    docker stop "$container_name" 2>/dev/null || true
    
    log "Removing Tailscale container..."
    docker rm "$container_name" 2>/dev/null || true
    
    # Try to detect volume name from container if not provided
    if [ -z "$volume_name" ]; then
        volume_name=$(docker inspect "$container_name" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{if eq .Destination "/var/lib/tailscale"}}{{.Name}}{{end}}{{end}}{{end}}' 2>/dev/null || echo "")
    fi
    
    # Clear volume if found
    if [ -n "$volume_name" ]; then
        log "Clearing Tailscale state volume: $volume_name"
        docker run --rm -v "$volume_name:/state" alpine:latest sh -c "rm -rf /state/*" 2>/dev/null || {
            log "${YELLOW}Warning: Failed to clear volume with alpine, trying busybox...${NC}"
            docker run --rm -v "$volume_name:/state" busybox sh -c "rm -rf /state/*" 2>/dev/null || true
        }
    else
        # Try multiple possible volume name formats (based on old script patterns)
        log "${YELLOW}Warning: Could not determine volume name, trying common patterns...${NC}"
        local branch_name=$(echo "$container_name" | sed 's/-tailscale$//')
        local possible_volumes=(
            "$container_name" 
            "${container_name//-/_}"
            "nr_${branch_name}_tailscale"
            "nr-${branch_name}_nr_${branch_name}_tailscale"
            "${branch_name}_tailscale"
        )
        for vol in "${possible_volumes[@]}"; do
            if docker volume inspect "$vol" &>/dev/null; then
                log "Found volume: $vol, clearing..."
                docker run --rm -v "$vol:/state" alpine:latest sh -c "rm -rf /state/*" 2>/dev/null || {
                    log "${YELLOW}Warning: Failed to clear volume with alpine, trying busybox...${NC}"
                    docker run --rm -v "$vol:/state" busybox sh -c "rm -rf /state/*" 2>/dev/null || true
                }
                break
            fi
        done
    fi
    
    # Restart container if compose file provided
    if [ -n "$compose_file" ]; then
        log "Restarting Tailscale container..."
        env TS_AUTHKEY="$TS_AUTHKEY" docker compose -f "$compose_file" up -d "$service_name"
        sleep 5
    fi
}

# Function to validate and retry Tailscale with automatic state clearing
validate_and_retry_tailscale() {
    local container_name="$1"
    local volume_name="${2:-}"
    local compose_file="${3:-}"
    local service_name="${4:-tailscale}"
    
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        validate_tailscale_connection "$container_name"
        local result=$?
        
        if [ $result -eq 0 ]; then
            return 0
        elif [ $result -eq 2 ]; then
            # Retry needed - clear state
            clear_tailscale_state "$container_name" "$volume_name" "$compose_file" "$service_name"
            retry_count=$((retry_count + 1))
        else
            return 1
        fi
    done
    
    return 1
}

# Function to remove Docker volumes safely
remove_volumes() {
    local volumes=("$@")
    log "Removing volumes..."
    for volume in "${volumes[@]}"; do
        docker volume rm "$volume" 2>/dev/null || true
    done
}

# Function to get container git info
get_container_git_info() {
    local branch="$1"
    local branch_repo_dir="$2"
    local github_repo="$3"
    
    local commit_short="unknown"
    local commit_hash="unknown"
    local commit_url=""
    # Reconstruct original branch name for GitHub URL (convert sanitized back to original)
    local original_branch="$branch"
    if [[ "$branch" == claude-* ]]; then
        # Convert claude-issue-XX to claude/issue-XX for GitHub URL
        original_branch=$(echo "$branch" | sed 's/^claude-/claude\//g')
    fi
    local branch_url="https://github.com/$github_repo/tree/$original_branch"
    
    # Check if branch_repo_dir exists and is a valid git repository
    if [ -d "$branch_repo_dir/.git" ]; then
        commit_short=$(cd "$branch_repo_dir" && git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        commit_hash=$(cd "$branch_repo_dir" && git rev-parse HEAD 2>/dev/null || echo "unknown")
        if [ "$commit_hash" != "unknown" ]; then
            commit_url="https://github.com/$github_repo/commit/$commit_hash"
        fi
    fi
    
    echo "$commit_short|$commit_hash|$commit_url|$branch_url"
}

# Function to ensure Docker is installed and ready
ensure_docker() {
    if ! command -v docker &> /dev/null; then
        log "${YELLOW}🐳 Installing Docker...${NC}"
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        systemctl enable docker
        systemctl start docker
    fi
    
    # Wait for Docker to be ready
    while ! docker version &> /dev/null; do
        log "Waiting for Docker to be ready..."
        systemctl start docker 2>/dev/null || true
        sleep 5
    done
    log "${GREEN}✅ Docker is ready${NC}"
}

# Function to ensure git is installed
ensure_git() {
    if ! command -v git &> /dev/null; then
        log "${YELLOW}📦 Installing git...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y git jq curl
        elif command -v yum &> /dev/null; then
            yum install -y git jq curl
        fi
    fi
}

# ============================================================================
# CONFIGURATION VALIDATION
# ============================================================================

# Validate required configuration was loaded
validate_config() {
    local missing_vars=()
    
    if [ -z "$TS_AUTHKEY" ]; then
        missing_vars+=("TS_AUTHKEY")
    fi
    
    if [ -z "$TAILNET" ]; then
        missing_vars+=("TAILNET")
    fi
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo -e "${RED}❌ Missing required configuration variables: ${missing_vars[*]}${NC}"
        echo "   Check ~/.localtailscalerc file exists and contains:"
        echo "   - export TS_AUTHKEY=\"your-auth-key\""
        echo "   - export TAILNET=\"your-tailnet\""
        return 1
    fi
    return 0
}

# Function to check if TS_AUTHKEY is set
check_ts_authkey() {
    if [ -z "$TS_AUTHKEY" ]; then
        echo -e "${YELLOW}⚠️  WARNING: TS_AUTHKEY not set!${NC}"
        echo "   Set with: export TS_AUTHKEY=your-tailscale-auth-key"
        echo
        return 1
    fi
    return 0
}

# ============================================================================
# TALLY SURVEY FUNCTIONS
# ============================================================================

# Function to check if survey exists for branch
check_survey_exists() {
    local survey_name="$1"
    local tally_token="$2"
    
    log "${BLUE}🔍 [TALLY] Checking if survey '$survey_name' exists...${NC}"
    
    if [ -z "$tally_token" ]; then
        log "${RED}❌ [TALLY] No token provided to check_survey_exists${NC}"
        return 1
    fi
    
    log "${BLUE}📡 [TALLY] Making API call to list forms...${NC}"
    # Use Tally API to list forms and check if survey exists
    local response=$(curl -s -H "Authorization: Bearer $tally_token" \
        "https://api.tally.so/forms" 2>/dev/null || echo "{}")
    
    log "${BLUE}📄 [TALLY] API response length: ${#response} characters${NC}"
    if [ ${#response} -lt 10 ]; then
        log "${RED}❌ [TALLY] API response too short, likely failed: '$response'${NC}"
        return 1
    fi
    
    # Validate JSON response
    if ! echo "$response" | jq . > /dev/null 2>&1; then
        log "${RED}❌ [TALLY] Invalid JSON response from API${NC}"
        return 1
    fi
    
    # Parse response to find matching survey name using jq with exact match
    if echo "$response" | jq -e --arg name "$survey_name" '.items[] | select(.name == $name)' > /dev/null 2>&1; then
        local survey_found="FOUND"
    else
        local survey_found="NOT_FOUND"
    fi

    if [ "$survey_found" = "FOUND" ]; then
        log "${GREEN}✅ [TALLY] Survey '$survey_name' found in API response${NC}"
        return 0
    else
        log "${YELLOW}⚠️  [TALLY] Survey '$survey_name' not found in API response${NC}"
        # Show first few survey names for debugging using jq
        local available_surveys=$(echo "$response" | jq -r '.items[:3] | map(.name) | join(", ")' 2>/dev/null || echo "none")
        log "${BLUE}📋 [TALLY] Available surveys: $available_surveys${NC}"
        return 1
    fi
}

# Function to get survey ID by name
get_survey_id() {
    local survey_name="$1"
    local tally_token="$2"
    
    log "${BLUE}🔍 [TALLY] Getting survey ID for '$survey_name'...${NC}"
    
    if [ -z "$tally_token" ]; then
        log "${RED}❌ [TALLY] No token provided to get_survey_id${NC}"
        return 1
    fi
    
    log "${BLUE}📡 [TALLY] Making API call to get survey ID...${NC}"
    local response=$(curl -s -H "Authorization: Bearer $tally_token" \
        "https://api.tally.so/forms" 2>/dev/null || echo "{}")
    
    log "${BLUE}📄 [TALLY] API response length: ${#response} characters${NC}"
    if [ ${#response} -lt 10 ]; then
        log "${RED}❌ [TALLY] API response too short, likely failed: '$response'${NC}"
        return 1
    fi
    
    # Validate JSON response
    if ! echo "$response" | jq . > /dev/null 2>&1; then
        log "${RED}❌ [TALLY] Invalid JSON response from API${NC}"
        return 1
    fi
    
    # Extract form ID for matching survey name using jq with exact match
    local survey_id=$(echo "$response" | jq -r --arg name "$survey_name" '.items[] | select(.name == $name) | .id // empty' 2>/dev/null)
    
    if [ -n "$survey_id" ]; then
        log "${GREEN}✅ [TALLY] Found survey ID: '$survey_id' for '$survey_name'${NC}"
        echo "$survey_id"
    else
        log "${RED}❌ [TALLY] Could not extract survey ID for '$survey_name'${NC}"
        # Debug: show what surveys were found using jq
        local found_surveys=$(echo "$response" | jq -r '.items[:3] | map("\(.name):\(.id)") | join(" | ")' 2>/dev/null || echo "none")
        log "${RED}📋 [TALLY] Available surveys: $found_surveys${NC}"
    fi
}

# Function to generate new UUID (simple version for bash)
generate_uuid() {
    # Generate a simple UUID-like string using /dev/urandom
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
    echo "$(date +%s)-$(shuf -i 1000-9999 -n 1)-$(shuf -i 1000-9999 -n 1)-$(shuf -i 1000-9999 -n 1)-$(shuf -i 100000000000-999999999999 -n 1)"
}

# Function to duplicate survey using proper 2-step process
duplicate_survey() {
    local new_survey_name="$1"
    local template_name="$2"
    local tally_token="$3"
    
    log "${BLUE}🔨 [TALLY] Duplicating survey '$template_name' as '$new_survey_name'...${NC}"
    
    if [ -z "$tally_token" ]; then
        log "${RED}❌ [TALLY] No token provided to duplicate_survey${NC}"
        return 1
    fi
    
    log "${BLUE}🔍 [TALLY] Step 1: Using hardcoded template ID for '$template_name'...${NC}"
    # Use hardcoded template ID instead of searching by name
    local template_id="3jj6Ga"
    
    log "${GREEN}✅ [TALLY] Template ID found: '$template_id'${NC}"
    log "${BLUE}📡 [TALLY] Step 2: Fetching complete template form data...${NC}"
    
    # Get the complete form data (blocks, settings, CSS)
    local template_data=$(curl -s -H "Authorization: Bearer $tally_token" \
        "https://api.tally.so/forms/$template_id" 2>/dev/null || echo "{}")
    
    log "${BLUE}📄 [TALLY] Template data length: ${#template_data} characters${NC}"
    if [ ${#template_data} -lt 50 ]; then
        log "${RED}❌ [TALLY] Failed to fetch template data: '$template_data'${NC}"
        return 1
    fi
    
    # Check if template data contains blocks
    if ! echo "$template_data" | grep -q '"blocks"'; then
        log "${RED}❌ [TALLY] Template data missing blocks field${NC}"
        return 1
    fi
    
    log "${GREEN}✅ [TALLY] Template data fetched successfully${NC}"
    log "${BLUE}🔄 [TALLY] Step 3: Creating form data with new name...${NC}"
    
    # Debug: Show original template name from data
    local original_name=$(echo "$template_data" | jq -r '.name // "null"' 2>/dev/null)
    log "${BLUE}🔍 [TALLY] Original template name: '$original_name'${NC}"
    log "${BLUE}🎯 [TALLY] Target survey name: '$new_survey_name'${NC}"
    
    # Replace the name field and FORM_TITLE blocks in the JSON using jq for reliable JSON manipulation
    local new_form_data=$(echo "$template_data" | jq --arg name "$new_survey_name" '
      .name = $name |
      .blocks |= map(
        if .type == "FORM_TITLE" then
          .payload.safeHTMLSchema = [[$name]] |
          .payload.title = $name
        else
          .
        end
      )
    ' 2>/dev/null)
    
    # Verify the name was replaced and JSON is valid
    if ! echo "$new_form_data" | jq . > /dev/null 2>&1; then
        log "${RED}❌ [TALLY] Failed to create valid JSON with new name${NC}"
        log "${RED}🔍 [TALLY] jq command: jq --arg name '$new_survey_name' '.name = \$name'${NC}"
        return 1
    fi
    
    # Double-check the name was set correctly
    local actual_name=$(echo "$new_form_data" | jq -r '.name' 2>/dev/null)
    if [ "$actual_name" != "$new_survey_name" ]; then
        log "${RED}❌ [TALLY] Name replacement failed - expected '$new_survey_name', got '$actual_name'${NC}"
        log "${RED}🔍 [TALLY] Name length: expected=${#new_survey_name}, actual=${#actual_name}${NC}"
        log "${RED}🔍 [TALLY] Name bytes: expected=$(echo -n "$new_survey_name" | od -t x1 -A n | tr -d ' '), actual=$(echo -n "$actual_name" | od -t x1 -A n | tr -d ' ')${NC}"
        return 1
    fi
    
    log "${GREEN}✅ [TALLY] Name successfully replaced: '$actual_name'${NC}"
    
    if [ -z "$new_form_data" ]; then
        log "${RED}❌ [TALLY] Failed to process template data${NC}"
        return 1
    fi
    
    # Count blocks using grep instead of jq
    local block_count=$(echo "$new_form_data" | grep -c '"uuid":' 2>/dev/null || echo "?")
    log "${GREEN}✅ [TALLY] Prepared form data with $block_count blocks${NC}"
    log "${BLUE}📡 [TALLY] Step 4: Creating new survey with duplicated data...${NC}"
    
    # Create new survey with the processed data
    local create_response=$(curl -s -X POST \
        -H "Authorization: Bearer $tally_token" \
        -H "Content-Type: application/json" \
        -d "$new_form_data" \
        "https://api.tally.so/forms" 2>/dev/null || echo "{}")
    
    log "${BLUE}📄 [TALLY] Create response length: ${#create_response} characters${NC}"
    if [ ${#create_response} -lt 10 ]; then
        log "${RED}❌ [TALLY] Create response too short, likely failed: '$create_response'${NC}"
        return 1
    fi
    
    # Validate JSON response
    if ! echo "$create_response" | jq . > /dev/null 2>&1; then
        log "${RED}❌ [TALLY] Invalid JSON response from survey creation API${NC}"
        return 1
    fi
    
    # Check for errors in response using jq
    if echo "$create_response" | jq -e '.error // .message' > /dev/null 2>&1; then
        local error_msg=$(echo "$create_response" | jq -r '.error // .message // "Unknown error"' 2>/dev/null)
        log "${RED}❌ [TALLY] API returned error: '$error_msg'${NC}"
        return 1
    fi
    
    # Extract new survey ID using jq
    local new_survey_id=$(echo "$create_response" | jq -r '.id // empty' 2>/dev/null)
    
    # Additional validation that we got a valid ID
    if [ -z "$new_survey_id" ] || [ "$new_survey_id" = "null" ]; then
        log "${RED}❌ [TALLY] No form ID returned from survey creation${NC}"
        log "${RED}📄 [TALLY] Create response: '$create_response'${NC}"
        return 1
    fi
    
    # Verify the created survey has the correct name by checking the response
    local created_name=$(echo "$create_response" | jq -r '.name // "unknown"' 2>/dev/null)
    log "${GREEN}✅ [TALLY] Successfully duplicated survey with ID: '$new_survey_id'${NC}"
    log "${GREEN}🎯 [TALLY] Created survey name: '$created_name'${NC}"
    
    # Final verification: check if created name matches what we intended
    if [ "$created_name" != "$new_survey_name" ]; then
        log "${YELLOW}⚠️  [TALLY] Warning: Created survey name '$created_name' doesn't match intended '$new_survey_name'${NC}"
        log "${YELLOW}🔍 [TALLY] This might indicate a Tally API issue or name normalization${NC}"
        
        # Additional verification: Fetch the survey via API to confirm the actual name
        log "${BLUE}🔍 [TALLY] Verifying survey name via API...${NC}"
        local api_response=$(curl -s -H "Authorization: Bearer $tally_token" \
            "https://api.tally.so/forms/$new_survey_id" 2>/dev/null || echo "{}")
        
        if [ ${#api_response} -gt 10 ] && echo "$api_response" | jq . > /dev/null 2>&1; then
            local api_name=$(echo "$api_response" | jq -r '.name // "unknown"' 2>/dev/null)
            log "${BLUE}📡 [TALLY] API verification - Survey name: '$api_name'${NC}"
            
            if [ "$api_name" = "$new_survey_name" ]; then
                log "${GREEN}✅ [TALLY] API verification successful - names match${NC}"
            else
                log "${RED}❌ [TALLY] API verification failed - expected '$new_survey_name', API says '$api_name'${NC}"
            fi
        else
            log "${YELLOW}⚠️  [TALLY] API verification failed - could not fetch survey details${NC}"
        fi
    fi
    
    echo "$new_survey_id"
}

# Function to setup survey for issue and experiment branches
setup_issue_survey() {
    local branch="$1"
    
    log "${BLUE}🚀 [TALLY] Starting survey setup for branch: '$branch'${NC}"
    
    # Extract issue ID from branch name (issue-NNNN pattern)
    local issue_id=$(echo "$branch" | sed -n 's/^issue-\([0-9]\+\)$/\1/p')
    
    # Extract experiment ID from branch name (experiment-* pattern)
    local experiment_id=$(echo "$branch" | sed -n 's/^experiment-\(.\+\)$/\1/p')
    
    if [ -z "$issue_id" ] && [ -z "$experiment_id" ]; then
        log "${BLUE}ℹ️  [TALLY] Branch '$branch' is not an issue or experiment branch, skipping survey setup${NC}"
        export TALLY_SURVEY_ID=""
        return 0
    fi
    
    if [ -n "$issue_id" ]; then
        log "${GREEN}✅ [TALLY] Detected issue branch with ID: $issue_id${NC}"
        log "${BLUE}🗣️  [TALLY] Setting up survey for issue branch: $branch${NC}"
    elif [ -n "$experiment_id" ]; then
        log "${GREEN}✅ [TALLY] Detected experiment branch: $experiment_id${NC}"
        log "${BLUE}🗣️  [TALLY] Setting up survey for experiment branch: $branch${NC}"
    fi
    
    # Debug: Show branch name details
    log "${BLUE}🔍 [TALLY] Branch name debug info:${NC}"
    log "${BLUE}   - Raw branch: '$branch'${NC}"
    log "${BLUE}   - Length: ${#branch} characters${NC}"
    log "${BLUE}   - Hex dump: $(echo -n "$branch" | od -t x1 -A n | tr -d ' ')${NC}"
    
    # Get Tally token from environment (passed from local machine) or local config
    local tally_token="$TALLY_TOKEN"
    log "${BLUE}🔍 [TALLY] Checking for TALLY_TOKEN in environment...${NC}"
    
    if [ -z "$tally_token" ]; then
        log "${YELLOW}⚠️  [TALLY] No TALLY_TOKEN in environment, checking ~/.localtallyrc...${NC}"
        if [ -f ~/.localtallyrc ]; then
            log "${BLUE}📁 [TALLY] Found ~/.localtallyrc, sourcing it...${NC}"
            source ~/.localtallyrc
            tally_token="$TALLY_TOKEN"
            if [ -n "$tally_token" ]; then
                log "${GREEN}✅ [TALLY] Token loaded from ~/.localtallyrc${NC}"
            else
                log "${RED}❌ [TALLY] ~/.localtallyrc exists but TALLY_TOKEN is empty${NC}"
            fi
        else
            log "${YELLOW}⚠️  [TALLY] ~/.localtallyrc not found${NC}"
        fi
    else
        log "${GREEN}✅ [TALLY] Token found in environment (length: ${#tally_token} chars)${NC}"
    fi
    
    if [ -z "$tally_token" ]; then
        log "${YELLOW}⚠️  [TALLY] No Tally token found anywhere, skipping survey setup${NC}"
        export TALLY_SURVEY_ID=""
        return 0
    fi
    
    # Survey name matches branch name
    local survey_name="$branch"
    local template_name="nr-experiment-template"
    
    log "${BLUE}📋 [TALLY] Survey configuration:${NC}"
    log "${BLUE}   - Survey name: '$survey_name'${NC}"
    log "${BLUE}   - Template name: '$template_name'${NC}"
    
    # Check if survey already exists
    log "${BLUE}🔍 [TALLY] Checking if survey already exists...${NC}"
    if check_survey_exists "$survey_name" "$tally_token"; then
        log "${GREEN}✅ [TALLY] Survey '$survey_name' already exists, getting ID...${NC}"
        local survey_id=$(get_survey_id "$survey_name" "$tally_token")
    else
        log "${BLUE}🔨 [TALLY] Survey doesn't exist, duplicating template '$template_name' as '$survey_name'...${NC}"
        local survey_id=$(duplicate_survey "$survey_name" "$template_name" "$tally_token")
    fi
    
    if [ -n "$survey_id" ]; then
        export TALLY_SURVEY_ID="$survey_id"
        log "${GREEN}✅ [TALLY] Survey ready: $survey_name (ID: $survey_id)${NC}"
        log "${GREEN}🎯 [TALLY] TALLY_SURVEY_ID exported: '$TALLY_SURVEY_ID'${NC}"
    else
        log "${YELLOW}⚠️  [TALLY] Failed to setup survey, continuing without it${NC}"
        export TALLY_SURVEY_ID=""
    fi
    
    log "${BLUE}🏁 [TALLY] Survey setup completed for branch: '$branch'${NC}"
    return 0
}

# ============================================================================
# GIT OPERATIONS
# ============================================================================

# Function to get and validate branch name (only called during local execution)
get_branch_name() {
    # Get current git branch (original, with slashes)
    GIT_BRANCH_NAME=$(git branch --show-current)
    
    # Sanitize branch name for Docker/Tailscale naming (replace non-alphanumeric with hyphens)
    BRANCH_NAME=$(echo "$GIT_BRANCH_NAME" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')
    
    # Validate branch name
    if [ -z "$GIT_BRANCH_NAME" ]; then
        echo -e "${RED}❌ Error: Could not determine git branch${NC}"
        exit 1
    fi
}

# Function to check for uncommitted changes
check_uncommitted_changes() {
    # Skip git checks if explicitly disabled (for testing)
    if [ "${SKIP_GIT_CHECKS:-}" = "true" ]; then
        return 0
    fi
    
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "${RED}❌ Error: Uncommitted changes detected!${NC}"
        echo "Please commit and push your changes before deploying:"
        echo
        git status --short
        echo
        echo "Run the following commands:"
        echo "  git add ."
        echo "  git commit -m 'Your commit message'"
        echo "  git push origin $GIT_BRANCH_NAME"
        exit 1
    fi
}

# Function to check if local and remote branches are in sync
check_branch_sync() {
    # Fetch latest from remote
    git fetch origin "$GIT_BRANCH_NAME" 2>/dev/null || {
        echo -e "${YELLOW}⚠️  Warning: Could not fetch from remote. Branch may not exist on remote.${NC}"
        echo "Please push your branch to remote first:"
        echo "  git push -u origin $GIT_BRANCH_NAME"
        exit 1
    }
    
    # Get commit hashes
    LOCAL_COMMIT=$(git rev-parse HEAD)
    REMOTE_COMMIT=$(git rev-parse "origin/$GIT_BRANCH_NAME" 2>/dev/null || echo "")
    
    if [ -z "$REMOTE_COMMIT" ]; then
        echo -e "${YELLOW}⚠️  Warning: Remote branch origin/$GIT_BRANCH_NAME does not exist.${NC}"
        echo "Please push your branch to remote first:"
        echo "  git push -u origin $GIT_BRANCH_NAME"
        exit 1
    fi
    
    if [ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]; then
        echo -e "${RED}❌ Error: Local and remote branches are out of sync!${NC}"
        echo "Local:  $LOCAL_COMMIT"
        echo "Remote: $REMOTE_COMMIT"
        echo
        echo "Please sync your branches:"
        echo "  git push origin $GIT_BRANCH_NAME  # if local is ahead"
        echo "  git pull origin $GIT_BRANCH_NAME  # if remote is ahead"
        exit 1
    fi
    
    log "${GREEN}✅ Local and remote branches are in sync${NC}"
}

# ============================================================================
# DASHBOARD FUNCTIONS
# ============================================================================

# Function to generate nginx configuration with no-cache headers
generate_nginx_config() {
    cat > nginx-dashboard.conf << 'NGINX_CONFIG'
server {
    listen       80;
    listen  [::]:80;
    server_name  localhost;

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
        
        # Disable caching for dashboard to ensure fresh content
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
    }

    # Still allow caching for static assets like images
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg)$ {
        root   /usr/share/nginx/html;
        expires 1h;
        add_header Cache-Control "public, immutable";
    }

    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
    }
}
NGINX_CONFIG
}

# Function to generate dashboard HTML (extracted to external file for maintainability)
generate_dashboard_html() {
    local dashboard_file="${1:-dashboard.html}"
    log "Generating $dashboard_file..."
    
    # This could be moved to a separate template file
    cat > "$dashboard_file" << 'DASHBOARD_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="Live status dashboard for Node-RED Modernization Project experiments. Test ongoing UI/UX improvements and provide feedback to shape Node-RED's future.">
    <meta name="keywords" content="Node-RED, dashboard, experiments, modernization, UI, UX, testing, status">
    <meta name="author" content="Node-RED Modernization Project">
    <meta name="robots" content="noindex, nofollow">
    
    <title>Node-RED Modernization Project - Experiment Dashboard</title>
    
    <!-- Favicon implementation matching node-red-academy.learnworlds.com -->
    <link rel="icon" type="image/png" href="https://lwfiles.mycourse.app/67605a7461b32c08f9864eb5-public/c41a9ea6f80733c54d30135a2b3d3254.png">
    <link rel="apple-touch-icon" type="image/png" href="https://lwfiles.mycourse.app/67605a7461b32c08f9864eb5-public/c41a9ea6f80733c54d30135a2b3d3254.png">
    
    <!-- Preconnect to external domains for performance -->
    <link rel="preconnect" href="https://tally.so">
    <link rel="preconnect" href="https://lwfiles.mycourse.app">
    
    <!-- Tally popup widget -->
    <script async src="https://tally.so/widgets/embed.js"></script>
    <script>
    window.TallyConfig = {
      "formId": "31L4dW",
      "popup": {
        "emoji": {
          "text": "👋",
          "animation": "wave"
        },
        "hideTitle": true,
        "open": {
          "trigger": "time",
          "ms": 30000
        }
      }
    };
    </script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f0f0f0; min-height: 100vh; padding: 20px; }
        .container { max-width: 1200px; margin: 0 auto; }
        .header { text-align: center; margin-bottom: 20px; background: #8f0000; color: white; padding: 40px 20px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header h1 { font-size: 2.5rem; margin-bottom: 10px; font-weight: 400; letter-spacing: -0.5px; display: inline; line-height: 1.2; }
        .header h1 .logo { height: 1em; width: auto; vertical-align: middle; margin-right: 0.2em; }
        .header p { font-size: 1.1rem; opacity: 0.95; margin-bottom: 15px; }
        .header-links { display: flex; justify-content: center; gap: 20px; flex-wrap: wrap; }
        .header-link { color: white; text-decoration: none; padding: 8px 16px; border: 1px solid rgba(255, 255, 255, 0.3); border-radius: 4px; font-size: 0.9rem; transition: all 0.3s ease; background: rgba(255, 255, 255, 0.1); }
        .header-link:hover { background: rgba(255, 255, 255, 0.2); border-color: rgba(255, 255, 255, 0.6); transform: translateY(-1px); }
        .meta-info { color: #666; font-size: 0.9rem; background: white; padding: 10px 15px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.05); white-space: nowrap; }
        .meta-info code { background: #f5f5f5; padding: 2px 6px; border-radius: 3px; color: #8f0000; font-weight: 500; }
        .controls { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; flex-wrap: wrap; gap: 15px; }
        .refresh-btn { background: white; color: #666; border: 2px solid #ddd; padding: 0 16px; border-radius: 8px; cursor: pointer; transition: all 0.3s ease; font-size: 14px; font-weight: 500; box-shadow: 0 2px 4px rgba(0,0,0,0.05); height: 40px; display: flex; align-items: center; justify-content: center; position: relative; white-space: nowrap; min-width: 120px; }
        .refresh-btn:hover { background: rgba(143, 0, 0, 0.05); color: #8f0000; border-color: #8f0000; }
        .control-buttons { display: flex; align-items: center; gap: 20px; flex-wrap: wrap; }
        .status-filter { display: flex; align-items: center; background: white; border-radius: 8px; border: 2px solid #ddd; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.05); height: 40px; }
        .filter-btn { background: transparent; color: #666; border: none; padding: 0 15px; cursor: pointer; transition: all 0.3s ease; font-size: 14px; font-weight: 500; line-height: 1; min-width: 70px; border-right: 1px solid #ddd; position: relative; white-space: nowrap; height: 40px; display: flex; align-items: center; justify-content: center; flex: 1; }
        .filter-btn:last-child { border-right: none; }
        .filter-btn:hover { background: rgba(143, 0, 0, 0.05); color: #8f0000; }
        .filter-btn.active { background: #8f0000; color: white; }
        .instances-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 20px; margin-top: 20px; }
        .instance-card { background: white; border-radius: 8px; padding: 0; box-shadow: 0 2px 6px rgba(0, 0, 0, 0.1); transition: all 0.3s ease; cursor: pointer; position: relative; overflow: hidden; border: 1px solid #e0e0e0; display: flex; flex-direction: column; }
        .instance-card:hover { transform: translateY(-3px); box-shadow: 0 6px 20px rgba(0, 0, 0, 0.15); border-color: #8f0000; }
        .instance-card.online:hover { border-color: #4CAF50; }
        .instance-card.checking:hover { border-color: #2196F3; }
        .instance-card::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 4px; background: #4CAF50; z-index: 1; }
        .instance-card.checking::before { background: #2196F3; }
        .instance-card.offline::before { background: #f44336; }
        .instance-card-content { padding: 25px; flex: 1; }
        .instance-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 15px; }
        .instance-name { font-size: 1.3rem; font-weight: 600; color: #333; margin: 0; }
        .status-badge { padding: 4px 12px; border-radius: 20px; font-size: 0.8rem; font-weight: 500; text-transform: uppercase; letter-spacing: 0.5px; }
        .status-online { background: #e8f5e8; color: #4CAF50; }
        .status-offline { background: #ffebee; color: #f44336; }
        .status-checking { background: #e3f2fd; color: #2196F3; }
        .instance-info { margin-bottom: 0; }
        .info-row { display: flex; justify-content: space-between; margin-bottom: 8px; font-size: 0.9rem; }
        .info-label { color: #666; font-weight: 600; }
        .info-value { color: #333; font-family: 'SF Mono', Monaco, monospace; font-size: 0.85rem; text-align: right; flex: 1; margin-left: 10px; word-break: break-all; }
        .info-value a { color: #0066cc; text-decoration: none; transition: color 0.2s ease; }
        .info-value code { background: #f5f5f5; padding: 2px 6px; border-radius: 3px; color: #8f0000; font-weight: 500; }
        .info-value a:hover { color: #8f0000; text-decoration: underline; }
        .experiment-link-bar { background: #8f0000; color: white; padding: 15px; text-align: center; font-weight: 600; font-size: 1rem; letter-spacing: 0.5px; transition: background 0.3s ease; border-radius: 0 0 8px 8px; }
        .instance-card:hover .experiment-link-bar { background: #a70000; }
        .experiments-section { margin-bottom: 30px; }
        .section-title { font-size: 1.5rem; margin-bottom: 10px; color: #333; }
        .section-description { color: #666; margin-bottom: 20px; font-size: 1rem; }
        .section-divider { margin: 40px 0; border: none; border-top: 2px dashed #e0e0e0; }
        .claude-section { background: #f8f9fa; padding: 20px; border-radius: 8px; }
        @media (max-width: 900px) {
            .controls { flex-direction: column; align-items: stretch; }
            .meta-info { width: 100%; text-align: center; }
            .control-buttons { justify-content: center; width: 100%; }
        }
        @media (max-width: 600px) {
            .header h1 { font-size: 2rem; }
            .instances-grid { grid-template-columns: 1fr; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1><img src="https://us1.discourse-cdn.com/flex026/uploads/nodered/original/1X/778549404735e222c89ce5449482a189ace8cdae.png" alt="Node-RED" class="logo"> Node-RED Modernization Project Experiment Dashboard</h1>
            <p>Live status of all currently running Node-RED experiments | Feel free to test the other experiments!</p>
            <div class="header-links">
                <a href="https://discourse.nodered.org/t/node-red-survey-shaping-the-future-of-node-reds-user-experience/98346" target="_blank" rel="noopener noreferrer" class="header-link">Modernization Project</a>
                <a href="https://github.com/node-red/node-red/issues" target="_blank" rel="noopener noreferrer" class="header-link">Issue Tracker</a>
            </div>
        </div>
        <div class="controls">
            <div class="meta-info" id="meta-info">Loading...</div>
            <div class="control-buttons">
                <button class="refresh-btn" onclick="checkAllStatus()">Check status</button>
                <div class="status-filter">
                    <button class="filter-btn active" data-filter="all" id="all-btn">All (<span id="total-count">0</span>)</button>
                    <button class="filter-btn" data-filter="online" id="online-btn">Online (<span id="online-count">0</span>)</button>
                    <button class="filter-btn" data-filter="offline" id="offline-btn">Offline (<span id="offline-count">0</span>)</button>
                </div>
            </div>
        </div>
        <div id="instances" class="instances-grid"></div>
    </div>
    <script>
        let containersData = null;
        let currentFilter = 'all';
        function getRelativeTime(date) {
            const now = new Date();
            const diffMs = now - date;
            const diffSecs = Math.floor(diffMs / 1000);
            const diffMins = Math.floor(diffSecs / 60);
            const diffHours = Math.floor(diffMins / 60);
            const diffDays = Math.floor(diffHours / 24);
            if (diffSecs < 60) return `${diffSecs} seconds ago`;
            if (diffMins < 60) return `${diffMins} minutes ago`;
            if (diffHours < 24) return `${diffHours} hours ago`;
            return `${diffDays} days ago`;
        }
        async function loadContainersData() {
            try {
                const response = await fetch('containers.json');
                containersData = await response.json();
                const metaInfo = document.getElementById('meta-info');
                const generatedDate = new Date(containersData.generated);
                const generated = generatedDate.toLocaleString();
                const relativeTime = getRelativeTime(generatedDate);
                metaInfo.innerHTML = `<span style="font-weight: 600;">Generated:</span> <code>${relativeTime}</code> (${generated})`;
                containersData.containers.forEach(container => { container.urlStatus = 'checking'; });
                displayContainers();
                updateStats();
                checkAllStatus();
            } catch (error) {
                console.error('Error loading containers data:', error);
                document.getElementById('instances').innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: #666; font-size: 1.2rem; margin: 50px 0;">❌ Failed to load containers data</div>';
            }
        }
        async function checkAllStatus() {
            if (!containersData) return;
            const promises = containersData.containers.map(async (container) => {
                container.urlStatus = 'checking';
                displayContainers();
                try {
                    const controller = new AbortController();
                    const timeoutId = setTimeout(() => controller.abort(), 5000);
                    const response = await fetch(container.url, { method: 'HEAD', signal: controller.signal, mode: 'no-cors' });
                    clearTimeout(timeoutId);
                    container.urlStatus = 'online';
                } catch (error) {
                    container.urlStatus = 'offline';
                }
                return container;
            });
            await Promise.all(promises);
            displayContainers();
            updateStats();
        }
        function displayContainers() {
            if (!containersData) return;
            const container = document.getElementById('instances');
            const filteredContainers = getFilteredContainers();
            if (filteredContainers.length === 0) {
                container.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: #666; font-size: 1.2rem; margin: 50px 0;">No containers match the current filter</div>';
                return;
            }
            
            // Separate Claude and manual experiments
            const claudeExperiments = filteredContainers.filter(c => c.is_claude === true);
            const manualExperiments = filteredContainers.filter(c => c.is_claude !== true);
            
            // For manual experiments only, use the original simple grid
            if (claudeExperiments.length === 0) {
                // Original behavior - all cards in main grid
                container.innerHTML = filteredContainers.map(cont => createContainerCard(cont)).join('');
            } else {
                // When we have Claude experiments, show sections
                let html = '';
                
                // Manual experiments (without header)
                if (manualExperiments.length > 0) {
                    html += manualExperiments.map(cont => createContainerCard(cont)).join('');
                }
                
                // Divider between sections
                if (manualExperiments.length > 0 && claudeExperiments.length > 0) {
                    html += '<hr class="section-divider" style="grid-column: 1/-1;">';
                }
                
                // Claude experiments header (inline, not taking grid space)
                if (claudeExperiments.length > 0) {
                    html += `<div style="grid-column: 1/-1;">
                        <h2 class="section-title">Auto-Generated Experiments (${claudeExperiments.length})</h2>
                        <p class="section-description">The experiments below are auto-generated and may have unintended changes. Mostly for quickly checking generated results.</p>
                    </div>`;
                    html += claudeExperiments.map(cont => createContainerCard(cont, true)).join('');
                }
                
                container.innerHTML = html;
            }
            container.querySelectorAll('.instance-card').forEach(card => {
                card.addEventListener('click', function(event) {
                    if (event.target.tagName === 'A' || event.target.closest('a')) { return; }
                    const url = this.getAttribute('data-url');
                    window.open(url, '_blank');
                });
            });
        }
        function createContainerCard(container, isClaudeExperiment = false) {
            const urlStatus = container.urlStatus || 'unknown';
            const statusClass = urlStatus === 'online' ? 'online' : urlStatus === 'checking' ? 'checking' : urlStatus;
            const deployedDate = new Date(container.created);
            const deployedTime = deployedDate.toLocaleString();
            const deployedRelative = getRelativeTime(deployedDate);
            
            
            return `
                <div class="instance-card ${statusClass}" data-url="${container.url}">
                    <div class="instance-card-content">
                        <div class="instance-header">
                            <h3 class="instance-name">${container.issue_title ? container.issue_title.replace(/^\[NR Modernization Experiment\]\s*/, '') : container.name}</h3>
                            <span class="status-badge status-${urlStatus}">${urlStatus}</span>
                        </div>
                        <div class="instance-info">
                            <div class="info-row">
                                <span class="info-label">Deployed:</span>
                                <span class="info-value" title="${deployedTime}">${deployedRelative}</span>
                            </div>
                            ${container.branch && container.commit ? `
                            <div class="info-row">
                                <span class="info-label">Branch:</span>
                                <span class="info-value"><a href="${container.branch_url}" target="_blank">${container.branch.replace(/^claude\//, '')}</a></span>
                            </div>
                            <div class="info-row">
                                <span class="info-label">Commit:</span>
                                <span class="info-value"><a href="${container.commit_url}" target="_blank">${container.commit}</a></span>
                            </div>
                            ` : ''}
                            <div class="info-row">
                                <span class="info-label">Image:</span>
                                <span class="info-value"><code>${container.image}</code></span>
                            </div>
                            ${container.issue_url ? `
                            <div class="info-row">
                                <span class="info-label">Issue:</span>
                                <span class="info-value"><a href="${container.issue_url}" target="_blank">#${container.issue_url.split('/').pop()}</a></span>
                            </div>
                            ` : ''}
                            ${container.pr_urls && container.pr_urls.length > 0 ? `
                            <div class="info-row">
                                <span class="info-label">PR${container.pr_urls.length > 1 ? 's' : ''}:</span>
                                <span class="info-value">${container.pr_urls.map(pr_url => 
                                    `<a href="${pr_url}" target="_blank">#${pr_url.split('/').pop()}</a>`
                                ).join(', ')}</span>
                            </div>
                            ` : ''}
                        </div>
                    </div>
                    <div class="experiment-link-bar">Open live experiment</div>
                </div>
            `;
        }
        function getFilteredContainers() {
            if (!containersData) return [];
            if (currentFilter === 'all') { return containersData.containers; }
            return containersData.containers.filter(container => { return container.urlStatus === currentFilter; });
        }
        function updateStats() {
            if (!containersData) return;
            const stats = { total: containersData.containers.length, online: containersData.containers.filter(c => c.urlStatus === 'online').length, offline: containersData.containers.filter(c => c.urlStatus === 'offline').length };
            document.getElementById('total-count').textContent = stats.total;
            document.getElementById('online-count').textContent = stats.online;
            document.getElementById('offline-count').textContent = stats.offline;
        }
        document.addEventListener('DOMContentLoaded', loadContainersData);
        document.querySelectorAll('.filter-btn').forEach(btn => {
            btn.addEventListener('click', function() {
                document.querySelector('.filter-btn.active').classList.remove('active');
                this.classList.add('active');
                currentFilter = this.getAttribute('data-filter');
                displayContainers();
            });
        });
    </script>
</body>
</html>
DASHBOARD_HTML
}

# Function to generate dashboard content by scanning all running containers
generate_dashboard_content() {
    log "Scanning containers for dashboard..."
    
    # Find ALL containers with the nr-experiment label (server-wide scan)
    containers=$(docker ps -q --filter "label=nr-experiment=true" 2>/dev/null || true)
    
    if [ -n "$containers" ]; then
        # Generate containers.json with all running containers
        echo "{" > containers.json
        echo "  \"generated\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"," >> containers.json
        echo "  \"containers\": [" >> containers.json
        
        first=true
        for container in $containers; do
            if [ "$first" = false ]; then
                echo "," >> containers.json
            fi
            first=false
            
            name=$(docker inspect --format='{{.Name}}' "$container" | sed 's/^\///')
            image=$(docker inspect --format='{{.Config.Image}}' "$container")
            created=$(docker inspect --format='{{.State.StartedAt}}' "$container")
            
            # Get branch name from container label
            branch=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project"}}' "$container" | sed 's/^nr-//')
            
            # Determine if this is a Claude branch (sanitized name starts with claude-)
            is_claude="false"
            if [[ "$branch" == claude-* ]]; then
                is_claude="true"
            fi
            
            # Extract issue ID from branch name
            issue_id=""
            if [[ "$branch" =~ ^issue-([0-9]+)$ ]]; then
                issue_id="${BASH_REMATCH[1]}"
            elif [[ "$branch" =~ ^claude-issue-([0-9]+) ]]; then
                issue_id="${BASH_REMATCH[1]}"
            fi
            
            issue_url=""
            issue_title=""
            pr_url=""
            pr_number=""
            
            # First check for associated issue
            if [ -n "$issue_id" ]; then
                # Use different repo for Claude branches
                if [ "$is_claude" = "true" ]; then
                    issue_url="https://github.com/dimitrieh/node-red/issues/$issue_id"
                    api_url="https://api.github.com/repos/dimitrieh/node-red/issues/$issue_id"
                else
                    issue_url="https://github.com/$GITHUB_ISSUES_REPO/issues/$issue_id"
                    api_url="https://api.github.com/repos/$GITHUB_ISSUES_REPO/issues/$issue_id"
                fi
                # Try to fetch issue title
                response=$(curl -s -f "$api_url" 2>/dev/null || echo "{}")
                issue_title=$(echo "$response" | grep '"title":' | head -1 | sed 's/.*"title": *"\([^"]*\)".*/\1/' | sed 's/\[NR Modernization Experiment\] *//')
            fi
            
            # Check for associated PRs on dimitrieh/node-red for this branch
            # First check open PRs
            pr_api_url="https://api.github.com/repos/dimitrieh/node-red/pulls?state=open&head=dimitrieh:$branch&sort=created&direction=desc"
            pr_response_open=$(curl -s -f "$pr_api_url" 2>/dev/null || echo "[]")
            
            # Then check closed PRs if needed
            pr_api_url="https://api.github.com/repos/dimitrieh/node-red/pulls?state=closed&head=dimitrieh:$branch&sort=created&direction=desc"
            pr_response_closed=$(curl -s -f "$pr_api_url" 2>/dev/null || echo "[]")
            
            # Combine responses (open PRs first, then closed)
            pr_response=$(echo "$pr_response_open" | sed 's/\]$//' | sed 's/^\[//')
            if [ "$pr_response" != "" ] && [ "$pr_response_closed" != "[]" ]; then
                pr_response="${pr_response},"
            fi
            pr_response="[${pr_response}$(echo "$pr_response_closed" | sed 's/\]$//' | sed 's/^\[//')]"
            
            # Extract all PR numbers and create JSON array
            pr_numbers=$(echo "$pr_response" | grep '"number":' | sed 's/.*"number": *\([0-9]*\).*/\1/' | tr '\n' ' ')
            pr_urls="["
            pr_list=""
            most_recent_pr_number=""
            most_recent_pr_title=""
            
            if [ -n "$pr_numbers" ]; then
                # The first PR in the list is the most recent (open if any, otherwise most recent closed)
                most_recent_pr_number=$(echo "$pr_numbers" | awk '{print $1}')
                most_recent_pr_title=$(echo "$pr_response" | grep -m1 '"title":' | sed 's/.*"title": *"\([^"]*\)".*/\1/')
                
                for pr_num in $pr_numbers; do
                    if [ -n "$pr_list" ]; then
                        pr_urls="${pr_urls},"
                        pr_list="${pr_list},"
                    fi
                    pr_urls="${pr_urls}\"https://github.com/dimitrieh/node-red/pull/$pr_num\""
                    pr_list="${pr_list}$pr_num"
                done
                
                # If we don't have an issue title yet, use the most recent PR title
                if [ -z "$issue_title" ] && [ -n "$most_recent_pr_title" ]; then
                    issue_title="PR #$most_recent_pr_number: $most_recent_pr_title"
                fi
            fi
            pr_urls="${pr_urls}]"
            
            # Get git info using common function
            branch_repo_dir=~/node-red-deployments-$branch
            git_info=$(get_container_git_info "$branch" "$branch_repo_dir" "$GITHUB_REPO")
            IFS='|' read -r commit_short commit_hash commit_url branch_url <<< "$git_info"
            
            # Generate container entry
            cat >> containers.json << CONTAINER_EOF
    {
        "name": "${issue_title:-$branch}",
        "image": "$image",
        "created": "$created",
        "url": "https://$name.${TAILNET}.ts.net",
        "issue_url": "$issue_url",
        "issue_title": "$issue_title",
        "pr_urls": $pr_urls,
        "pr_numbers": "$pr_list",
        "branch": "$branch",
        "commit": "$commit_short",
        "commit_url": "$commit_url",
        "branch_url": "$branch_url",
        "is_claude": $is_claude
    }
CONTAINER_EOF
        done
        
        echo "" >> containers.json
        echo "  ]" >> containers.json
        echo "}" >> containers.json
        
        log "Generated containers.json with $(echo "$containers" | wc -l) containers"
    else
        # Create empty containers.json when no containers are running
        log "${YELLOW}⚠️  No containers found, generating empty dashboard${NC}"
        echo '{"generated":"'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'","containers":[]}' > containers.json
    fi
    
    # Generate dashboard HTML
    generate_dashboard_html
}

# Function to cleanup old Claude experiments (7-day TTL)
cleanup_old_claude_experiments() {
    log "Checking for expired Claude experiments..."
    
    # Find all containers with the nr-experiment label
    local containers=$(docker ps -q --filter "label=nr-experiment=true" 2>/dev/null || true)
    local removed_count=0
    
    if [ -n "$containers" ]; then
        for container in $containers; do
            # Get branch name from container label
            local branch=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project"}}' "$container" | sed 's/^nr-//')
            
            # Check if it's a Claude branch (sanitized name starts with claude-)
            if [[ "$branch" == claude-* ]]; then
                # Get container creation time
                local created=$(docker inspect --format='{{.State.StartedAt}}' "$container")
                local created_timestamp=$(date -d "$created" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${created%%.*}" +%s 2>/dev/null || echo "0")
                local current_timestamp=$(date +%s)
                
                # Calculate age in days
                local age_seconds=$((current_timestamp - created_timestamp))
                local age_days=$((age_seconds / 86400))
                
                # Check if older than 7 days
                if [ "$age_days" -gt 7 ]; then
                    log "Removing expired Claude experiment: $branch (${age_days} days old)"
                    
                    # Navigate to deployment directory
                    local deployment_dir="$HOME/node-red-deployments-$branch"
                    if [ -d "$deployment_dir" ]; then
                        cd "$deployment_dir"
                        
                        # Stop and remove containers
                        docker compose down 2>/dev/null || true
                        
                        # Notify GitHub issue about removal (if GITHUB_TOKEN is available)
                        if [ -n "${GITHUB_TOKEN:-}" ]; then
                            notify_issue_removal "$branch" "TTL_EXPIRED" "$age_days"
                        fi
                        
                        # Remove deployment directory
                        cd ~
                        rm -rf "$deployment_dir"
                        
                        removed_count=$((removed_count + 1))
                    fi
                fi
            fi
        done
    fi
    
    if [ "$removed_count" -gt 0 ]; then
        log "Removed $removed_count expired Claude experiment(s)"
    else
        log "No expired Claude experiments found"
    fi
}

# Function to notify GitHub issue about experiment removal
notify_issue_removal() {
    local branch=$1
    local reason=$2  # "TTL_EXPIRED" or "MANUAL_CLEANUP"
    local age_days=$3
    
    # Extract issue number from branch name (claude-issue-XX-...)
    if [[ "$branch" =~ claude-issue-([0-9]+) ]]; then
        local issue_number="${BASH_REMATCH[1]}"
        
        # Prepare message based on reason
        local message=""
        if [ "$reason" = "TTL_EXPIRED" ]; then
            message="**Experiment Auto-Removed**

This experiment has been automatically removed after ${age_days} days (7-day TTL exceeded)."
        else
            message="**Experiment Manually Removed**

This experiment has been manually removed after ${age_days} days of runtime."
        fi
        
        # Add metadata to message
        local full_message="${message}

_Branch: \`${branch}\`_
_Removed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')_"
        
        # Post to GitHub issue
        local api_url="https://api.github.com/repos/dimitrieh/node-red/issues/${issue_number}/comments"
        
        # Use jq to properly escape the JSON if available, otherwise use printf
        if command -v jq >/dev/null 2>&1; then
            local body=$(echo "$full_message" | jq -R -s '{body: .}')
        else
            # Fallback: manually escape
            local escaped_message=$(printf '%s' "$full_message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g')
            local body="{\"body\": \"${escaped_message}\"}"
        fi
        
        if response=$(curl -s -X POST \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "$api_url" \
            -d "$body" 2>&1); then
            # Check if response contains an error
            if echo "$response" | grep -q '"message"'; then
                log "${YELLOW}⚠️  Failed to notify issue #${issue_number} about removal: $(echo "$response" | grep '"message"' | head -1)${NC}"
            else
                log "${GREEN}✅ Notified issue #${issue_number} about removal${NC}"
            fi
        else
            log "${YELLOW}⚠️  Failed to notify issue #${issue_number} about removal${NC}"
        fi
    fi
}

# Function to notify GitHub issue about successful deployment
notify_deployment_success() {
    local branch=$BRANCH_NAME
    
    # Only notify for Claude branches
    if [[ "$branch" =~ ^claude-issue-([0-9]+) ]]; then
        local issue_number="${BASH_REMATCH[1]}"
        
        # Only notify if GITHUB_TOKEN is available
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            local deployment_url="https://nr-${branch}.${TAILNET}.ts.net"
            local dashboard_url="https://dashboard.${TAILNET}.ts.net"
            
            # Reconstruct original branch name for GitHub API and PR URL
            local original_branch="${GIT_BRANCH_NAME:-}"
            if [ -z "$original_branch" ]; then
                # If GIT_BRANCH_NAME not available, reconstruct from sanitized name
                original_branch=$(echo "$branch" | sed 's/^claude-/claude\//')
            fi
            
            # Check if PR already exists for this branch
            local pr_section=""
            local pr_api_url="https://api.github.com/repos/dimitrieh/node-red/pulls?head=dimitrieh:${original_branch}&state=all"
            
            if pr_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                             -H "Accept: application/vnd.github.v3+json" \
                             "$pr_api_url" 2>&1); then
                
                # Check if we have jq available (should be in GitHub Actions)
                if command -v jq >/dev/null 2>&1; then
                    local pr_count=$(echo "$pr_response" | jq '. | length' 2>/dev/null || echo "0")
                    
                    if [ "$pr_count" -gt "0" ]; then
                        # PR exists, get details of the first (most recent) one
                        local pr_number=$(echo "$pr_response" | jq -r '.[0].number' 2>/dev/null)
                        local pr_url=$(echo "$pr_response" | jq -r '.[0].html_url' 2>/dev/null)
                        local pr_state=$(echo "$pr_response" | jq -r '.[0].state' 2>/dev/null)
                        local pr_merged=$(echo "$pr_response" | jq -r '.[0].merged' 2>/dev/null)
                        
                        if [ "$pr_state" = "open" ]; then
                            # If there's an open PR, post to PR instead of issue
                            log "${GREEN}✅ Open PR #${pr_number} exists - posting to PR instead of issue${NC}"
                            log "${CYAN}📋 PR URL: ${pr_url}${NC}"
                            
                            # Post deployment notification to PR
                            local pr_message="**Experiment Deployed**

Your Node-RED experiment is now live at:
${deployment_url}

View all experiments: ${dashboard_url}

This deployment will automatically expire in 7 days.

---

_Branch: \`${branch}\`_
_Deployed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')_"
                            
                            local pr_comment_url="https://api.github.com/repos/dimitrieh/node-red/issues/${pr_number}/comments"
                            
                            # Use jq to properly escape the JSON if available, otherwise use printf
                            if command -v jq >/dev/null 2>&1; then
                                local body=$(echo "$pr_message" | jq -R -s '{body: .}')
                            else
                                # Fallback: manually escape using printf
                                local escaped_message=$(printf '%s' "$pr_message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g')
                                local body="{\"body\": \"${escaped_message}\"}"
                            fi
                            
                            if response=$(curl -s -X POST \
                                -H "Authorization: token $GITHUB_TOKEN" \
                                -H "Accept: application/vnd.github.v3+json" \
                                "$pr_comment_url" \
                                -d "$body" 2>&1); then
                                # Check if response contains an error
                                if echo "$response" | grep -q '"message"'; then
                                    log "${YELLOW}⚠️  Failed to notify PR #${pr_number}: $(echo "$response" | grep '"message"' | head -1)${NC}"
                                else
                                    log "${GREEN}✅ Notified PR #${pr_number} about deployment${NC}"
                                fi
                            else
                                log "${YELLOW}⚠️  Failed to notify PR #${pr_number} about deployment${NC}"
                            fi
                            
                            return 0
                        elif [ "$pr_merged" = "true" ]; then
                            pr_section="

---

**Previous Pull Request:** [#${pr_number}](${pr_url}) (Merged)

**Create new PR via URL:**
https://github.com/dimitrieh/node-red/compare/experiment-template...${original_branch}?expand=1"
                        else
                            pr_section="

---

**Previous Pull Request:** [#${pr_number}](${pr_url}) (Closed)

**Create new PR via URL:**
https://github.com/dimitrieh/node-red/compare/experiment-template...${original_branch}?expand=1"
                        fi
                    else
                        # No PR exists, suggest creating one
                        pr_section="

---

**Create PR via URL (Avoids fork detection)**

Go directly to:
https://github.com/dimitrieh/node-red/compare/experiment-template...${original_branch}?expand=1

This URL pattern keeps it within your repo."
                    fi
                else
                    # jq not available, fallback to simple grep check
                    if echo "$pr_response" | grep -q '"number"'; then
                        # At least one PR exists, but can't parse details
                        pr_section="

---

**Note:** A pull request may already exist for this branch. Check: https://github.com/dimitrieh/node-red/pulls?q=head:${original_branch}"
                    else
                        # Likely no PR exists
                        pr_section="

---

**Create PR via URL (Avoids fork detection)**

Go directly to:
https://github.com/dimitrieh/node-red/compare/experiment-template...${original_branch}?expand=1

This URL pattern keeps it within your repo."
                    fi
                fi
            else
                # API call failed, provide fallback
                pr_section="

---

**Create PR via URL (Avoids fork detection)**

Go directly to:
https://github.com/dimitrieh/node-red/compare/experiment-template...${original_branch}?expand=1

This URL pattern keeps it within your repo."
            fi
            
            local message="**Experiment Deployed**

Your Node-RED experiment is now live at:
${deployment_url}

View all experiments: ${dashboard_url}

This deployment will automatically expire in 7 days.${pr_section}"
            
            # Add metadata to message
            local full_message="${message}

---

_Branch: \`${branch}\`_
_Deployed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')_"
            
            # Post deployment notification
            local api_url="https://api.github.com/repos/dimitrieh/node-red/issues/${issue_number}/comments"
            
            # Use jq to properly escape the JSON if available, otherwise use printf
            if command -v jq >/dev/null 2>&1; then
                local body=$(echo "$full_message" | jq -R -s '{body: .}')
            else
                # Fallback: manually escape using printf
                local escaped_message=$(printf '%s' "$full_message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g')
                local body="{\"body\": \"${escaped_message}\"}"
            fi
            
            if response=$(curl -s -X POST \
                -H "Authorization: token $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github.v3+json" \
                "$api_url" \
                -d "$body" 2>&1); then
                # Check if response contains an error
                if echo "$response" | grep -q '"message"'; then
                    log "${YELLOW}⚠️  Failed to notify issue #${issue_number}: $(echo "$response" | grep '"message"' | head -1)${NC}"
                else
                    log "${GREEN}✅ Notified issue #${issue_number} about deployment${NC}"
                fi
            else
                log "${YELLOW}⚠️  Failed to notify issue #${issue_number} about deployment${NC}"
            fi
        fi
    fi
}

# Function to prepare and copy all dashboard files to volumes
prepare_and_copy_dashboard_files() {
    log "Preparing and copying dashboard files to volumes..."
    
    # Ensure Tailscale config exists
    if [ ! -f "tailscale-serve-dashboard.json" ]; then
        generate_tailscale_serve_config "dashboard" "http://dashboard:80" "tailscale-serve-dashboard.json"
    fi
    
    generate_nginx_config
    
    # Copy config files (tailscale serve config and nginx config)
    docker run --rm -v global-dashboard_dashboard_config:/config -v "$(pwd):/source" alpine:latest sh -c "
        cp /source/tailscale-serve-dashboard.json /config/ &&
        cp /source/nginx-dashboard.conf /config/default.conf
    "
    
    # Copy content files (dashboard HTML and containers data)
    docker run --rm -v global-dashboard_dashboard_content:/content -v "$(pwd):/source" alpine:latest sh -c "
        cp /source/dashboard.html /content/index.html &&
        cp /source/containers.json /content/containers.json
    "
}

# Function to clean up temporary dashboard files
cleanup_dashboard_files() {
    rm -f dashboard.html containers.json nginx-dashboard.conf tailscale-serve-dashboard.json
}

# ============================================================================
# DISPLAY FUNCTIONS
# ============================================================================

# Function to display deployment info
show_deployment_info() {
    echo -e "${BLUE}=== Node-RED Deployment for Branch: $BRANCH_NAME ===${NC}"
    echo
    echo "Docker Configuration:"
    echo "  - Node-RED Container:    nr-$BRANCH_NAME"
    echo "  - Tailscale Container:   nr-$BRANCH_NAME-tailscale"
    echo "  - Network:               nr-$BRANCH_NAME-net"
    echo "  - Node-RED Data Volume:  nr_${BRANCH_NAME}_data"
    echo "  - Tailscale Volume:      nr_${BRANCH_NAME}_tailscale"
    echo
    echo "Networking:"
    echo "  - Internal Node-RED:     http://node-red:1880 (within Docker network)"
    echo "  - Tailscale Hostname:    nr-$BRANCH_NAME"
    echo "  - External Access:       https://nr-$BRANCH_NAME.${TAILNET:-[your-tailnet]}.ts.net"
    echo
    echo "Tailscale Configuration:"
    echo "  - Tag: nr-experiment"
    echo "  - Serves HTTPS on port 443"
    echo "  - Proxies all requests (/) to internal Node-RED on port 1880"
    echo "  - Includes Tailscale state validation and automatic stale state cleanup"
    echo
}

# ============================================================================
# DEPLOYMENT FUNCTIONS
# ============================================================================

# Configuration
DEPLOY_MODE="${DEPLOY_MODE:-local}"
HETZNER_HOST="${HETZNER_HOST:-your-server-ip}"
HETZNER_USER="${HETZNER_USER:-root}"
HETZNER_SSH_KEY="${HETZNER_SSH_KEY:-~/.ssh/id_rsa}"
CONTAINER_TAG="nr-experiment"
GITHUB_REPO="${GITHUB_REPO:-dimitrieh/node-red}"
GITHUB_ISSUES_REPO="${GITHUB_ISSUES_REPO:-node-red/node-red}"

# Parse command line flags
REMOVE_DASHBOARD=false
for arg in "$@"; do
    case $arg in
        --remove-dashboard)
            REMOVE_DASHBOARD=true
            shift
            ;;
    esac
done

# Function for local deployment
deploy_local() {
    log "${GREEN}🏠 Local Deployment Mode${NC}"
    
    # Setup survey for issue branches
    setup_issue_survey "$BRANCH_NAME"
    
    # Build Docker image if needed
    if [ "$1" = "up" ] || [ "$1" = "" ] || ! docker image inspect "nr-demo:$BRANCH_NAME" >/dev/null 2>&1; then
        log "${BLUE}Building Docker image for branch: $BRANCH_NAME${NC}"
        echo "  - Base Image:        node:18-alpine"
        echo "  - Target Image:      nr-demo:$BRANCH_NAME"
        echo "  - Security:          Non-root user, read-only filesystem"
        echo "  - Demo Settings:     Embedded in Docker image (inline configuration)"
        echo
        docker build -t "nr-demo:$BRANCH_NAME" .
        log "${GREEN}✅ Docker image built: nr-demo:$BRANCH_NAME${NC}"
    fi
    
    # Create branch-specific docker-compose file from template
    COMPOSE_FILE="docker-compose-$BRANCH_NAME.yml"
    log "Creating $COMPOSE_FILE from template"
    sed -e "s/BRANCH_PLACEHOLDER/$BRANCH_NAME/g" \
        docker-compose.template.yml > "$COMPOSE_FILE"
    
    # Generate Tailscale serve configuration for Node-RED
    log "Generating Tailscale serve configuration..."
    generate_tailscale_serve_config "nr-$BRANCH_NAME" "http://node-red:1880" "tailscale-serve.json"
    
    # Run docker-compose
    if [ "$1" = "up" ] || [ "$1" = "" ]; then
        log "Running: docker compose -f $COMPOSE_FILE up -d"
        env TS_AUTHKEY="$TS_AUTHKEY" TALLY_SURVEY_ID="$TALLY_SURVEY_ID" docker compose -f "$COMPOSE_FILE" up -d
        
        # Validate Tailscale connection and retry if needed
        validate_and_retry_tailscale "nr-$BRANCH_NAME-tailscale" "nr_${BRANCH_NAME}_tailscale" "$COMPOSE_FILE" "tailscale"
    else
        log "Running: docker compose -f $COMPOSE_FILE $*"
        env TS_AUTHKEY="$TS_AUTHKEY" TALLY_SURVEY_ID="$TALLY_SURVEY_ID" docker compose -f "$COMPOSE_FILE" "$@"
    fi
    
    if [ "$1" = "up" ] || [ "$1" = "" ]; then
        echo
        log "${GREEN}✅ Local Deployment complete!${NC}"
        echo "   Access Node-RED at: https://nr-$BRANCH_NAME.${TAILNET:-[your-tailnet]}.ts.net"
    elif [ "$1" = "down" ]; then
        log "${BLUE}🧹 Cleaning up local resources...${NC}"
        
        # Remove volumes
        remove_volumes "nr_${BRANCH_NAME}_data" "nr_${BRANCH_NAME}_tailscale"
        
        # Remove branch-specific image
        log "Removing image: nr-demo:$BRANCH_NAME"
        docker image rm "nr-demo:$BRANCH_NAME" 2>/dev/null || true
        
        # Prune unused images
        log "Pruning unused images..."
        docker image prune -f
        
        # Remove generated files
        log "Removing generated files..."
        rm -f "$COMPOSE_FILE" tailscale-serve.json
        
        echo
        log "${GREEN}✅ Local cleanup complete!${NC}"
        echo "   Removed containers, volumes, images, and generated files for branch: $BRANCH_NAME"
    fi
}

# Function for remote deployment to Hetzner
deploy_remote() {
    log "${GREEN}🚀 Remote Deployment Mode (Hetzner)${NC}"
    echo "  - Host: $HETZNER_HOST"
    echo "  - User: $HETZNER_USER"
    echo "  - Branch: $BRANCH_NAME"
    echo
    
    # Validate configuration before proceeding
    if ! validate_config; then
        exit 1
    fi
    
    # Check branch sync for remote deployment
    check_branch_sync
    
    # Check if required environment variables are set
    if [ -z "$HETZNER_HOST" ] || [ "$HETZNER_HOST" = "your-server-ip" ]; then
        log "${RED}❌ HETZNER_HOST not set!${NC}"
        echo "   Set with: export HETZNER_HOST=your-server-ip"
        exit 1
    fi
    
    if ! check_ts_authkey; then
        log "${RED}❌ TS_AUTHKEY is required for remote deployment!${NC}"
        log "   Check ~/.localtailscalerc configuration."
        exit 1
    fi
    
    # Validate other required variables
    if [ -z "$GITHUB_REPO" ]; then
        log "${RED}❌ GITHUB_REPO not set!${NC}"
        exit 1
    fi
    
    if [ -z "$GITHUB_ISSUES_REPO" ]; then
        log "${RED}❌ GITHUB_ISSUES_REPO not set!${NC}"
        exit 1
    fi
    
    # Get git remote URL
    GIT_REMOTE=$(git config --get remote.origin.url 2>/dev/null || echo "")
    if [ -z "$GIT_REMOTE" ]; then
        log "${RED}❌ No git remote origin found. Cannot deploy via git.${NC}"
        exit 1
    fi
    
    # Convert SSH URL to HTTPS for public repos
    if [[ "$GIT_REMOTE" == git@github.com:* ]]; then
        GIT_REMOTE="https://github.com/${GIT_REMOTE#git@github.com:}"
        log "📡 Git remote (converted to HTTPS): $GIT_REMOTE"
    else
        log "📡 Git remote: $GIT_REMOTE"
    fi
    
    # Deploy via single SSH session
    log "${BLUE}🔨 Deploying to Hetzner server...${NC}"
    
    # Validate TAILNET is set from config
    if [ -z "$TAILNET" ]; then
        log "${RED}❌ TAILNET not set! Check ~/.localtailscalerc configuration.${NC}"
        exit 1
    fi
    TAILNET_TO_PASS="$TAILNET"
    
    log "📋 Deployment variables:"
    log "   Branch: $BRANCH_NAME"
    log "   Tailnet: $TAILNET_TO_PASS"
    log "   Git Remote: $GIT_REMOTE"
    log "   GitHub Repo: $GITHUB_REPO"
    log "   Remove Dashboard: $REMOVE_DASHBOARD"
    log "   TS_AUTHKEY: ${TS_AUTHKEY:+SET (${#TS_AUTHKEY} chars)}"
    log "   TALLY_TOKEN: ${TALLY_TOKEN:+SET (${#TALLY_TOKEN} chars)}"
    echo
    
    # Copy the deploy-dry.sh script to remote and execute it
    scp -i "$HETZNER_SSH_KEY" "$0" "$HETZNER_USER@$HETZNER_HOST:/tmp/deploy-dry.sh"
    
    # Pass all required variables as environment variables to remote script
    ssh -i "$HETZNER_SSH_KEY" "$HETZNER_USER@$HETZNER_HOST" \
        "export BRANCH_NAME='$BRANCH_NAME' && \
         export GIT_BRANCH_NAME='$GIT_BRANCH_NAME' && \
         export TS_AUTHKEY='$TS_AUTHKEY' && \
         export TALLY_TOKEN='$TALLY_TOKEN' && \
         export GITHUB_TOKEN='$GITHUB_TOKEN' && \
         export TAILNET='$TAILNET_TO_PASS' && \
         export GIT_REMOTE='$GIT_REMOTE' && \
         export GITHUB_REPO='$GITHUB_REPO' && \
         export GITHUB_ISSUES_REPO='$GITHUB_ISSUES_REPO' && \
         export REMOVE_DASHBOARD='$REMOVE_DASHBOARD' && \
         export DEPLOY_MODE='remote_execution' && \
         bash /tmp/deploy-dry.sh $@"
    
    # Check SSH command exit status
    SSH_EXIT_CODE=$?
    if [ $SSH_EXIT_CODE -eq 0 ]; then
        # SSH command succeeded
        if [ "$1" = "up" ] || [ "$1" = "" ]; then
            echo
            log "${GREEN}✅ Remote Deployment complete!${NC}"
            echo "   Server: $HETZNER_HOST"
            echo "   Node-RED: https://nr-$BRANCH_NAME.${TAILNET:-[your-tailnet]}.ts.net"
            echo "   Dashboard: https://dashboard.${TAILNET:-[your-tailnet]}.ts.net"
        elif [ "$1" = "down" ]; then
            echo
            log "${GREEN}✅ Remote cleanup complete!${NC}"
            echo "   Server: $HETZNER_HOST"
            echo "   All traces of branch '$BRANCH_NAME' deployment have been removed"
            if [ "$REMOVE_DASHBOARD" = "true" ]; then
                echo "   Dashboard has been completely removed (no trace left)"
            else
                echo "   Dashboard remains running with updated content"
            fi
        fi
    else
        # SSH command failed
        log "${RED}❌ Remote deployment failed! (Exit code: $SSH_EXIT_CODE)${NC}"
        exit $SSH_EXIT_CODE
    fi
}

# Function for remote execution (when script is running on remote server)
deploy_remote_execution() {
    log "${BLUE}=== Remote Script Execution ===${NC}"
    log "📋 Received variables:"
    log "   Branch: $BRANCH_NAME"
    log "   Tailnet: $TAILNET"
    log "   Git Remote: $GIT_REMOTE"
    log "   Remove Dashboard: $REMOVE_DASHBOARD"
    log "   TS_AUTHKEY: ${TS_AUTHKEY:+SET (${#TS_AUTHKEY} chars)}"
    log "   TALLY_TOKEN: ${TALLY_TOKEN:+SET (${#TALLY_TOKEN} chars)}"
    
    # Validate critical variables were received
    if [ -z "$TS_AUTHKEY" ]; then
        log "${RED}❌ TS_AUTHKEY not received by remote script!${NC}"
        exit 1
    fi
    
    if [ -z "$TAILNET" ]; then
        log "${RED}❌ TAILNET not received by remote script!${NC}"
        exit 1
    fi
    
    echo
    
    # Ensure Docker and git are installed
    ensure_docker
    ensure_git
    
    # Set deployment directory
    REPO_DIR=~/node-red-deployments-$BRANCH_NAME
    
    # Only build and deploy for 'up' commands
    if [[ "$@" == *"up"* ]]; then
        log "${BLUE}🔄 Updating code and building...${NC}"
        
        # Git-first approach: handle repository operations
        GIT_SUCCESS=false
        if [ -d "$REPO_DIR/.git" ]; then
            log "Repository exists, updating..."
            cd "$REPO_DIR"
            if git fetch origin && git checkout "${GIT_BRANCH_NAME:-$BRANCH_NAME}" && git reset --hard "origin/${GIT_BRANCH_NAME:-$BRANCH_NAME}"; then
                GIT_SUCCESS=true
            else
                log "${RED}Failed to update existing repository${NC}"
            fi
        else
            log "No valid git repository found"
            if [ -d "$REPO_DIR" ]; then
                log "Removing corrupted directory..."
                rm -rf "$REPO_DIR"
            fi
            log "Cloning repository..."
            if git clone "$GIT_REMOTE" "$REPO_DIR"; then
                cd "$REPO_DIR"
                if git checkout "${GIT_BRANCH_NAME:-$BRANCH_NAME}"; then
                    GIT_SUCCESS=true
                else
                    log "${RED}Failed to checkout branch ${GIT_BRANCH_NAME:-$BRANCH_NAME}${NC}"
                fi
            else
                log "${RED}Failed to clone repository${NC}"
            fi
        fi
        
        if [ "$GIT_SUCCESS" != true ]; then
            log "${RED}❌ Git operations failed, exiting${NC}"
            exit 1
        fi
        
        # Setup survey for issue branches
        setup_issue_survey "$BRANCH_NAME"
        
        # Generate docker-compose file from template
        log "Generating docker-compose.yml from template..."
        sed -e "s/BRANCH_PLACEHOLDER/$BRANCH_NAME/g" \
            docker-compose.template.yml > docker-compose.yml
        
        # Generate Tailscale serve configurations
        log "Generating Tailscale serve configurations..."
        generate_tailscale_serve_config "nr-$BRANCH_NAME" "http://node-red:1880" "tailscale-serve.json" "$TAILNET"
        generate_tailscale_serve_config "dashboard" "http://dashboard:80" "tailscale-serve-dashboard.json" "$TAILNET"
        
        # Build Docker image
        log "${BLUE}Building Docker image: nr-demo:$BRANCH_NAME${NC}"
        docker build -f Dockerfile -t "nr-demo:$BRANCH_NAME" .
        
        # Clean up dangling images
        docker system prune -f
        
        # Deploy with docker-compose
        log "${BLUE}Deploying with docker-compose...${NC}"
        if env TS_AUTHKEY="$TS_AUTHKEY" TALLY_SURVEY_ID="$TALLY_SURVEY_ID" docker compose -f docker-compose.yml up -d; then
            log "${GREEN}✅ Main deployment successful${NC}"
            
            # Validate Tailscale connection and retry if needed
            if ! validate_and_retry_tailscale "nr-$BRANCH_NAME-tailscale" "" "docker-compose.yml" "tailscale"; then
                log "${RED}❌ Tailscale validation failed, deployment aborted${NC}"
                exit 1
            fi
        else
            log "${RED}❌ Main deployment failed${NC}"
            exit 1
        fi
        
        # Cleanup old Claude experiments (after deployment, before dashboard)
        cleanup_old_claude_experiments
        
        # Deploy dashboard if dashboard config exists
        if [ -f "docker-compose-dashboard.yml" ]; then
            log "${BLUE}Generating and deploying dashboard...${NC}"
            
            # Generate dashboard content
            generate_dashboard_content
            
            # Deploy dashboard
            log "Deploying dashboard container..."
            env TS_AUTHKEY="$TS_AUTHKEY" docker compose -f docker-compose-dashboard.yml up -d
            
            # Copy dashboard files to volumes
            prepare_and_copy_dashboard_files
            
            # Validate dashboard Tailscale connection
            if ! validate_and_retry_tailscale "dashboard-tailscale" "" "docker-compose-dashboard.yml" "dashboard-tailscale"; then
                log "${YELLOW}⚠️  Dashboard Tailscale validation failed, but continuing...${NC}"
            fi
            
            # Clean up generated files
            cleanup_dashboard_files
            
            log "${GREEN}✅ Dashboard deployed successfully${NC}"
            
            # Notify GitHub issue about deployment (after dashboard is ready)
            notify_deployment_success
        else
            log "${YELLOW}⚠️  docker-compose-dashboard.yml not found, skipping dashboard deployment${NC}"
            
            # Still notify even if no dashboard
            notify_deployment_success
        fi
        
    else
        log "${BLUE}⏭️  Handling '$@' command${NC}"
        
        # Check if deployment directory exists
        if [ ! -d "$REPO_DIR" ]; then
            log "${YELLOW}⚠️  No deployment directory found for branch $BRANCH_NAME${NC}"
            if [[ "$@" == *"down"* ]]; then
                log "Nothing to clean up for branch $BRANCH_NAME"
                exit 0
            else
                exit 1
            fi
        fi
        
        cd "$REPO_DIR"
        
        # Run the docker command
        if [[ "$@" == *"down"* ]]; then
            # For down commands
            if [ -f "docker-compose.yml" ]; then
                log "Running: docker compose down"
                env TS_AUTHKEY="$TS_AUTHKEY" docker compose -f docker-compose.yml down 2>/dev/null || true
            else
                log "docker-compose.yml not found, cleaning up by container/project names..."
                # Stop and remove containers by project name
                docker stop $(docker ps -q --filter "label=com.docker.compose.project=nr-$BRANCH_NAME") 2>/dev/null || true
                docker rm $(docker ps -aq --filter "label=com.docker.compose.project=nr-$BRANCH_NAME") 2>/dev/null || true
                # Remove networks by project name
                docker network rm "nr-${BRANCH_NAME}_nr-${BRANCH_NAME}-net" 2>/dev/null || true
            fi
            
            log "${BLUE}🧹 Performing full cleanup for branch $BRANCH_NAME...${NC}"
            
            # Remove branch-specific image
            log "Removing image: nr-demo:$BRANCH_NAME"
            docker image rm "nr-demo:$BRANCH_NAME" 2>/dev/null || true
            
            # Handle dashboard based on REMOVE_DASHBOARD flag
            if [ "$REMOVE_DASHBOARD" = "true" ]; then
                log "${BLUE}🗑️  Removing dashboard completely...${NC}"
                
                # Stop and remove dashboard
                if [ -f "docker-compose-dashboard.yml" ]; then
                    docker compose -f docker-compose-dashboard.yml down 2>/dev/null || true
                fi
                
                # Remove dashboard volumes
                remove_volumes "global-dashboard_dashboard_content" "global-dashboard_dashboard_config" "global-dashboard_dashboard_tailscale"
                
                # Remove dashboard network
                docker network rm global-dashboard_dashboard-net 2>/dev/null || true
                
                log "${GREEN}✅ Dashboard completely removed${NC}"
                
            elif [ -f "docker-compose-dashboard.yml" ]; then
                log "${BLUE}Updating dashboard to reflect current server state...${NC}"
                
                # Copy dashboard compose file to home directory for safe access
                cp docker-compose-dashboard.yml ~/docker-compose-dashboard.yml
                
                # Temporarily move to home to generate dashboard content
                cd ~
                
                # Generate updated dashboard content (server-wide scan)
                generate_dashboard_content
                
                # Update dashboard with fresh data
                docker stop dashboard 2>/dev/null || true
                docker rm dashboard 2>/dev/null || true
                remove_volumes "global-dashboard_dashboard_content" "global-dashboard_dashboard_config"
                
                env TS_AUTHKEY="$TS_AUTHKEY" docker compose -f ~/node-red-deployments-$BRANCH_NAME/docker-compose-dashboard.yml up -d dashboard
                
                prepare_and_copy_dashboard_files
                cleanup_dashboard_files
                
                log "${GREEN}✅ Dashboard updated successfully${NC}"
            fi
            
            # Selective cleanup
            log "Performing selective docker cleanup..."
            docker image prune -af
            docker container prune -f
            
            # Remove the entire deployment directory
            log "Removing deployment directory: $REPO_DIR"
            rm -rf "$REPO_DIR"
            
            log "${GREEN}✅ Full cleanup complete for branch $BRANCH_NAME${NC}"
        else
            # For other commands
            log "Running: docker compose $@"
            env TS_AUTHKEY="$TS_AUTHKEY" TALLY_SURVEY_ID="$TALLY_SURVEY_ID" docker compose -f docker-compose.yml "$@"
        fi
    fi
    
    # Clean up sensitive data from bash history
    log "${BLUE}🧹 Cleaning up sensitive data from history...${NC}"
    sed -i '/TS_AUTHKEY/d' ~/.bash_history 2>/dev/null || true
    sed -i '/TALLY_TOKEN/d' ~/.bash_history 2>/dev/null || true
    history -c 2>/dev/null || true
    log "${GREEN}✅ History cleaned${NC}"
    
    log "${GREEN}=== Remote script completed ===${NC}"
}

# ============================================================================
# MAIN SCRIPT EXECUTION
# ============================================================================

# Only execute main logic if not being sourced for testing
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ] && [ "$DEPLOY_MODE" != "test" ]; then
    # Check if we're running in remote execution mode
    if [ "$DEPLOY_MODE" = "remote_execution" ]; then
        # We're running on the remote server
        deploy_remote_execution "$@"
    else
        # We're running locally
        # Get branch name first (only for local execution)
        get_branch_name
        
        # Run safety checks first
        check_uncommitted_changes
        
        show_deployment_info
        
        # Export for docker-compose
        export BRANCH_NAME
        
        # Determine deployment mode and execute
        if [ "$DEPLOY_MODE" = "remote" ] || [ "$DEPLOY_MODE" = "hetzner" ]; then
            deploy_remote "$@"
        else
            deploy_local "$@"
        fi
    fi
fi