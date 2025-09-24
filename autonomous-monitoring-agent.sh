#!/usr/bin/env bash
# SuperClaude Framework - Autonomous Monitoring Agent
# Integrates continuous monitoring with Claude-powered autonomous response

set -euo pipefail

# SuperClaude Framework Configuration
CLAUDE_LOG="/home/a/.claude/autonomous-monitoring.log"
AGENT_SPAWNER="/home/a/.claude/agents/spawn-agent.sh"
FINDINGS_DIR="/home/a/.claude/findings"
ACTION_THRESHOLD=3  # Number of issues before spawning Claude agent

# Ensure required directories exist
mkdir -p "$(dirname "$CLAUDE_LOG")" "$FINDINGS_DIR"

log_with_timestamp() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" | tee -a "$CLAUDE_LOG"
}

# Exception Handler: Claude agent for diagnosis only (no assumptions about fixes)
handle_exception_with_claude() {
    local error_context="$1"
    local failed_operation="$2"
    local error_details="$3"

    local exception_file="$FINDINGS_DIR/exception_$(date +%s).json"

    log_with_timestamp "🚨 EXCEPTION: $error_context failed - documenting for Claude analysis"

    # Create detailed error documentation for Claude
    cat > "$exception_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "error_context": "$error_context",
    "failed_operation": "$failed_operation",
    "error_details": "$error_details",
    "system_state": {
        "load": "$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',' || echo 'unknown')",
        "memory": "$(free 2>/dev/null | awk 'NR==2{printf "%.1f", $3*100/$2}' || echo 'unknown')%",
        "processes": $(pgrep -c . 2>/dev/null || echo 0),
        "disk_space": "$(df / 2>/dev/null | awk 'NR==2{print $5}' || echo 'unknown')"
    },
    "analysis_request": "This operation failed. Please analyze what went wrong and suggest solutions. Create a diagnostic report in .claude/diagnostics/ but do not assume you can fix it automatically."
}
EOF

    # Spawn Claude agent for analysis and documentation only
    spawn_claude_diagnostic_agent "$error_context" "$exception_file" "DIAGNOSTIC MODE: Analyze the failure in $failed_operation. Create detailed diagnostic report. Do not attempt automatic fixes - focus on understanding and documenting the problem."

    # Return failure - no retry assumptions
    return 1
}

