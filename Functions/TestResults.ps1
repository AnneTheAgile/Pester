function Get-HumanTime($Seconds) {
    if($Seconds -gt 0.99) {
        $time = [math]::Round($Seconds, 2)
        $unit = 's'
    }
    else {
        $time = [math]::Floor($Seconds * 1000)
        $unit = 'ms'
    }
    return "$time$unit"
}

function GetFullPath ([string]$Path) {
    $fullpath = Resolve-Path -Path $Path -ErrorAction SilentlyContinue -ErrorVariable Error
    if ($fullpath)
    {
        $fullpath
    }
    else
    {
        $error[0].TargetObject
    }
}

function Export-PesterResults
{
    param (
        $PesterState,
        [string] $Path,
        [string] $Format
    )

    switch ($Format)
    {
        'LegacyNUnitXml' { Export-LegacyNUnitReport -InputObject $PesterState -Path $Path }

        default
        {
            throw "'$Format' is not a valid Pester export format."
        }
    }
}
function Export-LegacyNUnitReport {
    param (
        [parameter(Mandatory=$true,ValueFromPipeline=$true)]
        $PesterState,

        [parameter(Mandatory=$true)]
        [String]$Path
    )

    #the xmlwriter create method can resolve relatives paths by itself. but its current directory might
    #be different from what PowerShell sees as the current directory so I have to resolve the path beforehand
    #working around the limitations of Resolve-Path

    $Path = GetFullPath -Path $Path

    $settings = New-Object -TypeName Xml.XmlWriterSettings -Property @{
        Indent = $true
        NewLineOnAttributes = $false
    }

    $xmlWriter = $null
    try {
        $xmlWriter = [Xml.XmlWriter]::Create($Path,$settings)

        Write-NUnitReport -XmlWriter $xmlWriter -PesterState $PesterState

        $xmlWriter.Flush()
    }
    finally
    {
        if ($null -ne $xmlWriter) {
            try { $xmlWriter.Close() } catch {}
        }
    }
}

function Write-NUnitReport($PesterState, [System.Xml.XmlWriter] $XmlWriter)
{
    # Write the XML Declaration
    $XmlWriter.WriteStartDocument($false)

    # Write Root Element
    $xmlWriter.WriteStartElement('test-results')

    Write-NUnitTestResultAttributes @PSBoundParameters
    Write-NUnitTestResultChildNodes @PSBoundParameters

    $XmlWriter.WriteEndElement()
}

function Write-NUnitTestResultAttributes($PesterState, [System.Xml.XmlWriter] $XmlWriter)
{
    $XmlWriter.WriteAttributeString('xmlns','xsi', $null, 'http://www.w3.org/2001/XMLSchema-instance')
    $XmlWriter.WriteAttributeString('xsi','noNamespaceSchemaLocation', [Xml.Schema.XmlSchema]::InstanceNamespace , 'nunit_schema_2.5.xsd')
    $XmlWriter.WriteAttributeString('name','Pester')
    $XmlWriter.WriteAttributeString('total', $PesterState.TotalCount)
    $XmlWriter.WriteAttributeString('errors', '0')
    $XmlWriter.WriteAttributeString('failures', $PesterState.FailedCount)
    $XmlWriter.WriteAttributeString('not-run', '0')
    $XmlWriter.WriteAttributeString('inconclusive', '0')
    $XmlWriter.WriteAttributeString('ignored', '0')
    $XmlWriter.WriteAttributeString('skipped', '0')
    $XmlWriter.WriteAttributeString('invalid', '0')
    $date = Get-Date
    $XmlWriter.WriteAttributeString('date', (Get-Date -Date $date -Format 'yyyy-MM-dd'))
    $XmlWriter.WriteAttributeString('time', (Get-Date -Date $date -Format 'HH:mm:ss'))

}

