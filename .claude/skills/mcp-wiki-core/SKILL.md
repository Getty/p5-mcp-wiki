---
name: mcp-wiki-core
description: Load before editing p5-mcp-wiki — MCP::Wiki::Server tool surface, heading_path als Section-Identität, TOC-Parser, optionale Git::Raw-Historie, Pfad-Sicherheitsmodell.
user-invocable: false
model: inherit
---

# mcp-wiki-core

MCP::Wiki ist ein stdio-MCP-Server, der ein Verzeichnis voller Markdown-Dateien als
Wiki verwaltet: TOC extrahieren, Abschnitte absatzweise lesen/schreiben, optional pro
Änderung committen und Abschnitte aus der Git-Historie zurückholen. Ein Produkt, eine
Distribution, ein Einstiegspunkt (`bin/mcp-wiki`).

## Vocabulary

| Term | Meaning |
|------|---------|
| **page** | Eine `.md`-Datei unter der wiki_root und außerhalb von `.git`, adressiert **relativ** zur wiki_root (`sub/dir/seite.md`) |
| **wiki_root** | Basisverzeichnis; beim Serverstart festgelegt, kein Tool-Aufruf kann es ändern |
| **section** | Bereich von einer Überschrift bis zur nächsten Überschrift (beliebigen Levels) |
| **heading_path** | `#`-getrennte Kette, die eine section identifiziert — die einzige stabile Adresse |
| **TOC entry** | `MCP::Wiki::TOC::Entry`, ein Heading plus Zeilenbereich und Preview |
| **on_change** | Callback-Kette; feuert nach dem Schreiben, trägt `{ type, page, ... }` |
| **event type** | `create` · `update` · `rename` · `delete` · `restore` |

## Layer Map

```
bin/mcp-wiki                     # CLI: Getopt::Long -> Server->new -> to_stdio
lib/MCP/Wiki.pm                  # nur $VERSION + POD, kein Code
lib/MCP/Wiki/Server.pm           # Moo; 9 Tools in _setup_tools; on_change; Git-Auto-Commit
lib/MCP/Wiki/Document.pm         # eine Seite: content/get_toc/get_paragraph/set_paragraph
lib/MCP/Wiki/TOC/Parser.pm       # zeilenbasierter ATX-Parser -> Entry-Liste
lib/MCP/Wiki/TOC/Entry.pm        # Wertobjekt + as_hash (die Wire-Form der TOC)
lib/MCP/Wiki/Git/History.pm      # Git::Raw: section history, restore, auto_commit
lib/MCP/Wiki/Git.pm              # Altbestand, vom Server NICHT benutzt (s.u.)
```

Tools: `list_pages` `get_toc` `get_paragraph` `create_page` `update_paragraph`
`rename_page` `delete_page` `get_section_history` `restore_section`.

## Core invariants

- **Jeder Dateizugriff eines Tools läuft über `_resolve_page`.** Der Client ist ein
  Sprachmodell, das ungeprüften Wiki-Inhalt liest; der Seitenname ist das Einzige, was
  einen Aufruf im Wiki hält. Der Helfer läuft den Namen komponentenweise ab der
  aufgelösten Wurzel ab, löst Existierendes sofort per `realpath` auf (Symlinks, `..`)
  und hängt den noch nicht existierenden Rest als reine Namen an. Abgelehnt wird, was
  die Wurzel verlässt (geprüft in jedem Schritt mit `subsumes`, also an der Pfadgrenze:
  `/wiki-evil` liegt nicht unter `/wiki`), was eine Komponente `.git` trägt (beliebige
  Schreibweise, im Namen wie im aufgelösten Pfad) und was keine `.md`-Datei ist. Ein
  Tool, das selbst einen Pfad baut, öffnet die Lücke wieder. `list_pages` listet genau
  das, was `_resolve_page` annimmt, und betritt `.git` nicht.
