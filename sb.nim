
import std/[httpclient, json, os, strutils, terminal, times, uri, algorithm, re, sets, tables, parseopt]
import std/[threadpool, locks, cpuinfo, editdistance]
import i18n

const
  Version = "0.5.0"
  AppName = "SilverBullet CLI"
  SystemPrefixes = ["Library/", "SETTINGS", "PLUGS", "_"]
  DefaultRecentLimit = 10
  MaxSnippetLength = 80
  SeparatorLength = 60
  HttpTimeoutMs = 30000
  PageContentSeparator = "\n"
  
  MaxRetries = 3
  RetryDelayMs = 500 # Start-Verzögerung (wird erhöht bei Retries)

  ValidCommands = ["config", "lang", "list", "ls", "get", "show", "cat", "create", "new", 
                   "edit", "update", "append", "add", "delete", "rm", "del", "search", "find", 
                   "recent", "backup", "restore", "download", "dl", "upload", "ul", "graph", 
                   "help", "version"]

type
  Config = object
    serverUrl: string
    authToken: string
    language: Language

  CliOptions = object
    showAll: bool
    fullBackup: bool
    verbose: bool
    force: bool
    targetPrefix: string
    configFile: string
    command: string
    args: seq[string]

# Globale Variablen
var config: Config
var configFile = getConfigDir() / "silverbullet-cli" / "config.json"

# Threading & Shutdown Globals
var consoleLock: Lock
var progressLock: Lock
var processedCount: int
var globalTotal: int
# Volatile sorgt dafür, dass alle Threads die Änderung sofort sehen
var shuttingDown {.volatile.}: bool = false 

proc t(key: string, args: varargs[string]): string =
  i18n.t(key, $config.language, args)

# --- STRG+C HANDLER ---
proc ctrlCHandler() {.noconv.} =
  # Setze das globale Flag
  shuttingDown = true
  # Direkter Echo ohne Lock, da wir im Signal Handler sind
  echo ""
  echo "🛑 " & (if config.language == langDE: "Abbruch..." else: "Aborting...")

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
      if langStr == "de":
        config.language = langDE
      else:
        config.language = langEN
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

# --- CONFIG FUNCTIONS ---

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
  let barColor = if percent == 100: fgGreen else: fgCyan
  stdout.write("\r" & label & ": [")
  stdout.styledWrite(barColor, "=".repeat(filled))
  stdout.write(" ".repeat(barWidth - filled))
  stdout.write("] " & $percent & "% (" & $current & "/" & $total & ")")
  stdout.flushFile()
  if current == total:
    echo ""

# --- CLIENT ---

proc createClient(): HttpClient =
  result = newHttpClient(timeout = HttpTimeoutMs)
  result.headers = newHttpHeaders({
    "X-Sync-Mode": "true",
    "Accept": "application/json"
  })
  if config.authToken != "":
    result.headers["Authorization"] = "Bearer " & config.authToken

# Retry Logik für allgemeine Requests
proc makeRequest(client: HttpClient, httpMethod: HttpMethod, endpoint: string, body = ""): string =
  let url = config.serverUrl & endpoint
  var attempts = 0
  
  while true:
    try:
      var response: Response
      case httpMethod
      of HttpGet:
        response = client.get(url)
      of HttpPut:
        client.headers["Content-Type"] = "text/markdown"
        response = client.request(url, httpMethod = HttpPut, body = body)
        client.headers.del("Content-Type") 
      of HttpDelete:
        response = client.request(url, httpMethod = HttpDelete)
      else:
        raise newException(ValueError, "Unsupported HTTP method")
      
      # 404 ist kein Retry-Grund, sondern ein valides Ergebnis (z.B. bei Edit Check)
      if response.code == Http404: return "" 

      if response.code != Http200 and response.code != Http201 and response.code != Http204:
        # Server Fehler (5xx) könnten man retrien, hier brechen wir aber ab für Klarheit
        styledEcho(fgRed, "✗ HTTP Error: ", resetStyle, $response.code, " ", response.status)
        if response.body.len > 0:
          echo "Response body: ", response.body[0..min(response.body.len-1, 500)]
        quit(1)
      
      return response.body

    except HttpRequestError, OSError:
      # Hier greift der Retry bei Netzwerkfehlern (Timeout, Connection refused)
      attempts.inc
      if attempts > MaxRetries:
        # Finaler Fehler
        raise
      
      # Exponential Backoff: 500ms, 1000ms, 1500ms...
      let waitTime = RetryDelayMs * attempts
      styledEcho(fgYellow, "⚠ Network error, retrying in ", $waitTime, "ms...", resetStyle)
      sleep(waitTime)
    except Exception as e:
      # Andere Fehler sofort werfen
      styledEcho(fgRed, "✗ Error: ", resetStyle, e.msg)
      quit(1)

