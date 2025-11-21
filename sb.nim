# =============================================================
# SilverBullet CLI (Nim)
# -------------------------------------------------------------
# Zweck:
#   Ein kleines Kommandozeilen-Tool, um Seiten (Markdown-Dateien)
#   auf einem SilverBullet-Server zu erstellen, abzurufen, zu
#   bearbeiten, anzuhängen, zu löschen und zu durchsuchen.
# =============================================================

import std/[httpclient, json, os, strutils, terminal, times, uri, algorithm, re, sets, tables]

const
  Version = "1.0.2"
  AppName = "SilverBullet CLI"
  # System-Verzeichnisse die standardmäßig ausgeblendet werden
  SystemPrefixes = [
    "Library/",
    "SETTINGS",
    "PLUGS",
    "_"  # Dateien die mit _ beginnen
  ]

type
  Config = object
    serverUrl: string
    authToken: string

var config: Config
var configFile = getConfigDir() / "silverbullet-cli" / "config.json"

## Prüft ob eine Seite eine System-Seite ist
proc isSystemPage(pageName: string): bool =
  for prefix in SystemPrefixes:
    if pageName.startsWith(prefix):
      return true
  return false

## Formatiert eine Zahl mit führenden Nullen
## Beispiel: formatWithLeadingZeros(9, 2) = "09"
proc formatWithLeadingZeros(num: int, width: int): string =
  let numStr = $num
  let zerosNeeded = width - numStr.len
  if zerosNeeded > 0:
    return "0".repeat(zerosNeeded) & numStr
  else:
    return numStr

## Lädt Konfiguration aus der JSON-Datei (falls vorhanden).
proc loadConfig() =
  if fileExists(configFile):
    try:
      let data = parseFile(configFile)
      config.serverUrl = data{"serverUrl"}.getStr("")
      config.authToken = data{"authToken"}.getStr("")
    except:
      discard

## Speichert die aktuelle Konfiguration (Server-URL, Token) als JSON-Datei.
proc saveConfig() =
  createDir(parentDir(configFile))
  let data = %* {
    "serverUrl": config.serverUrl,
    "authToken": config.authToken
  }
  writeFile(configFile, data.pretty())

## Liest Text von der Standard-Eingabe (stdin) ein.
proc readFromStdin(): string =
  var content = ""
  var line: string
  while stdin.readLine(line):
    if content.len > 0:
      content.add("\n")
    content.add(line)
  return content

## Führt eine HTTP-Anfrage aus (GET/PUT/DELETE)
proc makeRequest(client: HttpClient, httpMethod: HttpMethod, endpoint: string, body = ""): string =
  let url = config.serverUrl & endpoint
  
  client.headers = newHttpHeaders({
    "X-Sync-Mode": "true",
    "Accept": "application/json"
  })
  
  if config.authToken != "":
    client.headers["Authorization"] = "Bearer " & config.authToken
  
  try:
    var response: Response
    case httpMethod
    of HttpGet:
      response = client.get(url)
    of HttpPut:
      client.headers["Content-Type"] = "text/markdown"
      response = client.request(url, httpMethod = HttpPut, body = body)
    of HttpDelete:
      response = client.request(url, httpMethod = HttpDelete)
    else:
      raise newException(ValueError, "Unsupported HTTP method")
    
    if response.code != Http200 and response.code != Http201 and response.code != Http204:
      styledEcho(fgRed, "✗ HTTP Error: ", resetStyle, $response.code, " ", response.status)
      if response.body.len > 0:
        echo "Response body: ", response.body[0..min(response.body.len-1, 500)]
      quit(1)
    
    return response.body
  except HttpRequestError as e:
    styledEcho(fgRed, "✗ HTTP Error: ", resetStyle, e.msg)
    quit(1)
  except Exception as e:
    styledEcho(fgRed, "✗ Error: ", resetStyle, e.msg)
    quit(1)