- **`wiki_root` steht per Default auf `.`** (`bin/mcp-wiki`). Der Server schreibt damit in
  das Verzeichnis, aus dem er gestartet wurde — ein unbedachter Testlauf oder Handgriff
  ändert echte Dateien. Schreibende Tools gehören ausschließlich gegen ein
  `Path::Tiny`-Tempdir getestet, niemals gegen den Checkout oder `$HOME`.
- **Es gibt kein `root_dir`.** Tools werden über `_add_tool` registriert; der Wrapper
  lehnt jeden Aufruf mit `root_dir` ab, statt ihn gegen die konfigurierte Wurzel
  auszuführen, wo derselbe Seitenname eine andere Datei meinen kann. Neue Tools ebenfalls
  über `_add_tool`, nie direkt über `$server->tool`.
- **`heading_path` ist die Section-Identität, Zeilennummern sind es nicht.** Jeder
  Tool-Aufruf baut ein frisches `Document` und parst neu; `line_start`/`line_end` sind
  Ergebnis *dieses* Parse-Laufs und nach jeder Änderung wertlos. Nie einen Zeilenbereich
  über zwei Aufrufe hinweg tragen — auch nicht in der Historie, wo genau deshalb der
  Blob jedes Commits neu geparst wird. Die Adresse ist das Argument von vier Tools und
  der Schlüssel, an dem die Git-Historie matcht; eine Korrektur der Konstruktion entwertet
  alle Adressen, die Nutzer schon halten — ADR-Grade, nicht nebenbei.
- **Tool-Handler sind Closures, keine Methoden.** `code => sub ($tool, $args)` — `$tool`
  ist die `MCP::Tool`-Instanz, nicht der Server. Der Server kommt über die Closure-Variable
  `$self` herein. Ausgabe ausschließlich via `$tool->structured_result(...)` bzw.
  `$tool->text_result($msg, 1)` für Fehler. Details: skill `perl-mcp`.
- **Fehler sind Tool-Ergebnisse, keine Exceptions.** Jeder Handler fängt `_create_document`
  in `eval` und antwortet mit `text_result(..., 1)`. Ein `die`, das bis zum Transport
  durchschlägt, killt die stdio-Session — beim Erweitern der Tools den `eval`-Rahmen
  mitziehen.
- **Git ist optional und lazy.** `git_history` liefert `undef`, wenn `use_git` aus ist
  **oder** `Git::Raw` fehlt (`_build_git_history` prüft beides per `eval require`).
  Die Historie-Tools antworten dann sauber mit "Git history not available". Diese
  Weichheit ist Absicht: die Distribution muss ohne Git::Raw installierbar und testbar
  bleiben. Kein `use Git::Raw` auf Dateiebene einführen.
- **Auto-Commit hängt an `_fire_on_change`, nicht an den Tools.** Ein neues schreibendes
  Tool committet automatisch mit, sobald es `_fire_on_change` aufruft — und nur dann.
  `restore` ist vom Auto-Commit ausgenommen (`$event->{type} ne 'restore'`).
- **on_change-Handler dürfen nicht scheitern lassen.** Handler laufen in `eval`, Fehler
  werden `warn`t; der Schreibvorgang gilt trotzdem als erfolgreich. Diese Reihenfolge —
  erst Datei schreiben, dann Callbacks — ist die Garantie, auf die Konsumenten bauen.
