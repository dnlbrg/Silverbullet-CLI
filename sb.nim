import std/[httpclient, json, os, strutils, terminal, times, uri, algorithm, re, sets, tables]

const
  Version = "0.1.0"
  AppName = "SilverBullet CLI"
  SystemPrefixes = ["Library/", "SETTINGS", "PLUGS", "_"]
  DefaultRecentLimit = 10
  MaxSnippetLength = 80
  SeparatorLength = 60
  HttpTimeoutMs = 30000
  PageContentSeparator = "\n"

type
  Language = enum
    langDE = "de"
    langEN = "en"
  
  Config = object
    serverUrl: string
    authToken: string
    language: Language

var translations = {
  "de": {
    "config_saved": "Konfiguration gespeichert",
    "server": "Server",
    "token": "Token",
    "total": "Gesamt",
    "pages": "Seiten",
    "all": "alle",
    "without_system": "ohne System-Seiten, verwende --all um alle zu sehen",
    "showing": "Zeige",
    "of": "von",
    "found": "Gefunden",
    "backed_up": "Gesichert",
    "files": "Dateien",
    "skipped": "Übersprungen",
    "system_files": "System-Dateien (verwende --full für komplettes Backup)",
    "restored": "Wiederhergestellt",
    "size": "Größe",
    "bytes": "Bytes",
    "page_created": "Seite '$1' erstellt",
    "page_updated": "Seite '$1' aktualisiert",
    "page_deleted": "Seite '$1' gelöscht",
    "page_not_exist": "Seite '$1' existiert nicht, wird erstellt",
    "text_appended": "Text zu '$1' hinzugefügt",
    "invalid_pagename": "Ungültiger Seitenname",
    "backup_success": "Backup erfolgreich nach: $1",
    "restore_success": "Restore erfolgreich!",
    "downloaded": "Heruntergeladen",
    "uploaded": "Hochgeladen",
    "saved_as": "Gespeichert als",
    "as_page": "Als Seite",
    "file_not_found": "Datei nicht gefunden",
    "backup_dir_not_found": "Backup-Verzeichnis nicht gefunden",
    "download_error": "Fehler beim Download",
    "upload_error": "Fehler beim Upload",
    "aborted": "Abgebrochen.",
    "confirm_delete": "Seite '$1' wirklich löschen? (j/N): ",
    "pages_in_sb": "Seiten in SilverBullet",
    "search_for": "Suche nach: '$1'",
    "in_title": "(im Titel)",
    "recent_pages": "Kürzlich geänderte Seiten",
    "creating_backup": "Erstelle Backup...",
    "target_dir": "Zielverzeichnis",
    "restoring_backup": "Stelle Backup wieder her...",
    "source": "Quelle",
    "target_prefix": "Ziel-Präfix",
    "target": "Ziel",
    "original_paths": "Original-Pfade",
    "downloading_page": "Lade Seite herunter...",
    "uploading_file": "Lade Datei hoch...",
    "analyzing_links": "Analysiere Verlinkungen...",
    "isolated_pages": "Isolierte Seiten (keine Verlinkungen)",
    "connections": "Verbindungen",
    "isolated": "Isoliert",
    "outgoing_links": "ausgehende Links",
    "incoming_links": "eingehende Links",
    "not_found": "(nicht vorhanden)",
    "could_not_restore": "Dateien konnten nicht wiederhergestellt werden",
    "error_no_url": "Keine Server-URL konfiguriert!",
    "error_use": "Verwende: sb config <server-url>",
    "error_example": "Beispiel:",
    "error_pagename_required": "Fehler: Seitenname erforderlich",
    "error_query_required": "Fehler: Suchbegriff erforderlich",
    "error_url_required": "Fehler: Server-URL erforderlich",
    "error_backup_dir_required": "Fehler: Backup-Verzeichnis erforderlich",
    "error_no_content": "Fehler: Kein Inhalt angegeben",
    "error_file_and_page_required": "Fehler: Quelldatei und Seitenname erforderlich",
    "error_unknown_command": "Unbekannter Befehl",
    "error_use_help": "Verwende 'sb help' für Hilfe",
    "usage_config": "Verwendung: sb config <url> [token]",
    "usage_create": "Verwendung: sb create <page> [<text>]",
    "usage_restore": "Verwendung: sb restore <backup-verzeichnis> [--to=<ziel-präfix>]",
    "usage_download": "Verwendung: sb download <page> [<ausgabedatei>]",
    "usage_upload": "Verwendung: sb upload <datei> <page>",
    "language_set": "Sprache gesetzt auf"
  }.toTable,
  
  "en": {
    "config_saved": "Configuration saved",
    "server": "Server",
    "token": "Token",
    "total": "Total",
    "pages": "pages",
    "all": "all",
    "without_system": "without system pages, use --all to show all",
    "showing": "Showing",
    "of": "of",
    "found": "Found",
    "backed_up": "Backed up",
    "files": "files",
    "skipped": "Skipped",
    "system_files": "system files (use --full for complete backup)",
    "restored": "Restored",
    "size": "Size",
    "bytes": "bytes",
    "page_created": "Page '$1' created",
    "page_updated": "Page '$1' updated",
    "page_deleted": "Page '$1' deleted",
    "page_not_exist": "Page '$1' does not exist, creating",
    "text_appended": "Text appended to '$1'",
    "invalid_pagename": "Invalid page name",
    "backup_success": "Backup successful to: $1",
    "restore_success": "Restore successful!",
    "downloaded": "Downloaded",
    "uploaded": "Uploaded",
    "saved_as": "Saved as",
    "as_page": "As page",
    "file_not_found": "File not found",
    "backup_dir_not_found": "Backup directory not found",
    "download_error": "Download error",
    "upload_error": "Upload error",
    "aborted": "Aborted.",
    "confirm_delete": "Really delete page '$1'? (y/N): ",
    "pages_in_sb": "Pages in SilverBullet",
    "search_for": "Search for: '$1'",
    "in_title": "(in title)",
    "recent_pages": "Recently changed pages",
    "creating_backup": "Creating backup...",
    "target_dir": "Target directory",
    "restoring_backup": "Restoring backup...",
    "source": "Source",
    "target_prefix": "Target prefix",
    "target": "Target",
    "original_paths": "Original paths",
    "downloading_page": "Downloading page...",
    "uploading_file": "Uploading file...",
    "analyzing_links": "Analyzing links...",
    "isolated_pages": "Isolated pages (no links)",
    "connections": "Connections",
    "isolated": "Isolated",
    "outgoing_links": "outgoing links",
    "incoming_links": "incoming links",
    "not_found": "(not found)",
    "could_not_restore": "files could not be restored",
    "error_no_url": "No server URL configured!",
    "error_use": "Use: sb config <server-url>",
    "error_example": "Example:",
    "error_pagename_required": "Error: Page name required",
    "error_query_required": "Error: Search query required",
    "error_url_required": "Error: Server URL required",
    "error_backup_dir_required": "Error: Backup directory required",
    "error_no_content": "Error: No content provided",
    "error_file_and_page_required": "Error: Source file and page name required",
    "error_unknown_command": "Unknown command",
    "error_use_help": "Use 'sb help' for help",
    "usage_config": "Usage: sb config <url> [token]",
    "usage_create": "Usage: sb create <page> [<text>]",
    "usage_restore": "Usage: sb restore <backup-directory> [--to=<target-prefix>]",
    "usage_download": "Usage: sb download <page> [<output-file>]",
    "usage_upload": "Usage: sb upload <file> <page>",
    "language_set": "Language set to"
  }.toTable
}.toTable

