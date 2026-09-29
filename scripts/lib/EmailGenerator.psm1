<#
    Generates realistic-sounding synthetic customer emails for
    demo-pipeline.ps1 and serve-live-console.ps1 - varied enough (customers,
    objects, complaint styles, tone, greetings/closings) that running 50-100
    of them doesn't produce visibly repeated content.

    This is still not an AI text generator - it's combinatorial templating
    (pick a body, wrap it in a random greeting/closing, mix in a random
    customer/object/urgency), but with enough source variety that the
    combinations rarely repeat exactly, which is the actual complaint this
    module exists to fix.
#>

Set-StrictMode -Version Latest

$script:Customers = @(
    @{ Name = 'Hausverwaltung Nord';        Objects = @(@{ Number='N-01'; Street='Ludwigstr. 12' }, @{ Number='N-02'; Street='Ludwigstr. 30' }, @{ Number='N-03'; Street='Delitzscher Str. 8' }) }
    @{ Name = 'Gewerbepark Sued';           Objects = @(@{ Number='S-01'; Street='Suedring 4' }, @{ Number='S-02'; Street='Suedring 19' }) }
    @{ Name = 'Wohnpark Alt-Leipzig';       Objects = @(@{ Number='A-01'; Street='Karl-Liebknecht-Str. 88' }, @{ Number='A-02'; Street='Karl-Liebknecht-Str. 102' }, @{ Number='A-03'; Street='Bornaische Str. 55' }) }
    @{ Name = 'Buerohaus Connewitz';        Objects = @(@{ Number='C-01'; Street='Ratsstr. 3' }, @{ Number='C-02'; Street='Wolfgang-Heinze-Str. 21' }) }
    @{ Name = 'Wohnungsgenossenschaft West';Objects = @(@{ Number='W-01'; Street='Lindenauer Markt 2' }, @{ Number='W-02'; Street='Merseburger Str. 47' }, @{ Number='W-03'; Street='Zschochersche Str. 14' }) }
    @{ Name = 'Immobilien Schmidt & Partner';Objects = @(@{ Number='P-01'; Street='Peterssteinweg 9' }, @{ Number='P-02'; Street='Riemannstr. 33' }) }
    @{ Name = 'Studentenwerk Leipzig Ost';  Objects = @(@{ Number='E-01'; Street='Eisenbahnstr. 60' }, @{ Number='E-02'; Street='Eisenbahnstr. 74' }) }
)

