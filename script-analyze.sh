#!/bin/bash
set -euo pipefail

# =====================================================================
# Analysis Script - Build Stage
# This script analyzes what alarms need to be created or deleted
# Outputs: plan.txt (list of actions to take)
# NO EXTERNAL DEPENDENCIES - Pure bash only
# =====================================================================

AWS_REGION="${AWS_REGION:-us-east-1}"
ALARM_SUFFIX="-cloudwatch-alarm"
ALARM_THRESHOLD="${ALARM_THRESHOLD:-5}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# =====================================================================
# Helper Functions
# =====================================================================

extract_queue_name() {
    echo "$1" | awk -F'/' '{print $NF}'
}

is_dlq() {
    [[ "$1" =~ -dlq$ || "$1" =~ -dead-letter$ || "$1" =~ _dlq$ ]]
}

get_threshold() {
    if is_dlq "$1"; then echo "1"; else echo "$ALARM_THRESHOLD"; fi
}

# =====================================================================
# Fetch Data
# =====================================================================

get_sqs_queues() {
    aws sqs list-queues \
        --region "$AWS_REGION" \
        --query 'QueueUrls' \
        --output text 2>/dev/null || echo ""
}

get_cloudwatch_alarms() {
    aws cloudwatch describe-alarms \
        --region "$AWS_REGION" \
        --query "MetricAlarms[?contains(AlarmName,'${ALARM_SUFFIX}')].AlarmName" \
        --output text 2>/dev/null || echo ""
}

# =====================================================================
# Main Analysis
# =====================================================================

main() {
    log "=========================================="
    log "Build Stage: Analyzing SQS Queues"
    log "=========================================="
    
    log "Fetching SQS queues..."
    queues=$(get_sqs_queues)
    
    log "Fetching CloudWatch alarms..."
    alarms=$(get_cloudwatch_alarms)
    
    # Build maps
    declare -A queue_map
    declare -A alarm_map
    
    # Populate queue map
    if [ -n "$queues" ]; then
        for url in $queues; do
            q=$(extract_queue_name "$url")
            queue_map["$q"]=1
        done
    fi
    
    # Populate alarm map
    if [ -n "$alarms" ]; then
        for alarm in $alarms; do
            alarm_map["$alarm"]=1
        done
    fi
    
    # Prepare plan file
    > plan.txt  # Clear file
    echo "REGION=$AWS_REGION" >> plan.txt
    echo "ALARM_SUFFIX=$ALARM_SUFFIX" >> plan.txt
    echo "---CREATE---" >> plan.txt
    
    create_count=0
    delete_count=0
    
    log ""
    log "Analyzing differences..."
    
    # Find alarms to create (only if we have queues)
    if [ ${#queue_map[@]} -gt 0 ]; then
        for q in "${!queue_map[@]}"; do
            expected_alarm="${q}${ALARM_SUFFIX}"
            if [[ -z "${alarm_map[$expected_alarm]:-}" ]]; then
                threshold=$(get_threshold "$q")
                echo "$q|$expected_alarm|$threshold" >> plan.txt
                log "  [CREATE] $expected_alarm (threshold: $threshold)"
                ((create_count++))
            fi
        done
    fi
    
    echo "---DELETE---" >> plan.txt
    
    # Find alarms to delete (only if we have alarms)
    if [ ${#alarm_map[@]} -gt 0 ]; then
        for alarm in "${!alarm_map[@]}"; do
            queue="${alarm%$ALARM_SUFFIX}"
            if [[ -z "${queue_map[$queue]:-}" ]]; then
                echo "$alarm" >> plan.txt
                log "  [DELETE] $alarm (orphaned)"
                ((delete_count++))
            fi
        done
    fi
    
    echo "---SUMMARY---" >> plan.txt
    echo "CREATE_COUNT=$create_count" >> plan.txt
    echo "DELETE_COUNT=$delete_count" >> plan.txt
    
    log ""
    log "Plan saved to plan.txt"
    log ""
    log "=========================================="
    log "Summary:"
    log "  Alarms to create: $create_count"
    log "  Alarms to delete: $delete_count"
    log "=========================================="
    
    # Show plan
    echo ""
    echo "=== PLAN CONTENTS ==="
    cat plan.txt
    echo "=== END PLAN ==="
    
    # Exit successfully even if no changes needed
    exit 0
}

main