## Druckt die Hilfe
proc showHelp() =
  echo """
$1 v$2

VERWENDUNG:
  sb [BEFEHL] [OPTIONEN]

BEFEHLE:
  config <url> [token]    Konfiguriert Server-URL und optionalen Auth-Token
  list                    Listet alle Seiten auf
  get <page>              Zeigt Inhalt einer Seite an
  create <page> <text>    Erstellt eine neue Seite
  edit <page> <text>      Bearbeitet eine existierende Seite
  append <page> <text>    Fügt Text an eine Seite an
  delete <page>           Löscht eine Seite
  search <query>          Durchsucht alle Seiten
  recent                  Zeigt kürzlich geänderte Seiten
  backup [verzeichnis]    Erstellt ein Backup aller Seiten
  restore <verzeichnis>   Stellt Seiten aus Backup wieder her
  download <page> [datei] Lädt eine Seite in eine lokale Datei
  upload <datei> <page>   Lädt eine lokale Datei als Seite hoch
  graph [format]          Zeigt Verlinkungen zwischen Seiten (text, dot)
  version                 Zeigt Version an
  help                    Zeigt diese Hilfe an

GLOBALE OPTIONEN:
  --configfile=<pfad>     Verwendet alternative Konfigurationsdatei
  --all, -a               Zeigt auch System-Seiten (Library/, SETTINGS, etc.)
  --full                  Bei backup: inkl. System-Seiten (Library, SETTINGS, PLUGS)
  --to=<pfad>             Bei restore: Ziel-Präfix für wiederhergestellte Dateien

BEISPIELE:
  sb config http://localhost:3000
  sb list
  sb list --all              # Zeigt auch System-Seiten
  sb get index
  sb create "Meeting Notes" "# Meeting"
  sb append index "- New item"
  sb search "TODO"
  sb recent
  sb recent --all            # Zeigt auch System-Seiten
  
  # Backup
  sb backup                  # Backup nach ./backup-YYYYMMDD-HHMMSS/
  sb backup /pfad/zu/backup  # Backup in spezifisches Verzeichnis
  sb backup --full           # Inkl. System-Seiten
  
  # Restore
  sb restore backup-20250119-143025           # Am Original-Ort wiederherstellen
  sb restore backup-20250119-143025 --to=Archiv  # Nach Archiv/* verschieben
  sb restore /pfad/zu/backup --to=Import      # Nach Import/* importieren
  
  # Download/Upload einzelner Seiten
  sb download "Daily Notes"                   # Lädt nach "Daily Notes.md"
  sb download "Daily Notes" notizen.md        # Lädt nach "notizen.md"
  sb upload notizen.md "Daily Notes"          # Hochladen als "Daily Notes"
  sb upload ~/docs/todo.md "TODO Liste"       # Von beliebigem Pfad
  
  # Mit stdin/pipe
  echo "# Test" | sb create "Test Page"
  cat notes.txt | sb append "Daily Notes"
  sb create "From Stdin" < input.txt
  
  # Mit alternativer Config
  sb --configfile=/path/to/config.json list

KONFIGURATION:
  Die Konfiguration wird standardmäßig gespeichert in:
  $3
""" % [AppName, Version, configFile]

## Setzt/normalisiert die Server-URL und speichert den Token
proc configureServer(url: string, token = "") =
  var serverUrl = url.strip(chars = {'/'})
  
  if not serverUrl.startsWith("http://") and not serverUrl.startsWith("https://"):
    serverUrl = "http://" & serverUrl
  
  config.serverUrl = serverUrl
  config.authToken = token
  saveConfig()
  styledEcho(fgGreen, "✓ ", resetStyle, "Konfiguration gespeichert")
  echo "Server: ", config.serverUrl
  if token != "":
    echo "Token: ********"

