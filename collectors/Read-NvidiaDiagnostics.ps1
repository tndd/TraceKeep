function Invoke-DiagnosticProcess {
    param([string]$Executable, [string]$Arguments, [int]$TimeoutMilliseconds = 1500)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        if (-not $process.Start()) { throw 'Diagnostic process did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            # Only terminate the read-only child created by this invocation.
            try { $process.Kill() } catch {}
            throw "Diagnostic reader timed out after $TimeoutMilliseconds ms."
        }
        if (-not $stdout.Wait(200) -or -not $stderr.Wait(200)) { throw 'Diagnostic reader output did not complete.' }
        if ($process.ExitCode -ne 0) { throw "Diagnostic reader exit $($process.ExitCode): $($stderr.Result) $($stdout.Result)" }
        return $stdout.Result
    } finally { $process.Dispose() }
}

function Read-NvidiaDiagnostics {
    param([string]$Executable)
    $fields = 'temperature.gpu,utilization.gpu,power.draw,power.limit,fan.speed,clocks.gr,clocks.mem,pstate,clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.hw_power_brake_slowdown,clocks_event_reasons.sw_thermal_slowdown,clocks_event_reasons.sw_power_cap,clocks_event_reasons_counters.hw_power_brake_slowdown,clocks_event_reasons_counters.hw_thermal_slowdown,clocks_event_reasons_counters.sw_thermal_slowdown,clocks_event_reasons_counters.sw_power_cap'
    $output = Invoke-DiagnosticProcess $Executable "--query-gpu=$fields --format=csv,noheader,nounits"
    $headers = @('temperatureC','loadPercent','powerW','powerLimitW','fanPercent','graphicsMHz','memoryMHz','pstate','hwThermalSlowdown','hwPowerBrakeSlowdown','swThermalSlowdown','swPowerCap','hwPowerBrakeMicroseconds','hwThermalMicroseconds','swThermalMicroseconds','swPowerCapMicroseconds')
    foreach ($row in @($output -split '[\r\n]+' | Where-Object { $_.Trim() } | ConvertFrom-Csv -Header $headers)) {
        $unsupported = @()
        foreach ($property in $row.PSObject.Properties) {
            if ($null -eq $property.Value) { throw 'GPU reader returned an incomplete row.' }
            $property.Value = $property.Value.Trim()
            if ($property.Value -match '^\[?N/A\]?$|^\[Not Supported\]$') {
                $unsupported += $property.Name
                $property.Value = $null
            }
        }
        $row | Add-Member -NotePropertyName unsupportedFields -NotePropertyValue $unsupported
        $row
    }
}
