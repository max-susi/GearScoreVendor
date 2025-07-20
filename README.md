# GearScoreVendor

Ein World of Warcraft Retail Addon zum automatischen Verkauf von Ausrüstungsgegenständen basierend auf ihrem Item-Level.

## Features
- **Automatischer Verkauf** von Items in einem definierten Item-Level-Bereich
- **Warband Token Management** - Erkennt und verwaltet Warband-gebundene Tier-Tokens
- **Preset-System** - Speichere und lade verschiedene Item-Level-Konfigurationen
- **Minimap-Icon** - Schnellzugriff über Minimap-Button
- **Artefakt-Relikte** - Verkauft auch Artefakt-Relikte im konfigurierten Bereich
- **Debug-Modus** - Detaillierte Informationen für Fehlersuche

## Installation
1. Lade das Repository als ZIP herunter oder klone es:
   ```
   git clone https://github.com/max-susi/GearScoreVendor.git
   ```
2. Kopiere den Ordner `GearScoreVendor` in deinen WoW Addons-Ordner:
   - Windows: `C:/Program Files (x86)/World of Warcraft/_retail_/Interface/AddOns/`
   - macOS: `/Applications/World of Warcraft/_retail_/Interface/AddOns/`
3. Starte World of Warcraft neu und aktiviere das Addon im Addon-Menü.

## Nutzung

### Grundfunktionen
1. **Händler öffnen** - Beim Öffnen eines Händlers erscheint der "GSV Verkauf" Button
2. **Item-Level einstellen** - Nutze `/gsv` oder klicke auf das Minimap-Icon
3. **Verkauf starten** - Klicke auf "GSV Verkauf" beim Händler

### Befehle
- `/gsv` - Öffnet das Optionsfenster
- `/gsv min <zahl>` - Setzt das minimale Item-Level
- `/gsv max <zahl>` - Setzt das maximale Item-Level
- `/gsv show` - Zeigt die aktuellen Einstellungen
- `/gsv sell` - Startet den Verkauf (nur bei geöffnetem Händler)
- `/gsv preset <name> <min> <max>` - Erstellt ein neues Preset
- `/gsv use <name>` - Lädt ein gespeichertes Preset
- `/gsv list` - Zeigt alle gespeicherten Presets
- `/gsv tokens` - Öffnet das Token-Management-Fenster
- `/gsv debug` - Aktiviert/Deaktiviert den Debug-Modus
- `/gsv icon` - Zeigt/Versteckt das Minimap-Symbol

### Warband Token Management
Wenn Warband-gebundene Tier-Tokens im konfigurierten Item-Level-Bereich gefunden werden:
- Ein Fenster zeigt alle gefundenen Tokens
- Einzelne Tokens können verwendet oder verkauft werden
- "Alle verwenden" nutzt alle Tokens nacheinander
- Option zum Überspringen von Warband-Tokens beim automatischen Verkauf

### Sicherheitsfeatures
- Verkauft nur echte Ausrüstungsgegenstände (keine Quest-Items, Schlüssel, etc.)
- Warband-Tokens werden standardmäßig übersprungen
- Bestätigungsdialoge werden beim Verkauf automatisch bestätigt

## Technische Details

### Unterstützte Item-Typen
- Waffen (alle Typen)
- Rüstungen (alle Slots)
- Schmuckstücke (Ringe, Halsketten, Schmuckstücke)
- Artefakt-Relikte
- Umhänge

### Version
- **Aktuelle Version**: 2.0.1
- **Interface**: 100207 (WoW Retail)
- **Autor**: c4gg-dev

## Bekannte Probleme
- Keine derzeit bekannt

## Mitwirken
Pull Requests und Issues sind willkommen! Bitte erstelle Issues auf GitHub für Fehlerberichte oder Feature-Anfragen.

## Lizenz
Dieses Projekt steht unter der MIT-Lizenz.