## Fragt die Dateiliste am Server ab und zeigt sie an
proc listPages(showAll = false) =
  let client = newHttpClient()
  defer: client.close()
  
  let response = makeRequest(client, HttpGet, "/.fs")
  
  try:
    let data = parseJson(response)
    
    echo "\n📄 Seiten in SilverBullet\n"
    echo "─".repeat(60)
    
    var pages: seq[tuple[name: string, lastModified: int]] = @[]
    
    for item in data:
      if item.kind == JObject:
        let name = item["name"].getStr()
        if name.endsWith(".md"):
          let pageName = name[0..^4]
          # Filtere System-Seiten aus, außer --all wurde angegeben
          if showAll or not isSystemPage(pageName):
            let modified = item{"lastModified"}.getInt(0)
            pages.add((name: pageName, lastModified: modified))
    
    pages.sort(proc(a, b: tuple[name: string, lastModified: int]): int = 
      cmp(b.lastModified, a.lastModified))
    
    let numWidth = max(2, ($pages.len).len)
    
    for i, page in pages:
      let numStr = formatWithLeadingZeros(i+1, numWidth)
      if page.lastModified > 0:
        let modTime = fromUnix(page.lastModified div 1000)
        let timeStr = modTime.format("dd.MM.yyyy HH:mm")
        stdout.styledWrite(fgCyan, numStr, ". ", resetStyle)
        stdout.styledWrite(fgWhite, page.name, " ")
        stdout.styledWriteLine(fgYellow, "(", timeStr, ")")
      else:
        stdout.styledWrite(fgCyan, numStr, ". ", resetStyle)
        stdout.styledWriteLine(fgWhite, page.name)
    
    echo "─".repeat(60)
    if showAll:
      echo "Gesamt: ", pages.len, " Seiten (alle)"
    else:
      echo "Gesamt: ", pages.len, " Seiten (ohne System-Seiten, verwende --all um alle zu sehen)"
  except JsonParsingError as e:
    styledEcho(fgRed, "✗ JSON Parse Error: ", resetStyle, e.msg)
    echo "Server response (first 500 chars):"
    if response.len > 0:
      echo response[0..min(response.len-1, 500)]
    quit(1)

## Holt den Inhalt einer Seite und zeigt ihn an
proc getPage(pageName: string) =
  let client = newHttpClient()
  defer: client.close()
  
  let encodedName = encodeUrl(pageName)
  let content = makeRequest(client, HttpGet, "/.fs/" & encodedName & ".md")
  echo content

## Erstellt oder überschreibt eine Seite
proc createOrEditPage(pageName: string, content: string, isEdit = false) =
  let client = newHttpClient()
  defer: client.close()
  
  let encodedName = encodeUrl(pageName)
  discard makeRequest(client, HttpPut, "/.fs/" & encodedName & ".md", content)
  
  let action = if isEdit: "aktualisiert" else: "erstellt"
  styledEcho(fgGreen, "✓ ", resetStyle, "Seite '", pageName, "' ", action)

## Hängt Text an eine Seite an
proc appendToPage(pageName: string, content: string) =
  let client = newHttpClient()
  defer: client.close()
  
  let encodedName = encodeUrl(pageName)
  let currentContent = makeRequest(client, HttpGet, "/.fs/" & encodedName & ".md")
  let newContent = currentContent & "\n" & content
  discard makeRequest(client, HttpPut, "/.fs/" & encodedName & ".md", newContent)
  styledEcho(fgGreen, "✓ ", resetStyle, "Text zu '", pageName, "' hinzugefügt")

## Löscht eine Seite
proc deletePage(pageName: string) =
  let client = newHttpClient()
  defer: client.close()
  
  let encodedName = encodeUrl(pageName)
  discard makeRequest(client, HttpDelete, "/.fs/" & encodedName & ".md")
  styledEcho(fgRed, "✗ ", resetStyle, "Seite '", pageName, "' gelöscht")

## Durchsucht alle Seiten
proc searchPages(query: string) =
  let client = newHttpClient()
  defer: client.close()
  
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  echo "\n🔍 Suche nach: '", query, "'\n"
  echo "─".repeat(60)
  
  var found = 0
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        
        if query.toLower() in pageName.toLower():
          found.inc
          styledEcho(fgCyan, "• ", resetStyle, pageName, " ", fgYellow, "(im Titel)")
          continue
        
        try:
          let encodedName = encodeUrl(name)
          let content = makeRequest(client, HttpGet, "/.fs/" & encodedName)
          
          if query.toLower() in content.toLower():
            found.inc
            styledEcho(fgCyan, "• ", resetStyle, pageName)
            
            for line in content.splitLines():
              if query.toLower() in line.toLower():
                let trimmed = line.strip()
                if trimmed.len > 0:
                  echo "  ", trimmed[0..min(trimmed.len-1, 80)]
                break
        except CatchableError:
          discard
  
  echo "─".repeat(60)
  echo "Gefunden: ", found, " Seiten"

