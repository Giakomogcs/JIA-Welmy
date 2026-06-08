# Builds Welmy-Front.json (n8n workflow) by embedding front-welmy.html into an
# HTML template node served via a GET webhook (welmy-app).
$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $PSScriptRoot
$htmlPath  = Join-Path $root 'front-welmy.html'
$outPath   = Join-Path $root 'workspaces\Welmy-Front.json'

if (-not (Test-Path $htmlPath)) { throw "front-welmy.html not found at $htmlPath" }

# Read the HTML exactly as-is (preserve CRLF).
$html = [System.IO.File]::ReadAllText($htmlPath)

$workflow = [ordered]@{
  name  = 'Welmy-Front'
  nodes = @(
    [ordered]@{
      parameters = [ordered]@{
        httpMethod   = 'GET'
        path         = 'welmy-app'
        responseMode = 'responseNode'
        options      = [ordered]@{ allowedOrigins = '*' }
      }
      id          = 'a1b2c3d4-0001-4000-8000-000000000001'
      name        = 'App'
      type        = 'n8n-nodes-base.webhook'
      typeVersion = 2
      position    = @(-220, 0)
      webhookId   = 'welmy-app'
    },
    [ordered]@{
      parameters = [ordered]@{
        operation = 'generateHtmlTemplate'
        html      = $html
      }
      id          = 'a1b2c3d4-0002-4000-8000-000000000002'
      name        = 'HTML'
      type        = 'n8n-nodes-base.html'
      typeVersion = 1.2
      position    = @(0, 0)
    },
    [ordered]@{
      parameters = [ordered]@{
        respondWith  = 'text'
        responseBody = '={{ $json.html }}'
        options      = [ordered]@{
          responseHeaders = [ordered]@{
            entries = @(
              [ordered]@{ name = 'Content-Type'; value = 'text/html; charset=utf-8' }
            )
          }
        }
      }
      id          = 'a1b2c3d4-0003-4000-8000-000000000003'
      name        = 'Respond to App'
      type        = 'n8n-nodes-base.respondToWebhook'
      typeVersion = 1.1
      position    = @(220, 0)
    }
  )
  connections = [ordered]@{
    'App'  = [ordered]@{ main = @(, @(, [ordered]@{ node = 'HTML'; type = 'main'; index = 0 })) }
    'HTML' = [ordered]@{ main = @(, @(, [ordered]@{ node = 'Respond to App'; type = 'main'; index = 0 })) }
  }
  pinData  = [ordered]@{}
  active   = $true
  settings = [ordered]@{ executionOrder = 'v1' }
  id       = 'WelmyFront'
  tags     = @()
}

$json = $workflow | ConvertTo-Json -Depth 50
[System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $outPath ($([math]::Round((Get-Item $outPath).Length/1KB)) KB)"
