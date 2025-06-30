#Requires -Version 5.1

<#
.SYNOPSIS
    Retrieves pull requests from GitHub and measures time from open to close.

.DESCRIPTION
    This script fetches pull requests from specified repositories in a GitHub organization
    and calculates metrics like time to close, time to merge, time to first review, and other PR analytics.
    Designed to run in Azure DevOps pipelines with proper logging and error handling.

.PARAMETER owner
    GitHub organization or user name

.PARAMETER repository
    Repository name (optional - if not specified, searches all accessible repositories)

.PARAMETER token
    GitHub Personal Access Token with repo permissions

.PARAMETER days
    Number of days to look back for PRs (default: 30)

.PARAMETER state
    PR state filter: all, open, closed (default: all)

.PARAMETER outputPath
    Path to save the CSV report (required for pipeline)

.PARAMETER includeDetails
    Include detailed PR information in output

.PARAMETER maxResults
    Maximum number of PRs to retrieve per repository (default: 100)

.PARAMETER includeDrafts
    Include draft PRs in analysis
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory, HelpMessage = "GitHub organization or user name")]
    [ValidateNotNullOrEmpty()]
    [string]$owner,

    [Parameter(HelpMessage = "Repository name (leave empty for all accessible repositories)")]
    [string]$repository = "",

    [Parameter(Mandatory, HelpMessage = "GitHub Personal Access Token with repo permissions")]
    [ValidateNotNullOrEmpty()]
    [string]$token,

    [Parameter(HelpMessage = "Number of days to look back for PRs")]
    [ValidateRange(1, 365)]
    [int]$days = 30,

    [Parameter(HelpMessage = "PR state filter")]
    [ValidateSet('all', 'open', 'closed')]
    [string]$state = 'all',

    [Parameter(Mandatory, HelpMessage = "Path to save CSV report")]
    [string]$outputPath,

    [Parameter(HelpMessage = "Include detailed PR information")]
    [switch]$includeDetails,

    [Parameter(HelpMessage = "Maximum number of PRs to retrieve per repository")]
    [ValidateRange(1, 1000)]
    [int]$maxResults = 100,

    [Parameter(HelpMessage = "Include draft PRs in analysis")]
    [switch]$includeDrafts
)

# Set strict mode and error handling
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Script-level variables
$script:ApiCallCount = 0
$script:StartTime = Get-Date
$script:RateLimitRemaining = 5000
$script:RateLimitReset = (Get-Date).AddHours(1)

#region Helper Functions

function Write-PipelineLog {
    <#
    .SYNOPSIS
        Writes Azure DevOps pipeline-compatible log messages
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug', 'Section')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    switch ($Level) {
        'Warning' { 
            Write-Host "##vso[task.logissue type=warning]$Message"
            Write-Warning "[$timestamp] ⚠️ $Message"
        }
        'Error' { 
            Write-Host "##vso[task.logissue type=error]$Message"
            Write-Error "[$timestamp] ❌ $Message"
        }
        'Section' {
            Write-Host "##[section]$Message"
        }
        'Debug' { 
            Write-Verbose "[$timestamp] 🔍 $Message"
        }
        'Success' {
            Write-Host "[$timestamp] ✅ $Message" -ForegroundColor Green
        }
        default { 
            Write-Host "[$timestamp] ℹ️ $Message"
        }
    }
}