# --- WORKER PROCS (With Retry & Shutdown Check) ---

proc distributeWork[T](data: seq[T], chunks: int): seq[seq[T]] =
  result = newSeq[seq[T]](chunks)
  for i, item in data:
    result[i mod chunks].add(item)

proc backupChunk(files: seq[string], backupPath: string, conf: Config, verbose: bool) {.thread.} =
  let client = newHttpClient(timeout = HttpTimeoutMs)
  client.headers = newHttpHeaders({"X-Sync-Mode": "true", "Accept": "application/json"})
  if conf.authToken != "":
    client.headers["Authorization"] = "Bearer " & conf.authToken
  defer: client.close()

  for name in files:
    # Graceful Shutdown Check
    if shuttingDown: return

    let pageName = name[0..^4]
    var attempts = 0
    
    while true:
      try:
        let url = conf.serverUrl & "/.fs/" & encodeUrl(pageName) & ".md"
        let content = client.getContent(url) 
        
        let filePath = backupPath / name
        let dir = parentDir(filePath)
        if dir != "" and not dirExists(dir):
          createDir(dir)
        
        writeFile(filePath, content)
        
        withLock progressLock:
          processedCount.inc
          if not verbose and not shuttingDown:
            showProgress(processedCount, globalTotal, "Backup")
        
        if verbose:
          withLock consoleLock:
            echo "✓ ", name
        
        # Erfolg -> Raus aus der while Schleife
        break 

      except CatchableError as e:
        attempts.inc
        if attempts > MaxRetries or shuttingDown:
          # Nach 3 Versuchen oder bei Shutdown aufgeben
          withLock consoleLock:
            if not verbose: echo "" 
            styledEcho(fgRed, "✗ ", resetStyle, name, " (", e.msg, ")")
          break
        else:
          # Warten und erneut versuchen
          sleep(RetryDelayMs * attempts)
          if verbose:
             withLock consoleLock:
               echo t("retrying", $attempts, $MaxRetries, name)

proc restoreChunk(files: seq[string], sourceDir: string, targetPrefix: string, conf: Config, verbose: bool) {.thread.} =
  let client = newHttpClient(timeout = HttpTimeoutMs)
  client.headers = newHttpHeaders({"X-Sync-Mode": "true"})
  if conf.authToken != "":
    client.headers["Authorization"] = "Bearer " & conf.authToken
  defer: client.close()

  for file in files:
    # Graceful Shutdown Check
    if shuttingDown: return

    var attempts = 0
    while true:
      try:
        let content = readFile(file)
        let relPath = file.replace(sourceDir, "").strip(chars = {'/', '\\'})
        var pageName = relPath[0..^4].replace("\\", "/")
        
        if targetPrefix != "":
          pageName = targetPrefix & "/" & pageName
        
        let url = conf.serverUrl & "/.fs/" & encodeUrl(pageName) & ".md"
        
        client.headers["Content-Type"] = "text/markdown"
        discard client.putContent(url, content)
        
        withLock progressLock:
          processedCount.inc
          if not verbose and not shuttingDown:
            showProgress(processedCount, globalTotal, "Restore")
        
        if verbose:
          withLock consoleLock:
            echo "✓ ", pageName
        
        break # Erfolg

      except CatchableError as e:
        attempts.inc
        let relPath = file.replace(sourceDir, "").strip(chars = {'/', '\\'})
        if attempts > MaxRetries or shuttingDown:
          withLock consoleLock:
            if not verbose: echo ""
            styledEcho(fgRed, "✗ ", resetStyle, relPath, " (", e.msg, ")")
          break
        else:
          sleep(RetryDelayMs * attempts)
          if verbose:
             withLock consoleLock:
               echo t("retrying", $attempts, $MaxRetries, relPath)

