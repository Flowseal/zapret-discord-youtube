# Discord + AION 2 ALT diagnostics

Run option 13 in service.bat as Administrator on Windows.

## Requirements
- Game Filter TCP or TCP+UDP enabled and includes port 13328.
- Verified game server address must be included in active IPSet (or IPSet mode any).
- Close AION 2 before cycling configs; remove installed zapret service first.
- To discover the correct endpoint while in game: Get-NetTCPConnection -State Established -RemotePort 13328 | Select-Object RemoteAddress,RemotePort,OwningProcess
- Put the confirmed address into utils/targets-aion2.txt or enter it at the prompt.

## Operation
1. Save running winws commands and measure a direct TCP baseline.
2. Run all general*.bat strategies, one at a time.
3. Check four Discord HTTPS endpoints and sample game TCP handshake latency.
4. Export CSV files in utils/test results; show provisional ranking.
5. Restore prior winws processes in a finally block.

Eligible means all four Discord probes succeed, the strategy starts, and every TCP handshake succeeds.
TCP handshake does NOT establish AION 2 login success, DPI bypass success, or true gameplay latency.
These tests also do not measure game packet loss, UDP, or DPS. Real gameplay verification is mandatory.

## Verification
Run powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\aion2-tests.ps1
Tests check PowerShell syntax parsing, known edge cases, 1000 randomized CIDR comparisons, stats, sorting, and legacy menu routing.
GitHub Actions Windows testing is configured, but only a completed green workflow is evidence it ran.

## Safety
Switching strategies interrupts winws traffic. The script tries to restore previous commands, but forced termination can prevent restoration.
It does not intentionally change IPSet or Game Filter configuration files. Do not run other winws managers concurrently.