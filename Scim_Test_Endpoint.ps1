# =====================================================
# Configuration: Update these values for your environment
# =====================================================
$Hostname    = "TestServer.Example.com"
$BearerToken = "ThisIsYourAPIKeySoChangeMe"
$useHttps    = $false    # Set $true for HTTPS, or $false for HTTP

# Determine protocol and port based on $useHttps value.
if ($useHttps) {
    $protocol = "https"
    $port     = 443
} else {
    $protocol = "http"
    $port     = 80
}

# =====================================================
# Set up the HTTP Listener using wildcard prefixes.
# =====================================================
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("${protocol}://+:${port}/scim/")
$listener.Prefixes.Add("${protocol}://+:${port}/scim/serviceproviderconfig/")
$listener.Prefixes.Add("${protocol}://+:${port}/scim/users/")
$listener.Prefixes.Add("${protocol}://+:${port}/scim/schemas/")
$listener.Start()
Write-Host "SCIM test server running. Expected hostname: ${protocol}://${Hostname}:${port}/scim/"

# =====================================================
# In-Memory User Store (sample user)
# =====================================================
$users = @(
    @{
        id           = "1"
        userName     = "jdoe"
        name         = @{ givenName = "John"; familyName = "Doe" }
        active       = $true
        emails       = @(
            @{ value = "jdoe@example.com"; type = "work" }
        )
        phoneNumbers = @(
            @{ value = "+1234567890"; type = "mobile" }
        )
        department   = "Engineering"
        title        = "Software Engineer"
    }
)

# =====================================================
# Helper Functions
# =====================================================
function ConvertTo-ScimJson {
    param (
        [hashtable]$user,
        [string[]]$attributes
    )
    $scimRepresentation = @{
        schemas = @("urn:ietf:params:scim:schemas:core:2.0:User")
    }
    foreach ($key in $user.Keys) {
        $scimRepresentation[$key] = $user[$key]
    }
    return $scimRepresentation | ConvertTo-Json -Depth 10
}

function Read-RequestBody {
    param ($request)
    $reader = New-Object System.IO.StreamReader($request.InputStream)
    $body = $reader.ReadToEnd()
    $reader.Close()
    return $body
}

function Get-RequestedAttributes {
    param ($urlQuery)
    $attributes = @()
    if ($urlQuery -match "attributes=") {
        $queryParams = [System.Web.HttpUtility]::ParseQueryString($urlQuery)
        $attrParam = $queryParams["attributes"]
        if ($attrParam -and $attrParam.Trim() -ne "") {
            $attributes = $attrParam.Split(",") | ForEach-Object { $_.Trim() }
        }
    }
    return $attributes
}

# =====================================================
# Main Listener Loop
# =====================================================
while ($listener.IsListening) {
    $context   = $listener.GetContext()
    $request   = $context.Request
    $response  = $context.Response
    $path      = $request.Url.AbsolutePath.ToLower()

    Write-Host "`n[$($request.HttpMethod)] $path"
    Write-Host "Full URL: $($request.Url.AbsoluteUri)"

    if ($request.Url.Host -ne $Hostname) {
        $response.StatusCode = 400
        $errMsg = '{"error": "Invalid Host header"}'
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
        $response.ContentType = "application/json"
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
        $response.OutputStream.Flush()
        $response.Close()
        continue
    }

    $authHeader = $request.Headers["Authorization"]
    $providedKey = $null
    if ($authHeader -and $authHeader.StartsWith("Bearer ")) {
        $providedKey = $authHeader.Substring(7)
    }

    if ($providedKey -ne $BearerToken) {
        $response.StatusCode = 401
        $response.ContentType = "application/json"
        $responseBody = '{"error":"Unauthorized - Invalid API Key"}'
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
        $response.OutputStream.Flush()
        $response.Close()
        continue
    }

    $response.ContentType = "application/scim+json"

    if ((($path -eq "/scim/users") -or ($path -eq "/scim/users/")) -and $request.HttpMethod -eq "POST") {
        $body = Read-RequestBody $request | ConvertFrom-Json
        $newId = ([int]$users[-1].id + 1).ToString()
        $userObj = @{}
        foreach ($property in $body.PSObject.Properties) {
            $userObj[$property.Name] = $property.Value
        }
        $userObj["id"] = $newId
        $users += $userObj
        $response.StatusCode = 201
        $responseBody = ConvertTo-ScimJson -user $userObj -attributes @()
    }
    elseif ((($path -eq "/scim/users") -or ($path -eq "/scim/users/")) -and $request.HttpMethod -eq "GET") {
        $requestedAttrs = Get-RequestedAttributes $request.Url.Query
        $decodedQuery = [System.Net.WebUtility]::UrlDecode($request.Url.Query)
        if ($decodedQuery -match 'userName\s+eq\s+"(.+?)"') {
            $filterUserName = $matches[1]
            $matchedUsers = $users | Where-Object { $_.userName -eq $filterUserName }
            $listResponse = @{
                schemas      = @("urn:ietf:params:scim:api:messages:2.0:ListResponse")
                totalResults = $matchedUsers.Count
                Resources    = $matchedUsers | ForEach-Object {
                    ConvertTo-ScimJson -user $_ -attributes $requestedAttrs | ConvertFrom-Json
                }
            }
            $responseBody = $listResponse | ConvertTo-Json -Depth 10
        }
        else {
            $listResponse = @{
                schemas      = @("urn:ietf:params:scim:api:messages:2.0:ListResponse")
                totalResults = $users.Count
                Resources    = $users | ForEach-Object {
                    ConvertTo-ScimJson -user $_ -attributes $requestedAttrs | ConvertFrom-Json
                }
            }
            $responseBody = $listResponse | ConvertTo-Json -Depth 10
        }
        $response.StatusCode = 200
    }
    elseif ($path -match "^/scim/users/([\w-]+)$" -and $request.HttpMethod -eq "GET") {
        $userId = $matches[1]
        $user = $users | Where-Object { $_.id -eq $userId }
        if ($user) {
            $responseBody = ConvertTo-ScimJson -user $user -attributes @()
            $response.StatusCode = 200
        }
        else {
            $response.StatusCode = 404
            $responseBody = '{"error":"User not found"}'
        }
    }
    elseif ($path -match "^/scim/users/([\w-]+)$" -and $request.HttpMethod -eq "PATCH") {
        $userId = $matches[1]
        $body = Read-RequestBody $request | ConvertFrom-Json
        $user = $users | Where-Object { $_.id -eq $userId }
        if ($user) {
            foreach ($property in $body.PSObject.Properties) {
                if ($property.Name -ne "id") {
                    $user[$property.Name] = $property.Value
                }
            }
            $response.StatusCode = 200
            $responseBody = ConvertTo-ScimJson -user $user -attributes @()
        }
        else {
            $response.StatusCode = 404
            $responseBody = '{"error":"User not found"}'
        }
    }
    elseif ($path -eq "/scim/serviceproviderconfig" -or $path -eq "/scim/serviceproviderconfig/") {
        $response.StatusCode = 200
        $responseBody = @'
{
    "schemas": ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"],
    "patch": { "supported": true },
    "bulk": { "supported": false },
    "filter": { "supported": true },
    "changePassword": { "supported": false },
    "sort": { "supported": false },
    "etag": { "supported": false },
    "authenticationSchemes": []
}
'@
    }
    else {
        $response.StatusCode = 404
        $responseBody = '{"error":"Endpoint not implemented"}'
    }

    $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Flush()
    $response.Close()
}
