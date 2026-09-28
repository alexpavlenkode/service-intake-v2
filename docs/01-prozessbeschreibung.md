# Prozessbeschreibung: Auftragseingang Hausservice GmbH

> **Portfolio-Referenzcase:** Dieses Projekt bildet einen realistischen
> Service-Intake-Prozess für einen mittelständischen Servicebetrieb ab.
> Konzipiert wurden Prozessmodell, Datenmodell, Automatisierung,
> Fehlerbehandlung, Berechtigungskonzept, Monitoring und Deployment.
> Unternehmens- und Testdaten sind synthetisch; die
> Wirtschaftlichkeitsbetrachtung basiert auf transparent ausgewiesenen
> Planungsannahmen.

**Dokument:** 01 Prozessbeschreibung · **Version:** 3 · **Stand:** [Datum] · **Autor:** Alex [Nachname]

---

## 0. Zweck des Dokuments und mein Beitrag

Dieses Dokument beschreibt den fachlichen Rahmen für die Automatisierung des
Auftragseingangs. Die fachliche Prozessdefinition erfolgt bewusst vor der
technischen Umsetzung, da die entscheidenden Fragen zunächst Prozess,
Zuständigkeit und Fehlerverhalten betreffen.

**Aufgabenstellung:** Aus einem unstrukturierten E-Mail-Eingang einen
nachvollziehbaren, wiederholbaren und betreibbaren Prozess machen, der auch im
Fehlerfall ein definiertes Verhalten zeigt.

Zentrale von mir getroffene Entwurfsentscheidungen:

1. **Trennung von Nachricht und Auftrag.** Eine eingehende Nachricht und ein
   Auftrag haben eigene Lebenszyklen. Eine Nachricht kann Dublette oder nicht
   relevant sein und nie zu einem Auftrag werden; ein Auftrag kann mehrere
   Nachrichten haben. Beides in einem Statusfeld zu führen, macht spätere
   Auswertung und Fehlersuche unmöglich.
2. **Zwei Stufen der Dublettenerkennung** (Abschnitt 6): technische Idempotenz
   entscheidet automatisch, fachliche Ähnlichkeit entscheidet nie allein.
3. **Zwei getrennte Queues** (Abschnitt 7): fachliche Klärung durch den
   Disponenten, technisches Scheitern durch automatischen Retry und, wenn das
   nicht hilft, durch eine Dead-Letter-Queue.
4. **Zentral definierte Statusübergänge** (Abschnitt 5). Nicht jeder Automatismus
   darf jeden Status setzen. Ein doppelt ausgelöster Ablauf darf einen bereits
   zugewiesenen Auftrag nicht zurücksetzen.
5. **Protokollierung jedes Verarbeitungsversuchs** (Abschnitt 8), nicht nur des
   Endergebnisses. Die Run History der Plattform beantwortet die Frage
   "warum steht dieser Auftrag so da" nicht.
6. **Berechtigungen über Rollen im Datenmodell**, nicht über gefilterte Ansichten
   in der Oberfläche.

Der Wert liegt nicht im Bauen der Flows, sondern in diesen Festlegungen: Sie
entscheiden darüber, ob der Prozess nach sechs Monaten Betrieb noch
beherrschbar ist.

## 1. Ausgangslage

Die Hausservice GmbH (ca. 45 Mitarbeitende, davon 18 im Außendienst) übernimmt
Kleinreparaturen und Wartung für Hausverwaltungen und Gewerbekunden im Raum
Leipzig. Aufträge kommen fast ausschließlich per E-Mail an ein gemeinsames
Postfach (`auftrag@hausservice-gmbh.example`).

Angenommenes Mengengerüst: rund **900 Nachrichten** im Monat, daraus etwa
**600 Aufträge**. Zwei Disponentinnen übertragen die Angaben von Hand in eine
Excel-Liste und verteilen die Arbeit per Telefon und Messenger.

**Was daran heute weh tut**

- Dieselbe Anfrage wird mehrfach erfasst, wenn ein Kunde nachfasst oder eine
  Hausverwaltung die Mail intern weiterleitet.
- Rückfragen und Terminzusagen stehen verteilt in einzelnen Postfächern; wer
  nicht im Verteiler war, sieht den aktuellen Stand nicht.
- Fehlt eine Angabe, bleibt die Mail liegen, ohne dass jemand die Wiedervorlage
  steuert.