var config: Config
var configFile = getConfigDir() / "silverbullet-cli" / "config.json"

proc t(key: string, args: varargs[string]): string =
  let lang = $config.language
  if lang in translations and key in translations[lang]:
    result = translations[lang][key]
    for i, arg in args:
      result = result.replace("$" & $(i+1), arg)
  else:
    result = key

proc isSystemPage(pageName: string): bool =
  for prefix in SystemPrefixes:
    if pageName.startsWith(prefix):
      return true
  return false

proc shouldIncludePage(pageName: string, showAll: bool): bool =
  showAll or not isSystemPage(pageName)

proc validatePageName(name: string): bool =
  not (name.contains("..") or name.contains("\0") or name.len == 0)

proc getPageEndpoint(pageName: string): string =
  "/.fs/" & encodeUrl(pageName) & ".md"

proc formatWithLeadingZeros(num: int, width: int): string =
  ($num).align(width, '0')

proc loadConfig() =
  if fileExists(configFile):
    try:
      let data = parseFile(configFile)
      config.serverUrl = data{"serverUrl"}.getStr("")
      config.authToken = data{"authToken"}.getStr("")
      let langStr = data{"language"}.getStr("en")
      config.language = if langStr == "de": langDE else: langEN
    except CatchableError:
      config.language = langEN
  else:
    config.language = langEN

