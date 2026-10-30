# kavita-sync

Spiegelt die E-Books eines selbst gehosteten [Kavita](https://github.com/Kareadita/Kavita)-Servers auf ein reMarkable 2, in das Verzeichnis, aus dem [Plato](https://github.com/baskerville/plato) liest.

Das Programm läuft auf dem Tablet (Firmware 3.28, BusyBox-`sh`, kein Paketmanager). Es spricht Kavitas OPDS-Feed (`/api/opds/<API_KEY>`), lädt epub, pdf, cbz und die übrigen Dateien herunter und lässt Dateien liegen, die sich nicht geändert haben.

Firmware-Updates löschen das Root-Dateisystem. Alles, was bleiben soll, liegt deshalb unter `/home/root`.

## API-Schlüssel

In Kavita, als der Benutzer, dessen Bibliothek synchronisiert werden soll:

1. Benutzermenü → **Settings** → **3rd party clients / OPDS**.
2. OPDS für diesen Benutzer einschalten.
3. Den Schlüssel aus der OPDS-URL kopieren. Sie hat die Form `https://books.jenskock.de/api/opds/<API_KEY>`.
4. Dem Benutzer das Recht zum **Herunterladen** geben. Ohne dieses Recht antwortet der Server mit 401 oder 403, und es kommt keine Datei an.

Der Schlüssel und die Server-URL stehen nur in der Konfiguration auf dem Tablet, nicht in diesem Repository.

## Installation

Das Tablet per USB anschließen. Die Netzwerkadresse ist in der Regel `10.11.99.1`, der Benutzer `root`. Das Passwort steht auf dem Gerät unter Settings → General → About (Copyrights and licenses).

Vom Rechner aus, im Verzeichnis dieses Repositories:

```sh
scp -r . root@10.11.99.1:/home/root/kavita-sync
ssh root@10.11.99.1 'sh /home/root/kavita-sync/install.sh'
```

Auf dem Tablet, wenn die Dateien schon unter `/home/root/kavita-sync` liegen:

```sh
sh /home/root/kavita-sync/install.sh
```

`install.sh` legt an:

| Pfad | Inhalt |
| --- | --- |
| `/home/root/kavita-sync/` | Skript, Bibliotheken, Beispielkonfiguration |
| `/home/root/.local/bin/kavita-sync` | Symlink |
| `/home/root/.config/kavita-sync.conf` | Konfiguration, Modus 600, wird nie überschrieben |
| `/home/root/plato-media/` | Zielverzeichnis für Plato |
| `/home/root/.profile` | PATH-Ergänzung zwischen zwei Markierungszeilen |

Danach die Konfiguration bearbeiten:

```sh
vi /home/root/.config/kavita-sync.conf
```

`API_KEY=` eintragen. `SERVER_URL` steht im Beispiel bereits auf `https://books.jenskock.de`.

Wenn `kavita-sync` danach nicht im PATH liegt, einmal `source /home/root/.profile` ausführen oder das Programm über den vollen Pfad starten:

```sh
/home/root/kavita-sync/kavita-sync --dry-run
```

### HTTPS

`books.jenskock.de` ist HTTPS und steht hinter Cloudflare. Das wget von BusyBox auf dem reMarkable spricht kein TLS. `install.sh` prüft, ob `curl` oder ein wget mit HTTPS vorhanden ist. Fehlt beides, lädt es das statische wget von Toltec über HTTP nach `/home/root/.local/bin/wget` und prüft die SHA-256-Summe, bevor es die Datei aktiviert. Dasselbe erzwingt `--fetch-wget`.

Cloudflare blockiert oft einen nackten wget-User-Agent. Die Beispielkonfiguration setzt deshalb einen normalen Browser-Agenten. Steht in der Logdatei, die Antwort sei kein OPDS-Feed, den `USER_AGENT` in der Konfiguration setzen.

### Optionen von install.sh

```sh
sh install.sh [--prefix DIR] [--timer] [--fetch-wget]
```

`--prefix` ändert das Basisverzeichnis (Vorgabe `/home/root`). `--timer` installiert einen systemd-Timer, siehe unten.

## Konfiguration

Die Datei ist `KEY=VALUE` und wird nicht als Shell-Skript ausgeführt. Vorlage: `kavita-sync.conf.example`.

| Schlüssel | Bedeutung |
| --- | --- |
| `SERVER_URL` | Origin von Kavita, ohne Schrägstrich am Ende. Ein Unterpfad ist erlaubt. |
| `API_KEY` | OPDS-Schlüssel. Erlaubt sind Buchstaben, Ziffern, Punkt, Unterstrich und Bindestrich. |
| `DEST` | Absolutes Zielverzeichnis. Vorgabe `/home/root/plato-media`. `/`, `/home` und `/home/root` werden abgelehnt. |
| `LAYOUT` | Ordnerstruktur, siehe unten. Vorgabe `library-series`. |
| `STATE_DIR` | Manifest und Sperre. Vorgabe `/home/root/.local/share/kavita-sync`. |
| `DELETE_MISSING` | `1`, damit verschwundene Bücher gelöscht werden. Vorgabe `0`. |
| `USER_AGENT` | HTTP-User-Agent. |
| `CA_CERT` | Optionales CA-Bundle, falls die Zertifikatsprüfung scheitert. |
| `INSECURE` | `1` nur zum Eingrenzen eines Zertifikatsproblems. |

`LAYOUT` ist eines von:

| Wert | Pfad |
| --- | --- |
| `flat` | `Titel.epub` |
| `series` | `Serie/Titel.epub` |
| `author` | `Autor/Titel.epub` |
| `author-series` | `Autor/Serie/Titel.epub` |
| `library` | `Bibliothek/Titel.epub` |
| `library-series` | `Bibliothek/Serie/Titel.epub` |
| `library-author-series` | `Bibliothek/Autor/Serie/Titel.epub` |

Zeichen, die auf dem Dateisystem stören (`/ \ : * ? " < > |`), werden durch `-` ersetzt. Zwei Kapitel mit demselben Dateinamen bekommen ein Suffix wie `-c101`.

## Benutzung

```sh
kavita-sync --dry-run          # Katalog holen, nichts schreiben
kavita-sync                    # neue und geänderte Dateien laden
kavita-sync --delete           # zusätzlich lokal entfernen, was der Server nicht mehr führt
kavita-sync --force            # jede Datei neu laden, auch wenn sie unverändert wirkt
kavita-sync --verbose          # jede Katalog-Anfrage protokollieren
kavita-sync --config DATEI     # andere Konfiguration
```

`--dry-run` lädt die OPDS-Feeds, schreibt aber keine Bücher, löscht nichts und ändert das Manifest nicht. Die Zeilen lauten `would download`, `would skip` und, zusammen mit `--delete`, `would delete`.

Ein normaler Lauf lädt nur, was neu ist oder sich geändert hat (ETag und `If-Modified-Since`). Die Datei entsteht als `*.partial.<pid>` im Zielordner und wird erst danach umbenannt. Ist der Inhalt bytegleich, bleibt die vorhandene Datei.

`--delete` entfernt nur Dateien, die das Manifest kennt, die unter `DEST` liegen und die in diesem Lauf nicht mehr im Katalog standen. Der Lauf muss dafür den Katalog vollständig und ohne Fehler gelesen haben. Fremde Dateien in `DEST` bleiben stehen. Ohne `--delete` und mit `DELETE_MISSING=0` wird nichts gelöscht.

Zwei Läufe gleichzeitig sind gesperrt. Der zweite endet mit Status 3.

Exit-Status: `0` in Ordnung, `1` Fehler beim Sync, `2` Aufruf oder Konfiguration, `3` schon ein Lauf aktiv. Meldungen gehen nach stderr. Der API-Schlüssel wird in den Meldungen durch `***` ersetzt. Während einer Übertragung steht er trotzdem in der URL und kann kurz in der Prozessliste sichtbar sein.

Welche Bibliotheken ankommen: alle Bibliotheken, darin alle Serien (Seite für Seite, 20 Einträge), darin jedes Kapitel. Kavita hängt die Download-Links direkt an die Serie. Ältere Server, die noch Band und Kapitel als Unterkataloge liefern, werden ebenfalls verfolgt. Sammlungen, Leselisten und Smart Filter werden nicht gespiegelt.

## Timer

Optional, und nach einem Firmware-Update wieder einzurichten, weil die Units unter `/etc` liegen:

```sh
sh /home/root/kavita-sync/install.sh --timer
```

Der Timer startet drei Minuten nach dem Boot und einmal am Tag (`OnCalendar=daily`, `Persistent=true`). Im Suspend laufen auf dem reMarkable keine Timer. Wer das Gerät meist schlafen lässt, startet den Sync von Hand, solange es wach ist.

## Deinstallation

```sh
sh /home/root/kavita-sync/uninstall.sh
```

Das entfernt Skript, Symlink, PATH-Block und die systemd-Units. Bücher, Konfiguration und Manifest bleiben.

```sh
sh /home/root/kavita-sync/uninstall.sh --purge-config --purge-state --remove-wget
```

`--purge-config` löscht die Konfiguration, `--purge-state` Manifest und Sperre, `--remove-wget` das statische wget. Die Bücher in `DEST` bleiben in jedem Fall.

## Tests

Auf einem Rechner mit `shellcheck`, `dash` oder `/bin/sh`, `python3`, `curl` und nach Möglichkeit `busybox`:

```sh
sh tests/run.sh
```

Das prüft die Skripte mit `shellcheck -s sh`, füttert einen lokalen OPDS-Server und wiederholt den Lauf unter BusyBox-`sh` mit BusyBox-`awk`. Abgedeckt sind unter anderem Dry-Run, inkrementeller Lauf, 304, `--force`, `--delete`, ein abgebrochener Katalog (dann wird nichts gelöscht), ein einzelner fehlgeschlagener Download, eine Weiterleitung auf einen anderen Host, die Sperre, Installation und Prüfsumme. HTTP wird mit curl, GNU wget und BusyBox-wget geprüft. Python läuft nur in diesem Test, nicht auf dem Tablet.
