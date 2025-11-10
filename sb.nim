import std/[httpclient, json, os, strutils, terminal, times, uri, algorithm]

const
  Version = "1.0.0"
  AppName = "SilverBullet CLI"

type
  Config = object
    serverUrl: string
    authToken: string

var config: Config
var configFile = getConfigDir() / "silverbullet-cli" / "config.json"

proc loadConfig() =
  if fileExists(configFile):
    try:
      let data = parseFile(configFile)
      config.serverUrl = data{"serverUrl"}.getStr("")
      config.authToken = data{"authToken"}.getStr("")
    except:
      discard

proc saveConfig() =
  createDir(parentDir(configFile))
  let data = %* {
    "serverUrl": config.serverUrl,
    "authToken": config.authToken
  }
  writeFile(configFile, data.pretty())

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
    
    # Check status code
    if response.code != Http200 and response.code != Http201 and response.code != Http204:
      styledEcho(fgRed, "✗ HTTP Error: ", resetStyle, $response.code, " ", response.status)
      echo "Response body: ", response.body[0..min(response.body.len-1, 500)]
      quit(1)
    
    return response.body
  except HttpRequestError as e:
    styledEcho(fgRed, "✗ HTTP Error: ", resetStyle, e.msg)
    quit(1)
  except Exception as e:
    styledEcho(fgRed, "✗ Error: ", resetStyle, e.msg)
    quit(1)

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
  version                 Zeigt Version an
  help                    Zeigt diese Hilfe an

GLOBALE OPTIONEN:
  --configfile=<pfad>     Verwendet alternative Konfigurationsdatei

BEISPIELE:
  sb config http://localhost:3000
  sb list
  sb get index
  sb create "Neue Notiz" "# Bla
bla bla..."
  sb append index "- Neuer Eintrag"
  sb search "TODO"
  
  # Mit alternativer Config
  sb --configfile=/path/to/config.json list

KONFIGURATION:
  Die Konfiguration wird standardmäßig gespeichert in:
  $3