$script:TradeBodies = @{
    Sanitaer = @(
        'Der Wasserhahn in der Kueche tropft seit Tagen, egal wie fest ich zudrehe.'
        'Im Bad ist die Toilettenspuelung kaputt, das Wasser laeuft staendig nach.'
        'Wir haben einen Rohrbruch im Keller entdeckt, es steht bereits Wasser auf dem Boden.'
        'Die Dusche im 2. OG hat kaum noch Wasserdruck, seit letzter Woche.'
        'Der Abfluss in der Spuele ist komplett verstopft, das Wasser laeuft nicht mehr ab.'
        'Aus der Heizungsanlage im Keller tropft Wasser auf den Boden, sieht nach einem Leck aus.'
        'Das Warmwasser wird nur noch lauwarm, obwohl der Boiler auf Maximum steht.'
        'In der Gaestewohnung ist der Wasserhahn im Bad abgebrochen, man kann kein Wasser mehr abstellen.'
        'Unter der Spuele in der Teekueche hat sich eine grosse Pfuetze gebildet.'
        'Die Toilette im Erdgeschoss laeuft seit heute frueh ununterbrochen.'
    )
    Elektro = @(
        'Im Flur funktionieren zwei von drei Lichtschaltern nicht mehr.'
        'Die Steckdose neben dem Schreibtisch gibt keinen Strom mehr, andere im Raum gehen noch.'
        'Seit dem Gewitter am Wochenende faellt im ganzen Buero regelmaessig der Strom aus.'
        'Das Licht im Treppenhaus flackert und geht manchmal ganz aus.'
        'Der Sicherungskasten im Keller macht komische Gerauesche, ein Kollege meinte es riecht verbrannt.'
        'Im Besprechungsraum funktioniert die Deckenbeleuchtung gar nicht mehr.'
        'Die Aussenbeleuchtung am Eingang schaltet sich seit ein paar Tagen nicht mehr automatisch ein.'
        'In der Kueche ist eine Steckdose beim Anschliessen der Kaffeemaschine kurz durchgebrannt.'
        'Der Bewegungsmelder im Hausflur reagiert nicht mehr zuverlaessig.'
        'Wir haben einen Kurzschluss im Serverraum, die Sicherung fliegt alle paar Stunden raus.'
    )
    Heizung = @(
        'Die Heizung im Wohnzimmer wird nicht mehr richtig warm, obwohl sie auf Stufe 5 steht.'
        'Seit heute morgen kommt kein warmes Wasser mehr aus der Heizung im Bad.'
        'Der Heizkoerper im Kinderzimmer macht laute Klopfgeraeusche in der Nacht.'
        'Die zentrale Heizungsanlage im Keller ist komplett ausgefallen, es ist kalt im ganzen Haus.'
        'Ein Heizkoerper im 3. Stock tropft an der Verschraubung.'
        'Die Fussbodenheizung im Bad reagiert nicht mehr auf den Thermostat.'
        'Im Flur ist die Heizung eiskalt, waehrend die anderen Raeume normal warm werden.'
        'Wir vermuten Luft in der Heizungsanlage, mehrere Heizkoerper werden nur oben warm.'
        'Der Heizkessel zeigt einen Fehlercode an und die Anlage schaltet sich staendig ab.'
        'Seit dem Wochenende gluckert es in der Heizung im gesamten Erdgeschoss.'
    )
    Schliessanlage = @(
        'Der Hauptschluessel passt nicht mehr in das neue Schloss am Haupteingang.'
        'Die elektronische Tuer am Hintereingang oeffnet nicht mehr, auch nicht mit der Karte.'
        'Ein Schluessel ist im Schloss der Kellertuer abgebrochen.'
        'Die Gegensprechanlage am Eingang funktioniert seit gestern nicht mehr.'
        'Das automatische Tor zur Tiefgarage bleibt haengen und schliesst nicht richtig.'
        'Wir brauchen dringend einen Ersatzschluessel fuer das Buero im 1. Stock, der alte ist verloren gegangen.'
        'Der Fluchttuer-Oeffner am Notausgang klemmt und laesst sich nur mit Kraft bedienen.'
        'Das Schloss an der Poststation ist verklemmt, wir kommen nicht mehr an die Post.'
    )
    Sonstiges = @(
        'Die Aussentuer am Haupteingang schliesst nicht mehr richtig, es zieht staendig.'
        'Im Treppenhaus ist eine Fliese lose und stellt eine Stolpergefahr dar.'
        'Der Aufzug bleibt seit gestern manchmal zwischen den Stockwerken stehen.'
        'Ein Fenster im 2. Stock laesst sich nicht mehr richtig schliessen.'
        'Die Fassade hat nach dem Sturm einen sichtbaren Riss bekommen.'
        'Der Briefkasten Nr. 14 ist beschaedigt und laesst sich nicht mehr abschliessen.'
        'Im Hof steht seit dem Regen eine grosse Pfuetze, der Ablauf scheint verstopft.'
        'Die Markise ueber dem Eingang haengt schief und laesst sich nicht mehr einfahren.'
    )
}

$script:Greetings = @(
    'Sehr geehrte Damen und Herren,'
    'Hallo zusammen,'
    'Guten Tag,'
    'Liebes Hausservice-Team,'
    'Hallo,'
    ''  # some people just start writing
)
$script:Closings = @(
    "Mit freundlichen Gruessen`nA. Mueller"
    "Vielen Dank im Voraus`nT. Schneider"
    "Bitte um kurzfristige Rueckmeldung.`nGruss, K. Weber"
    "Danke und viele Gruesse`nS. Hoffmann"
    "Beste Gruesse`nJ. Becker"
    ''
)
$script:UrgencyPrefixes = @('', '', '', 'Dringend: ', 'Bitte zeitnah: ', 'Wichtig: ')

$script:NotARequestTemplates = @(
    @{ Subject = 'Automatische Antwort: Abwesenheit'; Body = 'Ich bin ab sofort bis zum naechsten Montag nicht im Buero. Ihre Nachricht wird nicht weitergeleitet.' }
    @{ Subject = 'Unser Newsletter fuer Sie'; Body = 'Entdecken Sie jetzt unsere neuen Angebote fuer Hausverwaltungen! Jetzt anmelden und profitieren.' }
    @{ Subject = 'Vielen Dank fuer die schnelle Reparatur'; Body = 'Wollte mich nur kurz bedanken, alles funktioniert wieder einwandfrei. Kein weiterer Handlungsbedarf.' }
    @{ Subject = 'Terminverschiebung Teammeeting'; Body = 'Das interne Meeting am Donnerstag wurde auf Freitag 10 Uhr verschoben.' }
    @{ Subject = 'Ihre Rechnung Nr. 4471'; Body = 'Anbei erhalten Sie wie besprochen die Rechnung fuer den letzten Monat.' }
)

function Get-RandomItem { param([array] $Items) $Items[(Get-Random -Minimum 0 -Maximum $Items.Count)] }