## Zeigt die zuletzt geänderten Seiten
proc showRecent(limit = 10, showAll = false) =
  let client = newHttpClient()
  defer: client.close()
  
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  echo "\n🕐 Kürzlich geänderte Seiten\n"
  echo "─".repeat(60)
  
  var pages: seq[tuple[name: string, lastModified: int]] = @[]
  
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        # Filtere System-Seiten aus, außer --all wurde angegeben
        if showAll or not isSystemPage(pageName):
          let modified = item{"lastModified"}.getInt(0)
          pages.add((name: pageName, lastModified: modified))
  
  pages.sort(proc(a, b: tuple[name: string, lastModified: int]): int = 
    cmp(b.lastModified, a.lastModified))
  
  let numWidth = max(2, ($min(limit, pages.len)).len)
  
  for i in 0..<min(limit, pages.len):
    let numStr = formatWithLeadingZeros(i+1, numWidth)
    if pages[i].lastModified > 0:
      let modTime = fromUnix(pages[i].lastModified div 1000)
      let timeStr = modTime.format("dd.MM.yyyy HH:mm:ss")
      stdout.styledWrite(fgCyan, numStr, ". ", resetStyle)
      stdout.styledWrite(fgWhite, pages[i].name, " ")
      stdout.styledWriteLine(fgYellow, "(", timeStr, ")")
    else:
      stdout.styledWrite(fgCyan, numStr, ". ", resetStyle)
      stdout.styledWriteLine(fgWhite, pages[i].name)
  
  echo "─".repeat(60)
  if showAll:
    echo "Zeige ", min(limit, pages.len), " von ", pages.len, " Seiten (alle)"
  else:
    echo "Zeige ", min(limit, pages.len), " von ", pages.len, " Seiten (ohne System-Seiten, verwende --all um alle zu sehen)"

## Erstellt ein Backup aller Seiten
proc backupPages(targetDir = "", fullBackup = false) =
  let client = newHttpClient()
  defer: client.close()
  
  # Erstelle Backup-Verzeichnis mit Zeitstempel
  let timestamp = now().format("yyyyMMdd-HHmmss")
  let backupPath = if targetDir != "":
    targetDir
  else:
    getCurrentDir() / "backup-" & timestamp
  
  echo "\n💾 Erstelle Backup..."
  echo "Zielverzeichnis: ", backupPath
  echo "─".repeat(60)
  
  # Erstelle Verzeichnis
  createDir(backupPath)
  
  # Hole Dateiliste
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  var backedUp = 0
  var skipped = 0
  
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        
        # Filtere System-Seiten aus, außer --full wurde angegeben
        if not fullBackup and isSystemPage(pageName):
          skipped.inc
          continue
        
        try:
          # Hole Seiteninhalt
          let encodedName = encodeUrl(name)
          let content = makeRequest(client, HttpGet, "/.fs/" & encodedName)
          
          # Erstelle Unterverzeichnisse falls nötig
          let filePath = backupPath / name
          let dir = parentDir(filePath)
          if dir != "" and not dirExists(dir):
            createDir(dir)
          
          # Speichere Datei
          writeFile(filePath, content)
          backedUp.inc
          echo "✓ ", name
        except CatchableError as e:
          styledEcho(fgRed, "✗ ", resetStyle, name, " (", e.msg, ")")
  
  echo "─".repeat(60)
  echo "Gesichert: ", backedUp, " Dateien"
  if skipped > 0:
    echo "Übersprungen: ", skipped, " System-Dateien (verwende --full für komplettes Backup)"
  styledEcho(fgGreen, "✓ ", resetStyle, "Backup erfolgreich nach: ", backupPath)

