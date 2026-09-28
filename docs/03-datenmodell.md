# Datenmodell (Dataverse)

**Dokument:** 03 Datenmodell · **Version:** 1 · **Stand:** [Datum] · **Autor:** Alex [Nachname]

Grundlage ist die [Prozessbeschreibung](01-prozessbeschreibung.md). Alle Tabellen
werden innerhalb der Lösung *Reliable Service Intake* mit dem Publisher-Präfix
`hsv_` angelegt, nicht in der Default-Lösung.

---

## 1. Leitgedanken des Entwurfs

1. **Nachricht und Auftrag sind getrennte Tabellen mit eigenem Lebenszyklus.**
   Eine Nachricht kann Dublette, nicht relevant oder Antwort zu einem
   bestehenden Auftrag sein und trotzdem vollständig dokumentiert bleiben.
2. **Idempotenz wird von der Datenbank erzwungen, nicht von der Ablauflogik.**
   Ein Alternate Key auf der Provider-Message-ID macht das doppelte Anlegen
   technisch unmöglich. Eine vorgeschaltete Prüfung "existiert schon?" in einem
   Flow ist bei parallelen Läufen nicht sicher.
3. **Berechtigungen liegen im Datenmodell.** Der Techniker ist Owner seines
   Auftrags; seine Rolle liest auf User-Ebene. Keine Sicherheit über
   gefilterte Ansichten.
4. **Standardtabellen vor eigenen Tabellen.** Kunde und Ansprechpartner werden
   über die Standardtabellen Account und Contact abgebildet. Eigene Tabellen
   entstehen nur dort, wo die Plattform nichts Passendes mitbringt.
5. **Protokoll ist Bewegungsdaten, nicht Log.** Verarbeitungsversuche liegen als
   Zeilen in Dataverse, damit sie auswertbar, filterbar und in der App sichtbar
   sind — mit Schlüsseln und Statuscodes, ohne vollständigen Mailinhalt.

## 2. Überblick

```
Account (Standard)
   │ 1:N
   ├── Contact (Standard)          Ansprechpartner
   ├── hsv_serviceobject           Objekt / Liegenschaft
   │        │ 1:N
   └────────┴── hsv_workorder      Auftrag
                    │ 1:N
                    └── hsv_inboundmessage   Eingangsnachricht
                              │ 1:N
                              └── hsv_processingattempt   Verarbeitungsversuch

hsv_statustransition   Konfiguration erlaubter Statusübergänge (eigenständig)
```

## 3. Tabellen

### 3.1 hsv_serviceobject — Objekt

Ownership: **Organization**. Stammdaten, keine zeilenbasierte Trennung nötig.

| Spalte | Typ | Pflicht | Hinweis |
| --- | --- | --- | --- |
| hsv_name | Text (100) | ja | Primärspalte, z. B. "Ludwigstr. 12, VG West" |
| hsv_account | Lookup → Account | ja | Eigentümer/Verwalter |
| hsv_objectnumber | Text (50) | ja | Nummer der Hausverwaltung |
| hsv_street / hsv_postalcode / hsv_city | Text | ja | Adresse |
| hsv_notes | Mehrzeilig (2000) | nein | Zugang, Schlüssel, Besonderheiten |

**Alternate Key:** `hsv_account` + `hsv_objectnumber`. Verhindert doppelte
Objekte je Kunde und erlaubt Upsert beim Import.

### 3.2 hsv_workorder — Auftrag

Ownership: **User/Team**. Der Owner ist der ausführende Techniker; darauf
stützt sich die Sichtbarkeitsregel aus der Prozessbeschreibung.

| Spalte | Typ | Pflicht | Hinweis |
| --- | --- | --- | --- |
| hsv_workordernumber | Autonummer `WO-{SEQNUM:00000}` | ja | Primärspalte, fachliche Referenz nach außen |
| hsv_title | Text (200) | ja | Kurzbeschreibung |
| hsv_description | Mehrzeilig (10000) | nein | Übernommener Sachverhalt |
| hsv_account | Lookup → Account | ja | |
| hsv_serviceobject | Lookup → hsv_serviceobject | ja | |
| hsv_contact | Lookup → Contact | nein | Ansprechpartner vor Ort |
| hsv_trade | Choice `hsv_trade` | ja | Sanitär, Elektro, Heizung, Schließanlage, Sonstiges |
| hsv_priority | Choice `hsv_priority` | ja | Standard, Dringend, Notfall |
| hsv_status | Choice `hsv_workorderstatus` | ja | Neu, Zugewiesen, In Arbeit, Abgeschlossen, Storniert |
| hsv_sourcemessage | Lookup → hsv_inboundmessage | nein | Auslösende Nachricht |
| hsv_assignedon / hsv_completedon | DateTime | nein | Gesetzt durch Statusübergang, nicht manuell |
| hsv_duedate | DateTime | nein | |
| ownerid | Owner | ja | Techniker oder Dispositionsteam |

**Alternate Key:** `hsv_workordernumber`.