# --- STANDARD COMMANDS ---

proc listPages(client: HttpClient, showAll = false) =
  let response = makeRequest(client, HttpGet, "/.fs")
  try:
    let data = parseJson(response)
    echo "\n📄 ", t("pages_in_sb"), "\n", "─".repeat(SeparatorLength)
    var pages: seq[tuple[name: string, lastModified: int]] = @[]
    for item in data:
      if item.kind == JObject:
        let name = item["name"].getStr()
        if name.endsWith(".md"):
          let pageName = name[0..^4]
          if shouldIncludePage(pageName, showAll):
            pages.add((name: pageName, lastModified: item{"lastModified"}.getInt(0)))
    pages.sort(proc(a, b: tuple[name: string, lastModified: int]): int =
      cmp(b.lastModified, a.lastModified))
    let numWidth = max(2, ($pages.len).len)
    for i, page in pages:
      let numStr = formatWithLeadingZeros(i+1, numWidth)
      if page.lastModified > 0:
        let timeStr = fromUnix(page.lastModified div 1000).format("dd.MM.yyyy HH:mm")
        stdout.styledWrite(fgCyan, numStr, ". ", resetStyle)
        stdout.styledWrite(fgWhite, page.name, " ")
        stdout.styledWriteLine(fgYellow, "(", timeStr, ")")
      else:
        stdout.styledWrite(fgCyan, numStr, ". ", resetStyle)
        stdout.styledWriteLine(fgWhite, page.name)
    echo "─".repeat(SeparatorLength)
    let label = if showAll: t("all") else: t("without_system")
    echo t("total"), ": ", pages.len, " ", t("pages"), " (", label, ")"
  except JsonParsingError as e:
    styledEcho(fgRed, "✗ JSON Parse Error: ", resetStyle, e.msg)
    quit(1)

