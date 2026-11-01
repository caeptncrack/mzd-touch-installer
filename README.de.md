# MZD Touch Installer

**Touch in Android Auto und Bedienung während der Fahrt für Mazda Connect 74.00.324 / 74.00.324A, mit einem USB-Stick installiert und wieder entfernt.**

[English](README.md) (ausführlicher)

| | |
|---|---|
| Im Auto getestet | Mazda Connect **74.00.324A** (EU, `cmu150_EU`) |
| Sollte laufen auf | allen Regionen von 74.00.324 / 74.00.324A (z. B. Nordamerika). Weicht das Gerät vom getesteten Stand ab, sagt der Installer das und fragt, bevor er etwas ändert. Rückmeldungen sind willkommen. |
| Braucht | einen USB-Stick (FAT32), sonst nichts: keinen Rechner im Auto, keine Mazda-Originaldateien |

Enthalten sind zwei Community-Projekte, ihre Dateien **unverändert**:

| Teil | Projekt | Autor | Lizenz |
|---|---|---|---|
| Touch in Android Auto | [oem-aa-mod](https://github.com/VitaliyKurokhtin/oem-aa-mod) 0.10.0 | [VitaliyKurokhtin](https://github.com/VitaliyKurokhtin) | AGPL-3.0 |
| Touch während der Fahrt (Mazda-Connect-Menüs) | [TouchTune](https://github.com/Miatafy/TouchTune) 1.2.1 | [Miatafy](https://github.com/Miatafy) | GPL-3.0 |

Der Verdienst für die Funktionen gehört den beiden Autoren. Dieses Repository ergänzt: einen Stick und einen Dialog für beides, eine Sicherung der Originaldateien **im Auto** vor der ersten Änderung (der Rückbau spielt genau diese zurück), abgesicherte Schreibvorgänge mit automatischem Zurückrollen und einen einzigen Mazda-SafeReboot am Ende.

Die Android-Auto-Konfiguration ist die unveränderte Release-Konfiguration von oem-aa-mod: Touch, Navigationshinweise im Head-up-Display, Stummschalten pausiert die Medien am Handy, Mazda Connect startet Android-Auto-Medien nicht mehr von selbst, Android-Auto-Protokoll 1.6 zum Handy.

**Die Android-Auto-XML:** oem-aa-mod bringt eigene Fassungen von `/etc/aap_system_attributes.xml` und `_UCP.xml` mit. Sie verschieben außer dem Touch-Eintrag auch Videowerte (`par`, `fps`, `decoder_additional_depth`, dazu `real_density`) in den Block, den `aap_service` ans Handy schickt; Android Auto kann dadurch anders skaliert sein als ab Werk. Dieser Installer behält deshalb die beiden Dateien des eigenen Autos und ergänzt nur, was oem-aa-mod für seine Funktionen einträgt: `<touch_screen>`, die Taste `AAP_KEYCODE_MEDIA_PAUSE` und bei der Navigation `subscribe TRUE` mit `<cluster_type>ENUM</cluster_type>`. `<display>`, `<video>` und alle übrigen Zeilen bleiben Byte für Byte wie ab Werk; vor dem Schreiben wird geprüft, dass das Herausnehmen der Ergänzungen genau die Originaldatei ergibt. Hat die Datei nicht den erwarteten Aufbau, bleibt Android Auto unangetastet und TouchTune wird allein angeboten.

> **Sicherheit und Recht.** Bedienung während der Fahrt lenkt ab. § 23 Abs. 1a StVO schränkt das Bedienen von Geräten während der Fahrt ein; andere Länder haben ähnliche Regeln. Die Verantwortung bleibt beim Fahrer. Am besten bedient der Beifahrer.

## Benutzung

1. **Herunterladen:** im [neuesten Release](../../releases/latest) unter *Assets* die Datei **`mzd-touch-installer-<version>.zip`** laden, nicht „Source code“. Auf dem Rechner muss nichts installiert oder gebaut werden.
2. **Stick vorbereiten:** leerer USB-Stick bis 32 GB, **FAT32** (Windows: Rechtsklick auf den Stick → *Formatieren…* → *FAT32*).
   - **Windows:** Rechtsklick auf die ZIP → *Alle extrahieren…* → *Durchsuchen…* → den Stick wählen → *Extrahieren*. Oder irgendwo entpacken, den Ordner öffnen, alles darin markieren (Strg+A) und auf den Stick ziehen. Stick vor dem Abziehen auswerfen.
   - **macOS:** ZIP doppelklicken, den neuen Ordner öffnen, alles markieren (Cmd+A), auf den Stick ziehen, dann im *Terminal* `dot_clean -m /Volumes/<STICK>` und auswerfen.
   - **Prüfen:** auf dem Stick liegen `run.sh`, `README.txt`, `STICK.ID` und die Ordner `aa-mod`, `lib`, `payload`, `touchtune` direkt in der obersten Ebene, nicht in einem weiteren Ordner. Sonst nichts.
3. Im Auto: am sichersten bei laufendem Motor. Mazda Connect vollständig hochfahren lassen, Stick in die Mittelkonsole. Nach einigen Sekunden zeigt ein Dialog den Zustand:
   - nichts installiert → **Install** · Diagnosis · Cancel
   - beides installiert → **Remove both** · Diagnosis · Cancel
   - eines installiert → **Install** · Remove · Cancel
4. **Install** wählen. Eine Bestätigung erklärt in wenigen Zeilen, was passiert; **Start** tippen (**Back** führt zum Startdialog zurück). So fragt jede Schaltfläche des Startdialogs zuerst nach.
5. Während es läuft, steht *Do not pull the stick* auf dem Schirm. Den Stick erst abziehen, wenn der Schirm es sagt: *Remove the USB* vor dem Neustart oder *You can pull the stick now*, wenn ein Lauf ohne Neustart endet. Mazda Connect startet von selbst neu (oder fragt *Restart now*).

**Entfernen:** denselben Stick wieder einstecken, **Remove both**, mit **Start** bestätigen. Wiederhergestellt wird aus der Sicherung im Auto, Byte für Byte. Originaldateien von Mazda braucht man dafür nicht.

**Diagnose:** schreibt `diag-*.txt` auf den Stick (Versionen, Prüfsummen, Zustand; keine Inhalte von Mazda-Dateien, keine persönlichen Daten). Für eine Fehlermeldung `mzd-usb.log`, die neueste `diag-*.txt` und `touchtune/touchtune.log` anhängen, **nicht** die Ordner `backup-aa-touch-*` (Originaldateien des eigenen Autos).

## Lizenz

Skripte dieses Repositorys: GPL-3.0-or-later, Hinweise und Fremdlizenzen in [NOTICE.md](NOTICE.md). oem-aa-mod: AGPL-3.0. TouchTune: GPL-3.0. Kein Bezug zu Mazda, Google oder den Autoren von oem-aa-mod und TouchTune. Benutzung auf eigenes Risiko; „Remove both" ist jederzeit möglich.
