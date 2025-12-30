# bench_stop

A script for gracefully stopping all Frappe bench processes.

## Overview

When you start a Frappe bench with `bench start`, multiple processes are launched in the background. The standard approach to stop these processes is to use `pkill` or `kill -9` to terminate them. However, this approach has several problems:

1. **Data loss**: Force-killing processes can lead to incomplete operations, data corruption, or interrupted background jobs
2. **Hardcoded assumptions**: Simple scripts often assume default port numbers, which may not match your configuration
3. **Collateral damage**: Killing processes by name pattern can accidentally terminate unrelated processes

This script addresses these issues by reading your actual bench configuration and performing a graceful shutdown.

## Why Reading Configuration is Necessary

Frappe bench uses three separate Redis instances on different ports:

- **Cache Redis**: Typically port 13000 (but configurable)
- **Queue Redis**: Typically port 11000 (but configurable)
- **Socket.io Redis**: Typically port 12000 (but configurable)

Additionally, other services like the web server and Socket.io server may use non-default ports depending on your `sites/common_site_config.json` configuration.

A naive script that simply kills all processes named "redis-server" or "node" would:
- Kill system-wide Redis instances that are not part of the bench
- Terminate unrelated Node.js processes
- Fail to identify the correct processes if your bench uses custom ports

This script solves this problem by:

1. Reading port numbers from `config/redis_*.conf` files
2. Reading configuration from `sites/common_site_config.json`
3. Checking PID files in `config/pids/` when available
4. Using multiple methods to identify the correct processes:
   - PID files (most reliable)
   - Port numbers via `lsof`/`ss`
   - Process pattern matching as fallback

## Features

- **Graceful shutdown**: Sends SIGTERM first, waits for processes to terminate cleanly, only uses SIGKILL as last resort
- **Configuration-aware**: Reads your actual bench configuration instead of assuming defaults
- **Multi-method process detection**: Uses PID files, port lookup, and pattern matching for reliability
- **Colored output**: Clear status messages with color coding
- **Safe**: Validates environment before taking action

## Usage

```bash
# From the bench directory
./stop_bench.sh

# Or from anywhere with full path
/path/to/bench/stop_bench.sh
```

## How It Works

The script stops processes in reverse order of startup (important for clean shutdown):

1. **Worker** - Lets current background jobs finish
2. **Schedule** - Stops the scheduled task runner
3. **Watch processes** - Stops asset rebuild watchers (bench watch, esbuild, yarn)
4. **Serve** - Stops the web server
5. **Socket.io** - Stops the real-time communication server
6. **Redis instances** - Stops cache, queue, and socketio Redis servers

For each process:
1. Attempts to find the PID via PID file, port lookup, or pattern matching
2. Sends SIGTERM for graceful shutdown
3. Waits up to 10 seconds (Python) or 5 seconds (Redis/Node) for termination
4. If still running, sends SIGKILL as last resort

## Requirements

- Bash shell
- Standard Unix utilities: `grep`, `awk`, `ps`, `kill`
- Optional but recommended: `lsof` (more reliable port-based process detection)
- Must be run from or within a Frappe bench directory

## Installation

Place the script in your Frappe bench directory and make it executable:

```bash
chmod +x stop_bench.sh
```

## Example Output

```
[INFO] === Stopping Frappe Bench ===
[INFO] Bench directory: /home/user/frappe-bench

[INFO] Bench Worker: Stopping gracefully (PID: 12345)...
.
[INFO] Bench Worker: Stopped successfully
[INFO] Bench Schedule: Stopping gracefully (PID: 12346)...
[INFO] Bench Schedule: Stopped successfully
[INFO] Bench Watch: Stopping gracefully (PID: 12347)...
[INFO] Bench Watch: Stopped successfully
[WARN] Esbuild Watch: Not running
[INFO] Bench Serve: Stopping gracefully (PID: 12348)...
[INFO] Bench Serve: Stopped successfully
[INFO] Socket.io: Stopping gracefully (PID: 12349)...
[INFO] Socket.io: Stopped successfully
[INFO] Redis (cache): Stopping gracefully (PID: 12350)...
[INFO] Redis (cache): Stopped successfully
[INFO] Redis (queue): Stopping gracefully (PID: 12351)...
[INFO] Redis (queue): Stopped successfully
[INFO] Redis (socketio): Stopping gracefully (PID: 12352)...
[INFO] Redis (socketio): Stopped successfully

[INFO] === All bench processes stopped ===
```

## Troubleshooting

**Process not found**: Make sure you're running the script from the correct bench directory. The script checks for the presence of `Procfile` and `sites` directory to validate the location.

**Permission denied**: The script needs permission to send signals to the bench processes. If you started the bench as a different user, you may need to run the stop script as the same user or with appropriate permissions.

**Process still running after timeout**: This is normal behavior. The script will force-kill any process that doesn't respond to SIGTERM within the timeout period.

## License

This script is provided as-is for use with Frappe bench environments.