function Invoke-GitHubApiWithRetry {
    <#
    .SYNOPSIS
        Invokes GitHub API with retry logic and rate limiting
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        
        [hashtable]$Headers,
        
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method = 'GET',
        
        [int]$MaxRetries = 3,
        
        [int]$TimeoutSeconds = 60
    )
    
    $script:ApiCallCount++
    
    # Check rate limit
    if ($script:RateLimitRemaining -lt 10 -and (Get-Date) -lt $script:RateLimitReset) {
        $waitTime = ($script:RateLimitReset - (Get-Date)).TotalSeconds + 5
        Write-PipelineLog "Rate limit approaching. Waiting $([math]::Round($waitTime)) seconds..." -Level Warning
        Start-Sleep -Seconds $waitTime
    }
    
    $attempt = 0
    do {
        $attempt++
        try {
            $sanitizedUri = $Uri -replace $token, '***TOKEN***'
            Write-PipelineLog "API call #$script:ApiCallCount (attempt $attempt): $Method $sanitizedUri" -Level Debug
            
            $params = @{
                Uri         = $Uri
                Headers     = $Headers
                Method      = $Method
                TimeoutSec  = $TimeoutSeconds
            }
            
            $response = Invoke-RestMethod @params
            
            # Extract rate limit info from response headers if available
            if ($response.PSObject.Properties.Name -contains 'Headers') {
                if ($response.Headers.'X-RateLimit-Remaining') {
                    $script:RateLimitRemaining = [int]$response.Headers.'X-RateLimit-Remaining'
                }
                if ($response.Headers.'X-RateLimit-Reset') {
                    $script:RateLimitReset = [DateTimeOffset]::FromUnixTimeSeconds([int]$response.Headers.'X-RateLimit-Reset').DateTime
                }
            }
            
            return $response
        }
        catch {
            $statusCode = $null
            $errorMessage = $_.Exception.Message
            
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                
                # Handle specific HTTP status codes
                switch ($statusCode) {
                    401 { 
                        Write-PipelineLog "Authentication failed. Please check your GitHub token." -Level Error
                        throw
                    }
                    403 { 
                        if ($errorMessage -like "*rate limit*") {
                            Write-PipelineLog "Rate limit exceeded. Waiting before retry..." -Level Warning
                            Start-Sleep -Seconds 60
                        } else {
                            Write-PipelineLog "Access forbidden. Check token permissions." -Level Error
                            throw
                        }
                    }
                    404 { 
                        Write-PipelineLog "Resource not found: $sanitizedUri" -Level Error
                        throw
                    }
                    default {
                        Write-PipelineLog "HTTP $statusCode error on attempt $attempt`: $errorMessage" -Level Warning
                    }
                }
            }
            
            if ($attempt -eq $MaxRetries) {
                Write-PipelineLog "API call failed after $MaxRetries attempts: $errorMessage" -Level Error
                throw
            }
            
            $delay = [math]::Pow(2, $attempt - 1)
            Write-PipelineLog "Retrying in $delay seconds..." -Level Warning
            Start-Sleep -Seconds $delay
        }
    } while ($attempt -lt $MaxRetries)
}

function Get-GitHubRepositories {
    <#
    .SYNOPSIS
        Gets repositories for the specified owner
    #>
    param(
        [string]$Owner,
        [hashtable]$Headers
    )
    
    Write-PipelineLog "Retrieving repositories for $Owner..." -Level Info
    
    $repos = @()
    $page = 1
    $perPage = 100
    
    do {
        try {
            # Try organization repos first
            $uri = "https://api.github.com/orgs/$Owner/repos?type=all&sort=updated&per_page=$perPage&page=$page"
            $response = Invoke-GitHubApiWithRetry -Uri $uri -Headers $Headers
        }
        catch {
            if ($page -eq 1) {
                # Fall back to user repos
                Write-PipelineLog "Organization repos failed, trying user repos..." -Level Warning
                $uri = "https://api.github.com/users/$Owner/repos?type=all&sort=updated&per_page=$perPage&page=$page"
                $response = Invoke-GitHubApiWithRetry -Uri $uri -Headers $Headers
            }
            else {
                throw
            }
        }
        
        if (@($response).Count -eq 0) { break }
        
        $repos += $response
        $page++
        
        Write-PipelineLog "Retrieved $(@($repos).Count) repositories so far..." -Level Debug
        
    } while (@($response).Count -eq $perPage)
    
    Write-PipelineLog "Found $(@($repos).Count) total repositories" -Level Success
    return $repos
}