## Stellt Seiten aus einem Backup wieder her
proc restorePages(sourceDir: string, targetPrefix = "") =
  let client = newHttpClient()
  defer: client.close()
  
  if not dirExists(sourceDir):
    styledEcho(fgRed, "✗ ", resetStyle, "Backup-Verzeichnis nicht gefunden: ", sourceDir)
    quit(1)
  
  echo "\n📦 Stelle Backup wieder her..."
  echo "Quelle: ", sourceDir
  if targetPrefix != "":
    echo "Ziel-Präfix: ", targetPrefix, "/"
  else:
    echo "Ziel: Original-Pfade"
  echo "─".repeat(60)
  
  var restored = 0
  var failed = 0
  
  # Durchsuche rekursiv alle .md Dateien
  for file in walkDirRec(sourceDir):
    if file.endsWith(".md"):
      try:
        # Lese Dateiinhalt
        let content = readFile(file)
        
        # Berechne relativen Pfad
        let relPath = file.replace(sourceDir, "").strip(chars = {'/', '\\'})
        
        # Entferne .md Endung für Seitennamen
        var pageName = relPath[0..^4]
        
        # Normalisiere Pfad-Trenner zu /
        pageName = pageName.replace("\\", "/")
        
        # Füge Ziel-Präfix hinzu falls angegeben
        if targetPrefix != "":
          pageName = targetPrefix & "/" & pageName
        
        # Hochladen
        let encodedName = encodeUrl(pageName)
        discard makeRequest(client, HttpPut, "/.fs/" & encodedName & ".md", content)
        
        restored.inc
        echo "✓ ", pageName
      except CatchableError as e:
        failed.inc
        let relPath = file.replace(sourceDir, "").strip(chars = {'/', '\\'})
        styledEcho(fgRed, "✗ ", resetStyle, relPath, " (", e.msg, ")")
  
  echo "─".repeat(60)
  echo "Wiederhergestellt: ", restored, " Dateien"
  if failed > 0:
    echo "⚠ ", failed, " Dateien konnten nicht wiederhergestellt werden"
  if restored > 0:
    styledEcho(fgGreen, "✓ ", resetStyle, "Restore erfolgreich!")

## Lädt eine Seite in eine lokale Datei herunter
proc downloadPage(pageName: string, outputFile = "") =
  let client = newHttpClient()
  defer: client.close()
  
  echo "\n📥 Lade Seite herunter..."
  
  try:
    # Hole Seiteninhalt
    let encodedName = encodeUrl(pageName)
    let content = makeRequest(client, HttpGet, "/.fs/" & encodedName & ".md")
    
    # Bestimme Ausgabedatei
    let filename = if outputFile != "":
      outputFile
    else:
      pageName & ".md"
    
    # Speichere Datei
    writeFile(filename, content)
    
    styledEcho(fgGreen, "✓ ", resetStyle, "Heruntergeladen: ", pageName)
    echo "Gespeichert als: ", filename
    echo "Größe: ", content.len, " Bytes"
  except CatchableError as e:
    styledEcho(fgRed, "✗ ", resetStyle, "Fehler beim Download: ", e.msg)
    quit(1)

## Lädt eine lokale Datei als Seite hoch
proc uploadPage(sourceFile: string, pageName: string) =
  let client = newHttpClient()
  defer: client.close()
  
  echo "\n📤 Lade Datei hoch..."
  
  if not fileExists(sourceFile):
    styledEcho(fgRed, "✗ ", resetStyle, "Datei nicht gefunden: ", sourceFile)
    quit(1)
  
  try:
    # Lese Dateiinhalt
    let content = readFile(sourceFile)
    
    # Hochladen
    let encodedName = encodeUrl(pageName)
    discard makeRequest(client, HttpPut, "/.fs/" & encodedName & ".md", content)
    
    styledEcho(fgGreen, "✓ ", resetStyle, "Hochgeladen: ", sourceFile)
    echo "Als Seite: ", pageName
    echo "Größe: ", content.len, " Bytes"
  except CatchableError as e:
    styledEcho(fgRed, "✗ ", resetStyle, "Fehler beim Upload: ", e.msg)
    quit(1)



## Extrahiert Wiki-Links aus Markdown-Text
proc extractLinks(content: string): seq[string] =
  var links: seq[string] = @[]
  # Regex für [[Link]] und [[Link|Text]] Syntax
  # Verbesserte Unicode-Unterstützung für Emoji und Sonderzeichen
  let pattern = re"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"
  
  var pos = 0
  while pos < content.len:
    let match = content[pos..^1].find(pattern)
    if match >= 0:
      let startPos = pos + match
      let endPos = content.find("]]", startPos)
      if endPos >= 0:
        let fullMatch = content[startPos..endPos+1]
        # Extrahiere den Link-Text
        let linkContent = fullMatch[2..^3]  # Entferne [[ und ]]
        let linkName = if "|" in linkContent:
          linkContent.split("|")[0].strip()
        else:
          linkContent.strip()
        
        if linkName != "":
          links.add(linkName)
        pos = endPos + 2
      else:
        break
    else:
      break
  
  return links