- Niemand kann belastbar sagen, wie viele Anfragen unbearbeitet geblieben sind.
  Eine Anfrage, die niemand anfasst, erzeugt keine Fehlermeldung.

### 1.1 Einordnung von Umfang und Architekturtiefe

Der bewusst überschaubare Geschäftsfall dient als Referenzprozess. Die
Architekturprinzipien — Idempotenz, definierte Statusübergänge, Trennung von
fachlicher Klärung und technischem Fehler, durchgängige Protokollierung,
umgebungsunabhängiges Deployment — wurden so gewählt, dass sie auch bei
höherem Volumen, weiteren Eingangskanälen (Portal, Telefonnotiz, API) und
mehreren Mandanten tragen.

Für 900 Nachrichten im Monat wäre eine schlankere Lösung denkbar. Die
Mehrkosten entstehen hier nicht im Betrieb, sondern einmalig im Entwurf; im
Gegenzug bleibt der Prozess auditierbar und erweiterbar. Wo eine Vereinfachung
für kleine Betriebe sinnvoll ist, ist sie in Abschnitt 13 vermerkt.

## 2. Rollen

| Rolle | Verantwortung | Zugriff |
| --- | --- | --- |
| **Disponent** | Prüft den Eingang, klärt fehlende Angaben, entscheidet über potenzielle Dubletten, weist Aufträge zu | Alle Aufträge, Eingangsregister, Klärungsqueue |
| **Techniker** | Nimmt zugewiesene Aufträge an, dokumentiert Durchführung und Rückmeldung | Nur eigene zugewiesene Aufträge |
| **Auditor / Teamleitung** | Prüft Nachvollziehbarkeit, Laufzeiten, Eskalationen; ändert keine Aufträge | Lesend auf alle Aufträge und das Verarbeitungsprotokoll |
| **Plattformbetreuer** | Bearbeitet die technische Fehlerqueue, stößt Wiederholungen an | Dead-Letter-Queue, Protokoll, Konfiguration |
| *(System)* | Verarbeitet Nachrichten, legt Aufträge an, protokolliert jeden Versuch | Technisches Konto mit minimalen Rechten |

Die Trennung von Disponent und Techniker wird über Security Roles in Dataverse
abgebildet, **nicht** über gefilterte Ansichten in der App.

## 3. Ist-Prozess (As-is)

1. Kunde schickt eine E-Mail an das Sammelpostfach.
2. Disponentin liest die Mail und entscheidet aus dem Gedächtnis, ob es ein
   neuer Auftrag ist.
3. Sie überträgt Kunde, Objekt, Problem und Wunschtermin in die Excel-Liste und
   vergibt manuell eine Auftragsnummer.
4. Fehlen Angaben, antwortet sie dem Kunden und markiert die Mail als ungelesen.
5. Sie ruft einen Techniker an; die Zuweisung steht nur in der Spalte "Monteur".
6. Der Techniker meldet die Erledigung telefonisch zurück; die Disponentin
   pflegt den Status nach und schreibt dem Kunden.

**Bruchstellen:** Schritt 2 (Dubletten nur im Kopf), Schritt 3 (manuelle
Übertragung), Schritt 4 (keine gesteuerte Wiedervorlage), Schritt 6 (Status
hängt an einer Person).

## 4. Soll-Prozess (To-be)

1. Jede eingehende Nachricht wird zuerst **unverändert im Eingangsregister**
   gespeichert, mit Provider-Message-ID, Zeitstempel und Absender.
2. **Technische Idempotenzprüfung** über die Message-ID (Abschnitt 6, Stufe 1).
3. Ein deterministischer Parser liest strukturierte Angaben aus. Nur bei freiem
   Text ergänzt ein KI-Schritt die Extraktion; das Ergebnis durchläuft dieselbe
   Validierung.
4. **Fachliche Validierung:** Kunde bekannt, Objektadresse plausibel,
   Auftragsart zulässig, Pflichtfelder vorhanden.
5. **Fachliche Dublettenprüfung** (Abschnitt 6, Stufe 2). Treffer führen zu
   *Potenzielle Dublette*, nicht zur automatischen Verwerfung.
6. Bei bestandener Prüfung entsteht ein **Work Order** im Status *Neu*; die
   Nachricht wird ihm zugeordnet.
7. Fehlt etwas fachlich, geht die Nachricht in die **Klärungsqueue**. Nach
   Ergänzung wird sie erneut verarbeitet, ohne dass der Kunde neu schreiben muss.