function Get-PullRequestDetails {
    <#
    .SYNOPSIS
        Gets detailed information for a pull request
    #>
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$PullNumber,
        [hashtable]$Headers
    )
    
    $details = @{
        Reviews = @()
        IssueComments = @()
        ReviewComments = @()
    }
    
    try {
        # Get reviews
        $reviewsUri = "https://api.github.com/repos/$Owner/$Repo/pulls/$PullNumber/reviews"
        $details.Reviews = Invoke-GitHubApiWithRetry -Uri $reviewsUri -Headers $Headers
        
        # Get issue comments
        $issueCommentsUri = "https://api.github.com/repos/$Owner/$Repo/issues/$PullNumber/comments"
        $details.IssueComments = Invoke-GitHubApiWithRetry -Uri $issueCommentsUri -Headers $Headers
        
        # Get review comments
        $reviewCommentsUri = "https://api.github.com/repos/$Owner/$Repo/pulls/$PullNumber/comments"
        $details.ReviewComments = Invoke-GitHubApiWithRetry -Uri $reviewCommentsUri -Headers $Headers
        
    }
    catch {
        Write-PipelineLog "Failed to get details for PR #$PullNumber`: $_" -Level Warning
    }
    
    return $details
}

function ConvertTo-PRMetrics {
    <#
    .SYNOPSIS
        Converts PR data to metrics object
    #>
    param(
        [object]$PullRequest,
        [object]$Details
    )
    
    $createdAt = [DateTime]::Parse($PullRequest.created_at)
    $updatedAt = [DateTime]::Parse($PullRequest.updated_at)
    
    $metrics = [PSCustomObject]@{
        Repository = if ($PullRequest.base -and $PullRequest.base.repo -and ($PullRequest.base.repo -is [psobject]) -and $PullRequest.base.repo.PSObject.Properties['name']) { $PullRequest.base.repo.name } else { '' }
        PullNumber = if (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['number']) { $PullRequest.number } else { '' }
        Title = if (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['title']) { $PullRequest.title -replace '"', '""' } else { '' }  # Escape quotes for CSV
        Author = if ($PullRequest.user -and ($PullRequest.user -is [psobject]) -and $PullRequest.user.PSObject.Properties['login']) { $PullRequest.user.login } else { '' }
        State = if (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['state']) { $PullRequest.state } else { '' }
        IsDraft = if (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['draft']) { $PullRequest.draft } else { $false }
        CreatedAt = if (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['created_at']) { $createdAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        UpdatedAt = if (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['updated_at']) { $updatedAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        ClosedAt = ''
        MergedAt = ''
        TimeToClose = ''
        TimeToMerge = ''
        TimeToFirstReview = ''
        TimeToFirstComment = ''
        TotalReviews = @($Details.Reviews).Count
        TotalComments = (@($Details.IssueComments).Count + @($Details.ReviewComments).Count)
        Additions = (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['additions'])    ? $PullRequest.additions    : 0
        Deletions = (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['deletions'])    ? $PullRequest.deletions    : 0
        ChangedFiles = (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['changed_files']) ? $PullRequest.changed_files : 0
        Commits = (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['commits'])      ? $PullRequest.commits      : 0
        Url = if (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['html_url']) { $PullRequest.html_url } else { '' }
    }
    
    # Calculate time-based metrics
    if (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['closed_at'] -and $PullRequest.closed_at) {
        $closedAt = [DateTime]::Parse($PullRequest.closed_at)
        $metrics.ClosedAt = $closedAt.ToString('yyyy-MM-dd HH:mm:ss')
        $metrics.TimeToClose = [math]::Round(($closedAt - $createdAt).TotalHours, 2)
    }
    
    if (($PullRequest -is [psobject]) -and $PullRequest.PSObject.Properties['merged_at'] -and $PullRequest.merged_at) {
        $mergedAt = [DateTime]::Parse($PullRequest.merged_at)
        $metrics.MergedAt = $mergedAt.ToString('yyyy-MM-dd HH:mm:ss')
        $metrics.TimeToMerge = [math]::Round(($mergedAt - $createdAt).TotalHours, 2)
    }
    
    # Time to first review
    $submittedReviews = $Details.Reviews | Where-Object { ($_ -is [psobject]) -and $_.PSObject.Properties['submitted_at'] }
    if (@($submittedReviews).Count -gt 0) {
        $firstReview = $submittedReviews | Sort-Object submitted_at | Select-Object -First 1
        $firstReviewTime = [DateTime]::Parse($firstReview.submitted_at)
        $metrics.TimeToFirstReview = [math]::Round(($firstReviewTime - $createdAt).TotalHours, 2)
    }
    
    # Time to first comment
    $allComments = @()
    $allComments += $Details.IssueComments | Where-Object { ($_ -is [psobject]) -and $_.PSObject.Properties['created_at'] } | ForEach-Object { [DateTime]::Parse($_.created_at) }
    $allComments += $Details.ReviewComments | Where-Object { ($_ -is [psobject]) -and $_.PSObject.Properties['created_at'] } | ForEach-Object { [DateTime]::Parse($_.created_at) }
    
    if (@($allComments).Count -gt 0) {
        $firstCommentTime = $allComments | Sort-Object | Select-Object -First 1
        $metrics.TimeToFirstComment = [math]::Round(($firstCommentTime - $createdAt).TotalHours, 2)
    }
    
    return $metrics
}

#endregion Helper Functions

#region Main Script Logic

try {
    Write-PipelineLog "Starting GitHub PR Metrics Analysis" -Level Section
    Write-PipelineLog "Owner: $owner" -Level Info
    Write-PipelineLog "Repository: $(if ($repository) { $repository } else { 'All accessible repositories' })" -Level Info
    Write-PipelineLog "Days back: $days" -Level Info
    Write-PipelineLog "State filter: $state" -Level Info
    Write-PipelineLog "Output path: $outputPath" -Level Info
    
    # Setup
    $headers = @{
        'Authorization' = "Bearer $token"
        'Accept' = 'application/vnd.github.v3+json'
        'User-Agent' = 'ADO-GitHub-PR-Metrics/1.0'
    }
    
    $cutoffDate = (Get-Date).AddDays(-$days)
    $allMetrics = @()
    
    # Get repositories
    if ($repository) {
        $repositories = @(@{ name = $repository; full_name = "$owner/$repository" })
        Write-PipelineLog "Analyzing single repository: $repository" -Level Info
    }
    else {
        $repositories = Get-GitHubRepositories -Owner $owner -Headers $headers
    }
    
    Write-PipelineLog "Processing $($repositories.Count) repositories" -Level Info
    
    # Process each repository
    $repoCount = 0
    foreach ($repo in $repositories) {
        $repoCount++
        Write-PipelineLog "[$repoCount/$($repositories.Count)] Processing repository: $($repo.name)" -Level Info
        
        try {
            # Get pull requests
            $repoPRs = @()
            $page = 1
            $perPage = 100
            
            do {
                $uri = "https://api.github.com/repos/$owner/$($repo.name)/pulls?state=$state&sort=updated&direction=desc&per_page=$perPage&page=$page"
                $prs = @(Invoke-GitHubApiWithRetry -Uri $uri -Headers $headers)
                
                if ($prs.Count -eq 0) { break }
                
                # Filter by date and draft status
                $filteredPRs = $prs | Where-Object {
                    $prDate = [DateTime]::Parse($_.created_at)
                    $prDate -ge $cutoffDate -and ($includeDrafts -or -not $_.draft)
                }
                
                $repoPRs += $filteredPRs
                
                # Stop if we've gone past our date range or hit max results
                if (($prs[-1] -and [DateTime]::Parse($prs[-1].created_at) -lt $cutoffDate) -or $repoPRs.Count -ge $maxResults) {
                    break
                }
                
                $page++
                
            } while ($prs.Count -eq $perPage)
            
            # Limit results
            if ($repoPRs.Count -gt $maxResults) {
                $repoPRs = $repoPRs | Select-Object -First $maxResults
            }
            
            Write-PipelineLog "Found $($repoPRs.Count) PRs in $($repo.name)" -Level Info
            
            # Process each PR
            $prCount = 0
            foreach ($pr in $repoPRs) {
                $prCount++
                Write-PipelineLog "  [$prCount/$($repoPRs.Count)] Processing PR #$($pr.number): $($pr.title)" -Level Debug
                
                # Get detailed information
                $details = @{ Reviews = @(); IssueComments = @(); ReviewComments = @() }
                if ($includeDetails) {
                    $details = Get-PullRequestDetails -Owner $owner -Repo $repo.name -PullNumber $pr.number -Headers $headers
                }
                
                # Convert to metrics
                $metrics = ConvertTo-PRMetrics -PullRequest $pr -Details $details
                $allMetrics += $metrics
            }
        }
        catch {
            Write-PipelineLog "Failed to process repository $($repo.name): $_" -Level Error
            continue
        }
    }
    
    # Export results
    Write-PipelineLog "Exporting $($allMetrics.Count) PR metrics to CSV..." -Level Info
    
    if ($allMetrics.Count -gt 0) {
        # Ensure output directory exists
        $outputDir = Split-Path $outputPath -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }
        
        # Export to CSV
        $allMetrics | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
        Write-PipelineLog "Report exported successfully to: $outputPath" -Level Success
        
        # Display summary statistics
        Write-PipelineLog "Analysis Summary" -Level Section
        Write-PipelineLog "Total PRs analyzed: $($allMetrics.Count)" -Level Info
        
        $openPRs = @($allMetrics | Where-Object { $_.State -eq 'open' })
        $closedPRs = @($allMetrics | Where-Object { $_.State -eq 'closed' })
        $mergedPRs = @($allMetrics | Where-Object { $_.MergedAt -ne '' })
        
        Write-PipelineLog "Open PRs: $($openPRs.Count)" -Level Info
        Write-PipelineLog "Closed PRs: $($closedPRs.Count)" -Level Info
        Write-PipelineLog "Merged PRs: $($mergedPRs.Count)" -Level Info
        
        if ($closedPRs.Count -gt 0) {
            $avgTimeToClose = (@($closedPRs | Where-Object { $_.TimeToClose -ne '' }) | Measure-Object -Property TimeToClose -Average).Average
            if ($avgTimeToClose) {
                Write-PipelineLog "Average time to close: $([math]::Round($avgTimeToClose, 2)) hours" -Level Info
            }
        }
        
        if ($mergedPRs.Count -gt 0) {
            $avgTimeToMerge = (@($mergedPRs | Where-Object { $_.TimeToMerge -ne '' }) | Measure-Object -Property TimeToMerge -Average).Average
            if ($avgTimeToMerge) {
                Write-PipelineLog "Average time to merge: $([math]::Round($avgTimeToMerge, 2)) hours" -Level Info
            }
        }
        
        # Set pipeline variables for summary
        Write-Host "##vso[task.setvariable variable=totalPRs]$($allMetrics.Count)"
        Write-Host "##vso[task.setvariable variable=openPRs]$($openPRs.Count)"
        Write-Host "##vso[task.setvariable variable=closedPRs]$($closedPRs.Count)"
        Write-Host "##vso[task.setvariable variable=mergedPRs]$($mergedPRs.Count)"
    }
    else {
        Write-PipelineLog "No pull requests found matching the criteria" -Level Warning
        
        # Create empty CSV with headers
        $emptyMetrics = [PSCustomObject]@{
            Repository = ''; PullNumber = ''; Title = ''; Author = ''; State = ''
            IsDraft = ''; CreatedAt = ''; UpdatedAt = ''; ClosedAt = ''; MergedAt = ''
            TimeToClose = ''; TimeToMerge = ''; TimeToFirstReview = ''; TimeToFirstComment = ''
            TotalReviews = ''; TotalComments = ''; Additions = ''; Deletions = ''
            ChangedFiles = ''; Commits = ''; Url = ''
        }
        $emptyMetrics | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
    }
    
    # Script completion
    $duration = (Get-Date) - $script:StartTime
    Write-PipelineLog "Analysis completed successfully in $($duration.TotalSeconds.ToString('F2')) seconds" -Level Success
    Write-PipelineLog "Total API calls made: $script:ApiCallCount" -Level Info
    Write-PipelineLog "Rate limit remaining: $script:RateLimitRemaining" -Level Info
}
catch {
    $duration = (Get-Date) - $script:StartTime
    Write-PipelineLog "Script failed after $($duration.TotalSeconds.ToString('F2')) seconds: $_" -Level Error
    Write-PipelineLog "Stack trace: $($_.ScriptStackTrace)" -Level Debug
    exit 1
}
finally {
    # Cleanup
    if (Get-Variable -Name 'token' -ErrorAction SilentlyContinue) {
        Remove-Variable -Name 'token' -Force -ErrorAction SilentlyContinue
    }
    if (Get-Variable -Name 'headers' -ErrorAction SilentlyContinue) {
        Remove-Variable -Name 'headers' -Force -ErrorAction SilentlyContinue
    }
}

#endregion Main Script Logic