proc saveConfig() =
  createDir(parentDir(configFile))
  let data = %* {
    "serverUrl": config.serverUrl,
    "authToken": config.authToken,
    "language": $config.language
  }
  writeFile(configFile, data.pretty())

proc readFromStdin(): string =
  var content = ""
  var line: string
  while stdin.readLine(line):
    if content.len > 0:
      content.add("\n")
    content.add(line)
  return content

proc showProgress(current, total: int, label: string) =
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
    echo ""

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
    if "timeout" in e.msg.toLower():
      styledEcho(fgRed, "✗ Timeout: ", resetStyle, "Server not responding (>30s)")
    else:
      styledEcho(fgRed, "✗ Network Error: ", resetStyle, e.msg)
    quit(1)
  except Exception as e:
    styledEcho(fgRed, "✗ Error: ", resetStyle, e.msg)
    quit(1)

proc showHelp() =
  let helpTextDE = """
$1 v$2

VERWENDUNG:
  sb [BEFEHL] [OPTIONEN]

BEFEHLE:
  config <url> [token]    Konfiguriert Server-URL und optionalen Auth-Token
  lang <de|en>            Setzt die Sprache
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
  --all, -a               Zeigt auch System-Seiten
  --full                  Bei backup/restore: inkl. System-Seiten
  --verbose               Zeigt detaillierte Ausgaben
  --force, -f             Überspringt Bestätigungen
  --to=<pfad>             Bei restore: Ziel-Präfix

BEISPIELE:
  sb config http://localhost:3000
  sb lang de
  sb list
  sb delete "Test Page" -f
  sb backup --verbose

KONFIGURATION:
  Die Konfiguration wird gespeichert in: $3
"""

  let helpTextEN = """
$1 v$2

USAGE:
  sb [COMMAND] [OPTIONS]

COMMANDS:
  config <url> [token]    Configure server URL and optional auth token
  lang <de|en>            Set language
  list                    List all pages
  get <page>              Show page content
  create <page> <text>    Create a new page
  edit <page> <text>      Edit an existing page
  append <page> <text>    Append text to a page
  delete <page>           Delete a page (with confirmation)
  search <query>          Search all pages
  recent                  Show recently changed pages
  backup [directory]      Create a backup of all pages
  restore <directory>     Restore pages from backup
  download <page> [file]  Download a page to a local file
  upload <file> <page>    Upload a local file as a page
  graph [format]          Show links between pages (text, dot)
  version                 Show version
  help                    Show this help

GLOBAL OPTIONS:
  --configfile=<path>     Use alternative config file
  --all, -a               Show system pages too
  --full                  For backup/restore: incl. system pages
  --verbose               Show detailed output
  --force, -f             Skip confirmations
  --to=<path>             For restore: target prefix

EXAMPLES:
  sb config http://localhost:3000
  sb lang en
  sb list
  sb delete "Test Page" -f
  sb backup --verbose

CONFIGURATION:
  Configuration is saved in: $3
"""

  let helpText = if config.language == langDE: helpTextDE else: helpTextEN
  echo helpText % [AppName, Version, configFile]

