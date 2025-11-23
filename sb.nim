import std/[httpclient, json, os, strutils, terminal, times, uri, algorithm, re, sets, tables]

const
  Version = "0.1.0"
  AppName = "SilverBullet CLI"
  # System-Verzeichnisse die standardmäßig ausgeblendet werden
  SystemPrefixes = [
    "Library/",
    "SETTINGS",
    "PLUGS",
    "_"  # Dateien die mit _ beginnen
  ]
  # Konstanten für bessere Wartbarkeit
  DefaultRecentLimit = 10
  MaxSnippetLength = 80
  SeparatorLength = 60
  HttpTimeoutMs = 30000  # 30 Sekunden
  PageContentSeparator = "\n"

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

## Helper: Prüft ob Seite angezeigt werden soll
proc shouldIncludePage(pageName: string, showAll: bool): bool =
  showAll or not isSystemPage(pageName)

## Validiert Seitennamen auf gefährliche Zeichen
proc validatePageName(name: string): bool =
  not (name.contains("..") or name.contains("\0") or name.len == 0)

## Helper: Erstellt Endpoint-URL für eine Seite
proc getPageEndpoint(pageName: string): string =
  "/.fs/" & encodeUrl(pageName) & ".md"

## Formatiert eine Zahl mit führenden Nullen
proc formatWithLeadingZeros(num: int, width: int): string =
  ($num).align(width, '0')

## Lädt Konfiguration aus der JSON-Datei (falls vorhanden).
proc loadConfig() =
  if fileExists(configFile):
    try:
      let data = parseFile(configFile)
      config.serverUrl = data{"serverUrl"}.getStr("")
      config.authToken = data{"authToken"}.getStr("")
    except CatchableError:
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

## Zeigt Progress-Anzeige
proc showProgress(current, total: int, label = "Fortschritt") =
  if total == 0: return
  let percent = (current * 100) div total
  let barWidth = 30
  let filled = (percent * barWidth) div 100
  stdout.write("\r" & label & ": [")
  stdout.write("=".repeat(filled))
  stdout.write(" ".repeat(barWidth - filled))
  stdout.write("] " & $percent & "% (" & $current & "/" & $total & ")")
  stdout.flushFile()
  if current == total:
    echo ""  # Neue Zeile am Ende

## Führt eine HTTP-Anfrage aus (GET/PUT/DELETE)
proc makeRequest(client: HttpClient, httpMethod: HttpMethod, endpoint: string, body = ""): string =
  let url = config.serverUrl & endpoint
  
  client.timeout = HttpTimeoutMs
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
  except OSError as e:
    # OSError wird bei Timeouts geworfen
    if "timeout" in e.msg.toLower():
      styledEcho(fgRed, "✗ Timeout: ", resetStyle, "Server antwortet nicht (>30s)")
    else:
      styledEcho(fgRed, "✗ Netzwerkfehler: ", resetStyle, e.msg)
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
  delete <page>           Löscht eine Seite (mit Bestätigung)
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
  --full                  Bei backup/restore: inkl. System-Seiten
  --verbose               Zeigt detaillierte Ausgaben bei backup/restore
  --force, -f             Überspringt Bestätigungen (z.B. bei delete)
  --to=<pfad>             Bei restore: Ziel-Präfix für wiederhergestellte Dateien

BEISPIELE:
  sb config http://localhost:3000
  sb list
  sb get index
  sb create "Meeting Notes" "# Meeting"
  sb append index "- New item"
  sb delete "Test Page"
  sb delete "Test Page" -f
  sb search "TODO"
  sb backup
  sb backup --verbose
  sb restore backup-23112025-143025
  sb restore backup-23112025-143025 --verbose

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
    echo "─".repeat(SeparatorLength)
    
    var pages: seq[tuple[name: string, lastModified: int]] = @[]
    
    for item in data:
      if item.kind == JObject:
        let name = item["name"].getStr()
        if name.endsWith(".md"):
          let pageName = name[0..^4]
          if shouldIncludePage(pageName, showAll):
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
    
    echo "─".repeat(SeparatorLength)
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
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, "Ungültiger Seitenname")
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  let content = makeRequest(client, HttpGet, getPageEndpoint(pageName))
  echo content

