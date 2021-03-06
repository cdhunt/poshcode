#Requires -Version 2
###############################################################################
## Copyright (c) 2013 by Joel Bennett, all rights reserved.
## Free for use under MS-PL, MS-RL, GPL 2, or BSD license. Your choice. 
###############################################################################
## InvokeWeb.psm1 defines a subset of the Invoke-WebRequest functionality
## On PowerShell 3 and up we'll just use the built-in Invoke-WebRequest
if(!(Get-Command Invoke-WebRequest)) {
  function Invoke-WebRequest {
    <#
      .Synopsis
        Downloads a file or page from the web, or sends web API posts/requests
      .Description
        Creates an HttpWebRequest to download a web file or post data. This is a restricted 
      .Example
        Invoke-Web http://PoshCode.org/PoshCode.psm1
      
        Downloads the latest version of the PoshCode module to the current directory
      .Example
        Invoke-Web http://PoshCode.org/PoshCode.psm1 ~\Documents\WindowsPowerShell\Modules\PoshCode\
      
        Downloads the latest version of the PoshCode module to the default PoshCode module directory...
      .Example
        $RssItems = @(([xml](Invoke-WebRequest http://poshcode.org/api/)).rss.channel.GetElementsByTagName("item"))
      
        Returns the most recent items from the PoshCode.org RSS feed
    #>
    [CmdletBinding(DefaultParameterSetName="NoSession")]
    param(
      #  The URL of the file/page to download
      [Parameter(Mandatory=$true,Position=0)]
      [System.Uri][Alias("Url")]$Uri, # = (Read-Host "The URL to download")

      # Specifies the method used for the web request. Valid values are Default, Delete, Get, Head, Options, Post, Put, and Trace. Default value is Get.
      [ValidateSet("Default", "Get", "Head", "Post", "Put", "Delete", "Trace", "Options", "Merge", "Patch")]
      [String]$Method = "Get",

      #  Sends the results to the specified output file. Enter a path and file name. If you omit the path, the default is the current location.
      #  By default, Invoke-WebRequest returns the results to the pipeline. To send the results to a file and to the pipeline, use the Passthru parameter.
      [Parameter()]
      [Alias("OutPath")]
      [string]$OutFile,

      #  Text to include at the front of the UserAgent string
      [string]$UserAgent = "Mozilla/5.0 (Windows NT; Windows NT $([Environment]::OSVersion.Version.ToString(2)); $PSUICulture) WindowsPowerShell/$($PSVersionTable.PSVersion.ToString(2)); PoshCode/4.0; http://PoshCode.org",

      #  Specifies the client certificate that is used for a secure web request. Enter a variable that contains a certificate or a command or expression that gets the certificate.
      #  To find a certificate, use Get-PfxCertificate or use the Get-ChildItem cmdlet in the Certificate (Cert:) drive. If the certificate is not valid or does not have sufficient authority, the command fails.
      [System.Security.Cryptography.X509Certificates.X509Certificate[]]
      $ClientCertificate,

      #  Pass the default credentials
      [switch]$UseDefaultCredentials,

      #  Specifies a user account that has permission to send the request. The default is the current user.
      #  Type a user name, such as "User01" or "Domain01\User01", or enter a PSCredential object, such as one generated by the Get-Credential cmdlet.
      [System.Management.Automation.PSCredential]
      [System.Management.Automation.Credential()]
      [Alias("")]$Credential = [System.Management.Automation.PSCredential]::Empty,

      # Specifies that Authorization: Basic should always be sent. Requires $Credential to be set, and should only be used with https
      [ValidateScript({if(!($Credential -or $WebSession)){ throw "ForceBasicAuth requires the Credential parameter be set"} else { $true }})]
      [switch]$ForceBasicAuth,

      # Uses a proxy server for the request, rather than connecting directly to the Internet resource. Enter the URI of a network proxy server.
      # Note: if you have a default proxy configured in your internet settings, there is no need to set it here.
      [Uri]$Proxy,

      #  Pass the default credentials to the Proxy
      [switch]$ProxyUseDefaultCredentials,

      #  Pass specific credentials to the Proxy
      [System.Management.Automation.PSCredential]
      [System.Management.Automation.Credential()]
      $ProxyCredential= [System.Management.Automation.PSCredential]::Empty    
    )
    process {
      $EAP,$ErrorActionPreference = $ErrorActionPreference, "Stop"
      $request = [System.Net.HttpWebRequest]::Create($Uri)
      if($DebugPreference -ne "SilentlyContinue") {
        Set-Variable WebRequest -Scope 2 -Value $request
      }
      $ErrorActionPreference = $EAP

      # And override session values with user values if they provided any
      $request.UserAgent = $UserAgent

      # Authentication normally uses EITHER credentials or certificates, but what do I know ...
      if($ClientCertificate) {
        $request.ClientCertificates.AddRange($ClientCertificate)
      }
      if($UseDefaultCredentials) {
        $request.UseDefaultCredentials = $true
      } elseif($Credential -ne [System.Management.Automation.PSCredential]::Empty) {
        $request.Credentials = $Credential.GetNetworkCredential()
      }

      # You don't have to specify a proxy to specify proxy credentials (maybe your default proxy takes creds)
      if($Proxy) { $request.Proxy = New-Object System.Net.WebProxy $Proxy }
      if($request.Proxy -ne $null) {
        if($ProxyUseDefaultCredentials) {
          $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        } elseif($ProxyCredentials -ne [System.Management.Automation.PSCredential]::Empty) {
          $request.Proxy.Credentials = $ProxyCredentials
        }
      }

      if($ForceBasicAuth) {
        if(!$request.Credentials) {
          throw "ForceBasicAuth requires Credentials!"
        }
        $request.Headers.Add('Authorization', 'Basic ' + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($request.Credentials.UserName+":"+$request.Credentials.Password )));
      }

      try {
        $response = $request.GetResponse();
        if($DebugPreference -ne "SilentlyContinue") {
          Set-Variable WebResponse -Scope 2 -Value $response
        }
      } catch [System.Net.WebException] { 
        Write-Error $_.Exception -Category ResourceUnavailable
        return
      } catch { # Extra catch just in case, I can't remember what might fall here
        Write-Error $_.Exception -Category NotImplemented
        return
      }
   
      Write-Verbose "Retrieved $($Response.ResponseUri): $($Response.StatusCode)"
      if((Test-Path variable:response) -and $response.StatusCode -eq 200) {
        Write-Verbose "OutFile: $OutFile"

        # Magics to figure out a file location based on the response
        if($OutFile) {
          # If the path is just a file name, then interpret it as .\FileName
          if(!(Split-Path $OutFile) -and (![IO.Path]::IsPathRooted($OutFile))) {
            $OutFile = Join-Path (Get-Location -PSProvider FileSystem) $OutFile
          }
          # If the path is just a folder, guess the FileName from the response
          elseif(Test-Path -PathType "Container" $OutFile)
          {
            [string]$OutFilePath = ([regex]'(?i)filename=(.*)$').Match( $response.Headers["Content-Disposition"] ).Groups[1].Value
            $OutFilePath = $OutFilePath.trim("\/""'")
             
            $sep,$ofs = $ofs,""
            $OutFilePath = [Regex]::Replace($OutFilePath, "[$([Regex]::Escape(""$([System.IO.Path]::GetInvalidPathChars())$([IO.Path]::AltDirectorySeparatorChar)$([IO.Path]::DirectorySeparatorChar)""))]", "_")
            $sep,$ofs = $ofs,$sep
            
            if(!$OutFilePath) {
              $OutFilePath = $response.ResponseUri.Segments[-1]
              $OutFilePath = $OutFilePath.trim("\./")
              if(!$OutFilePath) { 
                $OutFilePath = Read-Host "Please provide a file name"
              }
              $OutFilePath = $OutFilePath.trim("\./")
            }
            if(!([IO.FileInfo]$OutFilePath).Extension) {
              $OutFilePath = $OutFilePath + "." + $response.ContentType.Split(";")[0].Split("/")[-1].Split("+")[-1]
            }          
            Write-Verbose "Determined a filename: $OutFilePath"
            $OutFile = Join-Path $OutFile $OutFilePath
            Write-Verbose "Calculated the full path: $OutFile"
          }
        }

        if(!$OutFile) {
          $encoding = [System.Text.Encoding]::GetEncoding( $response.CharacterSet )
          [string]$output = ""
        }
   
        try {
          if($ResponseHandler) {
            . $ResponseHandler $response
          }
        } catch {
          $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord $_.Exception, "Unexpected Exception", "InvalidResult", $_) )
        }

        try {
          [int]$goal = $response.ContentLength
          $reader = $response.GetResponseStream()
          if($OutFile) {
            try {
              $writer = new-object System.IO.FileStream $OutFile, "Create"
            } catch { # Catch just in case, lots of things could go wrong ...
              Write-Error $_.Exception -Category WriteError
              return
            }
          }        
          [byte[]]$buffer = new-object byte[] 4096
          [int]$total = [int]$count = 0
          do
          {
            $count = $reader.Read($buffer, 0, $buffer.Length);
            if($OutFile) {
              $writer.Write($buffer, 0, $count);
            } else {
              $output += $encoding.GetString($buffer,0,$count)
            } 
            # This is unecessary, but nice to have
            if(!$quiet) {
              $total += $count
              if($goal -gt 0) {
                Write-Progress "Downloading $Uri" "Saving $total of $goal" -id 0 -percentComplete (($total/$goal)*100)
              } else {
                Write-Progress "Downloading $Uri" "Saving $total bytes..." -id 0
              }
            }
          } while ($count -gt 0)
        } catch [Exception] {
          $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord $_.Exception, "Unexpected Exception", "InvalidResult", $_) )
          Write-Error "Could not download package from $Url"
        } finally {
          if(Test-Path variable:Reader) {
            $Reader.Close()
            $Reader.Dispose()
          }
          if(Test-Path variable:Writer) {
            $writer.Flush()
            $Writer.Close()
            $Writer.Dispose()
          }
        }
        
        Write-Progress "Finished Downloading $Uri" "Saved $total bytes..." -id 0 -Completed

        # I have a fundamental disagreement with Microsoft about what the output should be
        if($OutFile) {
          Get-Item $OutFile
        } elseif(Get-Variable output -Scope Local) {
          $output
        }
      }
      if(Test-Path variable:response) {
        $response.Close(); 
        $response.Dispose(); 
      }
    }
  }

  Export-ModuleMember Invoke-WebRequest
}