# Claude diagnostic agent - analysis only, no assumptions about fixes
spawn_claude_diagnostic_agent() {
    local diagnostic_context="$1"
    local analysis_file="$2"
    local diagnostic_task="$3"

    log_with_timestamp "🔬 SPAWNING DIAGNOSTIC AGENT for $diagnostic_context"

    # Create diagnostics directory
    mkdir -p "/home/a/.claude/diagnostics"

    # Use SuperClaude agent spawning for diagnostic analysis only
    nix-shell -p nodejs expect --run "expect -c \"
        spawn npx @anthropic-ai/claude-code \\\"DIAGNOSTIC MODE: Analyze $analysis_file for: $diagnostic_task. Create detailed diagnostic report in .claude/diagnostics/ explaining what went wrong and possible causes. Do NOT attempt to fix anything - focus only on understanding the problem.\\\"
        expect { -re {.*bypass permissions.*} { send \\\"2\\\\r\\\" } }
        expect { -re {.*Write.*} { exit 0 } timeout { exit 1 } }
    \"" &

    local agent_pid=$!
    log_with_timestamp "Diagnostic agent spawned with PID: $agent_pid for $diagnostic_context"

    # Log diagnostic agent information
    echo "{\"type\": \"diagnostic_agent\", \"context\": \"$diagnostic_context\", \"pid\": $agent_pid, \"timestamp\": \"$(date -Iseconds)\", \"analysis_file\": \"$analysis_file\"}" > "$FINDINGS_DIR/diagnostic_agent_$agent_pid.json"
}

# Original function enhanced with auto-repair
spawn_claude_agent() {
    local issue_type="$1"
    local findings_file="$2"
    local task_description="$3"

    log_with_timestamp "🤖 SPAWNING CLAUDE AGENT for $issue_type"

    # Use SuperClaude agent spawning with nix-shell compliance
    nix-shell -p nodejs expect --run "expect -c \"
        spawn npx @anthropic-ai/claude-code \\\"Analyze findings in $findings_file and $task_description. Use nix-shell wrappers for all commands. Document solution in .claude/solutions/\\\"
        expect { -re {.*bypass permissions.*} { send \\\"2\\\\r\\\" } }
        expect { -re {.*Write.*} { exit 0 } timeout { exit 1 } }
    \"" &

    local agent_pid=$!
    log_with_timestamp "Claude agent spawned with PID: $agent_pid for $issue_type"

    # Log agent information
    echo "{\"issue\": \"$issue_type\", \"pid\": $agent_pid, \"timestamp\": \"$(date -Iseconds)\", \"findings_file\": \"$findings_file\"}" > "$FINDINGS_DIR/agent_$agent_pid.json"
}

# System health monitoring with autonomous response capability - HARDENED
monitor_system_health() {
    local findings_file="$FINDINGS_DIR/health_findings_$(date +%s).json"
    local issues=0

    # Error handling wrapper
    {
        log_with_timestamp "🔍 MONITORING: System health assessment"

        # Initialize findings JSON with error handling
        {
            echo "{\"timestamp\": \"$(date -Iseconds)\", \"findings\": [" > "$findings_file" || {
                log_with_timestamp "❌ ERROR: Cannot write to findings file"
                return 1
            }
        }

        # Check waybar status - robust exception handling only
        {
            if command -v pgrep >/dev/null 2>&1; then
                if ! pgrep waybar >/dev/null 2>&1; then
                    echo "  {\"type\": \"waybar_missing\", \"severity\": \"high\", \"description\": \"Waybar process not running\"}," >> "$findings_file" 2>/dev/null || true
                    ((issues++))
                    log_with_timestamp "❌ ISSUE: Waybar not running"
                else
                    log_with_timestamp "✅ OK: Waybar running"
                fi
            else
                log_with_timestamp "ℹ️ INFO: pgrep not available, skipping waybar check"
            fi
        } || {
            # Exception: Only call Claude when actual failure occurs
            handle_exception_with_claude "waybar_check" "waybar_status_monitoring" "Failed to check waybar status" &
            log_with_timestamp "❌ EXCEPTION: Waybar check failed - Claude diagnostic launched"
        }

        # Check display management - hardened
        {
            if command -v hyprctl >/dev/null 2>&1; then
                if ! timeout 5 hyprctl monitors >/dev/null 2>&1; then
                    echo "  {\"type\": \"display_error\", \"severity\": \"high\", \"description\": \"Hyprland display management error\"}," >> "$findings_file" 2>/dev/null || true
                    ((issues++))
                    log_with_timestamp "❌ ISSUE: Hyprland display error"
                else
                    log_with_timestamp "✅ OK: Display management functional"
                fi
            else
                log_with_timestamp "ℹ️ INFO: Hyprctl not available (expected in some environments)"
            fi
        } || {
            log_with_timestamp "❌ ERROR: Display check failed"
        }

        # Check system load - hardened
        {
            local load="0.0"
            if command -v uptime >/dev/null 2>&1; then
                load=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',' || echo "0.0")
                if command -v bc >/dev/null 2>&1 && [[ -n "$load" ]] && [[ "$load" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                    if (( $(echo "$load > 5.0" | bc -l 2>/dev/null || echo 0) )); then
                        echo "  {\"type\": \"high_load\", \"severity\": \"medium\", \"description\": \"System load is $load\"}," >> "$findings_file" 2>/dev/null || true
                        ((issues++))
                        log_with_timestamp "⚠️ ISSUE: High system load: $load"
                    else
                        log_with_timestamp "✅ OK: System load normal: $load"
                    fi
                else
                    log_with_timestamp "⚠️ WARNING: Cannot calculate load comparison"
                fi
            else
                log_with_timestamp "⚠️ WARNING: uptime command not available"
            fi
        } || {
            log_with_timestamp "❌ ERROR: Load check failed"
        }

        # Check memory usage - hardened
        {
            if command -v free >/dev/null 2>&1; then
                local mem_usage=$(free 2>/dev/null | awk 'NR==2{printf "%.1f", $3*100/$2}' 2>/dev/null || echo "0.0")
                if command -v bc >/dev/null 2>&1 && [[ -n "$mem_usage" ]] && [[ "$mem_usage" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                    if (( $(echo "$mem_usage > 90.0" | bc -l 2>/dev/null || echo 0) )); then
                        echo "  {\"type\": \"high_memory\", \"severity\": \"high\", \"description\": \"Memory usage is ${mem_usage}%\"}," >> "$findings_file" 2>/dev/null || true
                        ((issues++))
                        log_with_timestamp "❌ ISSUE: High memory usage: ${mem_usage}%"
                    else
                        log_with_timestamp "✅ OK: Memory usage normal: ${mem_usage}%"
                    fi
                else
                    log_with_timestamp "⚠️ WARNING: Cannot calculate memory comparison"
                fi
            else
                log_with_timestamp "⚠️ WARNING: free command not available"
            fi
        } || {
            log_with_timestamp "❌ ERROR: Memory check failed"
        }

        # Close findings JSON - hardened
        {
            echo "  {\"type\": \"summary\", \"total_issues\": $issues}]}" >> "$findings_file" 2>/dev/null || {
                log_with_timestamp "❌ ERROR: Cannot close findings file"
            }
        }

        # Autonomous response with error handling
        {
            if (( issues >= ACTION_THRESHOLD )); then
                log_with_timestamp "🚨 THRESHOLD EXCEEDED: $issues issues detected, spawning autonomous Claude agent"
                spawn_claude_agent "system_health" "$findings_file" "Fix detected system health issues using SuperClaude framework patterns" || {
                    log_with_timestamp "❌ ERROR: Failed to spawn Claude agent"
                }
            elif (( issues > 0 )); then
                log_with_timestamp "⚠️ Issues detected but below threshold: $issues/$ACTION_THRESHOLD"
            fi
        } || {
            log_with_timestamp "❌ ERROR: Autonomous response failed"
        }

    } || {
        log_with_timestamp "❌ CRITICAL ERROR: System health monitoring failed completely"
        return 1
    }

    return $issues
}

# Advanced service monitoring with Claude integration
monitor_superclaude_services() {
    local findings_file="$FINDINGS_DIR/services_findings_$(date +%s).json"
    local issues=0

    log_with_timestamp "🔍 MONITORING: SuperClaude framework services"

    # Check for stuck agent processes
    local stuck_agents=$(pgrep -f "claude-code" | wc -l)
    if (( stuck_agents > 5 )); then
        log_with_timestamp "⚠️ ISSUE: Too many Claude agents running: $stuck_agents"
        echo "{\"type\": \"agent_overflow\", \"count\": $stuck_agents}" > "$findings_file"
        ((issues++))

        # Immediate autonomous response for agent overflow
        spawn_claude_agent "agent_cleanup" "$findings_file" "Clean up excess Claude agent processes using safe termination methods"
    fi

    # Check .claude directory health
    if [[ ! -d "/home/a/.claude" ]]; then
        log_with_timestamp "❌ CRITICAL: .claude directory missing"
        echo "{\"type\": \"framework_missing\", \"severity\": \"critical\"}" > "$findings_file"
        ((issues++))

        spawn_claude_agent "framework_repair" "$findings_file" "Restore SuperClaude framework directory structure"
    fi

    return $issues
}

# Performance monitoring with predictive analysis
monitor_performance_trends() {
    local findings_file="$FINDINGS_DIR/performance_findings_$(date +%s).json"

    log_with_timestamp "📊 MONITORING: Performance trends analysis"

    # Collect performance metrics
    local cpu_temp=""
    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        cpu_temp=$(cat /sys/class/thermal/thermal_zone0/temp | awk '{print $1/1000}')
    fi

    # Log performance data for trend analysis
    echo "{\"timestamp\": \"$(date -Iseconds)\", \"cpu_temp\": \"$cpu_temp\", \"load\": \"$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')\"}" >> "/home/a/.claude/performance_history.jsonl"

    # Trigger performance analysis every 10 cycles
    local cycle_count=$(wc -l < "/home/a/.claude/performance_history.jsonl" 2>/dev/null || echo "0")
    if (( cycle_count % 10 == 0 && cycle_count > 0 )); then
        log_with_timestamp "📈 ANALYSIS: Triggering performance trend analysis"
        spawn_claude_agent "performance_analysis" "/home/a/.claude/performance_history.jsonl" "Analyze performance trends and recommend optimizations using the last 10 data points"
    fi
}

# Main monitoring loop with SuperClaude integration - HARDENED
main_monitoring_loop() {
    log_with_timestamp "🚀 STARTING: SuperClaude Autonomous Monitoring Agent"
    log_with_timestamp "📋 Configuration: Action threshold=$ACTION_THRESHOLD, Findings dir=$FINDINGS_DIR"

    local cycle=0
    local consecutive_failures=0
    local max_failures=5

    while true; do
        # Cycle management with error recovery
        {
            ((cycle++))
            log_with_timestamp "🔄 CYCLE $cycle: Starting monitoring cycle"

            local health_issues=0
            local service_issues=0

            # Run monitoring modules with intelligent error handling and auto-repair
            {
                monitor_system_health || {
                    log_with_timestamp "⚠️ WARNING: System health monitoring failed - triggering repair"
                    auto_repair_and_retry "health_monitoring_failure" "monitor_system_health" "System health monitoring function failed" "monitor_system_health" 2 &
                    health_issues=0
                }
                health_issues=$?
            } || {
                log_with_timestamp "❌ ERROR: System health module crashed - triggering emergency repair"
                auto_repair_and_retry "health_module_crash" "health_monitoring_system" "Complete system health module crash" "echo 'health module test'" 1 &
                health_issues=0
            }

            {
                monitor_superclaude_services || {
                    log_with_timestamp "⚠️ WARNING: SuperClaude services monitoring failed - triggering repair"
                    auto_repair_and_retry "services_monitoring_failure" "monitor_superclaude_services" "SuperClaude services monitoring failed" "monitor_superclaude_services" 2 &
                    service_issues=0
                }
                service_issues=$?
            } || {
                log_with_timestamp "❌ ERROR: SuperClaude services module crashed - triggering emergency repair"
                auto_repair_and_retry "services_module_crash" "superclaude_monitoring_system" "Complete SuperClaude services module crash" "echo 'services module test'" 1 &
                service_issues=0
            }

            # Performance monitoring every 5 cycles with error handling
            {
                if (( cycle % 5 == 0 )); then
                    monitor_performance_trends || {
                        log_with_timestamp "⚠️ WARNING: Performance monitoring failed"
                    }
                fi
            } || {
                log_with_timestamp "❌ ERROR: Performance monitoring crashed"
            }

            local total_issues=$((health_issues + service_issues))
            log_with_timestamp "📊 CYCLE $cycle COMPLETE: $total_issues total issues detected"

            # Adaptive sleep with bounds checking
            local sleep_duration=30
            {
                if (( total_issues >= ACTION_THRESHOLD )); then
                    sleep_duration=10  # Check more frequently when issues detected
                elif (( total_issues > 0 )); then
                    sleep_duration=20
                fi

                # Ensure sleep_duration is valid
                if [[ ! "$sleep_duration" =~ ^[0-9]+$ ]] || (( sleep_duration < 5 || sleep_duration > 300 )); then
                    sleep_duration=30
                fi
            } || {
                log_with_timestamp "❌ ERROR: Sleep calculation failed, using default"
                sleep_duration=30
            }

            log_with_timestamp "⏰ SLEEP: $sleep_duration seconds until next cycle"

            # Reset consecutive failures on successful cycle
            consecutive_failures=0

            # Safe sleep with error handling
            {
                if command -v sleep >/dev/null 2>&1; then
                    sleep "$sleep_duration" || {
                        log_with_timestamp "⚠️ WARNING: Sleep interrupted"
                        sleep 10  # Fallback short sleep
                    }
                else
                    log_with_timestamp "❌ ERROR: sleep command not available"
                    # Busy wait fallback (not ideal but keeps running)
                    local count=0
                    while (( count < sleep_duration )); do
                        ((count++))
                        # Simple delay loop
                        printf "" >/dev/null
                    done
                fi
            } || {
                log_with_timestamp "❌ ERROR: Sleep failed completely"
            }

        } || {
            # Handle complete cycle failure
            ((consecutive_failures++))
            log_with_timestamp "❌ CRITICAL ERROR: Monitoring cycle $cycle failed completely (failure $consecutive_failures/$max_failures)"

            if (( consecutive_failures >= max_failures )); then
                log_with_timestamp "🚨 FATAL: Too many consecutive failures, entering recovery mode"

                # Recovery mode - extended sleep and reset
                {
                    sleep 60 || true  # Extended recovery sleep
                    consecutive_failures=0
                    log_with_timestamp "🔄 RECOVERY: Attempting to continue after failure recovery"
                } || {
                    log_with_timestamp "💀 TERMINAL: Recovery failed, system may be unstable"
                    exit 1
                }
            else
                # Short recovery sleep
                sleep 15 || true
            fi
        }
    done
}

# Signal handling for graceful shutdown
cleanup() {
    log_with_timestamp "🛑 SHUTDOWN: Autonomous monitoring agent received shutdown signal"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Start the autonomous monitoring loop
main_monitoring_loop