8. Scheitert ein technischer Schritt, greift begrenzter Retry; danach
   **Dead-Letter-Queue** mit kontrolliertem Replay.
9. Der Disponent weist den Auftrag einem Techniker zu.
10. Die Eingangsbestätigung geht nur über eine geprüfte Vorlage automatisch
    raus; jede andere Antwort gibt der Disponent frei.
11. Jeder Verarbeitungsversuch wird protokolliert (Abschnitt 8).

**Leitsatz:** Keine Nachricht verschwindet still. Jede vom System angenommene
Nachricht hat jederzeit einen bekannten Status.

## 5. Statusmodell

### 5.1 Nachricht (Message)

Hauptpfad: `Received → Parsed → Validated → Converted`

Nebenzustände: `Needs Clarification`, `Potential Duplicate`, `Duplicate`,
`Not Relevant`, `Technical Retry`, `Failed (Dead Letter)`, `Linked` (Antwort zu
einem bestehenden Auftrag).

| Von | Nach | Auslöser |
| --- | --- | --- |
| Received | Parsed | Parser erfolgreich |
| Received | Duplicate | Message-ID bereits verarbeitet |
| Received / Parsed | Technical Retry | temporärer Fehler (429, Timeout, 5xx) |
| Technical Retry | Parsed / Validated | Wiederholung erfolgreich |
| Technical Retry | Failed | Retry-Budget erschöpft |
| Parsed | Validated | alle Pflichtfelder und Regeln erfüllt |
| Parsed | Needs Clarification | Pflichtfeld fehlt oder Regel verletzt |
| Parsed | Not Relevant | keine Auftragsanfrage |
| Needs Clarification | Parsed | Angaben ergänzt, erneute Verarbeitung |
| Validated | Potential Duplicate | fachlicher Treffer im Zeitfenster |
| Potential Duplicate | Converted / Duplicate | Entscheidung des Disponenten, mit Begründung |
| Validated | Converted | Auftrag angelegt |
| Validated | Linked | Nachricht gehört zu bestehendem Auftrag |
| Failed | Technical Retry | manueller Replay durch Plattformbetreuer |

### 5.2 Auftrag (Work Order)

`Neu → Zugewiesen → In Arbeit → Abgeschlossen`, dazu `Storniert`.

### 5.3 Regel für Automatismen

Statusübergänge sind zentral definiert und werden vor dem Schreiben validiert.
Ein Automatismus darf nur Übergänge auslösen, die für seinen Auslöser erlaubt
sind. Läuft ein Ablauf doppelt und ist der Zielzustand bereits erreicht oder
überholt, endet er ohne Änderung und schreibt einen Protokolleintrag
`skipped – invalid transition`. Ein bereits zugewiesener Auftrag wird durch eine
erneut eintreffende Kopie der Ursprungsmail nicht zurückgesetzt.

## 6. Dublettenerkennung in zwei Stufen

**Stufe 1 — technische Idempotenz.** Schlüssel ist die unveränderliche
Provider-Message-ID. Eine bereits verarbeitete ID wird ohne Rückfrage als
`Duplicate` abgelegt. Diese Stufe entscheidet automatisch, weil sie eindeutig ist.

**Stufe 2 — fachliche Dublette.** Kunde + Objekt + normalisierter Inhalt
(Kleinschreibung, Stoppwörter entfernt, Gewerk und Ort im Objekt extrahiert)
innerhalb eines Zeitfensters von 72 Stunden. Ein Treffer setzt den Status
`Potential Duplicate` und zeigt dem Disponenten den **Match-Grund** und den
Vergleichsauftrag. Die Entscheidung trifft der Mensch und wird mit Begründung
dokumentiert.

Begründung für die Trennung: "Wasserhahn Küche defekt" und zwei Stunden später
"Wasserhahn Bad defekt" sind fachlich ähnlich und trotzdem zwei Aufträge. Eine
automatische Unterdrückung würde hier einen echten Auftrag verschlucken — der
teuerste denkbare Fehler in diesem Prozess. Falsch-positive Treffer kosten hier
nur einen Klick, ein verlorener Auftrag kostet einen Kunden.

## 7. Ausnahmen: zwei Queues

Nicht jede Ausnahme ist ein Fehler. Fachliche Klärung und technisches Scheitern
werden getrennt behandelt, weil sie unterschiedliche Verantwortliche,
Reaktionszeiten und Behandlungen haben.