function New-RealisticMessage {
    <#
        .PARAMETER Scenario
            clean | technical_duplicate | business_duplicate | missing_field | not_a_request
        .PARAMETER PreviousMessages
            Array of previously generated message hashtables (this run), used
            for the two duplicate scenarios.
    #>
    param(
        [ValidateSet('clean','technical_duplicate','business_duplicate','missing_field','not_a_request')]
        [string] $Scenario = 'clean',
        [System.Collections.Generic.List[hashtable]] $PreviousMessages
    )

    $fromNames = @('m.krause','j.fischer','a.wagner','s.koch','t.richter','k.klein','p.wolf','n.schroeder','l.neumann','d.schwarz')
    $fromDomains = @('web-mail.example','posteingang.example','mein-provider.example','mailbox.example')
    $from = "$(Get-RandomItem $fromNames)@$(Get-RandomItem $fromDomains)"

    switch ($Scenario) {
        'technical_duplicate' {
            if ($PreviousMessages -and $PreviousMessages.Count -gt 0) {
                return Get-RandomItem $PreviousMessages.ToArray()
            }
        }
        'business_duplicate' {
            $eligible = @($PreviousMessages | Where-Object { $_.Scenario -eq 'clean' })
            if ($eligible.Count -gt 0) {
                $prev = Get-RandomItem $eligible
                return @{ From = "andere-$(Get-RandomItem $fromNames)@$(Get-RandomItem $fromDomains)"; Subject = $prev.Subject; Body = $prev.Body + ' '; CustomerName = $prev.CustomerName; ObjectNumber = $prev.ObjectNumber; Street = $prev.Street; TradeValue = $prev.TradeValue; TradeLabel = $prev.TradeLabel; Scenario = 'business_duplicate' }
            }
        }
        'not_a_request' {
            $t = Get-RandomItem $script:NotARequestTemplates
            return @{ From = $from; Subject = $t.Subject; Body = $t.Body; CustomerName = ''; ObjectNumber = ''; Street = ''; TradeValue = 209710505; TradeLabel = 'Sonstiges'; Scenario = 'not_a_request' }
        }
        'missing_field' {
            $cust = Get-RandomItem $script:Customers
            $shortBodies = @('Hallo, koennen Sie sich bitte melden?', 'Bitte um Rueckruf.', 'Wir haben ein Problem, bitte melden.', '')
            return @{ From = $from; Subject = Get-RandomItem @('Anfrage','Problem','Bitte um Kontakt',''); Body = Get-RandomItem $shortBodies; CustomerName = ''; ObjectNumber = ''; Street = ''; TradeValue = 209710505; TradeLabel = 'Sonstiges'; Scenario = 'missing_field' }
        }
    }

    # clean (default / fallback if a duplicate scenario had nothing to reuse yet)
    $cust = Get-RandomItem $script:Customers
    $obj = Get-RandomItem $cust.Objects
    $tradeNames = @('Sanitaer','Elektro','Heizung','Schliessanlage','Sonstiges')
    $tradeLabel = Get-RandomItem $tradeNames
    $tradeValues = @{ Sanitaer=209710501; Elektro=209710502; Heizung=209710503; Schliessanlage=209710504; Sonstiges=209710505 }
    $body = Get-RandomItem $script:TradeBodies[$tradeLabel]

    $greeting = Get-RandomItem $script:Greetings
    $closing = Get-RandomItem $script:Closings
    $fullBody = (@($greeting, '', $body, '', "Objekt: $($obj.Number), $($obj.Street).", '', $closing) | Where-Object { $_ -ne $null }) -join "`n"

    $prefix = Get-RandomItem $script:UrgencyPrefixes
    $subject = "$prefix$tradeLabel-Problem bei $($cust.Name)"

    return @{
        From = $from; Subject = $subject; Body = $fullBody.Trim()
        CustomerName = $cust.Name; ObjectNumber = $obj.Number; Street = $obj.Street
        TradeValue = $tradeValues[$tradeLabel]; TradeLabel = $tradeLabel; Scenario = 'clean'
    }
}

function Get-ScenarioForIndex {
    # Roughly: 70% clean, 10% business duplicate, 8% technical duplicate,
    # 7% missing field, 5% not-a-request - stays representative whether you
    # generate 5 or 500.
    param([int] $Index, [int] $PreviousCleanCount)
    $roll = Get-Random -Minimum 0.0 -Maximum 1.0
    if ($roll -lt 0.70 -or $PreviousCleanCount -eq 0) { return 'clean' }
    if ($roll -lt 0.80) { return 'business_duplicate' }
    if ($roll -lt 0.88) { return 'technical_duplicate' }
    if ($roll -lt 0.95) { return 'missing_field' }
    return 'not_a_request'
}

Export-ModuleMember -Function New-RealisticMessage, Get-ScenarioForIndex, Get-RandomItem