proc getPage(client: HttpClient, pageName: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  echo makeRequest(client, HttpGet, getPageEndpoint(pageName))

proc appendToPage(client: HttpClient, pageName: string, content: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
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

proc deletePage(client: HttpClient, pageName: string, force = false) =
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
  discard makeRequest(client, HttpDelete, getPageEndpoint(pageName))
  styledEcho(fgRed, "✗ ", resetStyle, t("page_deleted", pageName))

proc searchPages(client: HttpClient, query: string) =
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
        
        # Fuzzy Suche
        let dist = editDistance(query.toLower(), pageName.toLower())
        let threshold = if query.len < 4: 1 else: 3
        if dist <= threshold:
           found.inc
           styledEcho(fgCyan, "• ", resetStyle, pageName, " ", fgMagenta, "(fuzzy match)")
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

proc showRecent(client: HttpClient, limit = DefaultRecentLimit, showAll = false) =
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  echo "\n🕐 ", t("recent_pages"), "\n", "─".repeat(SeparatorLength)
  var pages: seq[tuple[name: string, lastModified: int]] = @[]
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        if shouldIncludePage(pageName, showAll):
          pages.add((name: pageName, lastModified: item{"lastModified"}.getInt(0)))
  pages.sort(proc(a, b: tuple[name: string, lastModified: int]): int =
    cmp(b.lastModified, a.lastModified))
  let numWidth = max(2, ($min(limit, pages.len)).len)
  for i in 0..<min(limit, pages.len):
    let numStr = formatWithLeadingZeros(i+1, numWidth)
    if pages[i].lastModified > 0:
      let timeStr = fromUnix(pages[i].lastModified div 1000).format("dd.MM.yyyy HH:mm:ss")
      stdout.styledWrite(fgCyan, numStr, ". ", resetStyle)
      stdout.styledWrite(fgWhite, pages[i].name, " ")
      stdout.styledWriteLine(fgYellow, "(", timeStr, ")")
    else:
      stdout.styledWrite(fgCyan, numStr, ". ", resetStyle)
      stdout.styledWriteLine(fgWhite, pages[i].name)
  echo "─".repeat(SeparatorLength)
  let label = if showAll: t("all") else: t("without_system")
  echo t("showing"), " ", min(limit, pages.len), " ", t("of"), " ", pages.len, " ", t("pages"), " (", label, ")"

proc backupPages(client: HttpClient, targetDir = "", fullBackup = false, verbose = false) =
  let timestamp = now().format("ddMMyyyy-HHmmss")
  let backupPath = if targetDir != "": targetDir else: getCurrentDir() / "backup-" & timestamp
  echo "\n💾 ", t("creating_backup")
  echo t("target_dir"), ": ", backupPath
  createDir(backupPath)
  let response = makeRequest(client, HttpGet, "/.fs")
  let data = parseJson(response)
  var filesToBackup: seq[string] = @[]
  for item in data:
    if item.kind == JObject:
      let name = item["name"].getStr()
      if name.endsWith(".md"):
        let pageName = name[0..^4]
        if fullBackup or not isSystemPage(pageName):
          filesToBackup.add(name)
  globalTotal = filesToBackup.len
  processedCount = 0
  echo "─".repeat(SeparatorLength)
  echo t("total"), ": ", globalTotal, " ", t("files")
  if globalTotal == 0:
    echo "Nichts zu tun."
    return
  let numThreads = countProcessors()
  let chunks = distributeWork(filesToBackup, numThreads)
  for chunk in chunks:
    if chunk.len > 0:
      spawn backupChunk(chunk, backupPath, config, verbose)
  sync()
  echo ""
  echo "─".repeat(SeparatorLength)
  if shuttingDown:
    styledEcho(fgYellow, "⚠ ", t("operation_aborted"), resetStyle)
  else:
    styledEcho(fgGreen, "✓ ", resetStyle, t("backup_success", backupPath))

proc restorePages(client: HttpClient, sourceDir: string, targetPrefix = "", verbose = false) =
  if not dirExists(sourceDir):
    styledEcho(fgRed, "✗ ", resetStyle, t("backup_dir_not_found"), ": ", sourceDir)
    quit(1)
  echo "\n📦 ", t("restoring_backup")
  var filesToRestore: seq[string] = @[]
  for file in walkDirRec(sourceDir):
    if file.endsWith(".md"):
      filesToRestore.add(file)
  globalTotal = filesToRestore.len
  processedCount = 0
  echo "─".repeat(SeparatorLength)
  echo t("total"), ": ", globalTotal, " ", t("files")
  if globalTotal == 0:
    return
  let numThreads = countProcessors()
  let chunks = distributeWork(filesToRestore, numThreads)
  for chunk in chunks:
    if chunk.len > 0:
      spawn restoreChunk(chunk, sourceDir, targetPrefix, config, verbose)
  sync()
  echo ""
  echo "─".repeat(SeparatorLength)
  if shuttingDown:
    styledEcho(fgYellow, "⚠ ", t("operation_aborted"), resetStyle)
  else:
    styledEcho(fgGreen, "✓ ", resetStyle, t("restore_success"))

proc downloadPage(client: HttpClient, pageName: string, outputFile = "") =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  echo "\n📥 ", t("downloading_page")
  try:
    let content = makeRequest(client, HttpGet, getPageEndpoint(pageName))
    
    if content.len == 0:
       styledEcho(fgYellow, "⚠ ", resetStyle, "Page content is empty or not found.")
   
    let filename = if outputFile != "": outputFile else: pageName.replace('/', DirSep) & ".md"
    
    let dir = parentDir(filename)
    if dir != "" and not dirExists(dir):
      createDir(dir)
    
    writeFile(filename, content)
    
    styledEcho(fgGreen, "✓ ", resetStyle, t("downloaded"), ": ", pageName)
    echo t("saved_as"), ": ", filename
    echo t("size"), ": ", content.len, " ", t("bytes")
  except CatchableError as e:
    styledEcho(fgRed, "✗ ", resetStyle, t("download_error"), ": ", e.msg)
    quit(1)

proc uploadPage(client: HttpClient, sourceFile: string, pageName: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  echo "\n📤 ", t("uploading_file")
  if not fileExists(sourceFile):
    styledEcho(fgRed, "✗ ", resetStyle, t("file_not_found"), ": ", sourceFile)
    quit(1)
  try:
    let content = readFile(sourceFile)
    
    let cleanPageName = pageName.replace('\\', '/')
    
    discard makeRequest(client, HttpPut, getPageEndpoint(cleanPageName), content)
    
    styledEcho(fgGreen, "✓ ", resetStyle, t("uploaded"), ": ", sourceFile)
    echo t("as_page"), ": ", cleanPageName
    echo t("size"), ": ", content.len, " ", t("bytes")
  except CatchableError as e:
    styledEcho(fgRed, "✗ ", resetStyle, t("upload_error"), ": ", e.msg)
    quit(1)

proc extractLinks(content: string): seq[string] =
  var links: seq[string] = @[]
  let pattern = re"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"
  for match in content.findAll(pattern):
    let inner = match[2..^3]
    let linkName = if "|" in inner: inner.split("|")[0].strip() else: inner.strip()
    if linkName != "":
      links.add(linkName)
  return links

proc showGraph(client: HttpClient, format = "text", showAll = false) =
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
    echo "digraph Notes { rankdir=LR; node [shape=box, style=rounded];"
    for page, links in graph:
      let safeFrom = page.replace("\"", "\\\"")
      for link in links:
        if link in allPages:
          echo "  \"", safeFrom, "\" -> \"", link.replace("\"", "\\\""), "\";"
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

# --- INTERACTIVE EDITOR LOGIC ---

proc checkPageExists(client: HttpClient, pageName: string): bool =
  try:
    let url = config.serverUrl & getPageEndpoint(pageName)
    let resp = client.get(url)
    return resp.code == Http200
  except CatchableError:
    return false

proc createPage(client: HttpClient, pageName: string, content: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  if checkPageExists(client, pageName):
    styledEcho(fgRed, "✗ ", t("page_exists_error", pageName), resetStyle)
    echo t("use_edit_hint")
    return
  discard makeRequest(client, HttpPut, getPageEndpoint(pageName), content)
  styledEcho(fgGreen, "✓ ", resetStyle, t("page_created", pageName))

proc editPage(client: HttpClient, pageName: string, content: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  if not checkPageExists(client, pageName):
    styledEcho(fgRed, "✗ ", t("page_does_not_exist_error", pageName), resetStyle)
    echo t("use_create_hint")
    return
  discard makeRequest(client, HttpPut, getPageEndpoint(pageName), content)
  styledEcho(fgGreen, "✓ ", resetStyle, t("page_updated", pageName))

proc openEditor(client: HttpClient, pageName: string) =
  if not validatePageName(pageName):
    styledEcho(fgRed, "✗ ", resetStyle, t("invalid_pagename"))
    quit(1)
  echo "📥 ", t("fetching_page", pageName)
  var currentContent = ""
  try:
    let url = config.serverUrl & getPageEndpoint(pageName)
    let resp = client.get(url)
    if resp.code == Http404:
      styledEcho(fgYellow, "ℹ ", t("new_draft_msg"), resetStyle)
    elif resp.code == Http200:
      currentContent = resp.body
    else:
      styledEcho(fgRed, "✗ ", t("fetch_error_code", $resp.code), resetStyle)
      quit(1)
  except CatchableError as e:
    if "404" in e.msg:
       styledEcho(fgYellow, "ℹ ", t("new_draft_msg"), resetStyle)
    else:
       styledEcho(fgRed, "✗ Error: ", e.msg)
       quit(1)

  let tempDir = getTempDir()
  let tempFile = tempDir / ("sb_edit_" & pageName.replace("/", "_") & ".md")
  writeFile(tempFile, currentContent)
  
  var editor = getEnv("EDITOR")
  if editor == "":
    when defined(windows): editor = "notepad"
    else: editor = "nano"
  
  echo "📝 ", t("opening_editor", editor)
  let exitCode = execShellCmd(editor & " " & quoteShell(tempFile))
  
  if exitCode != 0:
    styledEcho(fgRed, "✗ ", t("editor_error", $exitCode), resetStyle)
    return

  let newContent = readFile(tempFile)
  removeFile(tempFile)

  if newContent == currentContent:
    echo "🤔 ", t("no_changes")
    return

  echo "📤 ", t("uploading_changes")
  discard makeRequest(client, HttpPut, getPageEndpoint(pageName), newContent)
  styledEcho(fgGreen, "✓ ", resetStyle, t("page_updated", pageName))

# --- MAIN ---

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
  create <page> <text>    Erstellt eine neue Seite (Fehler, falls existent)
  edit <page> [text]      Bearbeitet eine Seite (Fehler, falls nicht existent)
                          Ohne [text] öffnet sich der Editor (nano/notepad)
  append <page> <text>    Fügt Text an eine Seite an
  delete <page>           Löscht eine Seite (mit Bestätigung)
  search <query>          Durchsucht alle Seiten (Titel & Inhalt)
  recent                  Zeigt kürzlich geänderte Seiten
  backup [verzeichnis]    Erstellt ein Backup aller Seiten (parallelisiert)
  restore <verzeichnis>   Stellt Seiten aus Backup wieder her (parallelisiert)
  download <page> [datei] Lädt eine Seite in eine lokale Datei
  upload <datei> <page>   Lädt eine lokale Datei als Seite hoch
  graph [format]          Zeigt Verlinkungen zwischen Seiten (text, dot)
  version                 Zeigt Version an
  help                    Zeigt diese Hilfe an

GLOBALE OPTIONEN:
  --configfile=<pfad>     Verwendet alternative Konfigurationsdatei
  --all, -a               Zeigt auch System-Seiten
  --full                  Bei backup/restore: inkl. System-Seiten
  --verbose, -v           Zeigt detaillierte Ausgaben
  --force, -f             Überspringt Bestätigungen
  --to=<pfad>             Bei restore: Ziel-Präfix

BEISPIELE:
  sb config http://localhost:3000
  sb edit "Journal/Today"
  sb search "Meeting"
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
  create <page> <text>    Create a new page (Fails if exists)
  edit <page> [text]      Edit an existing page (Fails if missing)
                          Without [text], opens your editor (nano/notepad)
  append <page> <text>    Append text to a page
  delete <page>           Delete a page (with confirmation)
  search <query>          Search all pages (title & content)
  recent                  Show recently changed pages
  backup [directory]      Create a backup of all pages (threaded)
  restore <directory>     Restore pages from backup (threaded)
  download <page> [file]  Download a page to a local file
  upload <file> <page>    Upload a local file as a page
  graph [format]          Show links between pages (text, dot)
  version                 Show version
  help                    Show this help

GLOBAL OPTIONS:
  --configfile=<path>     Use alternative config file
  --all, -a               Show system pages too
  --full                  For backup/restore: incl. system pages
  --verbose, -v           Show detailed output
  --force, -f             Skip confirmations
  --to=<path>             For restore: target prefix

EXAMPLES:
  sb config http://localhost:3000
  sb edit "Journal/Today"
  sb search "Meeting"
  sb backup --verbose

CONFIGURATION:
  Configuration is saved in: $3
"""

  let helpText = if config.language == langDE: helpTextDE else: helpTextEN
  echo helpText % [AppName, Version, configFile]

proc main() =
  initLock(consoleLock)
  initLock(progressLock)
  setControlCHook(ctrlCHandler)
  
  var opts = CliOptions(configFile: getConfigDir() / "silverbullet-cli" / "config.json", verbose: false, force: false, showAll: false, fullBackup: false, targetPrefix: "", command: "", args: @[])
  var p = initOptParser(shortNoVal = {'a', 'f', 'v'}, longNoVal = @["all", "force", "verbose", "full"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if opts.command == "": opts.command = key.toLower() else: opts.args.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "configfile": opts.configFile = val
      of "all", "a":   opts.showAll = true
      of "full":       opts.fullBackup = true
      of "verbose", "v": opts.verbose = true
      of "force", "f": opts.force = true
      of "to":         opts.targetPrefix = val
      of "help", "h":  showHelp(); return
      of "version", "ver": echo AppName, " v", Version; return
      else: echo t("unknown_option", key)
    of cmdEnd: assert(false)

  configFile = opts.configFile; loadConfig()
  
  if opts.command == "":
    echo AppName, " v", Version
    echo "Use 'sb help' for commands."
    return

  # Fall 2: Befehl ist explizit 'help' -> Zeige die volle Hilfe
  if opts.command in ["help", "h"]:
    showHelp()
    return

  if opts.command in ["version", "ver"]: echo AppName, " v", Version; return
  
  if opts.command == "config":
    if opts.args.len < 1: echo t("error_url_required"); return
    configureServer(opts.args[0], if opts.args.len >= 2: opts.args[1] else: ""); return
  if opts.command in ["lang", "language"]:
    if opts.args.len < 1: echo "Error: Language required"; return
    setLanguage(opts.args[0]); return

  if config.serverUrl == "":
      styledEcho(fgRed, "✗ ", resetStyle, t("error_no_url")); quit(1)
  let client = createClient(); defer: client.close()

  case opts.command
  of "list", "ls":
    listPages(client, opts.showAll)
  of "get", "show", "cat":
    if opts.args.len < 1: echo t("error_pagename_required"); return
    getPage(client, opts.args[0])
  
  of "create", "new":
    if opts.args.len < 1: echo t("error_pagename_required"); return
    let content = if opts.args.len >= 2: opts.args[1..^1].join(" ") else: readFromStdin()
    if content.len == 0: echo t("error_no_content"); return
    createPage(client, opts.args[0], content)

  of "edit", "update":
    if opts.args.len < 1: echo t("error_pagename_required"); return
    
    if opts.args.len >= 2:
      let content = opts.args[1..^1].join(" ")
      editPage(client, opts.args[0], content)
    elif not isatty(stdin):
      let content = readFromStdin()
      if content.len > 0:
        editPage(client, opts.args[0], content)
      else:
        openEditor(client, opts.args[0])
    else:
      openEditor(client, opts.args[0])

  of "append", "add":
    if opts.args.len < 1: echo t("error_pagename_required"); return
    let content = if opts.args.len >= 2: opts.args[1..^1].join(" ") else: readFromStdin()
    if content.len == 0: echo t("error_no_content"); return
    appendToPage(client, opts.args[0], content)
  of "delete", "rm", "del":
    if opts.args.len < 1: echo t("error_pagename_required"); return
    deletePage(client, opts.args[0], opts.force)
  of "search", "find":
    if opts.args.len < 1: echo t("error_query_required"); return
    searchPages(client, opts.args[0])
  of "recent":
    showRecent(client, DefaultRecentLimit, opts.showAll)
  of "backup":
    backupPages(client, if opts.args.len >= 1: opts.args[0] else: "", opts.fullBackup, opts.verbose)
  of "restore":
    if opts.args.len < 1: echo t("error_backup_dir_required"); return
    restorePages(client, opts.args[0], opts.targetPrefix, opts.verbose)
  of "download", "dl":
    if opts.args.len < 1: echo t("error_pagename_required"); return
    downloadPage(client, opts.args[0], if opts.args.len >= 2: opts.args[1] else: "")
  of "upload", "ul":
    if opts.args.len < 2: echo t("error_file_and_page_required"); return
    uploadPage(client, opts.args[0], opts.args[1])
  of "graph":
    showGraph(client, if opts.args.len >= 1: opts.args[0] else: "text", opts.showAll)
  else:
    echo t("error_unknown_command"), ": ", opts.command
    var bestMatch = ""; var bestDist = 100
    for valid in ValidCommands:
      let dist = editDistance(opts.command, valid)
      if dist < bestDist: bestDist = dist; bestMatch = valid
    if bestDist <= 2:
      let msg = if config.language == langDE: "Meintest du '$1'?" else: "Did you mean '$1'?"
      styledEcho(fgYellow, "💡 ", msg % bestMatch, resetStyle)
    else:
      echo t("error_use_help")

when isMainModule:
  main()