function Write-NUnitTestResultChildNodes($PesterState, [System.Xml.XmlWriter] $XmlWriter)
{
    Write-NUnitEnvironmentInformation @PSBoundParameters
    Write-NUnitCultureInformation @PSBoundParameters

    $XmlWriter.WriteStartElement('test-suite')
    Write-NUnitGlobalTestSuiteAttributes @PSBoundParameters

    $XmlWriter.WriteStartElement('results')

    Write-NUnitDescribeElements @PSBoundParameters

    $XmlWriter.WriteEndElement()
    $XmlWriter.WriteEndElement()
}

function Write-NUnitEnvironmentInformation($PesterState, [System.Xml.XmlWriter] $XmlWriter)
{
    $XmlWriter.WriteStartElement('environment')

    $environment = Get-RunTimeEnvironment
    foreach ($keyValuePair in $environment.GetEnumerator()) {
        $XmlWriter.WriteAttributeString($keyValuePair.Name, $keyValuePair.Value)
    }

    $XmlWriter.WriteEndElement()
}

function Write-NUnitCultureInformation($PesterState, [System.Xml.XmlWriter] $XmlWriter)
{
    $XmlWriter.WriteStartElement('culture-info')

    $XmlWriter.WriteAttributeString('current-culture', ([System.Threading.Thread]::CurrentThread.CurrentCulture).Name)
    $XmlWriter.WriteAttributeString('current-uiculture', ([System.Threading.Thread]::CurrentThread.CurrentUiCulture).Name)

    $XmlWriter.WriteEndElement()
}

function Write-NUnitGlobalTestSuiteAttributes($PesterState, [System.Xml.XmlWriter] $XmlWriter)
{
    $XmlWriter.WriteAttributeString('type', 'Powershell')
    $XmlWriter.WriteAttributeString('name', $PesterState.Path)
    $XmlWriter.WriteAttributeString('executed', 'True')

    $isSuccess = $PesterState.FailedCount -eq 0
    $result = if ($isSuccess) { 'Success' }  else { 'Failure'}
    $XmlWriter.WriteAttributeString('result', $result)
    $XmlWriter.WriteAttributeString('success',[string]$isSuccess)
    $XmlWriter.WriteAttributeString('time',(Convert-TimeSpan $PesterState.Time))
    $XmlWriter.WriteAttributeString('asserts','0')
}

function Write-NUnitDescribeElements($PesterState, [System.Xml.XmlWriter] $XmlWriter)
{
    $Describes = $PesterState.TestResult | Group-Object -Property Describe
    foreach ($currentDescribe in $Describes)
    {
        $DescribeInfo = Get-TestSuiteInfo $currentDescribe

        #Write test suites
        $XmlWriter.WriteStartElement('test-suite')

        Write-NUnitTestSuiteAttributes -TestSuiteInfo $DescribeInfo -TestSuiteType 'PowerShell' -XmlWriter $XmlWriter

        $XmlWriter.WriteStartElement('results')

        Write-NUnitDescribeChildElements -TestResults $currentDescribe.Group -XmlWriter $XmlWriter

        $XmlWriter.WriteEndElement() #Close results tag
        $XmlWriter.WriteEndElement() #Close test-suite tag
    }

}

function Get-TestSuiteInfo ($TestSuiteGroup) {
    $suite = @{
        resultMessage = 'Failure'
        success = 'False'
        totalTime = '0.0'
        name = $TestSuiteGroup.name
    }

    #calculate the time first, I am converting the time into string in the TestCases
    $suite.totalTime = (Get-TestTime $TestSuiteGroup.Group)
    $suite.success = (Get-TestSuccess $TestSuiteGroup.Group)
    if($suite.success -eq 'True')
    {
        $suite.resultMessage = 'Success'
    }
    $suite
}

