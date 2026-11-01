# A6 test: simulate a stolen key driving a token flood (LLMjacking). Sends more calls in a
# few minutes than the analytics rule threshold. Stops early if the key stops working,
# which is the C2 containment from the playbook taking effect.
param([int] $Calls = 45)
$rg       = "lab-genai-irf"
$account  = terraform output -raw aoai_name
$endpoint = terraform output -raw aoai_endpoint
$key      = az cognitiveservices account keys list -g $rg -n $account --query key1 -o tsv
$uri      = "$($endpoint)openai/deployments/chat/chat/completions?api-version=2025-04-01-preview"
$body     = @{ messages = @(@{ role = "user"; content = "Write a 200 word product description for a stapler." }); max_completion_tokens = 600 } | ConvertTo-Json -Depth 4

for ($i = 1; $i -le $Calls; $i++) {
    try {
        $r = Invoke-RestMethod -Method Post -Uri $uri -Headers @{ "api-key" = $key } -ContentType "application/json" -Body $body
        Write-Host "$i ok tokens=$($r.usage.total_tokens)"
    } catch {
        Write-Host "$i failed: $($_.Exception.Response.StatusCode)" -ForegroundColor Yellow
        if ($_.Exception.Response.StatusCode -eq 401) { Write-Host "Key revoked. Containment worked."; break }
    }
    Start-Sleep -Milliseconds 500
}