## Erstellt oder überschreibt eine Seite
proc createOrEditPage(pageName: string, content: string, isEdit = false) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, "Ungültiger Seitenname")
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  discard makeRequest(client, HttpPut, getPageEndpoint(pageName), content)
  
  let action = if isEdit: "aktualisiert" else: "erstellt"
  styledEcho(fgGreen, "✓ ", resetStyle, "Seite '", pageName, "' ", action)

## Hängt Text an eine Seite an
proc appendToPage(pageName: string, content: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, "Ungültiger Seitenname")
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  # Versuche existierenden Inhalt zu holen
  var currentContent = ""
  try:
    currentContent = makeRequest(client, HttpGet, getPageEndpoint(pageName))
  except CatchableError:
    # Seite existiert nicht - wird neu erstellt
    styledEcho(fgYellow, "ℹ ", resetStyle, "Seite '", pageName, "' existiert nicht, wird erstellt")
  
  # Baue neuen Inhalt zusammen
  var newContent = currentContent
  if currentContent.len > 0 and not currentContent.endsWith("\n"):
    newContent.add(PageContentSeparator)
  
  newContent.add(content)
  
  # Stelle sicher dass Datei mit Newline endet
  if not newContent.endsWith("\n"):
    newContent.add("\n")
  
  # Speichere zurück
  discard makeRequest(client, HttpPut, getPageEndpoint(pageName), newContent)
  styledEcho(fgGreen, "✓ ", resetStyle, "Text zu '", pageName, "' hinzugefügt")

## Löscht eine Seite (mit optionaler Bestätigung)
proc deletePage(pageName: string, force = false) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, "Ungültiger Seitenname")
    quit(1)
  
  # Frage nach Bestätigung, außer --force
  if not force:
    stdout.styledWrite(fgYellow, "⚠ ", resetStyle, "Seite '", pageName, "' wirklich löschen? (j/N): ")
    stdout.flushFile()
    let answer = stdin.readLine().toLower()
    if answer != "j" and answer != "ja" and answer != "y" and answer != "yes":
      echo "Abgebrochen."
      return
  
  let client = newHttpClient()
  defer: client.close()
  
  discard makeRequest(client, HttpDelete, getPageEndpoint(pageName))
  styledEcho(fgRed, "✗ ", resetStyle, "Seite '", pageName, "' gelöscht")

## Durchsucht alle Seiten
proc searchPages(query: string) =
  let client = newHttpClient()
  defer: client.close()
  
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  echo "\n🔍 Suche nach: '", query, "'\n"
  echo "─".repeat(SeparatorLength)
  
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
          let content = makeRequest(client, HttpGet, getPageEndpoint(pageName))
          
          if query.toLower() in content.toLower():
            found.inc
            styledEcho(fgCyan, "• ", resetStyle, pageName)
            
            for line in content.splitLines():
              if query.toLower() in line.toLower():
                let trimmed = line.strip()
                if trimmed.len > 0:
                  echo "  ", trimmed[0..min(trimmed.len-1, MaxSnippetLength)]
                break
        except HttpRequestError, OSError:
          discard

  echo "─".repeat(SeparatorLength)
  echo "Gefunden: ", found, " Seiten"

## Zeigt die zuletzt geänderten Seiten
proc showRecent(limit = DefaultRecentLimit, showAll = false) =
  let client = newHttpClient()
  defer: client.close()
  
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  echo "\n🕐 Kürzlich geänderte Seiten\n"
  echo "─".repeat(SeparatorLength)
  
  var pages: seq[tuple[name: string, lastModified: int]] = @[]
  
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        if shouldIncludePage(pageName, showAll):
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
  
  echo "─".repeat(SeparatorLength)
  if showAll:
    echo "Zeige ", min(limit, pages.len), " von ", pages.len, " Seiten (alle)"
  else:
    echo "Zeige ", min(limit, pages.len), " von ", pages.len, " Seiten (ohne System-Seiten, verwende --all um alle zu sehen)"