function Get-TestTime($tests) {
    [TimeSpan]$totalTime = 0;
    if ($tests)
    {
        foreach ($test in $tests)
        {
            $totalTime += $test.time
        }
    }

    Convert-TimeSpan -TimeSpan $totalTime
}
function Convert-TimeSpan {
    param (
        [Parameter(ValueFromPipeline=$true)]
        $TimeSpan
    )
    process {
        if ($TimeSpan) {
            [string][math]::round(([TimeSpan]$TimeSpan).totalseconds,4)
        }
        else
        {
            '0'
        }
    }
}
function Get-TestSuccess($tests) {
    $result = $true
    if ($tests)
    {
        foreach ($test in $tests) {
            if (-not $test.Passed) {
                $result = $false
                break
            }
        }
    }
    [String]$result
}
function Write-NUnitTestSuiteAttributes($TestSuiteInfo, [System.Xml.XmlWriter] $XmlWriter, [string] $TestSuiteType)
{
    $XmlWriter.WriteAttributeString('type', $TestSuiteType)
    $XmlWriter.WriteAttributeString('name', $TestSuiteInfo.name)
    $XmlWriter.WriteAttributeString('executed', 'True')
    $XmlWriter.WriteAttributeString('result', $TestSuiteInfo.resultMessage)
    $XmlWriter.WriteAttributeString('success', $TestSuiteInfo.success)
    $XmlWriter.WriteAttributeString('time',$TestSuiteInfo.totalTime)
    $XmlWriter.WriteAttributeString('asserts','0')
}

function Write-NUnitDescribeChildElements([object[]] $TestResults, [System.Xml.XmlWriter] $XmlWriter)
{
    $suites = $TestResults | Group-Object -Property ParameterizedSuiteName

    foreach ($suite in $suites)
    {
        if ($suite.Name)
        {
            $suiteInfo = Get-TestSuiteInfo $suite

            $XmlWriter.WriteStartElement('test-suite')

            Write-NUnitTestSuiteAttributes -TestSuiteInfo $suiteInfo -TestSuiteType 'ParameterizedTest' -XmlWriter $XmlWriter

            $XmlWriter.WriteStartElement('results')
        }

        Write-NUnitTestCaseElements -TestResults $suite.Group -XmlWriter $XmlWriter

        if ($suite.Name)
        {
            $XmlWriter.WriteEndElement()
            $XmlWriter.WriteEndElement()
        }

    }

}

function Write-NUnitTestCaseElements([object[]] $TestResults, [System.Xml.XmlWriter] $XmlWriter)
{
    #Write test-results
    foreach ($testResult in $TestResults)
    {
        $XmlWriter.WriteStartElement('test-case')

        Write-NUnitTestCaseAttributes -TestResult $testResult -XmlWriter $XmlWriter

        $XmlWriter.WriteEndElement()
    }
}

function Write-NUnitTestCaseAttributes($TestResult, [System.Xml.XmlWriter] $XmlWriter)
{
    $XmlWriter.WriteAttributeString('name', $TestResult.Name)
    $XmlWriter.WriteAttributeString('executed', 'True')
    $XmlWriter.WriteAttributeString('time', (Convert-TimeSpan $TestResult.Time))
    $XmlWriter.WriteAttributeString('asserts', '0')
    $XmlWriter.WriteAttributeString('success', $TestResult.Passed)

    if ($TestResult.Passed)
    {
        $XmlWriter.WriteAttributeString('result', 'Success')
    }
    else
    {
        $XmlWriter.WriteAttributeString('result', 'Failure')

        $XmlWriter.WriteStartElement('failure')

        $xmlWriter.WriteElementString('message', $TestResult.FailureMessage)
        $XmlWriter.WriteElementString('stack-trace', $TestResult.StackTrace)

        $XmlWriter.WriteEndElement()
    }
}
function Get-RunTimeEnvironment() {
    $osSystemInformation = (Get-WmiObject Win32_OperatingSystem)
    @{
        'nunit-version' = '2.5.8.0'
        'os-version' = $osSystemInformation.Version
        platform = $osSystemInformation.Name
        cwd = (Get-Location).Path #run path
        'machine-name' = $env:ComputerName
        user = $env:Username
        'user-domain' = $env:userDomain
        'clr-version' = $PSVersionTable.ClrVersion.ToString()
    }
}

function Exit-WithCode ($FailedCount) {
    $host.SetShouldExit($FailedCount)
}