proc configureServer(url: string, token = "") =
  var serverUrl = url.strip(chars = {'/'})
  
  if not serverUrl.startsWith("http://") and not serverUrl.startsWith("https://"):
    serverUrl = "http://" & serverUrl
  
  config.serverUrl = serverUrl
  config.authToken = token
  saveConfig()
  styledEcho(fgGreen, "✓ ", resetStyle, t("config_saved"))
  echo t("server"), ": ", config.serverUrl
  if token != "":
    echo t("token"), ": ********"

proc setLanguage(lang: string) =
  case lang.toLower()
  of "de", "deutsch", "german":
    config.language = langDE
  of "en", "english", "englisch":
    config.language = langEN
  else:
    echo "Unknown language. Use: de or en"
    return
  
  saveConfig()
  styledEcho(fgGreen, "✓ ", resetStyle, t("language_set"), ": ", $config.language)

proc listPages(showAll = false) =
  let client = newHttpClient()
  defer: client.close()
  
  let response = makeRequest(client, HttpGet, "/.fs")
  
  try:
    let data = parseJson(response)
    
    echo "\n📄 ", t("pages_in_sb"), "\n"
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
      echo t("total"), ": ", pages.len, " ", t("pages"), " (", t("all"), ")"
    else:
      echo t("total"), ": ", pages.len, " ", t("pages"), " (", t("without_system"), ")"
  except JsonParsingError as e:
    styledEcho(fgRed, "✗ JSON Parse Error: ", resetStyle, e.msg)
    quit(1)