## Gibt Text durch einen Pager aus (wie less)
proc usePager(content: string) =
  when defined(windows):
    # Unter Windows: more verwenden
    let tmpFile = getTempDir() / "sb_output.txt"
    writeFile(tmpFile, content)
    discard execShellCmd("more < " & tmpFile)
    removeFile(tmpFile)
  else:
    # Unter Linux/Mac: less verwenden (fallback: more, fallback: cat)
    if findExe("less") != "":
      let tmpFile = getTempDir() / "sb_output.txt"
      writeFile(tmpFile, content)
      discard execShellCmd("less " & tmpFile)
      removeFile(tmpFile)
    elif findExe("more") != "":
      let tmpFile = getTempDir() / "sb_output.txt"
      writeFile(tmpFile, content)
      discard execShellCmd("more " & tmpFile)
      removeFile(tmpFile)
    else:
      # Kein Pager verfügbar, direkt ausgeben
      echo content

## Prüft ob Ausgabe durch Pager geleitet werden soll
proc shouldUsePager(lines: int): bool =
  # Verwende Pager wenn mehr als 30 Zeilen
  return lines > 30
## Erstellt einen Graph der Verlinkungen zwischen Seiten
proc showGraph(format = "text", showAll = false) =
  let client = newHttpClient()
  defer: client.close()
  
  # Info-Ausgaben nur bei Text-Format
  if format.toLower() == "text":
    echo "\n🔗 Analysiere Verlinkungen..."
    echo "─".repeat(60)
  
  # Hole alle Seiten
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  # Sammle alle Seiten und ihre Links
  var graph: Table[string, seq[string]]
  var allPages: HashSet[string]
  
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        
        # Filtere System-Seiten
        if not showAll and isSystemPage(pageName):
          continue
        
        allPages.incl(pageName)
        
        try:
          let encodedName = encodeUrl(name)
          let content = makeRequest(client, HttpGet, "/.fs/" & encodedName)
          let links = extractLinks(content)
          graph[pageName] = links
        except:
          graph[pageName] = @[]
  
  # Ausgabe je nach Format
  case format.toLower()
  of "dot", "graphviz":
    # Graphviz DOT Format - nur den Graph ausgeben
    echo "digraph Notes {"
    echo "  rankdir=LR;"
    echo "  node [shape=box, style=rounded];"
    echo ""
    for page, links in graph:
      let safeFrom = page.replace("\"", "\\\"")
      for link in links:
        if link in allPages:
          let safeTo = link.replace("\"", "\\\"")
          echo "  \"", safeFrom, "\" -> \"", safeTo, "\";"
    echo "}"
    
  else:
    # Text-Ausgabe (Standard)
    var totalLinks = 0
    var isolatedPages: seq[string] = @[]
    var output = ""
    
    for page in allPages:
      let outgoing = if page in graph: graph[page].len else: 0
      var incoming = 0
      
      for otherPage, links in graph:
        if page in links:
          incoming.inc
      
      if outgoing == 0 and incoming == 0:
        isolatedPages.add(page)
      elif outgoing > 0:
        output.add("\n📄 " & page & "\n")
        output.add("  → " & $outgoing & " ausgehende Links:\n")
        if page in graph:
          for link in graph[page]:
            if link in allPages:
              output.add("    • " & link & "\n")
              totalLinks.inc
            else:
              output.add("    • " & link & " (nicht vorhanden)\n")
        if incoming > 0:
          output.add("  ← " & $incoming & " eingehende Links\n")
    
    if isolatedPages.len > 0:
      output.add("\n🔷 Isolierte Seiten (keine Verlinkungen):\n")
      for page in isolatedPages:
        output.add("  • " & page & "\n")
    
    output.add("\n" & "─".repeat(60) & "\n")
    output.add("Seiten: " & $allPages.len & "\n")
    output.add("Verbindungen: " & $totalLinks & "\n")
    output.add("Isoliert: " & $isolatedPages.len & "\n")
    
    # Prüfe ob Pager verwendet werden soll
    let lineCount = output.count("\n")
    if shouldUsePager(lineCount):
      usePager(output)
    else:
      echo output