## Erstellt ein Backup aller Seiten
proc backupPages(targetDir = "", fullBackup = false, verbose = false) =
  let client = newHttpClient()
  defer: client.close()
  
  let timestamp = now().format("ddMMyyyy-HHmmss")
  let backupPath = if targetDir != "":
    targetDir
  else:
    getCurrentDir() / "backup-" & timestamp
  
  echo "\n💾 Erstelle Backup..."
  echo "Zielverzeichnis: ", backupPath
  echo "─".repeat(SeparatorLength)
  
  createDir(backupPath)
  
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  var totalFiles = 0
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        if fullBackup or not isSystemPage(pageName):
          totalFiles.inc
  
  var backedUp = 0
  var skipped = 0
  
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        
        if not fullBackup and isSystemPage(pageName):
          skipped.inc
          continue
        
        try:
          let content = makeRequest(client, HttpGet, getPageEndpoint(pageName))
          
          let filePath = backupPath / name
          let dir = parentDir(filePath)
          if dir != "" and not dirExists(dir):
            createDir(dir)
          
          writeFile(filePath, content)
          backedUp.inc
          
          if verbose:
            echo "✓ ", name
          else:
            showProgress(backedUp, totalFiles, "Backup")
        except CatchableError as e:
          if not verbose:
            echo ""
          styledEcho(fgRed, "✗ ", resetStyle, name, " (", e.msg, ")")
  
  echo "─".repeat(SeparatorLength)
  echo "Gesichert: ", backedUp, " Dateien"
  if skipped > 0:
    echo "Übersprungen: ", skipped, " System-Dateien (verwende --full für komplettes Backup)"
  styledEcho(fgGreen, "✓ ", resetStyle, "Backup erfolgreich nach: ", backupPath)

## Stellt Seiten aus einem Backup wieder her
proc restorePages(sourceDir: string, targetPrefix = "", verbose = false) =
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
  echo "─".repeat(SeparatorLength)
  
  var allFiles: seq[string] = @[]
  for file in walkDirRec(sourceDir):
    if file.endsWith(".md"):
      allFiles.add(file)
  
  let totalFiles = allFiles.len
  var restored = 0
  var failed = 0
  
  for file in allFiles:
    try:
      let content = readFile(file)
      
      let relPath = file.replace(sourceDir, "").strip(chars = {'/', '\\'})
      
      var pageName = relPath[0..^4]
      
      pageName = pageName.replace("\\", "/")
      
      if targetPrefix != "":
        pageName = targetPrefix & "/" & pageName
      
      discard makeRequest(client, HttpPut, getPageEndpoint(pageName), content)
      
      restored.inc
      
      if verbose:
        echo "✓ ", pageName
      else:
        showProgress(restored, totalFiles, "Restore")
    except CatchableError as e:
      failed.inc
      let relPath = file.replace(sourceDir, "").strip(chars = {'/', '\\'})
      if not verbose:
        echo ""
      styledEcho(fgRed, "✗ ", resetStyle, relPath, " (", e.msg, ")")
  
  echo "─".repeat(SeparatorLength)
  echo "Wiederhergestellt: ", restored, " Dateien"
  if failed > 0:
    echo "⚠ ", failed, " Dateien konnten nicht wiederhergestellt werden"
  if restored > 0:
    styledEcho(fgGreen, "✓ ", resetStyle, "Restore erfolgreich!")

## Lädt eine Seite in eine lokale Datei herunter
proc downloadPage(pageName: string, outputFile = "") =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, "Ungültiger Seitenname")
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  echo "\n📥 Lade Seite herunter..."
  
  try:
    let content = makeRequest(client, HttpGet, getPageEndpoint(pageName))
    
    let filename = if outputFile != "":
      outputFile
    else:
      pageName & ".md"
    
    writeFile(filename, content)
    
    styledEcho(fgGreen, "✓ ", resetStyle, "Heruntergeladen: ", pageName)
    echo "Gespeichert als: ", filename
    echo "Größe: ", content.len, " Bytes"
  except CatchableError as e:
    styledEcho(fgRed, "✗ ", resetStyle, "Fehler beim Download: ", e.msg)
    quit(1)