Statusübergänge werden zentral validiert (Abschnitt 5). `hsv_status` ist eine
eigene Choice-Spalte; `statecode` bleibt für Aktiv/Inaktiv reserviert.

### 3.3 hsv_inboundmessage — Eingangsnachricht

Ownership: **Organization**. Techniker haben keinen Zugriff; der Eingang gehört
der Disposition.

| Spalte | Typ | Pflicht | Hinweis |
| --- | --- | --- | --- |
| hsv_name | Text (200) | ja | Primärspalte, gekürzter Betreff |
| **hsv_providermessageid** | Text (250) | ja | Unveränderliche ID des Mailanbieters |
| hsv_conversationid | Text (250) | nein | Erkennt Antworten im bestehenden Thread |
| hsv_correlationid | Text (36) | ja | GUID, verbindet alle Verarbeitungsschritte |
| hsv_receivedon | DateTime | ja | Zeitpunkt des Eingangs, nicht der Verarbeitung |
| hsv_fromaddress | Text (250) | ja | |
| hsv_subject | Text (400) | nein | |
| hsv_body | Mehrzeilig (100000) | nein | Fachdaten, gehört ins Register, nicht ins Protokoll |
| hsv_hasattachments | Ja/Nein | ja | |
| hsv_status | Choice `hsv_messagestatus` | ja | Received, Parsed, Validated, Needs Clarification, Potential Duplicate, Duplicate, Not Relevant, Linked, Converted, Technical Retry, Failed |
| hsv_reasoncode | Choice `hsv_reasoncode` | nein | z. B. MISSING_OBJECT_ADDRESS, HTTP_429, NOT_A_REQUEST |
| hsv_account / hsv_serviceobject | Lookup | nein | Ergebnis der Zuordnung |
| hsv_workorder | Lookup → hsv_workorder | nein | Gesetzt bei Converted oder Linked |
| hsv_businesskey | Text (250) | nein | Kunde + Objekt + normalisierter Inhalt |
| hsv_businesskeyhash | Text (64) | nein | SHA-256 des Business Key, für schnellen Vergleich |
| hsv_duplicateof | Lookup → hsv_inboundmessage | nein | Selbstbezug auf die Ursprungsnachricht |
| hsv_matchreason | Mehrzeilig (2000) | nein | Warum ein Treffer vorgeschlagen wurde |
| hsv_duplicatedecision | Choice | nein | Offen, Bestätigt, Verworfen |
| hsv_decidedby / hsv_decidedon | Lookup → User / DateTime | nein | Wer die Entscheidung getroffen hat |
| hsv_extractionsource | Choice | ja | Parser, KI, Manuell |
| hsv_requiresreview | Ja/Nein | ja | Standard "ja" bei KI-Extraktion |
| hsv_nextreviewon | DateTime | nein | Wiedervorlage aus der Klärungsqueue |
| hsv_retrycount | Ganzzahl | ja | Standard 0 |

**Alternate Key:** `hsv_providermessageid` — unique. Das ist die technische
Idempotenz aus Stufe 1. Ein zweiter Create-Versuch mit derselben ID scheitert
mit einem Duplicate-Key-Fehler, den die Verarbeitung abfängt und als
`Duplicate` protokolliert.

`hsv_businesskeyhash` ist bewusst **nicht** unique: Stufe 2 schlägt nur vor und
blockiert nie.

### 3.4 hsv_processingattempt — Verarbeitungsversuch

Ownership: **Organization**. Beziehung zur Nachricht als **parental**, damit
Löschen und Freigaben mitlaufen.

| Spalte | Typ | Pflicht | Hinweis |
| --- | --- | --- | --- |
| hsv_name | Autonummer `PA-{SEQNUM:000000}` | ja | Primärspalte |
| hsv_inboundmessage | Lookup | ja | |
| hsv_correlationid | Text (36) | ja | Redundant zur Nachricht, für Auswertung ohne Join |
| hsv_attemptnumber | Ganzzahl | ja | |
| hsv_stage | Choice `hsv_stage` | ja | Ingest, Parse, Validate, Duplicate Check, Create, ERP, Notify |
| hsv_result | Choice `hsv_result` | ja | Success, Business Exception, Technical Failure, Skipped |
| hsv_retryable | Ja/Nein | ja | Grundlage der Retry-Entscheidung |
| hsv_reasoncode | Choice `hsv_reasoncode` | nein | Gleiche Choice wie bei der Nachricht |
| hsv_responsestatus | Ganzzahl | nein | HTTP-Statuscode ohne Antwortinhalt |
| hsv_durationms | Ganzzahl | nein | |
| hsv_triggeredby | Choice | ja | Event, Zeitplan, Manueller Replay, Benutzeraktion |
| hsv_previousattempt | Lookup → hsv_processingattempt | nein | Verkettung |
| hsv_componentversion | Text (20) | ja | Version der Lösung zum Zeitpunkt des Laufs |
| hsv_startedon / hsv_completedon | DateTime | ja / nein | |