proc getPage(pageName: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  let content = makeRequest(client, HttpGet, getPageEndpoint(pageName))
  echo content

proc createOrEditPage(pageName: string, content: string, isEdit = false) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  discard makeRequest(client, HttpPut, getPageEndpoint(pageName), content)
  
  let msg = if isEdit: t("page_updated", pageName) else: t("page_created", pageName)
  styledEcho(fgGreen, "✓ ", resetStyle, msg)

proc appendToPage(pageName: string, content: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  var currentContent = ""
  try:
    currentContent = makeRequest(client, HttpGet, getPageEndpoint(pageName))
  except CatchableError:
    styledEcho(fgYellow, "ℹ ", resetStyle, t("page_not_exist", pageName))
  
  var newContent = currentContent
  if currentContent.len > 0 and not currentContent.endsWith("\n"):
    newContent.add(PageContentSeparator)
  
  newContent.add(content)
  
  if not newContent.endsWith("\n"):
    newContent.add("\n")
  
  discard makeRequest(client, HttpPut, getPageEndpoint(pageName), newContent)
  styledEcho(fgGreen, "✓ ", resetStyle, t("text_appended", pageName))

proc deletePage(pageName: string, force = false) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  
  if not force:
    stdout.styledWrite(fgYellow, "⚠ ", resetStyle, t("confirm_delete", pageName))
    stdout.flushFile()
    let answer = stdin.readLine().toLower()
    let confirmChars = if config.language == langDE: ["j", "ja"] else: ["y", "yes"]
    if answer notin confirmChars:
      echo t("aborted")
      return
  
  let client = newHttpClient()
  defer: client.close()
  
  discard makeRequest(client, HttpDelete, getPageEndpoint(pageName))
  styledEcho(fgRed, "✗ ", resetStyle, t("page_deleted", pageName))

proc searchPages(query: string) =
  let client = newHttpClient()
  defer: client.close()
  
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  echo "\n🔍 ", t("search_for", query)
  echo "─".repeat(SeparatorLength)
  
  var found = 0
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        
        if query.toLower() in pageName.toLower():
          found.inc
          styledEcho(fgCyan, "• ", resetStyle, pageName, " ", fgYellow, t("in_title"))
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
  echo t("found"), ": ", found, " ", t("pages")

proc showRecent(limit = DefaultRecentLimit, showAll = false) =
  let client = newHttpClient()
  defer: client.close()
  
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  
  echo "\n🕐 ", t("recent_pages"), "\n"
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
    echo t("showing"), " ", min(limit, pages.len), " ", t("of"), " ", pages.len, " ", t("pages"), " (", t("all"), ")"
  else:
    echo t("showing"), " ", min(limit, pages.len), " ", t("of"), " ", pages.len, " ", t("pages"), " (", t("without_system"), ")"

proc backupPages(targetDir = "", fullBackup = false, verbose = false) =
  let client = newHttpClient()
  defer: client.close()
  
  let timestamp = now().format("ddMMyyyy-HHmmss")
  let backupPath = if targetDir != "":
    targetDir
  else:
    getCurrentDir() / "backup-" & timestamp
  
  echo "\n💾 ", t("creating_backup")
  echo t("target_dir"), ": ", backupPath
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
  echo t("backed_up"), ": ", backedUp, " ", t("files")
  if skipped > 0:
    echo t("skipped"), ": ", skipped, " ", t("system_files")
  styledEcho(fgGreen, "✓ ", resetStyle, t("backup_success", backupPath))

proc restorePages(sourceDir: string, targetPrefix = "", verbose = false) =
  let client = newHttpClient()
  defer: client.close()
  
  if not dirExists(sourceDir):
    styledEcho(fgRed, "✗ ", resetStyle, t("backup_dir_not_found"), ": ", sourceDir)
    quit(1)
  
  echo "\n📦 ", t("restoring_backup")
  echo t("source"), ": ", sourceDir
  if targetPrefix != "":
    echo t("target_prefix"), ": ", targetPrefix, "/"
  else:
    echo t("target"), ": ", t("original_paths")
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
  echo t("restored"), ": ", restored, " ", t("files")
  if failed > 0:
    echo "⚠ ", failed, " ", t("could_not_restore")
  if restored > 0:
    styledEcho(fgGreen, "✓ ", resetStyle, t("restore_success"))

proc downloadPage(pageName: string, outputFile = "") =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  echo "\n📥 ", t("downloading_page")
  
  try:
    let content = makeRequest(client, HttpGet, getPageEndpoint(pageName))
    
    let filename = if outputFile != "":
      outputFile
    else:
      pageName & ".md"
    
    writeFile(filename, content)
    
    styledEcho(fgGreen, "✓ ", resetStyle, t("downloaded"), ": ", pageName)
    echo t("saved_as"), ": ", filename
    echo t("size"), ": ", content.len, " ", t("bytes")
  except CatchableError as e:
    styledEcho(fgRed, "✗ ", resetStyle, t("download_error"), ": ", e.msg)
    quit(1)

proc uploadPage(sourceFile: string, pageName: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  
  let client = newHttpClient()
  defer: client.close()
  
  echo "\n📤 ", t("uploading_file")
  
  if not fileExists(sourceFile):
    styledEcho(fgRed, "✗ ", resetStyle, t("file_not_found"), ": ", sourceFile)
    quit(1)
  
  try:
    let content = readFile(sourceFile)
    
    discard makeRequest(client, HttpPut, getPageEndpoint(pageName), content)
    
    styledEcho(fgGreen, "✓ ", resetStyle, t("uploaded"), ": ", sourceFile)
    echo t("as_page"), ": ", pageName
    echo t("size"), ": ", content.len, " ", t("bytes")
  except CatchableError as e:
    styledEcho(fgRed, "✗ ", resetStyle, t("upload_error"), ": ", e.msg)
    quit(1)

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

proc showGraph(format = "text", showAll = false) =
  let client = newHttpClient()
  defer: client.close()
  
  if format.toLower() == "text":
    echo "\n🔗 ", t("analyzing_links")
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
        echo "  → ", outgoing, " ", t("outgoing_links"), ":"
        if page in graph:
          for link in graph[page]:
            if link in allPages:
              echo "    • ", link
              totalLinks.inc
            else:
              echo "    • ", link, " ", t("not_found")
        if incoming > 0:
          echo "  ← ", incoming, " ", t("incoming_links")
    
    if isolatedPages.len > 0:
      echo "\n🔷 ", t("isolated_pages"), ":"
      for page in isolatedPages:
        echo "  • ", page
    
    echo "\n─".repeat(SeparatorLength)
    echo t("pages"), ": ", allPages.len
    echo t("connections"), ": ", totalLinks
    echo t("isolated"), ": ", isolatedPages.len

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
      echo t("error_url_required")
      echo t("usage_config")
      return
    let url = args[1]
    let token = if args.len >= 3: args[2] else: ""
    configureServer(url, token)
    return
  
  if command in ["lang", "language"]:
    if args.len < 2:
      echo "Error: Language required (de or en)"
      return
    setLanguage(args[1])
    return
  
  if config.serverUrl == "":
    styledEcho(fgRed, "✗ ", resetStyle, t("error_no_url"))
    echo t("error_use")
    echo ""
    echo t("error_example")
    echo "  sb config http://localhost:3000"
    echo "  sb config https://your-server.com"
    quit(1)
  
  case command
  of "list", "ls":
    listPages(showAll)
  
  of "get", "show", "cat":
    if args.len < 2:
      echo t("error_pagename_required")
      return
    getPage(args[1])
  
  of "create", "new":
    if args.len < 2:
      echo t("error_pagename_required")
      echo t("usage_create")
      return
    let pageName = args[1]
    let content = if args.len >= 3:
      args[2..^1].join(" ")
    else:
      readFromStdin()
    
    if content.len == 0:
      echo t("error_no_content")
      return
    
    createOrEditPage(pageName, content)
  
  of "edit", "update":
    if args.len < 2:
      echo t("error_pagename_required")
      return
    let pageName = args[1]
    let content = if args.len >= 3:
      args[2..^1].join(" ")
    else:
      readFromStdin()
    
    if content.len == 0:
      echo t("error_no_content")
      return
    
    createOrEditPage(pageName, content, isEdit = true)
  
  of "append", "add":
    if args.len < 2:
      echo t("error_pagename_required")
      return
    let pageName = args[1]
    let content = if args.len >= 3:
      args[2..^1].join(" ")
    else:
      readFromStdin()
    
    if content.len == 0:
      echo t("error_no_content")
      return
    
    appendToPage(pageName, content)
  
  of "delete", "rm", "del":
    if args.len < 2:
      echo t("error_pagename_required")
      return
    deletePage(args[1], force)
  
  of "search", "find":
    if args.len < 2:
      echo t("error_query_required")
      return
    searchPages(args[1])
  
  of "recent":
    showRecent(DefaultRecentLimit, showAll)
  
  of "backup":
    let backupDir = if args.len >= 2: args[1] else: ""
    backupPages(backupDir, fullBackup, verbose)
  
  of "restore":
    if args.len < 2:
      echo t("error_backup_dir_required")
      echo t("usage_restore")
      return
    restorePages(args[1], targetPrefix, verbose)
  
  of "download", "dl":
    if args.len < 2:
      echo t("error_pagename_required")
      echo t("usage_download")
      return
    let outputFile = if args.len >= 3: args[2] else: ""
    downloadPage(args[1], outputFile)
  
  of "upload", "ul":
    if args.len < 3:
      echo t("error_file_and_page_required")
      echo t("usage_upload")
      return
    uploadPage(args[1], args[2])
  
  of "graph":
    let format = if args.len >= 2: args[1] else: "text"
    showGraph(format, showAll)
  
  else:
    echo t("error_unknown_command"), ": ", command
    echo t("error_use_help")

when isMainModule:
  main()