## Hauptfunktion
proc main() =
  var args: seq[string] = @[]
  for i in 1..paramCount():
    args.add(paramStr(i))
  
  # Prüfe auf globale Flags
  var showAll = false
  var fullBackup = false
  var targetPrefix = ""
  var i = 0
  while i < args.len:
    if args[i].startsWith("--configfile="):
      configFile = args[i][13..^1]
      args.delete(i)
    elif args[i] == "--configfile" and i + 1 < args.len:
      configFile = args[i + 1]
      args.delete(i)
      args.delete(i)
    elif args[i] == "--all" or args[i] == "-a":
      showAll = true
      args.delete(i)
    elif args[i] == "--full":
      fullBackup = true
      args.delete(i)
    elif args[i].startsWith("--to="):
      targetPrefix = args[i][5..^1]
      args.delete(i)
    else:
      i.inc
  
  loadConfig()
  
  if args.len == 0:
    showHelp()
    return
  
  let command = args[0].toLower()
  
  if command in ["help", "h"]:
    showHelp()
    return
  
  if command in ["version", "v"]:
    echo AppName, " v", Version
    return
  
  if command == "config":
    if args.len < 2:
      echo "Fehler: Server-URL erforderlich"
      echo "Verwendung: sb config <url> [token]"
      return
    let url = args[1]
    let token = if args.len >= 3: args[2] else: ""
    configureServer(url, token)
    return
  
  if config.serverUrl == "":
    styledEcho(fgRed, "✗ ", resetStyle, "Keine Server-URL konfiguriert!")
    echo "Verwende: sb config <server-url>"
    echo ""
    echo "Beispiel:"
    echo "  sb config http://localhost:3000"
    echo "  sb config https://your-server.com"
    quit(1)
  
  case command
  of "list", "ls":
    listPages(showAll)
  
  of "get", "show", "cat":
    if args.len < 2:
      echo "Fehler: Seitenname erforderlich"
      return
    getPage(args[1])
  
  of "create", "new":
    if args.len < 2:
      echo "Fehler: Seitenname erforderlich"
      echo "Verwendung: sb create <page> [<text>]"
      return
    let pageName = args[1]
    let content = if args.len >= 3:
      args[2..^1].join(" ")
    else:
      readFromStdin()
    
    if content.len == 0:
      echo "Fehler: Kein Inhalt angegeben"
      return
    
    createOrEditPage(pageName, content)
  
  of "edit", "update":
    if args.len < 2:
      echo "Fehler: Seitenname erforderlich"
      return
    let pageName = args[1]
    let content = if args.len >= 3:
      args[2..^1].join(" ")
    else:
      readFromStdin()
    
    if content.len == 0:
      echo "Fehler: Kein Inhalt angegeben"
      return
    
    createOrEditPage(pageName, content, isEdit = true)
  
  of "append", "add":
    if args.len < 2:
      echo "Fehler: Seitenname erforderlich"
      return
    let pageName = args[1]
    let content = if args.len >= 3:
      args[2..^1].join(" ")
    else:
      readFromStdin()
    
    if content.len == 0:
      echo "Fehler: Kein Inhalt angegeben"
      return
    
    appendToPage(pageName, content)
  
  of "delete", "rm", "del":
    if args.len < 2:
      echo "Fehler: Seitenname erforderlich"
      return
    deletePage(args[1])
  
  of "search", "find":
    if args.len < 2:
      echo "Fehler: Suchbegriff erforderlich"
      return
    searchPages(args[1])
  
  of "recent":
    showRecent(10, showAll)
  
  of "backup":
    let backupDir = if args.len >= 2: args[1] else: ""
    backupPages(backupDir, fullBackup)
  
  of "restore":
    if args.len < 2:
      echo "Fehler: Backup-Verzeichnis erforderlich"
      echo "Verwendung: sb restore <backup-verzeichnis> [--to=<ziel-präfix>]"
      return
    restorePages(args[1], targetPrefix)
  
  of "download", "dl":
    if args.len < 2:
      echo "Fehler: Seitenname erforderlich"
      echo "Verwendung: sb download <page> [<ausgabedatei>]"
      return
    let outputFile = if args.len >= 3: args[2] else: ""
    downloadPage(args[1], outputFile)
  
  of "upload", "ul":
    if args.len < 3:
      echo "Fehler: Quelldatei und Seitenname erforderlich"
      echo "Verwendung: sb upload <datei> <page>"
      return
    uploadPage(args[1], args[2])
  
  of "graph":
    let format = if args.len >= 2: args[1] else: "text"
    showGraph(format, showAll)
  
  else:
    echo "Unbekannter Befehl: ", command
    echo "Verwende 'sb help' für Hilfe"

when isMainModule:
  main()