| Merkmal | Klärungsqueue (Business Exception) | Dead-Letter-Queue (Technical Failure) |
| --- | --- | --- |
| Zuständig | Disponent | Plattformbetreuer |
| Ursache | Angaben fehlen, Regel verletzt, Zuordnung unklar | API nicht erreichbar, 429, Verbindung entzogen, Schemafehler |
| Automatik | kein automatischer Retry | begrenzter Retry mit Backoff |
| Auflösung | Mensch ergänzt, dann erneute Verarbeitung | Replay nach Behebung der Ursache |
| Sichtbarkeit | Arbeitsvorrat in der Disponenten-App | Technisches Dashboard, Alarm |

### Fünf typische fachliche Ausnahmen

| # | Ausnahme | Erwartetes Verhalten |
| --- | --- | --- |
| 1 | **Dublette / Weiterleitung** | Stufe 1 entscheidet automatisch, Stufe 2 legt dem Disponenten eine Entscheidung mit Match-Grund vor. Kein zweiter Auftrag ohne Entscheidung. |
| 2 | **Unvollständige Angaben** | Status *Needs Clarification* mit Grund; Wiedervorlage nach 24 h; nach Ergänzung erneute Verarbeitung ohne neue Kundenmail. |
| 3 | **Antwort im bestehenden Vorgang** | Status *Linked*: Nachricht wird als Kommunikation am vorhandenen Auftrag gespeichert, kein neuer Auftrag, Auftragsstatus unverändert. |
| 4 | **Freitext oder Anhang** | Deterministischer Parser scheitert, KI-Extraktion liefert Vorschlag, gleiche Validierung, Bestätigung durch den Disponenten. |
| 5 | **Nicht zuständig** | Status *Not Relevant* mit Grund; bleibt im Eingangsregister nachweisbar, erzeugt keinen Auftrag. |

### Technische Fehlerfälle (Testumfang Woche 4)

429 vom Zielsystem, Zielsystem nicht erreichbar, Verbindung entzogen,
Abbruch mitten in der Verarbeitung, Schema der Antwort weicht ab.

## 8. Verarbeitungsprotokoll (Processing Attempt)

Pro Verarbeitungsversuch und Stufe ein Eintrag:

| Feld | Zweck |
| --- | --- |
| Correlation ID | Verbindet alle Schritte einer Nachricht |
| Attempt Number | Wievielter Versuch |
| Stage | Parse, Validate, Duplicate Check, Create, ERP, Notify |
| Result | Success, Business Exception, Technical Failure, Skipped |
| Retryable | Ja/Nein — Grundlage der Retry-Entscheidung |
| Reason Code | Maschinenlesbar, z. B. `MISSING_OBJECT_ADDRESS`, `HTTP_429` |
| Duration (ms) | Erkennung von Laufzeitproblemen |
| Triggered By | Automatischer Lauf, manueller Replay, Benutzeraktion |
| Previous Attempt | Verkettung der Versuche |
| Response Status | Statuscode ohne fachlichen Inhalt der Antwort |
| Component Version | Welche Version der Lösung war aktiv |

Beispiel eines Verlaufs, wie er in der Demo gezeigt wird:

| Attempt | Stage | Result | Reason |
| --- | --- | --- | --- |
| 1 | Parse | Success | — |
| 1 | Validate | Success | — |
| 1 | ERP | Technical Failure | HTTP_429 |
| 2 | ERP | Technical Failure | HTTP_429 |
| 3 | ERP | Success | — |

Der Mailinhalt wird nicht vollständig ins Protokoll geschrieben; gespeichert
werden Schlüssel, Statuscodes und Gründe.

## 9. Nicht-funktionale Anforderungen

| Bereich | Anforderung |
| --- | --- |
| Nachvollziehbarkeit | Jede Nachricht besitzt eine Correlation ID; jeder Versuch ist protokolliert |
| Idempotenz | Wiederholte Verarbeitung derselben Nachricht erzeugt keinen zweiten Auftrag und keine zweite Kundenmail |
| Recoverability | Jede gescheiterte Verarbeitung ist ohne Zutun des Kunden wiederholbar |
| Security | Least Privilege; Techniker sehen ausschließlich eigene Datensätze; Rechte im Datenmodell, nicht in der UI |
| Datenschutz | Kein vollständiger Mailinhalt in technischen Logs; Aufbewahrungsdauer definiert |
| Performance | Standardnachrichten werden innerhalb von 5 Minuten nach Eingang verarbeitet |
| Deployability | Keine hart codierten URLs, IDs oder Mailadressen in Flows oder Apps |
| Observability | Backlog, älteste ungeklärte Nachricht und technische Fehler sind auf einem Dashboard sichtbar |