## Lädt eine lokale Datei als Seite hoch
proc uploadPage(sourceFile: string, pageName: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, "Ungültiger Seitenname")
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  echo "\n📤 Lade Datei hoch..."
  
  if not fileExists(sourceFile):
    styledEcho(fgRed, "✗ ", resetStyle, "Datei nicht gefunden: ", sourceFile)
    quit(1)
  
  try:
    let content = readFile(sourceFile)
    
    discard makeRequest(client, HttpPut, getPageEndpoint(pageName), content)
    
    styledEcho(fgGreen, "✓ ", resetStyle, "Hochgeladen: ", sourceFile)
    echo "Als Seite: ", pageName
    echo "Größe: ", content.len, " Bytes"
  except CatchableError as e:
    styledEcho(fgRed, "✗ ", resetStyle, "Fehler beim Upload: ", e.msg)
    quit(1)

## Extrahiert Wiki-Links aus Markdown-Text
proc extractLinks(content: string): seq[string] =
  var links: seq[string] = @[]
  let pattern = re"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"
  
  for match in content.findAll(pattern):
    let inner = match[2..^3]
    let linkName = if "|" in inner:
      inner.split("|")[0].strip()
    else:
      inner.strip()
    
    if linkName != "":
      links.add(linkName)
  
  return links

## Erstellt einen Graph der Verlinkungen zwischen Seiten
proc showGraph(format = "text", showAll = false) =
  let client = newHttpClient()
  defer: client.close()
  
  if format.toLower() == "text":
    echo "\n🔗 Analysiere Verlinkungen..."
    echo "─".repeat(SeparatorLength)
  
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  var graph: Table[string, seq[string]]
  var allPages: HashSet[string]
  var incomingCounts: Table[string, int]
  
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        
        if not shouldIncludePage(pageName, showAll):
          continue
        
        allPages.incl(pageName)
        incomingCounts[pageName] = 0
        
        try:
          let content = makeRequest(client, HttpGet, getPageEndpoint(pageName))
          let links = extractLinks(content)
          graph[pageName] = links
          
          for link in links:
            if link notin incomingCounts:
              incomingCounts[link] = 0
            incomingCounts[link] += 1
        except HttpRequestError, OSError:
          graph[pageName] = @[]
  
  case format.toLower()
  of "dot", "graphviz":
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
    var totalLinks = 0
    var isolatedPages: seq[string] = @[]
    
    for page in allPages:
      let outgoing = if page in graph: graph[page].len else: 0
      let incoming = incomingCounts.getOrDefault(page, 0)
      
      if outgoing == 0 and incoming == 0:
        isolatedPages.add(page)
      elif outgoing > 0:
        echo "\n📄 ", page
        echo "  → ", outgoing, " ausgehende Links:"
        if page in graph:
          for link in graph[page]:
            if link in allPages:
              echo "    • ", link
              totalLinks.inc
            else:
              echo "    • ", link, " (nicht vorhanden)"
        if incoming > 0:
          echo "  ← ", incoming, " eingehende Links"
    
    if isolatedPages.len > 0:
      echo "\n🔷 Isolierte Seiten (keine Verlinkungen):"
      for page in isolatedPages:
        echo "  • ", page
    
    echo "\n─".repeat(SeparatorLength)
    echo "Seiten: ", allPages.len
    echo "Verbindungen: ", totalLinks
    echo "Isoliert: ", isolatedPages.len

## Hauptfunktion
proc main() =
  var args: seq[string] = @[]
  for i in 1..paramCount():
    args.add(paramStr(i))
  
  var showAll = false
  var fullBackup = false
  var targetPrefix = ""
  var verbose = false
  var force = false
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
    elif args[i] == "--verbose":
      verbose = true
      args.delete(i)
    elif args[i] == "--force" or args[i] == "-f":
      force = true
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
  
  if command in ["version", "ver"]:
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
    deletePage(args[1], force)
  
  of "search", "find":
    if args.len < 2:
      echo "Fehler: Suchbegriff erforderlich"
      return
    searchPages(args[1])
  
  of "recent":
    showRecent(DefaultRecentLimit, showAll)
  
  of "backup":
    let backupDir = if args.len >= 2: args[1] else: ""
    backupPages(backupDir, fullBackup, verbose)
  
  of "restore":
    if args.len < 2:
      echo "Fehler: Backup-Verzeichnis erforderlich"
      echo "Verwendung: sb restore <backup-verzeichnis> [--to=<ziel-präfix>]"
      return
    restorePages(args[1], targetPrefix, verbose)
  
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