- **Der TOC-Parser ist bewusst zeilenbasiert, kein CommonMark.** Er kennt ATX-Headings
  (`#`..`######`), togglet an ```` ``` ````-Zeilen und überspringt 4-Space-Indent.
  Setext-Headings (`===`/`---`), HTML-Kommentare und Tabellenzellen erkennt er **nicht**.
  Wer echte AST-Genauigkeit will, tauscht den Parser aus — nicht Sonderfall um Sonderfall
  im Regex nach.
- **Ein Abschnitt endet an der *nächsten* Überschrift, gleich welchen Levels.** Ein H1
  enthält seine H2-Kinder also nicht; `content_preview` und `char_count` beziehen sich
  immer auf diesen flachen Bereich — inklusive der Überschriftszeile selbst.

## Sharp edges — verifiziert, nicht vermutet

Diese drei sind Defekte, keine Konventionen. Nicht "aus Versehen mitfixen", nicht
umbauen ohne Ticket — aber auch nie als korrektes Verhalten dokumentieren.

- **`_build_heading_path` baut keine Vorfahrenkette.** Es sammelt *alle* vorangehenden
  Headings mit `level <= aktuelles level`, also auch Geschwister. Bei
  `# Intro / ## Alpha / ## Beta / # Other` entsteht `Intro#Alpha#Beta` und `Intro#Other`
  statt `Intro#Beta` und `Other`. Damit ist jede über `heading_path` adressierte Section
  reihenfolgeabhängig: ein eingefügter Geschwisterabschnitt ändert die Adresse aller
  folgenden. Korrekt wäre ein Stack, der beim Betreten eines Levels alles `>= level`
  abräumt.
- **`get_paragraph` und `set_paragraph` sind nicht round-trip-fähig.** `get` liefert die
  Section **inklusive** Überschriftszeile (`line_start-1 .. line_end-1`); `set` ersetzt
  ab der Zeile *nach* der Überschrift, aber mit der Länge inklusive Überschrift — also
  eine Zeile zu viel. `set_paragraph($p, get_paragraph($p)->{content})` verdoppelt die
  Überschrift und frisst die erste Zeile des Folgeabschnitts.
- **`restore_section` wendet den Patch doppelt an.** `Git::History::restore_section`
  liefert in `content` bereits das **vollständige neue Dokument**; `Server.pm` reicht
  genau das an `$doc->set_paragraph($heading_path, ...)` weiter und schreibt damit das
  ganze Dokument in einen Abschnitt. Entweder gibt History nur den Section-Text zurück,
  oder Server schreibt die Datei direkt — nicht beides.

## Altbestand

- **`lib/MCP/Wiki/Git.pm` ist tot.** Der Server benutzt ausschließlich
  `MCP::Wiki::Git::History`. Beide Klassen haben `repo`/`auto_commit`; die Variante in
  `Git.pm` übergibt an `create_commit` einen Index-Entry als Parent-Liste und kann so
  nicht funktionieren. Kein Aufrufer, keine Tests — Kandidat zum Löschen, nicht zum
  Weiterpflegen.
- **`_build_history_file` / `.mcp-wiki-history.json`** wird gebaut, aber von niemandem
  gelesen oder geschrieben. Die Historie kommt vollständig aus den Git-Blobs.
- **`update_content_hash`**, `Digest::SHA` in `Server.pm`, `to_json`,
  `Types::Standard` in `Entry.pm` und `commit_reason_required`: importiert bzw.
  attributiert, nirgends ausgewertet. `PLAN.md` beschreibt zusätzlich Content-Hashing,
  Conflict-Marker, `MCP::Wiki::Git::Blame` und Async-Callbacks — nichts davon existiert.
  **`PLAN.md` ist ein Entwurf, keine Spezifikation des Ist-Zustands.**

## Docker-Setup — WIP

Das Docker-Setup ist laut eigener Commit-Nachricht (9e571a6) WIP. Die Registry-Ziele in
`dist.ini` und in `maint/release-after.pl` widersprechen sich. Das braucht eine
Entscheidung, keine schleichende Politur.

## Verification

`prove -lr t/` ist das kanonische Signal — rekursiv, damit später angelegte
Unterverzeichnisse unter `t/` nicht stumm übersprungen werden. `dzil test` ist das
Release-Äquivalent.

Die Tests laufen ohne `Git::Raw` und ohne Netzwerk; `t/40-git.t` prüft absichtlich nur,
dass das Modul ohne Git::Raw sauber scheitert. Das muss so bleiben.