## 10. Abgrenzung

Nicht Bestandteil: Angebotserstellung, Rechnungsstellung, Materialwirtschaft,
Routenoptimierung, mobile App für Techniker. Die ERP-Anbindung wird über ein
Mock-API simuliert.

## 11. Kennzahlen und Modellrechnung

**Angenommene Baseline**

| Kennzahl | Ist (Annahme) | Ziel |
| --- | --- | --- |
| Aktive Bearbeitungszeit je Auftrag | 8 min | 2 min |
| Anteil manuell nachzubearbeitender Eingänge | ca. 100 % | < 25 % |
| Zeit bis zur Zuweisung | mehrere Stunden | < 30 min |

**Operative Kennzahlen im Betrieb**

| Kennzahl | Ziel |
| --- | --- |
| Untracked Messages (angenommene Nachricht ohne bekannten Status) | 0 |
| Exception Backlog (offene Klärungen) | wird täglich ausgewiesen |
| Alter der ältesten ungeklärten Nachricht | < 24 h |
| Dead-Letter-Einträge ohne Replay | 0 am Tagesende |

Die Kennzahl *Untracked Messages* gilt ab dem Moment, in dem eine Nachricht im
Postfach angenommen wurde. Ob eine Mail den Server überhaupt erreicht hat, kann
dieses System nicht beweisen.

**Modellrechnung.** Bei 600 Aufträgen im Monat und einer Reduktion der aktiven
Bearbeitungszeit von 8 auf 2 Minuten entfallen rechnerisch rund 60 von 80
Stunden manueller Arbeit im Monat.

*Modellrechnung auf Basis der angenommenen Baseline, keine gemessene
Produktivitätssteigerung.* Freigewordene Stunden sind zunächst zusätzliche
Kapazität; zu einer Einsparung werden sie erst, wenn dadurch Überstunden,
externe Unterstützung oder eine geplante Einstellung entfallen.

## 12. Abnahmekriterien

1. 30 korrekte Testmails erzeugen 30 Aufträge ohne manuellen Eingriff.
2. Eine erneut gesendete Nachricht mit identischer Message-ID erzeugt keinen
   zweiten Auftrag.
3. Eine fachlich ähnliche Nachricht wird als *Potential Duplicate* mit
   Match-Grund vorgelegt und nicht automatisch verworfen.
4. Eine Nachricht mit fehlendem Pflichtfeld landet in der Klärungsqueue und
   lässt sich nach Ergänzung erneut verarbeiten, ohne eine zweite Kundenmail
   auszulösen.
5. Ein Zielsystemfehler (429) führt zu begrenztem Retry und bei Erschöpfung zu
   einem Dead-Letter-Eintrag mit möglichem Replay.
6. Ein doppelt ausgelöster Ablauf setzt einen bereits zugewiesenen Auftrag nicht
   zurück; der Protokolleintrag weist `skipped – invalid transition` aus.
7. Ein Techniker sieht ausschließlich die ihm zugewiesenen Aufträge, geprüft mit
   zwei Testbenutzern.
8. Jeder Verarbeitungsversuch ist über die Correlation ID nachvollziehbar.
9. Alle umgebungsspezifischen Werte werden über Environment Variables und
   Connection References konfiguriert. Nach dem Import in eine zweite Umgebung
   sind keine Änderungen an Flows oder Apps erforderlich.

## 13. Offene Punkte

- Aufbewahrungsdauer für Eingangsregister und Protokoll festlegen.
- Normalisierungsregeln für die fachliche Dublettenprüfung am Testdatensatz
  kalibrieren und Trefferqualität dokumentieren.
- Entscheidung dokumentieren, warum Dataverse und nicht SharePoint-Listen
  (Beziehungen, Ownership, Rollen, Auditierbarkeit).
- Reduzierte Variante für sehr kleine Betriebe beschreiben: gemeinsame Queue
  mit Kennzeichen statt zweier Queues, Verzicht auf Component Versioning.
  Welche Prinzipien dabei erhalten bleiben müssen und welche entfallen können.