**Alternate Key:** `hsv_correlationid` + `hsv_attemptnumber` + `hsv_stage`.
Auch das Protokoll ist damit idempotent: ein doppelt ausgeführter Schritt
erzeugt keine doppelte Zeile.

### 3.5 hsv_statustransition — erlaubte Statusübergänge

Ownership: **Organization**, Konfigurationstabelle, in der Lösung als Daten
mitgeliefert.

| Spalte | Typ | Hinweis |
| --- | --- | --- |
| hsv_name | Text | z. B. "Message: Parsed → Validated" |
| hsv_entityname | Choice | Message, Work Order |
| hsv_fromstatus / hsv_tostatus | Text (50) | Statuswerte |
| hsv_allowedtrigger | Choice | Welcher Auslöser darf das |
| hsv_isactive | Ja/Nein | |

Damit steht die State Machine an einer Stelle und nicht verteilt in mehreren
Flows. Ein unzulässiger Übergang wird abgewiesen und als
`Skipped / INVALID_TRANSITION` protokolliert.

## 4. Beziehungen

| Von | Nach | Typ | Löschverhalten |
| --- | --- | --- | --- |
| Account | hsv_serviceobject | 1:N | Restrict |
| Account | hsv_workorder | 1:N | Restrict |
| hsv_serviceobject | hsv_workorder | 1:N | Restrict |
| Contact | hsv_workorder | 1:N | Remove Link |
| hsv_workorder | hsv_inboundmessage | 1:N | Remove Link |
| hsv_inboundmessage | hsv_inboundmessage (duplicateof) | 1:N Selbstbezug | Remove Link |
| hsv_inboundmessage | hsv_processingattempt | 1:N | **Parental / Cascade** |
| hsv_processingattempt | hsv_processingattempt (previous) | 1:N Selbstbezug | Remove Link |

Restrict statt Cascade bei Stammdaten ist Absicht: ein gelöschter Kunde darf
keine Auftragshistorie mitreißen.

## 5. Globale Choices

Als **globale** Auswahllisten anlegen, damit Nachricht und Protokoll dieselben
Werte teilen: `hsv_messagestatus`, `hsv_workorderstatus`, `hsv_stage`,
`hsv_result`, `hsv_reasoncode`, `hsv_trade`, `hsv_priority`.

Reason Codes sprechend und maschinenlesbar benennen:
`MISSING_OBJECT_ADDRESS`, `UNKNOWN_CUSTOMER`, `NOT_A_REQUEST`,
`POSSIBLE_DUPLICATE`, `HTTP_429`, `ERP_UNAVAILABLE`, `SCHEMA_MISMATCH`,
`INVALID_TRANSITION`, `RETRY_BUDGET_EXCEEDED`.

Wächst die Liste über etwa 30 Werte, wird daraus eine Konfigurationstabelle —
dann sind neue Codes kein Solution-Deployment mehr.

## 6. Sicherheit (Vorbereitung für Punkt 13)

| Tabelle | Disponent | Techniker | Auditor | Plattformbetreuer |
| --- | --- | --- | --- | --- |
| hsv_workorder | CRUD, Organization | Read/Write **User**, kein Delete | Read Organization | Read Organization |
| hsv_inboundmessage | CRUD, Organization | kein Zugriff | Read Organization | Read/Write Organization |
| hsv_processingattempt | Read Organization | kein Zugriff | Read Organization | Read/Write Organization |
| hsv_serviceobject / Account | Read/Write | Read Organization | Read | Read |
| hsv_statustransition | Read | kein Zugriff | Read | CRUD |

Der Techniker sieht seine Aufträge, weil er Owner ist — nicht, weil eine Ansicht
gefiltert ist. Zuweisung heißt technisch: Owner wechselt.

Auditing wird für hsv_workorder und hsv_inboundmessage aktiviert, insbesondere
für die Statusspalten und den Owner.

## 7. Bewusst nicht gewählt

- **Native Duplicate Detection Rules.** Sie greifen bei UI- und Importvorgängen,
  decken aber die serverseitige Verarbeitung nicht zuverlässig ab. Stufe 1 löst
  ein Alternate Key, Stufe 2 die Anwendungslogik mit Entscheidung durch den
  Menschen.
- **SharePoint-Listen als Datenbasis.** Keine echten Beziehungen, kein
  Rollenmodell auf Zeilenebene, keine Alternate Keys, kein Auditing.
  SharePoint bleibt für Anhänge und Dokumente.
- **Ein gemeinsames Statusfeld für Nachricht und Auftrag.** Vermischt zwei
  Lebenszyklen und macht Auswertungen unbrauchbar.
- **Vollständiger Mailtext im Protokoll.** Im Eingangsregister ja, im
  Verarbeitungsprotokoll nur Schlüssel, Codes und Gründe.

## 8. Offene Punkte

- Aufbewahrungsdauer für hsv_inboundmessage und hsv_processingattempt.
- Normalisierungsregeln für `hsv_businesskey` am Testdatensatz kalibrieren.
- Ablage der Anhänge: Dataverse-File-Spalte oder SharePoint-Dokumentablage.