""" % [AppName, Version, configFile]

proc configureServer(url: string, token = "") =
  var serverUrl = url.strip(chars = {'/'})
  
  # Add http:// if no scheme is provided
  if not serverUrl.startsWith("http://") and not serverUrl.startsWith("https://"):
    serverUrl = "http://" & serverUrl
  
  config.serverUrl = serverUrl
  config.authToken = token
  saveConfig()
  styledEcho(fgGreen, "✓ ", resetStyle, "Konfiguration gespeichert")
  echo "Server: ", config.serverUrl
  if token != "":
    echo "Token: ********"

proc listPages() =
  let client = newHttpClient()
  defer: client.close()
  
  # SilverBullet uses /.fs endpoint to list files
  let response = makeRequest(client, HttpGet, "/.fs")
  
  try:
    let data = parseJson(response)
    
    echo "\n📄 Seiten in SilverBullet\n"
    echo "─".repeat(60)
    
    var pages: seq[tuple[name: string, lastModified: int]] = @[]
    
    # The response is an array of file objects
    for item in data:
      if item.kind == JObject:
        let name = item["name"].getStr()
        if name.endsWith(".md"):
          let pageName = name[0..^4]  # Remove .md extension
          let modified = item{"lastModified"}.getInt(0)
          pages.add((name: pageName, lastModified: modified))
    
    # Sort by last modified (newest first)
    pages.sort(proc(a, b: tuple[name: string, lastModified: int]): int = 
      cmp(b.lastModified, a.lastModified))
    
    for i, page in pages:
      if page.lastModified > 0:
        let modTime = fromUnix(page.lastModified div 1000)
        let timeStr = modTime.format("dd.MM.yyyy HH:mm")
        stdout.styledWrite(fgCyan, $(i+1), ". ", resetStyle)
        stdout.styledWrite(fgWhite, page.name, " ")
        stdout.styledWriteLine(fgYellow, "(", timeStr, ")")
      else:
        stdout.styledWrite(fgCyan, $(i+1), ". ", resetStyle)
        stdout.styledWriteLine(fgWhite, page.name)
    
    echo "─".repeat(60)
    echo "Gesamt: ", pages.len, " Seiten"
  except JsonParsingError as e:
    styledEcho(fgRed, "✗ JSON Parse Error: ", resetStyle, e.msg)
    echo "Server response (first 500 chars):"
    echo response[0..min(response.len-1, 500)]
    quit(1)

proc getPage(pageName: string) =
  let client = newHttpClient()
  defer: client.close()
  
  let encodedName = encodeUrl(pageName)
  let content = makeRequest(client, HttpGet, "/.fs/" & encodedName & ".md")
  echo content

proc createOrEditPage(pageName: string, content: string, isEdit = false) =
  let client = newHttpClient()
  defer: client.close()
  
  let encodedName = encodeUrl(pageName)
  discard makeRequest(client, HttpPut, "/.fs/" & encodedName & ".md", content)
  
  let action = if isEdit: "aktualisiert" else: "erstellt"
  styledEcho(fgGreen, "✓ ", resetStyle, "Seite '", pageName, "' ", action)

proc appendToPage(pageName: string, content: string) =
  let client = newHttpClient()
  defer: client.close()
  
  let encodedName = encodeUrl(pageName)
  # Get current content
  let currentContent = makeRequest(client, HttpGet, "/.fs/" & encodedName & ".md")
  
  # Append new content
  let newContent = currentContent & "\n" & content
  
  discard makeRequest(client, HttpPut, "/.fs/" & encodedName & ".md", newContent)
  styledEcho(fgGreen, "✓ ", resetStyle, "Text zu '", pageName, "' hinzugefügt")

proc deletePage(pageName: string) =
  let client = newHttpClient()
  defer: client.close()
  
  let encodedName = encodeUrl(pageName)
  discard makeRequest(client, HttpDelete, "/.fs/" & encodedName & ".md")
  styledEcho(fgRed, "✗ ", resetStyle, "Seite '", pageName, "' gelöscht")

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
        
        # Check if query matches page name first
        if query.toLowerAscii() in pageName.toLowerAscii():
          found.inc
          styledEcho(fgCyan, "• ", resetStyle, pageName, " ", fgYellow, "(im Titel)")
          continue
        
        # Get page content and search in it
        try:
          # URL encode the filename properly
          let encodedName = name.replace(" ", "%20")
          let content = makeRequest(client, HttpGet, "/.fs/" & encodedName)
          
          if query.toLowerAscii() in content.toLowerAscii():
            found.inc
            styledEcho(fgCyan, "• ", resetStyle, pageName)
            
            # Show matching lines
            for line in content.splitLines():
              if query.toLowerAscii() in line.toLowerAscii():
                let trimmed = line.strip()
                if trimmed.len > 0:
                  echo "  ", trimmed[0..min(trimmed.len-1, 80)]
                break
        except CatchableError:
          # Skip files that can't be read
          discard
  
  echo "─".repeat(60)
  echo "Gefunden: ", found, " Seiten"

proc showRecent(limit = 10) =
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
        let modified = item{"lastModified"}.getInt(0)
        pages.add((name: pageName, lastModified: modified))
  
  pages.sort(proc(a, b: tuple[name: string, lastModified: int]): int = 
    cmp(b.lastModified, a.lastModified))
  
  for i in 0..<min(limit, pages.len):
    if pages[i].lastModified > 0:
      let modTime = fromUnix(pages[i].lastModified div 1000)
      let timeStr = modTime.format("yyyy-MM-dd HH:mm:ss")
      stdout.styledWrite(fgCyan, $(i+1), ". ", resetStyle)
      stdout.styledWrite(fgWhite, pages[i].name, " ")
      stdout.styledWriteLine(fgYellow, "(", timeStr, ")")
    else:
      stdout.styledWrite(fgCyan, $(i+1), ". ", resetStyle)
      stdout.styledWriteLine(fgWhite, pages[i].name)
  
  echo "─".repeat(60)

proc main() =
  # Get all command line arguments manually
  var args: seq[string] = @[]
  for i in 1..paramCount():
    args.add(paramStr(i))
  
  # Check for --configfile parameter
  var i = 0
  while i < args.len:
    if args[i].startsWith("--configfile="):
      configFile = args[i][9..^1]
      args.delete(i)
    elif args[i] == "--configfile" and i + 1 < args.len:
      configFile = args[i + 1]
      args.delete(i)
      args.delete(i)
    else:
      i.inc
  
  loadConfig()
  
  if args.len == 0:
    showHelp()
    return
  
  let command = args[0].toLowerAscii()
  
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
  
  # For all other commands, check if server is configured
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
    listPages()
  
  of "get", "show", "cat":
    if args.len < 2:
      echo "Fehler: Seitenname erforderlich"
      return
    getPage(args[1])
  
  of "create", "new":
    if args.len < 3:
      echo "Fehler: Seitenname und Inhalt erforderlich"
      echo "Verwendung: sb create <page> <text>"
      return
    let pageName = args[1]
    let content = args[2..^1].join(" ")
    createOrEditPage(pageName, content)
  
  of "edit", "update":
    if args.len < 3:
      echo "Fehler: Seitenname und Inhalt erforderlich"
      return
    let pageName = args[1]
    let content = args[2..^1].join(" ")
    createOrEditPage(pageName, content, isEdit = true)
  
  of "append", "add":
    if args.len < 3:
      echo "Fehler: Seitenname und Inhalt erforderlich"
      return
    let pageName = args[1]
    let content = args[2..^1].join(" ")
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
    showRecent()
  
  else:
    echo "Unbekannter Befehl: ", command
    echo "Verwende 'sb help' für Hilfe"

when isMainModule:
  main()