' ATMusic for Roku
' Copyright (C) 2026 ATDevs Team
'
' This program is free software: you can redistribute it and/or modify
' it under the terms of the GNU General Public License as published by
' the Free Software Foundation, either version 3 of the License, or
' (at your option) any later version.
'
' This program is distributed in the hope that it will be useful,
' but WITHOUT ANY WARRANTY; without even the implied warranty of
' MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
' GNU General Public License for more details.
'
' You should have received a copy of the GNU General Public License
' along with this program.  If not, see <https://www.gnu.org/licenses/>.

' ============================================================================
' AppShell.brs
'
' Everything that runs once Spool is reachable and the client is up to date:
' left-nav routing, the track/playlist grid, the audio queue, likes/
' favorites/playlists, and login/signup. Centralized, controller-style key
' handling (see HandleKey) rather than deep SceneGraph focus delegation,
' with one exception: the MarkupGrid and ButtonGroup nodes keep real
' setFocus()-based focus while they're the active region, since re-
' implementing their scrolling/selection by hand would be worse.
' ============================================================================

sub init()
    m.apiBase = "https://atmusic.atdevs.org"
    m.pendingTasks = []

    m.currentUser = invalid
    m.currentTrack = invalid
    m.queue = []
    m.queueIndex = -1
    m.audio = invalid
    m.playRegisteredForTrackId = ""

    m.navSections = ["New", "For You", "Trending", "Search", "Albums", "Creators", "Tags", "Playlists", "Discover", "Favorites", "Library", "Sync", "Info", "Now Playing", "Profile"]
    m.navIndex = 0
    m.focusRegion = "nav" ' nav | content | auth | profile | overlay
    m.viewStack = []
    m.listParams = invalid
    m.nowPlayingOverlayVisible = false
    m.preOverlayFocusRegion = "nav"

    ' ---- node refs ----
    m.grid = m.top.findNode("grid")
    m.grid.ObserveField("itemSelected", "OnGridItemSelected")

    m.contentTitle = m.top.findNode("contentTitle")
    m.contentSubtitle = m.top.findNode("contentSubtitle")
    m.emptyStateLabel = m.top.findNode("emptyStateLabel")

    m.authGroup = m.top.findNode("authGroup")
    m.authButtons = m.top.findNode("authButtons")
    m.authButtons.ObserveField("buttonSelected", "OnAuthButtonSelected")

    m.profileGroup = m.top.findNode("profileGroup")
    m.profileButtons = m.top.findNode("profileButtons")
    m.profileButtons.ObserveField("buttonSelected", "OnProfileButtonSelected")

    m.miniPlayer = m.top.findNode("miniPlayer")

    m.nowPlayingOverlay = m.top.findNode("nowPlayingOverlay")
    m.npButtons = m.top.findNode("npButtons")
    m.npButtons.ObserveField("buttonSelected", "OnNpButtonSelected")

    m.playlistPickerOverlay = m.top.findNode("playlistPickerOverlay")
    m.pickerButtons = m.top.findNode("pickerButtons")
    m.pickerButtons.ObserveField("buttonSelected", "OnPickerButtonSelected")

    m.toastGroup = m.top.findNode("toastGroup")
    m.toastTimer = m.top.findNode("toastTimer")
    m.toastTimer.ObserveField("fire", "OnToastTimerFire")

    ' ---- client debug mode: background sender ----
    m.debugTask = CreateObject("roSGNode", "DebugTask")
    m.debugTask.session = m.global.sessionId
    m.debugTask.ObserveField("batch", "OnDebugBatch")
    m.debugTask.ObserveField("ready", "OnDebugReady")
    m.debugTask.control = "RUN"

    m.visOverlay = m.top.findNode("visOverlay")
    m.visStage = m.top.findNode("visStage")
    m.visTimer = m.top.findNode("visTimer")
    m.visTimer.ObserveField("fire", "OnVisTick")
    m.visModes = []
    m.visIndex = 0
    m.visReady = false
    m.visWantId = ""
    m.visLinked = {}
    m.visPendingLibs = 0
    m.visPendingModule = invalid
    m.visLastTrack = ""
    m.lyOverlay = m.top.findNode("lyOverlay")
    m.lyTimer = m.top.findNode("lyTimer")
    m.lyTimer.ObserveField("fire", "OnLyricsTick")
    m.lyLines = []
    m.lySynced = false
    m.lyScroll = 0
    m.lyIndex = -2
    m.syncTimer = m.top.findNode("syncTimer")
    m.syncTimer.ObserveField("fire", "OnSyncTick")
    m.syncCode = ""
    m.syncRole = "follower"
    m.syncEpoch = 0
    m.syncActive = false
    m.syncState = invalid
    m.syncBusy = false
    m.syncTrackId = ""
    m.syncPending = false
    m.syncLastSeekMs = 0
    m.syncBackoffMs = 6000
    m.syncStable = 0
    m.syncDriftMs = 0
    m.syncRtt = 0
    m.syncClock = CreateObject("roTimespan")
    m.clientId = ""
    regc = CreateObject("roRegistrySection", "atmusic")
    if regc.Exists("client_id")
        m.clientId = regc.Read("client_id")
    else
        m.clientId = "roku-" + CreateObject("roDeviceInfo").GetRandomUUID()
        regc.Write("client_id", m.clientId)
        regc.Flush()
    end if

    m.qrOverlay = m.top.findNode("qrOverlay")
    m.qrPoster = m.top.findNode("qrPoster")
    m.qrStatus = m.top.findNode("qrStatus")
    m.qrTimer = m.top.findNode("qrTimer")
    m.qrTimer.ObserveField("fire", "OnQrTimer")
    m.pendingLoginPassword = ""
    m.qrToken = ""
    m.qrCounter = 0
    m.qrBusy = false
    m.textView = m.top.findNode("textView")
    m.textLabel = m.top.findNode("textLabel")

    BuildNavItems()
    m.top.setFocus(true)

    ' restore the saved login cookies first, then ask the server who we are
    ApiRequest("auth:restore", "RESTORE", "/api/auth/me", invalid, "OnApiResponse")

    if Left(m.global.launchAction, 7) = "atclam:" then StartAtclamAction(Mid(m.global.launchAction, 8))

    ' Show the New feed straight away instead of a blank pane until the user
    ' presses OK; keep focus on the nav so the first d-pad press still works.
    m.keepNavFocusOnce = true
    ActivateNavItem(0)
end sub

sub OnDebugReady()
    di = CreateObject("roDeviceInfo")
    DLog("info", "ATMusic Roku " + CreateObject("roAppInfo").GetVersion() + " start; model=" + di.GetModel() + " os=" + di.GetOSVersion().major + "." + di.GetOSVersion().minor + " ui=" + di.GetUIResolution().name + " debug=" + m.global.debugOn.ToStr())
end sub

' ==================================================================== nav ==

sub BuildNavItems()
    navGroup = m.top.findNode("navItems")
    m.navLabels = []
    y = 0
    for each section in m.navSections
        lbl = CreateObject("roSGNode", "Label")
        lbl.font = "font:MediumBoldSystemFont"
        lbl.translation = [32, y]
        lbl.width = 240
        lbl.height = 46
        lbl.text = section
        navGroup.appendChild(lbl)
        m.navLabels.push(lbl)
        y = y + 54
    end for
    RenderNavFocus()
end sub

sub RenderNavFocus()
    for i = 0 to m.navLabels.Count() - 1
        lbl = m.navLabels[i]
        if i = m.navIndex and m.focusRegion = "nav"
            lbl.color = "0xFFFFFFFF"
        else if i = m.navIndex
            lbl.color = "0x4FD1C5FF"
        else
            lbl.color = "0x5A5A66FF"
        end if
    end for
end sub

sub ActivateNavItem(index as integer)
    DLog("nav", "section=" + m.navSections[index] + " loggedIn=" + (m.currentUser <> invalid).ToStr())
    m.global.screenName = m.navSections[index]
    m.navIndex = index
    section = m.navSections[index]
    m.viewStack = []

    m.grid.visible = false
    m.textView.visible = false
    m.authGroup.visible = false
    m.profileGroup.visible = false
    m.emptyStateLabel.visible = false
    m.contentSubtitle.text = ""

    if section = "New"
        m.contentTitle.text = "New Tracks"
        LoadTrackList({mode: "feed", sort: "new", page: 1, pageSize: 20})

    else if section = "For You"
        m.contentTitle.text = "For You"
        m.contentSubtitle.text = "Picked from what you play, like and favorite"
        if m.currentUser = invalid
            ShowAuthPrompt("Log in to get tracks picked for you.")
        else
            LoadBrowse("foryou", "/api/for-you?limit=30")
        end if

    else if section = "Trending"
        m.contentTitle.text = "Trending"
        LoadTrackList({mode: "feed", sort: "trending", page: 1, pageSize: 20})

    else if section = "Search"
        m.contentTitle.text = "Search"
        OpenSearchDialog()

    else if section = "Albums"
        m.contentTitle.text = "Albums"
        m.contentSubtitle.text = "Collections of tracks from creators"
        LoadBrowse("albums", "/api/albums?page_size=100")

    else if section = "Creators"
        m.contentTitle.text = "Creators"
        m.contentSubtitle.text = "Verified creators on ATMusic"
        LoadBrowse("creators", "/api/creators?page_size=100")

    else if section = "Tags"
        m.contentTitle.text = "Tags"
        m.contentSubtitle.text = "Browse tracks by genre, mood and more"
        LoadBrowse("tags", "/api/tags?page_size=100")

    else if section = "Discover"
        m.contentTitle.text = "Discover Playlists"
        m.contentSubtitle.text = "Public playlists made by the community"
        LoadBrowse("discover", "/api/playlists/discover?page_size=50")

    else if section = "Library"
        m.contentTitle.text = "Library"
        ShowLibraryMenu()

    else if section = "Sync"
        m.contentTitle.text = "ATMusic Sync"
        ShowSyncMenu()

    else if section = "Info"
        m.contentTitle.text = "Info"
        ShowInfoMenu()

    else if section = "Playlists"
        m.contentTitle.text = "Your Playlists"
        if m.currentUser = invalid
            ShowAuthPrompt("Log in to view and create playlists.")
        else
            LoadPlaylists()
        end if

    else if section = "Favorites"
        m.contentTitle.text = "Favorites"
        if m.currentUser = invalid
            ShowAuthPrompt("Log in to see your favorited tracks.")
        else
            LoadTrackList({mode: "favorites", page: 1, pageSize: 20})
        end if

    else if section = "Now Playing"
        if m.currentTrack = invalid
            ShowToast("Nothing is playing yet.")
            RenderNavFocus()
        else
            OpenNowPlaying()
        end if

    else if section = "Profile"
        m.contentTitle.text = "Profile"
        RenderProfile()
    end if
end sub

sub ShowAuthPrompt(message as string)
    DLog("auth", "prompt: " + message)
    m.top.findNode("authMessage").text = message
    m.authGroup.visible = true
    m.focusRegion = "auth"
    m.authButtons.setFocus(true)
    RenderNavFocus()
end sub

sub FocusContent()
    m.focusRegion = "content"
    m.grid.setFocus(true)
    RenderNavFocus()
end sub

' ============================================================== API core ==

function ApiRequest(requestId as string, method as string, path as string, jsonBody = invalid as dynamic, callback = invalid as dynamic) as object
    if Left(path, 11) <> "/api/debug/" then DLog("net", "-> " + method + " " + LogPath(path) + " [" + requestId + "]")
    task = CreateObject("roSGNode", "NetworkTask")
    task.requestId = requestId
    task.requestMethod = method
    task.requestUrl = m.apiBase + path
    if jsonBody <> invalid then task.requestJson = jsonBody
    if callback <> invalid then task.ObserveField("response", callback)
    m.pendingTasks.push(task)
    if m.pendingTasks.Count() > 40 then m.pendingTasks.Shift()
    task.control = "RUN"
    return task
end function

function UrlEncode(s as string) as string
    safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    hexDigits = "0123456789ABCDEF"
    result = ""
    for i = 0 to Len(s) - 1
        ch = Mid(s, i + 1, 1)
        if Instr(1, safe, ch) > 0
            result = result + ch
        else if ch = " "
            result = result + "%20"
        else
            code = Asc(ch)
            hi = Int(code / 16)
            lo = code mod 16
            result = result + "%" + Mid(hexDigits, hi + 1, 1) + Mid(hexDigits, lo + 1, 1)
        end if
    end for
    return result
end function

function MinInt(a as integer, b as integer) as integer
    if a < b then return a
    return b
end function

' The backend returns cover_url/stream_url as *relative* paths
' (e.g. "/api/tracks/<id>/stream"), which is fine for our own API calls
' but not valid for Poster.uri or Audio content.url - those need an
' absolute URI or Roku logs "Missing or invalid PHY" and silently shows/
' plays nothing. Resolve against the API host before handing them off.
function ResolveApiUrl(path as dynamic) as dynamic
    if path = invalid or path = "" then return invalid
    if Left(path, 4) = "http" then return path ' already absolute
    return m.apiBase + path
end function

' Single dispatcher for every NetworkTask response in the app.
sub OnApiResponse(event as object)
    result = event.GetData()
    parts = result.requestId.Split(":")
    kind = parts[0]
    if kind <> "debug" then DLog("net", "<- [" + result.requestId + "] code=" + result.code.ToStr() + " ok=" + result.success.ToStr() + " bytes=" + Len(result.body).ToStr())
    if kind = "debug"
        HandleDebugResponse(result)
        return
    end if

    if kind = "list"
        HandleListResponse(result)
    else if kind = "qr"
        HandleQrResponse(parts[1], result)
    else if kind = "browse"
        HandleBrowseResponse(parts[1], result)
    else if kind = "albumdetail"
        HandleAlbumDetailResponse(result)
    else if kind = "info"
        HandleInfoResponse(parts[1], result)
    else if kind = "lib"
        HandleLibraryResponse(parts[1], result)
    else if kind = "sync"
        HandleSyncResponse(parts[1], result)
    else if kind = "lyrics"
        HandleLyricsResponse(result)
    else if kind = "vis"
        HandleVisResponse(parts[1], result)
    else if kind = "playlistsnav"
        HandlePlaylistsListResponse(result)
    else if kind = "playlistpicker"
        HandlePlaylistPickerResponse(result)
    else if kind = "playlistdetail"
        HandlePlaylistDetailResponse(result, parts[1])
    else if kind = "playlistcreate"
        HandlePlaylistCreateResponse(result)
    else if kind = "playlistaddtrack"
        HandlePlaylistAddTrackResponse(result)
    else if kind = "playlistremovetrack"
        HandlePlaylistRemoveTrackResponse(result, parts[1])
    else if kind = "track"
        HandleTrackActionResponse(parts[1], parts[2], result)
    else if kind = "auth"
        HandleAuthResponse(parts[1], result)
    else if kind = "profile"
        HandleProfileResponse(result)
    end if
end sub

' ===================================================================== session/auth ==

sub CheckSession()
    DLog("auth", "check session")
    ApiRequest("auth:me", "GET", "/api/auth/me", invalid, "OnApiResponse")
end sub

sub HandleAuthResponse(action as string, result as object)
    if action = "restore"
        CheckSession()
        return
    end if
    if action = "me"
        if result.success and result.json <> invalid and result.json.user <> invalid
            m.currentUser = result.json.user
        else
            m.currentUser = invalid
        end if
        DLog("auth", "session restored loggedIn=" + (m.currentUser <> invalid).ToStr())
        SyncDebugSender()
        return
    end if

    if action = "login" or action = "signup"
        if result.success and result.json <> invalid and result.json.user <> invalid
            m.currentUser = result.json.user
            m.pendingLoginPassword = ""
            DLog("auth", "login ok")
            SyncDebugSender()
            ShowToast("Welcome, " + m.currentUser.username + ".")
            if m.navSections[m.navIndex] = "Profile" then RenderProfile()
            if m.navSections[m.navIndex] = "Playlists" then ActivateNavItem(m.navIndex)
            if m.navSections[m.navIndex] = "Favorites" then ActivateNavItem(m.navIndex)
        else if action = "login" and result.json <> invalid and result.json.mfa_required = true
            HandleMfaRequired(result.json)
        else
            m.pendingLoginPassword = ""
            msg = "That didn't work."
            if result.json <> invalid and result.json.error <> invalid then msg = result.json.error
            ShowToast(msg)
            RenderProfile()
        end if
        return
    end if

    if action = "logout"
        m.currentUser = invalid
        DLog("auth", "logout")
        SyncDebugSender()
        ShowToast("Logged out.")
        RenderProfile()
    end if
end sub

sub RenderProfile()
    m.grid.visible = false
    m.emptyStateLabel.visible = false

    if m.currentUser = invalid
        m.profileGroup.visible = false
        ShowAuthPrompt("Log in or create an account to like tracks, save favorites, and build playlists.")
        return
    end if

    m.authGroup.visible = false
    m.profileGroup.visible = true
    m.top.findNode("profileUsername").text = "@" + m.currentUser.username
    m.top.findNode("profileRole").text = m.currentUser.role
    bio = m.currentUser.bio
    if bio = invalid or bio = "" then bio = "No bio yet."
    m.top.findNode("profileBio").text = bio
    m.top.findNode("profileStats").text = ""

    ApiRequest("profile:" + m.currentUser.username, "GET", "/api/users/" + m.currentUser.username, invalid, "OnApiResponse")

    m.focusRegion = "profile"
    m.profileButtons.buttons = ["Log Out"]
    m.profileButtons.setFocus(true)
    RenderNavFocus()
end sub

sub HandleProfileResponse(result as object)
    if not result.success or result.json = invalid then return
    m.top.findNode("profileStats").text = result.json.track_count.ToStr() + " tracks uploaded"
end sub

sub OnAuthButtonSelected()
    idx = m.authButtons.buttonSelected
    if idx = 0
        StartQrLogin()
    else if idx = 1
        StartLogin()
    else if idx = 2
        StartSignup()
    end if
end sub

sub OnProfileButtonSelected()
    idx = m.profileButtons.buttonSelected
    if idx = 0
        ApiRequest("auth:logout", "POST", "/api/auth/logout", {}, "OnApiResponse")
    end if
end sub

' ---- login (username -> password -> submit) ----

sub StartLogin()
    DLog("auth", "password login dialog")
    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = "Username or Email"
    kb.buttons = ["Next", "Cancel"]
    kb.ObserveField("buttonSelected", "OnLoginUsernameButton")
    m.authDialog = kb
    m.top.GetScene().dialog = kb
end sub

sub OnLoginUsernameButton()
    idx = m.authDialog.buttonSelected
    if idx <> 0
        m.authDialog.close = true
        return
    end if
    username = m.authDialog.text
    m.authDialog.close = true
    if username = "" then return
    m.pendingLoginUsername = username

    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = "Password"
    kb.buttons = ["Log In", "Cancel"]
    kb.textEditBox.secureMode = true
    kb.ObserveField("buttonSelected", "OnLoginPasswordButton")
    m.authDialog = kb
    m.top.GetScene().dialog = kb
end sub

sub OnLoginPasswordButton()
    idx = m.authDialog.buttonSelected
    password = m.authDialog.text
    m.authDialog.close = true
    if idx <> 0 then return
    if password = "" then return

    m.pendingLoginPassword = password
    ApiRequest("auth:login", "POST", "/api/auth/login", {username: m.pendingLoginUsername, password: password}, "OnApiResponse")
end sub

' ---- signup (username -> email -> password -> submit) ----

sub StartSignup()
    DLog("auth", "signup dialog")
    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = "Choose a Username"
    kb.buttons = ["Next", "Cancel"]
    kb.ObserveField("buttonSelected", "OnSignupUsernameButton")
    m.authDialog = kb
    m.top.GetScene().dialog = kb
end sub

sub OnSignupUsernameButton()
    idx = m.authDialog.buttonSelected
    username = m.authDialog.text
    m.authDialog.close = true
    if idx <> 0 or username = "" then return
    m.pendingSignupUsername = username

    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = "Email Address"
    kb.buttons = ["Next", "Cancel"]
    kb.ObserveField("buttonSelected", "OnSignupEmailButton")
    m.authDialog = kb
    m.top.GetScene().dialog = kb
end sub

sub OnSignupEmailButton()
    idx = m.authDialog.buttonSelected
    email = m.authDialog.text
    m.authDialog.close = true
    if idx <> 0 or email = "" then return
    m.pendingSignupEmail = email

    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = "Choose a Password (6+ characters)"
    kb.buttons = ["Sign Up", "Cancel"]
    kb.textEditBox.secureMode = true
    kb.ObserveField("buttonSelected", "OnSignupPasswordButton")
    m.authDialog = kb
    m.top.GetScene().dialog = kb
end sub

sub OnSignupPasswordButton()
    idx = m.authDialog.buttonSelected
    password = m.authDialog.text
    m.authDialog.close = true
    if idx <> 0 or password = "" then return

    ApiRequest("auth:signup", "POST", "/api/auth/signup", {
        username: m.pendingSignupUsername
        email: m.pendingSignupEmail
        password: password
    }, "OnApiResponse")
end sub

' =============================================================== search ==

sub OpenSearchDialog()
    DLog("ui", "search dialog")
    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = "Search Spool"
    kb.buttons = ["Search", "Cancel"]
    kb.ObserveField("buttonSelected", "OnSearchDialogButton")
    m.searchDialog = kb
    m.top.GetScene().dialog = kb
end sub

sub OnSearchDialogButton()
    idx = m.searchDialog.buttonSelected
    query = m.searchDialog.text
    m.searchDialog.close = true
    if idx <> 0 or query = ""
        RenderNavFocus()
        return
    end if
    m.contentSubtitle.text = "Results for """ + query + """"
    LoadTrackList({mode: "search", query: query, page: 1, pageSize: 20})
end sub

' ========================================================== track lists ==

sub LoadTrackList(params as object)
    DLog("list", "load mode=" + params.mode + " page=" + params.page.ToStr())
    m.listParams = params
    m.grid.visible = true
    m.emptyStateLabel.visible = false

    path = ""
    if params.mode = "feed"
        path = "/api/tracks?sort=" + params.sort + "&page=" + params.page.ToStr() + "&page_size=" + params.pageSize.ToStr()
    else if params.mode = "favorites"
        path = "/api/users/me/favorites?page=" + params.page.ToStr() + "&page_size=" + params.pageSize.ToStr()
    else if params.mode = "owner"
        path = "/api/tracks?owner=" + UrlEncode(params.query) + "&sort=new&page=" + params.page.ToStr() + "&page_size=" + params.pageSize.ToStr()
    else if params.mode = "tag"
        path = "/api/tracks?tag=" + UrlEncode(params.query) + "&sort=new&page=" + params.page.ToStr() + "&page_size=" + params.pageSize.ToStr()
    else if params.mode = "search"
        path = "/api/tracks?search=" + UrlEncode(params.query) + "&sort=new&page=" + params.page.ToStr() + "&page_size=" + params.pageSize.ToStr()
    end if

    ApiRequest("list:" + params.mode, "GET", path, invalid, "OnApiResponse")
end sub

sub HandleListResponse(result as object)
    if not result.success then DLog("error", "list failed code=" + result.code.ToStr())
    if not result.success or result.json = invalid
        ShowToast("Couldn't load tracks. Check your connection.")
        return
    end if

    tracks = result.json.tracks
    DLog("list", "loaded " + tracks.Count().ToStr() + " tracks")
    totalPages = result.json.total_pages
    page = result.json.page
    hasMore = (page < totalPages) and (m.listParams.pageSize < 100)

    m.currentListTracks = tracks
    content = BuildTrackContentNode(tracks, hasMore)
    m.grid.content = content

    if tracks.Count() = 0
        m.grid.visible = false
        m.emptyStateLabel.visible = true
        m.emptyStateLabel.text = EmptyMessageFor(m.listParams.mode)
        RenderNavFocus()
    else
        m.grid.visible = true
        m.emptyStateLabel.visible = false
        if m.keepNavFocusOnce = true
            m.keepNavFocusOnce = false
        else
            FocusContent()
        end if
    end if
end sub

function EmptyMessageFor(mode as string) as string
    if mode = "favorites" then return "You haven't favorited any tracks yet. Open a track's Now Playing screen and hit Favorite."
    if mode = "search" then return "No tracks matched that search."
    if mode = "owner" then return "No tracks from this creator yet."
    if mode = "tag" then return "No tracks with this tag yet."
    return "Nothing here yet."
end function

function BuildTrackContentNode(tracks as object, hasMore as boolean) as object
    root = CreateObject("roSGNode", "ContentNode")
    for each t in tracks
        item = root.CreateChild("ContentNode")
        isPlaying = false
        if m.currentTrack <> invalid and m.currentTrack.id = t.id then isPlaying = true
        item.AddFields({
            kind: "track"
            trackId: t.id
            title: t.title
            subtitle: t.artist_name
            meta: t.plays.ToStr() + " plays"
            coverUrl: ResolveApiUrl(t.cover_url)
            url: ResolveApiUrl(t.stream_url)
            likesCount: t.likes
            dislikesCount: t.dislikes
            myLike: t.my_like
            isFavorited: (t.is_favorited = true)
            isPlaying: isPlaying
            ownerUsername: t.owner_username
        })
    end for
    if hasMore
        more = root.CreateChild("ContentNode")
        more.AddFields({kind: "loadMore", title: "Load more..."})
    end if
    return root
end function

sub OnGridItemSelected()
    idx = m.grid.itemSelected
    content = m.grid.content
    if content = invalid then return
    item = content.GetChild(idx)
    if item = invalid then return

    if item.kind = "loadMore"
        m.listParams.pageSize = MinInt(m.listParams.pageSize + 20, 100)
        LoadTrackList(m.listParams)
    else if item.kind = "track"
        BuildQueueFromGrid(idx)
        PlayCurrentQueueItem()
    else if item.kind = "playlist"
        LoadPlaylistDetail(item.playlistId, item.title)
    else if item.kind = "createPlaylist"
        OpenCreatePlaylistDialog(false)
    else if item.kind = "card"
        HandleCardSelected(item)
    end if
end sub

' =============================================================== queue ==

sub BuildQueueFromGrid(selectedIndex as integer)
    content = m.grid.content
    queue = []
    startIdx = 0
    for i = 0 to content.GetChildCount() - 1
        c = content.GetChild(i)
        if c.kind = "track"
            queue.push({
                id: c.trackId
                title: c.title
                artist: c.subtitle
                coverUrl: c.coverUrl
                url: c.url
                likesCount: c.likesCount
                dislikesCount: c.dislikesCount
                myLike: c.myLike
                isFavorited: c.isFavorited
            })
            if i = selectedIndex then startIdx = queue.Count() - 1
        end if
    end for
    m.queue = queue
    m.queueIndex = startIdx
end sub

sub PlayCurrentQueueItem()
    if m.queue <> invalid and m.queueIndex >= 0 and m.queueIndex < m.queue.Count() then DLog("play", "start id=" + m.queue[m.queueIndex].id + " idx=" + m.queueIndex.ToStr() + "/" + m.queue.Count().ToStr())
    if m.queue = invalid or m.queueIndex < 0 or m.queueIndex >= m.queue.Count() then return

    track = m.queue[m.queueIndex]
    m.currentTrack = track

    content = CreateObject("roSGNode", "ContentNode")
    content.url = track.url
    content.title = track.title

    if m.audio = invalid
        m.audio = CreateObject("roSGNode", "Audio")
        m.audio.ObserveField("state", "OnAudioStateChange")
        m.top.appendChild(m.audio)
    end if

    m.audio.content = content
    m.audio.control = "play"
    m.playRegisteredForTrackId = ""

    UpdateMiniPlayer()
    if m.nowPlayingOverlayVisible then UpdateNowPlayingPanel()
end sub

sub OnAudioStateChange(event as object)
    DLog("play", "audio state=" + m.audio.state)
    state = event.GetData()
    m.top.findNode("miniState").text = FriendlyState(state)
    if m.nowPlayingOverlayVisible then m.top.findNode("npStatus").text = FriendlyState(state)

    if state = "playing"
        if m.currentTrack <> invalid and m.playRegisteredForTrackId <> m.currentTrack.id
            ApiRequest("track:registerplay:" + m.currentTrack.id, "POST", "/api/tracks/" + m.currentTrack.id + "/play", {}, invalid)
            m.playRegisteredForTrackId = m.currentTrack.id
        end if
    else if state = "finished"
        AdvanceQueue()
    end if
end sub

function FriendlyState(state as string) as string
    if state = "playing" then return "Playing"
    if state = "paused" then return "Paused"
    if state = "buffering" then return "Buffering..."
    if state = "finished" then return "Finished"
    if state = "error" then return "Playback error"
    return ""
end function

sub AdvanceQueue()
    DLog("play", "advance queue")
    if m.queue = invalid then return
    if m.queueIndex + 1 < m.queue.Count()
        m.queueIndex = m.queueIndex + 1
        PlayCurrentQueueItem()
    else
        m.top.findNode("miniState").text = "Queue finished"
    end if
end sub

sub TogglePlayPause()
    if m.audio = invalid then return
    if m.audio.state = "playing"
        m.audio.control = "pause"
    else
        m.audio.control = "resume"
    end if
end sub

sub UpdateMiniPlayer()
    m.miniPlayer.visible = true
    m.top.findNode("miniTitle").text = m.currentTrack.title
    m.top.findNode("miniSubtitle").text = m.currentTrack.artist
    if m.currentTrack.coverUrl <> invalid and m.currentTrack.coverUrl <> ""
        m.top.findNode("miniCover").uri = m.currentTrack.coverUrl
    end if
end sub

' ========================================================== now playing ==

sub OpenNowPlaying()
    DLog("ui", "nowplaying open")
    m.preOverlayFocusRegion = m.focusRegion
    m.nowPlayingOverlay.visible = true
    m.nowPlayingOverlayVisible = true
    m.focusRegion = "overlay"
    UpdateNowPlayingPanel()
    m.npButtons.setFocus(true)
end sub

sub UpdateNowPlayingPanel()
    if m.currentTrack = invalid then return
    t = m.currentTrack
    m.top.findNode("npTitle").text = t.title
    m.top.findNode("npArtist").text = t.artist

    likeTxt = ""
    if t.myLike = 1 then likeTxt = "   (you liked this)"
    if t.myLike = -1 then likeTxt = "   (you disliked this)"
    m.top.findNode("npStats").text = t.likesCount.ToStr() + " likes    " + t.dislikesCount.ToStr() + " dislikes" + likeTxt

    if t.coverUrl <> invalid and t.coverUrl <> ""
        m.top.findNode("npCover").uri = t.coverUrl
        m.top.findNode("npCover").visible = true
        m.top.findNode("npCoverFallback").visible = false
    else
        m.top.findNode("npCover").visible = false
        m.top.findNode("npCoverFallback").visible = true
    end if

    if m.audio <> invalid then m.top.findNode("npStatus").text = FriendlyState(m.audio.state)
end sub

sub CloseNowPlaying()
    DLog("ui", "nowplaying close")
    m.nowPlayingOverlay.visible = false
    m.nowPlayingOverlayVisible = false
    m.npButtons.setFocus(false)
    if m.preOverlayFocusRegion = "content"
        FocusContent()
    else
        m.focusRegion = "nav"
        m.top.setFocus(true)
        RenderNavFocus()
    end if
end sub

sub OnNpButtonSelected()
    idx = m.npButtons.buttonSelected
    if idx = 0
        TogglePlayPause()
    else if idx = 1
        ToggleLike(1)
    else if idx = 2
        ToggleLike(-1)
    else if idx = 3
        ToggleFavorite()
    else if idx = 4
        OpenPlaylistPicker()
    else if idx = 5
        OpenLyrics()
    else if idx = 6
        OpenVisualizer()
    else if idx = 7
        CloseNowPlaying()
    end if
end sub

sub ToggleLike(value as integer)
    DLog("action", "like toggle")
    if m.currentUser = invalid
        ShowToast("Log in to like tracks.")
        return
    end if
    if m.currentTrack = invalid then return
    trackId = m.currentTrack.id
    if m.currentTrack.myLike = value
        ApiRequest("track:like:" + trackId, "DELETE", "/api/tracks/" + trackId + "/like", invalid, "OnApiResponse")
    else
        ApiRequest("track:like:" + trackId, "POST", "/api/tracks/" + trackId + "/like", {value: value}, "OnApiResponse")
    end if
end sub

sub ToggleFavorite()
    DLog("action", "favorite toggle")
    if m.currentUser = invalid
        ShowToast("Log in to favorite tracks.")
        return
    end if
    if m.currentTrack = invalid then return
    trackId = m.currentTrack.id
    if m.currentTrack.isFavorited = true
        ApiRequest("track:favorite:" + trackId, "DELETE", "/api/tracks/" + trackId + "/favorite", invalid, "OnApiResponse")
    else
        ApiRequest("track:favorite:" + trackId, "POST", "/api/tracks/" + trackId + "/favorite", {}, "OnApiResponse")
    end if
end sub

sub HandleTrackActionResponse(action as string, trackId as string, result as object)
    if not result.success or result.json = invalid or result.json.track = invalid
        ShowToast("That didn't work. Try again.")
        return
    end if
    t = result.json.track
    if m.currentTrack <> invalid and m.currentTrack.id = t.id
        m.currentTrack.likesCount = t.likes
        m.currentTrack.dislikesCount = t.dislikes
        m.currentTrack.myLike = t.my_like
        m.currentTrack.isFavorited = t.is_favorited
        if m.nowPlayingOverlayVisible then UpdateNowPlayingPanel()
    end if
end sub

' ===================================================== playlists (nav) ==

sub LoadPlaylists()
    m.grid.visible = true
    m.emptyStateLabel.visible = false
    ApiRequest("playlistsnav:list", "GET", "/api/playlists", invalid, "OnApiResponse")
end sub

sub HandlePlaylistsListResponse(result as object)
    if not result.success or result.json = invalid
        ShowToast("Couldn't load your playlists.")
        return
    end if
    playlists = result.json.playlists
    root = CreateObject("roSGNode", "ContentNode")

    create = root.CreateChild("ContentNode")
    create.AddFields({kind: "createPlaylist", title: "+ New Playlist"})

    for each p in playlists
        item = root.CreateChild("ContentNode")
        item.AddFields({
            kind: "playlist"
            playlistId: p.id
            title: p.name
            subtitle: p.visibility
            meta: p.track_count.ToStr() + " tracks"
        })
    end for

    m.grid.content = root
    FocusContent()
end sub

sub LoadPlaylistDetail(playlistId as string, playlistName as string)
    m.viewStack.push({mode: "playlists-nav-root"})
    m.currentPlaylistId = playlistId
    m.contentTitle.text = playlistName
    m.grid.visible = true
    ApiRequest("playlistdetail:" + playlistId, "GET", "/api/playlists/" + playlistId, invalid, "OnApiResponse")
end sub

sub HandlePlaylistDetailResponse(result as object, playlistId as string)
    if not result.success or result.json = invalid or result.json.playlist = invalid
        ShowToast("Couldn't load that playlist.")
        return
    end if
    playlist = result.json.playlist
    tracks = playlist.tracks
    m.currentListTracks = tracks
    content = BuildTrackContentNode(tracks, false)
    m.grid.content = content

    if tracks = invalid or tracks.Count() = 0
        m.grid.visible = false
        m.emptyStateLabel.visible = true
        m.emptyStateLabel.text = "This playlist is empty. Add tracks from a track's Now Playing screen."
        RenderNavFocus()
    else
        m.grid.visible = true
        m.emptyStateLabel.visible = false
        FocusContent()
    end if
end sub

sub OpenCreatePlaylistDialog(thenAddCurrentTrack as boolean)
    m.pendingAddAfterCreate = thenAddCurrentTrack
    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = "New Playlist Name"
    kb.buttons = ["Create", "Cancel"]
    kb.ObserveField("buttonSelected", "OnCreatePlaylistDialogButton")
    m.createPlaylistDialog = kb
    m.top.GetScene().dialog = kb
end sub

sub OnCreatePlaylistDialogButton()
    idx = m.createPlaylistDialog.buttonSelected
    name = m.createPlaylistDialog.text
    m.createPlaylistDialog.close = true
    if idx <> 0 or name = ""
        if m.pendingAddAfterCreate then RestoreOverlayFocus()
        return
    end if
    ApiRequest("playlistcreate", "POST", "/api/playlists", {name: name, visibility: "private"}, "OnApiResponse")
end sub

sub HandlePlaylistCreateResponse(result as object)
    if not result.success or result.json = invalid or result.json.playlist = invalid
        ShowToast("Couldn't create that playlist.")
        if m.pendingAddAfterCreate then RestoreOverlayFocus()
        return
    end if
    playlist = result.json.playlist
    ShowToast("Created """ + playlist.name + """.")

    if m.pendingAddAfterCreate
        AddCurrentTrackToPlaylist(playlist.id)
        RestoreOverlayFocus()
    else if m.navSections[m.navIndex] = "Playlists"
        LoadPlaylists()
    end if
end sub

' ---- add-to-playlist picker (opened from Now Playing) ----

sub OpenPlaylistPicker()
    DLog("ui", "playlist picker")
    if m.currentUser = invalid
        ShowToast("Log in to use playlists.")
        return
    end if
    if m.currentTrack = invalid then return
    ApiRequest("playlistpicker:list", "GET", "/api/playlists", invalid, "OnApiResponse")
end sub

sub HandlePlaylistPickerResponse(result as object)
    if not result.success or result.json = invalid
        ShowToast("Couldn't load your playlists.")
        return
    end if
    playlists = result.json.playlists
    names = []
    ids = []
    for each p in playlists
        names.push(p.name + " (" + p.track_count.ToStr() + ")")
        ids.push(p.id)
    end for
    names.push("+ New Playlist")
    names.push("Cancel")

    m.pickerPlaylistIds = ids
    m.pickerButtons.buttons = names
    m.playlistPickerOverlay.visible = true
    m.preOverlayFocusRegion = m.focusRegion
    m.focusRegion = "overlay"
    m.pickerButtons.setFocus(true)
end sub

sub OnPickerButtonSelected()
    idx = m.pickerButtons.buttonSelected
    count = m.pickerPlaylistIds.Count()
    m.playlistPickerOverlay.visible = false

    if idx < count
        AddCurrentTrackToPlaylist(m.pickerPlaylistIds[idx])
        RestoreOverlayFocus()
    else if idx = count
        OpenCreatePlaylistDialog(true)
    else
        RestoreOverlayFocus()
    end if
end sub

sub RestoreOverlayFocus()
    ' The picker is always opened from the Now Playing overlay, which is
    ' still visible underneath - just hand real focus back to its buttons.
    m.npButtons.setFocus(true)
    m.focusRegion = "overlay"
end sub

sub AddCurrentTrackToPlaylist(playlistId as string)
    ApiRequest("playlistaddtrack:" + playlistId, "POST", "/api/playlists/" + playlistId + "/tracks", {track_id: m.currentTrack.id}, "OnApiResponse")
end sub

sub HandlePlaylistAddTrackResponse(result as object)
    if result.success
        ShowToast("Added to playlist.")
    else
        msg = "Couldn't add to playlist."
        if result.json <> invalid and result.json.error <> invalid then msg = result.json.error
        ShowToast(msg)
    end if
end sub

sub HandlePlaylistRemoveTrackResponse(result as object, playlistId as string)
    if result.success
        ShowToast("Removed from playlist.")
        LoadPlaylistDetail(playlistId, m.contentTitle.text)
    else
        ShowToast("Couldn't remove that track.")
    end if
end sub

' ======================================================= toast messages ==

sub ShowToast(text as string)
    DLog("toast", text)
    m.top.findNode("toastLabel").text = text
    m.toastGroup.visible = true
    m.toastTimer.control = "stop"
    m.toastTimer.control = "start"
end sub

sub OnToastTimerFire()
    m.toastGroup.visible = false
end sub

' =============================================================== input ==

function HandleKey(key as string, press as boolean) as boolean
    if not press then return false
    DLog("key", key + " region=" + m.focusRegion + " qr=" + m.qrOverlay.visible.ToStr())

    if m.qrOverlay.visible
        if key = "back" then CloseQrLogin()
        return true
    end if

    if m.visOverlay.visible
        if key = "back"
            CloseVisualizer()
        else if key = "right"
            SwitchVisualizer(1)
        else if key = "left"
            SwitchVisualizer(-1)
        end if
        return true
    end if

    if m.lyOverlay.visible
        if key = "back"
            CloseLyrics()
        else if key = "down" and not m.lySynced
            if m.lyScroll < m.lyLines.Count() - 1 then m.lyScroll = m.lyScroll + 8
            RenderUnsyncedLyrics()
        else if key = "up" and not m.lySynced
            m.lyScroll = m.lyScroll - 8
            if m.lyScroll < 0 then m.lyScroll = 0
            RenderUnsyncedLyrics()
        end if
        return true
    end if

    if m.focusRegion = "overlay"
        if key = "back"
            if m.playlistPickerOverlay.visible
                m.playlistPickerOverlay.visible = false
                RestoreOverlayFocus()
            else
                CloseNowPlaying()
            end if
            return true
        end if
        return false ' let the focused ButtonGroup handle up/down/OK itself
    end if

    if m.focusRegion = "auth"
        if key = "left" or key = "back"
            m.focusRegion = "nav"
            m.authButtons.setFocus(false)
            m.top.setFocus(true)
            RenderNavFocus()
            return true
        end if
        return false
    end if

    if m.focusRegion = "profile"
        if key = "left" or key = "back"
            m.focusRegion = "nav"
            m.profileButtons.setFocus(false)
            m.top.setFocus(true)
            RenderNavFocus()
            return true
        end if
        return false
    end if

    if m.focusRegion = "content"
        if key = "left"
            m.focusRegion = "nav"
            m.grid.setFocus(false)
            m.top.setFocus(true)
            RenderNavFocus()
            return true
        else if key = "back"
            if m.viewStack.Count() > 0
                m.viewStack.pop()
                m.contentTitle.text = m.navSections[m.navIndex]
                ActivateNavItem(m.navIndex)
            else
                m.focusRegion = "nav"
                m.grid.setFocus(false)
                m.top.setFocus(true)
                RenderNavFocus()
            end if
            return true
        end if
        return false ' let the MarkupGrid handle up/down/OK itself
    end if

    ' focusRegion = "nav"
    if key = "back" and m.viewStack.Count() > 0
        ' an empty drill-down leaves focus on the nav: Back should still step out of it
        m.viewStack.pop()
        ActivateNavItem(m.navIndex)
        return true
    end if
    if key = "up"
        if m.navIndex > 0
            m.navIndex = m.navIndex - 1
            RenderNavFocus()
        end if
        return true
    else if key = "down"
        if m.navIndex < m.navSections.Count() - 1
            m.navIndex = m.navIndex + 1
            RenderNavFocus()
        end if
        return true
    else if key = "OK" or key = "right"
        ActivateNavItem(m.navIndex)
        return true
    end if

    return false
end function

' ======================================================== browse / info ==
' Generic "card" rows (albums, creators, tags, public playlists, info lines).
' Each carries a target ("album" | "creator" | "tag" | "playlist" | "text" |
' "info" | "none") and an arg; HandleCardSelected drills in. Back pops
' m.viewStack and re-activates the section (HandleKey).

function Txt(v as dynamic) as string
    if v = invalid then return ""
    if GetInterface(v, "ifToStr") <> invalid then return v.ToStr()
    return ""
end function

function StripMd(t as string) as string
    return t.Replace("**", "").Replace("__", "")
end function

function OneLine(v as dynamic, maxLen as integer) as string
    t = StripMd(Txt(v))
    t = t.Replace(Chr(10), " ").Replace(Chr(13), " ")
    if Len(t) > maxLen then t = Left(t, maxLen - 1) + "..."
    return t
end function

function AddCard(root as object, title as string, subtitle as string, meta as string, target as string, arg as string, extra = "" as string) as object
    item = root.CreateChild("ContentNode")
    item.AddFields({kind: "card", title: title, subtitle: subtitle, meta: meta, target: target, arg: arg, extra: extra})
    return item
end function

sub ShowCards(root as object, emptyMsg as string)
    m.currentListTracks = []
    m.grid.content = root
    if root.GetChildCount() = 0
        m.grid.visible = false
        m.emptyStateLabel.visible = true
        m.emptyStateLabel.text = emptyMsg
        RenderNavFocus()
    else
        m.grid.visible = true
        m.emptyStateLabel.visible = false
        if m.keepNavFocusOnce = true
            m.keepNavFocusOnce = false
        else
            FocusContent()
        end if
    end if
end sub

sub LoadBrowse(what as string, path as string)
    m.grid.visible = true
    m.emptyStateLabel.visible = false
    m.textView.visible = false
    ApiRequest("browse:" + what, "GET", path, invalid, "OnApiResponse")
end sub

sub HandleBrowseResponse(what as string, result as object)
    if not result.success or result.json = invalid
        ShowToast("Couldn't load that. Check your connection.")
        return
    end if
    j = result.json
    root = CreateObject("roSGNode", "ContentNode")
    if what = "albums"
        for each a in j.albums
            AddCard(root, Txt(a.title), "by " + Txt(a.owner_username), Txt(a.track_count) + " tracks", "album", Txt(a.id), Txt(a.title))
        end for
        ShowCards(root, "No albums yet.")
    else if what = "creators"
        for each c in j.creators
            uname = Txt(c.verified_username)
            sub_ = OneLine(c.bio, 90)
            if sub_ = "" then sub_ = "@" + uname
            AddCard(root, Txt(c.name), sub_, "", "creator", uname, Txt(c.name))
        end for
        ShowCards(root, "No creators yet.")
    else if what = "tags"
        for each t in j.tags
            AddCard(root, Txt(t.name), Txt(t.category), Txt(t.track_count) + " tracks", "tag", Txt(t.name), Txt(t.name))
        end for
        ShowCards(root, "No tags yet.")
    else if what = "foryou"
        for each r in j.results
            tid = Txt(r.track_id)
            item = root.CreateChild("ContentNode")
            item.AddFields({
                kind: "track"
                trackId: tid
                title: Txt(r.title)
                subtitle: Txt(r.artist_name)
                meta: "For you"
                coverUrl: m.apiBase + "/api/tracks/" + tid + "/cover"
                url: m.apiBase + "/api/tracks/" + tid + "/stream"
                likesCount: 0
                dislikesCount: 0
                myLike: invalid
                isFavorited: false
                isPlaying: false
                ownerUsername: ""
            })
        end for
        ShowCards(root, "Nothing to recommend yet. Play, like and favorite a few tracks first.")
    else if what = "discover"
        for each p in j.playlists
            AddCard(root, Txt(p.name), "public playlist", Txt(p.track_count) + " tracks", "playlist", Txt(p.id), Txt(p.name))
        end for
        ShowCards(root, "No public playlists yet.")
    end if
end sub

sub HandleCardSelected(item as object)
    DLog("ui", "card target=" + item.target + " title=" + item.title)
    target = item.target
    if target = "album"
        m.viewStack.push({mode: "browse"})
        m.contentTitle.text = item.extra
        m.contentSubtitle.text = ""
        ApiRequest("albumdetail:" + item.arg, "GET", "/api/albums/" + item.arg, invalid, "OnApiResponse")
    else if target = "creator"
        if item.arg = ""
            ShowToast("This creator has no linked account yet.")
            return
        end if
        m.viewStack.push({mode: "browse"})
        m.contentTitle.text = item.extra
        m.contentSubtitle.text = "Tracks by @" + item.arg
        LoadTrackList({mode: "owner", query: item.arg, page: 1, pageSize: 20})
    else if target = "tag"
        m.viewStack.push({mode: "browse"})
        m.contentTitle.text = "#" + item.extra
        m.contentSubtitle.text = "Tracks tagged " + item.extra
        LoadTrackList({mode: "tag", query: item.arg, page: 1, pageSize: 20})
    else if target = "playlist"
        LoadPlaylistDetail(item.arg, item.extra)
    else if target = "toggleDebug"
        ToggleDebug()
    else if target = "atclamTest"
        StartAtclamTest()
    else if target = "syncJoin"
        StartSyncJoin()
    else if target = "syncStart"
        StartSyncLeader()
    else if target = "syncLeave"
        LeaveSync("left")
    else if target = "search"
        m.viewStack.push({mode: "browse"})
        m.contentTitle.text = item.extra
        m.contentSubtitle.text = ""
        LoadTrackList({mode: "search", query: item.arg, page: 1, pageSize: 20})
    else if target = "lib"
        m.viewStack.push({mode: "browse"})
        OpenLibrary(item.arg, item.extra)
    else if target = "collection"
        m.viewStack.push({mode: "browse"})
        m.contentTitle.text = item.extra
        m.contentSubtitle.text = "Select an experience to run it on what's playing"
        ApiRequest("lib:collection", "GET", "/api/collections/" + item.arg, invalid, "OnApiResponse")
    else if target = "experience"
        OpenExperience(item.arg, item.extra)
    else if target = "info"
        m.viewStack.push({mode: "browse"})
        OpenInfo(item.arg, item.extra)
    else if target = "text"
        m.viewStack.push({mode: "browse"})
        ShowText(item.extra, item.arg)
    end if
end sub

sub HandleAlbumDetailResponse(result as object)
    if not result.success or result.json = invalid or result.json.album = invalid
        ShowToast("Couldn't load that album.")
        return
    end if
    album = result.json.album
    tracks = album.tracks
    m.currentListTracks = tracks
    desc = OneLine(album.description, 100)
    m.contentSubtitle.text = "by " + Txt(album.owner_username)
    if desc <> "" then m.contentSubtitle.text = m.contentSubtitle.text + "  -  " + desc
    m.grid.content = BuildTrackContentNode(tracks, false)
    if tracks = invalid or tracks.Count() = 0
        m.grid.visible = false
        m.emptyStateLabel.visible = true
        m.emptyStateLabel.text = "This album has no tracks yet."
        RenderNavFocus()
    else
        m.grid.visible = true
        m.emptyStateLabel.visible = false
        FocusContent()
    end if
end sub

' ---- Info hub (Stats / Status / Changelog / Credits) -----------------------

sub ShowInfoMenu()
    m.textView.visible = false
    root = CreateObject("roSGNode", "ContentNode")
    AddCard(root, "Stats", "Listeners and users right now", "", "info", "stats", "Stats")
    AddCard(root, "Status", "Is ATMusic healthy?", "", "info", "status", "Status")
    AddCard(root, "Changelog", "What changed in each version", "", "info", "changelog", "Changelog")
    AddCard(root, "Credits", "Open-source projects and models that make ATMusic work", "", "info", "credits", "Credits")
    dbgState = "Off"
    if m.global.debugOn then dbgState = "On"
    AddCard(root, "Debug logging", "Sends diagnostic events (no passwords or tokens) to ATMusic while you're signed in; select to turn on/off", dbgState, "toggleDebug", "", "Debug logging")
    AddCard(root, "ATCLAM runtime self-test", "Runs the conformance suite on this device's BrightScript VM", "", "atclamTest", "", "ATCLAM self-test")
    AddCard(root, "About this app", "ATMusic for Roku", "v" + CreateObject("roAppInfo").GetVersion(), "text", "ATMusic for Roku" + Chr(10) + Chr(10) + "Browse and play everything on atmusic.atdevs.org from your TV." + Chr(10) + "Sign in with your ATMusic account to like, favorite and build playlists." + Chr(10) + Chr(10) + "Source: github.com/atdevs-team/atmusic-roku (GPLv3)", "About this app")
    m.currentListTracks = []
    m.grid.visible = true
    m.emptyStateLabel.visible = false
    m.grid.content = root
    if m.keepNavFocusOnce = true
        m.keepNavFocusOnce = false
    else
        FocusContent()
    end if
end sub

sub OpenInfo(what as string, title as string)
    m.contentTitle.text = title
    m.contentSubtitle.text = ""
    if what = "stats"
        ApiRequest("info:stats", "GET", "/api/system/stats/live", invalid, "OnApiResponse")
    else if what = "status"
        ApiRequest("info:status", "GET", "/api/system/status", invalid, "OnApiResponse")
    else if what = "changelog"
        ApiRequest("info:changelog", "GET", "/api/changelog?page_size=30", invalid, "OnApiResponse")
    else if what = "credits"
        ApiRequest("info:credits", "GET", "/api/credits", invalid, "OnApiResponse")
    end if
end sub

sub HandleInfoResponse(what as string, result as object)
    if not result.success or result.json = invalid
        ShowToast("Couldn't load that. Check your connection.")
        return
    end if
    j = result.json
    root = CreateObject("roSGNode", "ContentNode")
    if what = "stats"
        AddCard(root, Txt(j.connected_users) + " people connected now", Txt(j.connected_logged_in_users) + " signed in", "", "none", "")
        AddCard(root, Txt(j.listening_users) + " listening right now", Txt(j.logged_in_listening_users) + " signed in", "", "none", "")
        AddCard(root, Txt(j.total_users) + " registered users", "", "", "none", "")
        AddCard(root, Txt(j.online_instances) + " servers online", "", "", "none", "")
    else if what = "status"
        state = "All systems normal"
        if j.updating = true then state = "Updating - back shortly"
        AddCard(root, state, "Version " + Txt(j.version), "", "none", "")
        if j.presence <> invalid
            AddCard(root, Txt(j.presence.online_instances) + " servers online", Txt(j.presence.connected_users) + " people connected", "", "none", "")
        end if
    else if what = "changelog"
        for each e in j.entries
            AddCard(root, "v" + Txt(e.version) + "  " + Txt(e.title), OneLine(e.body, 120), Left(Txt(e.created_at), 10), "text", Txt(e.body), "v" + Txt(e.version) + "  " + Txt(e.title))
        end for
    else if what = "credits"
        for each sec in j.sections
            AddCard(root, Txt(sec.title), OneLine(sec.intro, 110), "", "none", "")
            if sec.groups <> invalid
                for each g in sec.groups
                    if g.entries <> invalid
                        for each en in g.entries
                            AddCard(root, Txt(en.name), Txt(en.category) + "  -  " + Txt(en.author) + "  -  " + Txt(en.license), "", "text", Txt(en.name) + Chr(10) + Txt(en.category) + Chr(10) + Chr(10) + "By " + Txt(en.author) + Chr(10) + "License: " + Txt(en.license) + Chr(10) + Chr(10) + Txt(en.purpose) + Chr(10) + Chr(10) + Txt(en.url), Txt(en.name))
                        end for
                    end if
                end for
            end if
        end for
    end if
    ShowCards(root, "Nothing to show.")
end sub

sub ShowText(title as string, body as string)
    m.contentTitle.text = title
    m.contentSubtitle.text = ""
    m.grid.visible = false
    m.emptyStateLabel.visible = false
    m.textLabel.text = StripMd(body)
    m.textView.visible = true
end sub

' =========================================================== MFA login ==
' The backend answers a correct password on an MFA account with
' {mfa_required, pending_login_id, has_totp, has_webauthn}. On a TV there is no
' passkey authenticator, so: ask for the authenticator (TOTP) or a recovery
' code and resubmit; passkey-only accounts are pointed at phone (QR) login.

sub HandleMfaRequired(j as object)
    DLog("auth", "mfa required totp=" + (j.has_totp = true).ToStr() + " webauthn=" + (j.has_webauthn = true).ToStr())
    if j.has_totp <> true
        m.pendingLoginPassword = ""
        ShowToast("This account uses a passkey. Choose 'Log in with phone (QR)' instead.")
        RenderProfile()
        return
    end if
    m.mfaPendingId = Txt(j.pending_login_id)
    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = "Authenticator code (or a recovery code)"
    kb.buttons = ["Verify", "Cancel"]
    kb.ObserveField("buttonSelected", "OnMfaCodeButton")
    m.authDialog = kb
    m.top.GetScene().dialog = kb
end sub

sub OnMfaCodeButton()
    idx = m.authDialog.buttonSelected
    code = m.authDialog.text
    m.authDialog.close = true
    if idx <> 0 or code = ""
        m.pendingLoginPassword = ""
        return
    end if
    body = {username: m.pendingLoginUsername, password: m.pendingLoginPassword, pending_login_id: m.mfaPendingId}
    trimmed = code.Trim()
    isTotp = (Len(trimmed) = 6)
    if isTotp
        for i = 1 to 6
            c = Asc(Mid(trimmed, i, 1))
            if c < 48 or c > 57 then isTotp = false
        end for
    end if
    if isTotp
        body.totp_code = trimmed
    else
        body.recovery_code = trimmed
    end if
    ApiRequest("auth:login", "POST", "/api/auth/login", body, "OnApiResponse")
end sub

' ======================================================= phone (QR) login ==

sub StartQrLogin()
    DLog("auth", "qr login start")
    if m.qrBusy then return
    m.qrBusy = true
    m.qrStatus.text = "Getting a code..."
    m.qrPoster.uri = ""
    m.qrOverlay.visible = true
    m.focusRegion = "qr"
    m.top.setFocus(true)
    ApiRequest("qr:start", "POST", "/api/qr-login/start", {}, "OnApiResponse")
end sub

sub CloseQrLogin()
    DLog("auth", "qr login close")
    m.qrTimer.control = "stop"
    m.qrOverlay.visible = false
    m.qrToken = ""
    m.qrBusy = false
    ' hand focus back to the auth prompt / profile
    if m.currentUser = invalid
        m.focusRegion = "auth"
        m.authButtons.setFocus(true)
    else
        RenderProfile()
    end if
end sub

sub HandleQrResponse(what as string, result as object)
    if not m.qrOverlay.visible then return
    if what = "start"
        if not result.success or result.json = invalid or result.json.token = invalid
            m.qrStatus.text = "Couldn't get a login code. Press Back and try again."
            m.qrBusy = false
            return
        end if
        m.qrToken = result.json.token
        prefix = "base64,"
        du = Txt(result.json.qr_data_url)
        b64At = Instr(1, du, prefix)
        if b64At > 0
            ba = CreateObject("roByteArray")
            ba.FromBase64String(Mid(du, b64At + Len(prefix)))
            m.qrCounter = m.qrCounter + 1
            path = "tmp:/qr" + m.qrCounter.ToStr() + ".png"
            ba.WriteFile(path)
            m.qrPoster.uri = path
            m.qrStatus.text = "Waiting for you to approve on your phone..."
        else
            m.qrStatus.text = "Open this on your phone: " + Txt(result.json.login_url)
        end if
        m.qrBusy = false
        m.qrTimer.control = "start"
    else if what = "status"
        m.qrBusy = false
        if result.json = invalid then return
        st = Txt(result.json.status)
        if st <> "pending" then DLog("auth", "qr status=" + st)
        if st = "confirmed"
            m.qrTimer.control = "stop"
            m.qrStatus.text = "Approved. Logging in..."
            ApiRequest("qr:claim", "POST", "/api/qr-login/claim", {token: m.qrToken}, "OnApiResponse")
        else if st = "expired" or st = "not_found" or st = "claimed"
            m.qrTimer.control = "stop"
            m.qrStatus.text = "That code expired. Press Back, then try again."
        end if
    else if what = "claim"
        if result.success and result.json <> invalid and result.json.user <> invalid
            m.currentUser = result.json.user
            DLog("auth", "qr login ok")
            SyncDebugSender()
            CloseQrLogin()
            ShowToast("Welcome, " + m.currentUser.username + ".")
            if m.navSections[m.navIndex] = "Profile" then RenderProfile()
            if m.navSections[m.navIndex] = "Playlists" then ActivateNavItem(m.navIndex)
            if m.navSections[m.navIndex] = "Favorites" then ActivateNavItem(m.navIndex)
        else
            msg = "Login failed. Press Back and try again."
            if result.json <> invalid and result.json.error <> invalid then msg = result.json.error
            m.qrStatus.text = msg
        end if
    end if
end sub

sub OnQrTimer()
    if m.qrToken = "" or m.qrBusy then return
    m.qrBusy = true
    ApiRequest("qr:status", "GET", "/api/qr-login/status/" + m.qrToken, invalid, "OnApiResponse")
end sub

' ============================================================== library ==

sub ShowLibraryMenu()
    m.textView.visible = false
    root = CreateObject("roSGNode", "ContentNode")
    AddCard(root, "Genres", "Browse by genre", "", "lib", "genres", "Genres")
    AddCard(root, "Moods", "Browse by mood", "", "lib", "moods", "Moods")
    AddCard(root, "Artists", "Everyone with tracks on ATMusic", "", "lib", "artists", "Artists")
    AddCard(root, "Recently Added", "The newest tracks", "", "lib", "added", "Recently Added")
    AddCard(root, "Most Played", "What everyone is listening to", "", "lib", "most", "Most Played")
    AddCard(root, "Collections", "Groups of ATCLAM experiences (visualizers) - open one while a track plays", "", "lib", "collections", "Collections")
    AddCard(root, "Recently Played", "What you listened to lately (needs login)", "", "lib", "played", "Recently Played")
    m.currentListTracks = []
    m.grid.visible = true
    m.emptyStateLabel.visible = false
    m.grid.content = root
    if m.keepNavFocusOnce = true
        m.keepNavFocusOnce = false
    else
        FocusContent()
    end if
end sub

sub OpenLibrary(what as string, title as string)
    m.contentTitle.text = title
    m.contentSubtitle.text = ""
    if what = "genres"
        ApiRequest("lib:genres", "GET", "/api/library/genres", invalid, "OnApiResponse")
    else if what = "moods"
        ApiRequest("lib:moods", "GET", "/api/library/moods", invalid, "OnApiResponse")
    else if what = "artists"
        ApiRequest("lib:artists", "GET", "/api/library/artists", invalid, "OnApiResponse")
    else if what = "collections"
        ApiRequest("lib:collections", "GET", "/api/collections/discover?page_size=50", invalid, "OnApiResponse")
    else if what = "added"
        ApiRequest("lib:tracks", "GET", "/api/library/recently-added", invalid, "OnApiResponse")
    else if what = "most"
        ApiRequest("lib:tracks", "GET", "/api/library/most-played", invalid, "OnApiResponse")
    else if what = "played"
        if m.currentUser = invalid
            m.viewStack.pop()
            ShowToast("Log in to see what you played.")
            return
        end if
        ApiRequest("lib:tracks", "GET", "/api/library/recently-played", invalid, "OnApiResponse")
    end if
end sub

sub HandleLibraryResponse(what as string, result as object)
    if not result.success or result.json = invalid
        ShowToast("Couldn't load that. Check your connection.")
        return
    end if
    j = result.json
    if what = "tracks"
        m.currentListTracks = j.tracks
        m.grid.content = BuildTrackContentNode(j.tracks, false)
        if j.tracks = invalid or j.tracks.Count() = 0
            m.grid.visible = false
            m.emptyStateLabel.visible = true
            m.emptyStateLabel.text = "Nothing here yet."
            RenderNavFocus()
        else
            m.grid.visible = true
            m.emptyStateLabel.visible = false
            FocusContent()
        end if
        return
    end if
    root = CreateObject("roSGNode", "ContentNode")
    if what = "genres"
        for each g in j.genres
            AddCard(root, Txt(g.name), "", Txt(g.count) + " tracks", "search", Txt(g.name), Txt(g.name))
        end for
        ShowCards(root, "No genres yet.")
    else if what = "moods"
        for each md in j.moods
            AddCard(root, Txt(md.name), "", Txt(md.count) + " tracks", "search", Txt(md.name), Txt(md.name))
        end for
        ShowCards(root, "No moods yet.")
    else if what = "collections"
        for each c in j.collections
            AddCard(root, Txt(c.name), "by " + Txt(c.owner_username), Txt(c.experience_count) + " items", "collection", Txt(c.id), Txt(c.name))
        end for
        ShowCards(root, "No public collections yet.")
    else if what = "collection"
        co = j.collection
        if co <> invalid and co.experiences <> invalid
            for each ex in co.experiences
                AddCard(root, Txt(ex.title), OneLine(ex.description, 110), "", "experience", Txt(ex.id), Txt(ex.title))
            end for
        end if
        ShowCards(root, "This collection has no experiences yet.")
    else if what = "artists"
        for each a in j.artists
            AddCard(root, Txt(a.name), Txt(a.total_plays) + " plays", Txt(a.track_count) + " tracks", "search", Txt(a.name), Txt(a.name))
        end for
        ShowCards(root, "No artists yet.")
    end if
end sub

' ======================================================== debug logging ==
' DebugTask (background thread) batches DLog() entries; they are POSTed to the
' same /api/debug/logs endpoint the website's debug mode uses. Needs a login
' (until then entries wait in the task's bounded buffer).

sub SyncDebugSender()
    m.debugTask.canSend = (m.currentUser <> invalid and m.global.debugOn = true and m.debugBlocked <> true)
end sub

sub OnDebugBatch(event as object)
    if m.currentUser = invalid or m.global.debugOn <> true then return
    ApiRequest("debug:send", "POST", "/api/debug/logs", event.GetData(), "OnApiResponse")
end sub

sub HandleDebugResponse(result as object)
    if result.success then return
    print "[atm] debug upload failed code=" + result.code.ToStr()
    if result.code = 503 or result.code = 401 or result.code = 403
        ' storage low / not allowed / session gone: stop sending until next launch or login
        m.debugBlocked = true
        SyncDebugSender()
    end if
end sub

sub ToggleDebug()
    on = (m.global.debugOn <> true)
    reg = CreateObject("roRegistrySection", "atmusic")
    if on then reg.Write("debug", "1") else reg.Write("debug", "0")
    reg.Flush()
    DLog("info", "debug logging " + on.ToStr())
    m.global.debugOn = on
    m.debugBlocked = false
    SyncDebugSender()
    ShowToast("Debug logging " + iif(on, "on", "off"))
    ShowInfoMenu()
end sub

function iif(c as boolean, a as string, b as string) as string
    if c then return a
    return b
end function

' ================================================================ sync ==
' ATMusic Sync follower: join a session by code; the TV plays the leader's
' track and keeps its position matched. Follows the web client's lessons
' (see js/playsync.js): measure drift over time, only seek when clearly off,
' and back off after each seek so it can never become a seek storm.

sub ShowSyncMenu()
    m.textView.visible = false
    root = CreateObject("roSGNode", "ContentNode")
    if m.syncActive
        n = 0
        if m.syncState <> invalid and m.syncState.listener_count <> invalid then n = m.syncState.listener_count
        if m.syncRole = "leader"
            AddCard(root, "Session code: " + m.syncCode, "You are the leader - " + Txt(n) + " listening. Play something and everyone follows.", "", "none", "")
            AddCard(root, "End session", "Stop sharing", "", "syncLeave", "")
        else
            AddCard(root, "Synced to session " + m.syncCode, Txt(n) + " listening  -  drift " + m.syncDriftMs.ToStr() + " ms", "", "none", "")
            AddCard(root, "Leave session", "Keep playing, but stop following the leader", "", "syncLeave", "")
        end if
    else
        AddCard(root, "Start a session", "Share what this TV plays; others join with the code shown here", "", "syncStart", "")
        AddCard(root, "Join a session", "Enter the code shown on the leader's device (ATMusic Sync)", "", "syncJoin", "")
    end if
    m.currentListTracks = []
    m.grid.visible = true
    m.emptyStateLabel.visible = false
    m.grid.content = root
    if m.keepNavFocusOnce = true
        m.keepNavFocusOnce = false
    else
        FocusContent()
    end if
end sub

sub StartSyncJoin()
    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = "Session code"
    kb.buttons = ["Join", "Cancel"]
    kb.ObserveField("buttonSelected", "OnSyncCodeButton")
    m.authDialog = kb
    m.top.GetScene().dialog = kb
end sub

sub OnSyncCodeButton()
    idx = m.authDialog.buttonSelected
    code = m.authDialog.text.Trim().Replace(" ", "")
    m.authDialog.close = true
    if idx <> 0 or code = "" then return
    DLog("sync", "join requested")
    m.syncJoinCode = UCase(code)
    ApiRequest("sync:join", "POST", "/api/playsync/" + UrlEncode(m.syncJoinCode) + "/join", {client_id: m.clientId, name: "Roku TV"}, "OnApiResponse")
end sub

sub HandleSyncResponse(what as string, result as object)
    if what = "join"
        if result.success and result.json <> invalid and result.json.session <> invalid
            m.syncCode = m.syncJoinCode
            m.syncRole = "follower"
            m.syncActive = true
            m.syncState = result.json.session
            m.syncTrackId = ""
            m.syncStable = 0
            m.syncBackoffMs = 6000
            m.syncLastSeekMs = 0
            m.syncClock.Mark()
            m.syncTimer.control = "start"
            DLog("sync", "joined code=" + m.syncCode)
            ShowToast("Synced to " + m.syncCode)
            if m.navSections[m.navIndex] = "Sync" then ShowSyncMenu()
        else
            msg = "Couldn't join that session."
            if result.json <> invalid and result.json.error <> invalid then msg = result.json.error
            DLog("sync", "join failed: " + msg)
            ShowToast(msg)
        end if
    else if what = "create"
        if result.success and result.json <> invalid and result.json.session <> invalid
            ses = result.json.session
            m.syncCode = Txt(ses.code)
            m.syncRole = "leader"
            m.syncEpoch = ses.session_epoch
            m.syncActive = true
            m.syncState = ses
            m.syncTimer.control = "start"
            DLog("sync", "leading code=" + m.syncCode)
            ShowToast("Session code: " + m.syncCode)
            if m.navSections[m.navIndex] = "Sync" then ShowSyncMenu()
        else
            ShowToast("Couldn't start a session.")
        end if
    else if what = "poll"
        m.syncBusy = false
        m.syncRtt = m.syncPollClock.TotalMilliseconds()
        if not result.success or result.json = invalid then return
        ps = result.json.playsync
        if ps = invalid then return
        if ps.active = false
            LeaveSync("session ended")
            return
        end if
        m.syncState = ps
        if m.syncRole = "follower" then ApplySyncState(ps)
    else if what = "track"
        if result.success and result.json <> invalid and result.json.track <> invalid
            t = result.json.track
            m.queue = [{
                id: Txt(t.id), title: Txt(t.title), artist: Txt(t.artist_name)
                coverUrl: ResolveApiUrl(t.cover_url), url: ResolveApiUrl(t.stream_url)
                likesCount: t.likes, dislikesCount: t.dislikes, myLike: t.my_like, isFavorited: (t.is_favorited = true)
            }]
            m.queueIndex = 0
            m.syncPending = true
            PlayCurrentQueueItem()
        else
            DLog("error", "sync: couldn't load leader's track")
            m.syncTrackId = ""
        end if
    end if
end sub

sub OnSyncTick()
    if not m.syncActive or m.syncBusy then return
    m.syncBusy = true
    m.syncPollClock = CreateObject("roTimespan")
    curPos = 0.0
    if m.audio <> invalid and m.currentTrack <> invalid and m.audio.position <> invalid then curPos = m.audio.position
    body = {client_id: m.clientId, playsync_code: m.syncCode, playsync_name: "Roku TV", playsync_pos: curPos, playsync_drift_ms: m.syncDriftMs}
    if m.syncRole = "leader"
        tid = ""
        stt = "paused"
        if m.currentTrack <> invalid and m.audio <> invalid
            tid = m.currentTrack.id
            if m.audio.state = "playing" then stt = "playing"
        end if
        body = {client_id: m.clientId, playsync_code: m.syncCode, playsync_master: {track_id: tid, playback_state: stt, position: curPos, epoch: m.syncEpoch}}
    end if
    ApiRequest("sync:poll", "POST", "/api/system/sync", body, "OnApiResponse")
end sub

sub ApplySyncState(ps as object)
    tid = Txt(ps.current_track)
    if tid = "" then return
    playing = (Txt(ps.playback_state) = "playing")

    ' leader changed track -> load it
    if tid <> m.syncTrackId
        m.syncTrackId = tid
        DLog("sync", "leader track " + tid + " state=" + Txt(ps.playback_state))
        ApiRequest("sync:track", "GET", "/api/tracks/" + tid, invalid, "OnApiResponse")
        return
    end if
    if m.audio = invalid or m.currentTrack = invalid or m.currentTrack.id <> tid then return

    ' where the leader is right now, using the SERVER's clock for both ends (no client clock needed),
    ' plus half the poll round trip for the response's flight time
    target = ps.master_position
    if playing
        target = target + (ps.server_time_ms - ps.master_timestamp) / 1000.0 + (m.syncRtt / 2000.0)
    end if
    state = m.audio.state

    if not playing
        if state = "playing" then m.audio.control = "pause"
        m.syncDriftMs = 0
        return
    end if
    if state = "paused" then m.audio.control = "resume"
    if state <> "playing" and not m.syncPending then return

    drift = m.audio.position - target          ' + = we are ahead
    m.syncDriftMs = Int(drift * 1000)
    absMs = Abs(m.syncDriftMs)
    nowMs = m.syncClock.TotalMilliseconds()

    if m.syncPending and state = "playing"
        m.syncPending = false
        m.audio.seek = target + 0.4
        m.syncLastSeekMs = nowMs
        DLog("sync", "initial seek to " + target.ToStr())
        return
    end if

    if absMs < 500
        m.syncStable = m.syncStable + 1
        if m.syncStable > 10 then m.syncBackoffMs = 6000
        return
    end if
    m.syncStable = 0
    if absMs > 1500 and (nowMs - m.syncLastSeekMs) > m.syncBackoffMs
        DLog("sync", "seek drift=" + m.syncDriftMs.ToStr() + "ms backoff=" + m.syncBackoffMs.ToStr())
        m.audio.seek = target + 0.4
        m.syncLastSeekMs = nowMs
        m.syncBackoffMs = m.syncBackoffMs * 2
        if m.syncBackoffMs > 30000 then m.syncBackoffMs = 30000
    end if
end sub

sub LeaveSync(reason as string)
    if m.syncActive
        ApiRequest("sync:leave", "POST", "/api/playsync/" + UrlEncode(m.syncCode) + "/leave", {client_id: m.clientId}, "OnApiResponse")
    end if
    DLog("sync", "leave: " + reason)
    m.syncActive = false
    m.syncTimer.control = "stop"
    m.syncCode = ""
    m.syncTrackId = ""
    m.syncPending = false
    ShowToast("Sync " + reason)
    if m.navSections[m.navIndex] = "Sync" then ShowSyncMenu()
end sub

' ============================================================== lyrics ==
' Lyrics for the playing track (GET /api/tracks/<id>/lyrics -> lines [{t,text}]).
' Synced lyrics follow audio.position; unsynced ones can be scrolled with up/down.

sub OpenLyrics()
    if m.currentTrack = invalid then return
    DLog("lyrics", "open id=" + m.currentTrack.id)
    ApiRequest("lyrics:get", "GET", "/api/tracks/" + m.currentTrack.id + "/lyrics", invalid, "OnApiResponse")
end sub

sub HandleLyricsResponse(result as object)
    if not result.success or result.json = invalid
        ShowToast("Couldn't load lyrics.")
        return
    end if
    ly = result.json.lyrics
    if ly = invalid or ly.lines = invalid or ly.lines.Count() = 0
        DLog("lyrics", "none for this track")
        ShowToast("No lyrics for this track yet.")
        return
    end if
    ShowLyrics(ly.lines, ly.synced = true)
end sub

sub ShowLyrics(lines as object, synced as boolean)
    m.lyLines = lines
    m.lySynced = synced
    m.lyScroll = 0
    m.lyIndex = -2
    m.top.findNode("lyTitle").text = m.currentTrack.title
    m.top.findNode("lyArtist").text = m.currentTrack.artist
    for each n in ["lyPrev2", "lyPrev", "lyCur", "lyNext", "lyNext2"]
        m.top.findNode(n).visible = synced
    end for
    m.top.findNode("lyAll").visible = not synced
    m.top.findNode("lyHint").text = "Press Back to close"
    if not synced then m.top.findNode("lyHint").text = "Up/Down to scroll  -  Back to close"
    m.lyOverlay.visible = true
    m.lyOverlay.setFocus(true)
    DLog("lyrics", "show lines=" + lines.Count().ToStr() + " synced=" + synced.ToStr())
    if synced
        OnLyricsTick()
        m.lyTimer.control = "start"
    else
        RenderUnsyncedLyrics()
    end if
end sub

sub CloseLyrics()
    m.lyTimer.control = "stop"
    m.lyOverlay.visible = false
    DLog("lyrics", "close")
    if m.nowPlayingOverlayVisible then m.npButtons.setFocus(true)
end sub

sub RenderUnsyncedLyrics()
    txt = ""
    last = m.lyScroll + 13
    if last > m.lyLines.Count() - 1 then last = m.lyLines.Count() - 1
    for i = m.lyScroll to last
        txt = txt + Txt(m.lyLines[i].text) + Chr(10)
    end for
    m.top.findNode("lyAll").text = txt
end sub

function LyricLine(i as integer) as string
    if i < 0 or i >= m.lyLines.Count() then return ""
    return Txt(m.lyLines[i].text)
end function

sub OnLyricsTick()
    if not m.lySynced or m.audio = invalid then return
    p = m.audio.position
    idx = -1
    for i = 0 to m.lyLines.Count() - 1
        t = m.lyLines[i].t
        if t <> invalid and t <= p then idx = i else if t <> invalid and t > p then exit for
    end for
    if idx = m.lyIndex then return
    m.lyIndex = idx
    m.top.findNode("lyPrev2").text = LyricLine(idx - 2)
    m.top.findNode("lyPrev").text = LyricLine(idx - 1)
    m.top.findNode("lyCur").text = LyricLine(idx)
    m.top.findNode("lyNext").text = LyricLine(idx + 1)
    m.top.findNode("lyNext2").text = LyricLine(idx + 2)
end sub

sub StartSyncLeader()
    tid = ""
    if m.currentTrack <> invalid then tid = m.currentTrack.id
    DLog("sync", "start session as leader")
    ApiRequest("sync:create", "POST", "/api/playsync", {client_id: m.clientId, name: "Roku TV", track_id: tid}, "OnApiResponse")
end sub

' ================================================================ ATCLAM ==
sub StartAtclamAction(kind as string)
    DLog("atclam", "launch action " + kind)
    m.atclamTask = CreateObject("roSGNode", "AtclamTask")
    m.atclamTask.ObserveField("result", "OnAtclamResult")
    m.atclamTask.request = {kind: kind}
    m.atclamTask.control = "RUN"
end sub

sub StartAtclamTest()
    ShowToast("Running ATCLAM self-test...")
    m.atclamTask = CreateObject("roSGNode", "AtclamTask")
    m.atclamTask.ObserveField("result", "OnAtclamResult")
    m.atclamTask.request = {kind: "test"}
    m.atclamTask.control = "RUN"
end sub

sub OnAtclamResult(event as object)
    r = event.GetData()
    DLog("atclam", "result ok=" + r.ok.ToStr() + " " + Txt(r.text))
    m.viewStack.push({mode: "browse"})
    ShowText("ATCLAM self-test", Txt(r.text))
end sub

' ========================================================== visualizer ==
' Runs ATCLAM visualizer scripts ("visualizer.frame" handler) on the BrightScript VM
' (AtclamVm.brs) and draws their graphics.render / graphics.triangle host calls.
' Roku exposes no live audio analysis, so the script's inputs are DERIVED from the
' server's analysis of the playing track (waveform + spectrum + tempo), the same
' kind of data the website's analyser produces. The overlay says so.
' Scripts get a fuel budget per frame; host calls other than drawing are ignored here.

' Open a specific published script (e.g. from a Collection) in the visualizer.
sub OpenExperience(id as string, title as string)
    if m.currentTrack = invalid
        ShowToast("Play a track first - experiences run on what's playing.")
        return
    end if
    DLog("vis", "open experience " + id)
    m.visWantId = id
    if m.visReady
        for i = 0 to m.visModes.Count() - 1
            if m.visModes[i].id = id then m.visIndex = i
        end for
        m.visWantId = ""
    end if
    OpenVisualizer()
end sub

sub OpenVisualizer()
    if m.currentTrack = invalid then return
    DLog("vis", "open")
    if not m.visReady
        m.visModes = []
        raw = ReadAsciiFile("pkg:/data/builtin-visualizers.json")
        b = ParseJson(raw)
        if b <> invalid
            if b.spectrum_bars <> invalid then m.visModes.Push({id: "spectrum_bars", title: "Spectrum bars", b64: b.spectrum_bars})
            if b.waveform_pulse <> invalid then m.visModes.Push({id: "waveform_pulse", title: "Waveform pulse", b64: b.waveform_pulse})
        end if
        raw = ReadAsciiFile("pkg:/data/atclam-demos.json")
        dm = ParseJson(raw)
        if dm <> invalid
            for each k in dm
                m.visModes.Push({id: k, title: dm[k].title + " (demo)", b64: dm[k].bytecode_b64})
            end for
        end if
        m.visReady = true
        ApiRequest("vis:list", "GET", "/api/atclam/scripts/published?page=1", invalid, "OnApiResponse")
    end if
    m.visAnalysisFor = ""
    m.visAnalysis = invalid
    m.visHistory = []
    m.visOverlay.visible = true
    m.visOverlay.setFocus(true)
    SelectVisualizer(m.visIndex)
    m.visTimer.control = "start"
end sub

sub CloseVisualizer()
    m.visTimer.control = "stop"
    m.visOverlay.visible = false
    DLog("vis", "close")
    if m.nowPlayingOverlayVisible
        m.npButtons.setFocus(true)
    else
        m.grid.setFocus(true)
    end if
end sub

sub SwitchVisualizer(delta as integer)
    n = m.visModes.Count()
    if n = 0 then return
    m.visIndex = (m.visIndex + delta + n) mod n
    SelectVisualizer(m.visIndex)
end sub

sub SelectVisualizer(i as integer)
    if m.visModes.Count() = 0 then return
    mode = m.visModes[i]
    m.visCurrent = mode
    m.visTitle = m.top.findNode("visTitle")
    m.top.findNode("visTitle").text = mode.title
    m.top.findNode("visNote").text = "ATCLAM runtime on Roku (BrightScript VM). Data comes from the track's analysis, not live audio."
    m.top.findNode("visStatus").text = ""
    m.visLoaded = invalid
    m.visHistory = []
    m.visLinked = {}
    m.visLinked.SetModeCaseSensitive()
    m.visPendingLibs = 0
    m.visLastTrack = ""
    ClearVisStage()
    if mode.b64 <> invalid
        VisAcceptModule(mode.b64)
    else
        ApiRequest("vis:bytecode:" + mode.id, "GET", "/api/atclam/scripts/" + mode.id + "/bytecode", invalid, "OnApiResponse")
    end if
    DLog("vis", "mode " + mode.title)
end sub

sub ClearVisStage()
    while m.visStage.getChildCount() > 0
        m.visStage.removeChildIndex(0)
    end while
    m.visPoolUsed = 0
    m.visRectPool = []
    m.visSpanPool = []
end sub

sub HandleVisResponse(what as string, result as object)
    if what = "list"
        if result.success and result.json <> invalid and result.json.scripts <> invalid
            for each sc in result.json.scripts
                m.visModes.Push({id: Txt(sc.id), title: Txt(sc.title) + " (@" + Txt(sc.owner_username) + ")", b64: invalid})
            end for
            DLog("vis", "published scripts: " + result.json.scripts.Count().ToStr())
            if m.visWantId <> invalid and m.visWantId <> ""
                for i = 0 to m.visModes.Count() - 1
                    if m.visModes[i].id = m.visWantId
                        m.visIndex = i
                        SelectVisualizer(i)
                    end if
                end for
                m.visWantId = ""
            end if
        end if
    else if Left(what, 8) = "bytecode"
        if not m.visOverlay.visible then return
        if result.success and result.json <> invalid and result.json.bytecode_b64 <> invalid
            if Txt(result.json.runtime) = "server"
                m.top.findNode("visStatus").text = "This script runs on the server; not supported on Roku yet."
                return
            end if
            VisAcceptModule(result.json.bytecode_b64)
        else
            m.top.findNode("visStatus").text = "Couldn't download that script."
        end if
    else if what = "lib"
        parts = result.requestId.Split(":")
        m.visPendingLibs = m.visPendingLibs - 1
        if result.success and result.json <> invalid and result.json.bytecode_b64 <> invalid
            ld = AtclamLoad(result.json.bytecode_b64)
            if ld.ok then m.visLinked[parts[2]] = ld.module
            DLog("vis", "linked library " + parts[2] + " ok=" + ld.ok.ToStr())
        else
            DLog("error", "couldn't fetch library " + parts[2])
            m.top.findNode("visStatus").text = "Couldn't download library " + parts[2]
        end if
        if m.visPendingLibs <= 0 and m.visPendingModule <> invalid
            m.visLoaded = m.visPendingModule
            m.visPendingModule = invalid
        end if
    else if what = "analysis"
        if result.success and result.json <> invalid then m.visAnalysis = result.json.analysis
    end if
end sub

sub OnVisTick()
    if m.currentTrack = invalid or m.audio = invalid or m.visLoaded = invalid then return
    ' (re)load the track's analysis when the track changes
    if m.visAnalysisFor <> m.currentTrack.id
        m.visAnalysisFor = m.currentTrack.id
        m.visAnalysis = invalid
        ApiRequest("vis:analysis", "GET", "/api/tracks/" + m.currentTrack.id + "/analysis", invalid, "OnApiResponse")
    end if

    posS = m.audio.position
    level = 0.0#
    bands = [0.0#, 0.0#, 0.0#, 0.0#, 0.0#, 0.0#, 0.0#, 0.0#]
    an = m.visAnalysis
    if an <> invalid and an.waveform <> invalid and an.waveform.Count() > 0
        dur = m.audio.duration
        if dur = invalid or dur <= 0 then dur = 1
        wi = Int(posS / dur * an.waveform.Count())
        if wi < 0 then wi = 0
        if wi >= an.waveform.Count() then wi = an.waveform.Count() - 1
        level = an.waveform[wi][0] + 0.0#
        ' beat pulse from the tempo, so bars move with the music's pace
        bpm = 120.0#
        if an.bpm <> invalid then bpm = an.bpm + 0.0#
        pulse = 0.82# + 0.18# * Cos(6.2831853# * posS * bpm / 60.0#)
        sp = an.spectrum
        if sp <> invalid and sp.Count() >= 16
            for i = 0 to 7
                avg = (sp[i * 2] + sp[i * 2 + 1]) / 2.0#
                v = avg * (level / 60.0#) * pulse
                if v > 100 then v = 100
                if v < 0 then v = 0
                bands[i] = v
            end for
        end if
        level = level * pulse
    end if

    ctxValues = {}
    ctxValues.SetModeCaseSensitive()
    for i = 0 to 7
        ctxValues["atmusic.audio.band" + i.ToStr()] = bands[i]
    end for
    ctxValues["atmusic.audio.level"] = level
    ctxValues["atmusic.track.title"] = m.currentTrack.title
    ctxValues["atmusic.track.artist"] = m.currentTrack.artist
    ctxValues["atmusic.playback.position"] = posS + 0.0#

    VisRunTrackEvents()
    ctx = AtclamNewContext(ctxValues, {}, 6000)
    ctx.linked = m.visLinked
    res = AtclamExecuteHandlersForEvent(m.visLoaded, ["visualizer", "frame"], ctx)
    if not res.ok
        m.top.findNode("visStatus").text = "Script stopped: " + res.kind + " - " + res.msg
        DLog("vis", "script error " + res.kind)
        m.visTimer.control = "stop"
        return
    end if
    DrawVisHostCalls(res.host_calls, level)
end sub

sub DrawVisHostCalls(calls as object, level as dynamic)
    tris = []
    renderCall = invalid
    for each hc in calls
        if hc.name = "graphics.triangle" and hc.args.Count() = 6
            tris.Push(hc.args)
        else if hc.name = "graphics.render" and renderCall = invalid
            renderCall = hc
        end if
    end for
    m.visPoolUsed = 0
    if tris.Count() > 0 then DrawVisTriangles(tris)
    if renderCall <> invalid
        if renderCall.args.Count() > 1
            DrawVisBars(renderCall.args)
        else if renderCall.args.Count() = 1
            DrawVisWave(renderCall.args[0])
        end if
    end if
    ' hide strips not used this frame
    for i = m.visPoolUsed to m.visSpanPool.Count() - 1
        m.visSpanPool[i].visible = false
    end for
end sub

function VisRect(i as integer) as object
    while m.visRectPool.Count() <= i
        r = CreateObject("roSGNode", "Rectangle")
        r.color = "0x1F9E90FF"
        m.visStage.appendChild(r)
        m.visRectPool.Push(r)
    end while
    return m.visRectPool[i]
end function

sub DrawVisBars(vals as object)
    n = vals.Count()
    if n > 32 then n = 32
    stageW = 1264
    stageH = 560
    gap = 16
    bw = (stageW - gap * (n + 1)) / n
    for i = 0 to n - 1
        v = vals[i]
        if v = invalid then v = 0
        if v < 0 then v = 0
        if v > 100 then v = 100
        h = Int(v / 100.0 * (stageH - 8))
        r = VisRect(i)
        r.visible = true
        r.width = Int(bw)
        r.height = h
        r.translation = [gap + i * (bw + gap), stageH - h]
    end for
    for i = n to m.visRectPool.Count() - 1
        m.visRectPool[i].visible = false
    end for
end sub

sub DrawVisWave(level as dynamic)
    if level = invalid then level = 0
    m.visHistory.Push(level)
    maxN = 64
    if m.visHistory.Count() > maxN then m.visHistory.Shift()
    stageW = 1264
    stageH = 560
    bw = stageW / maxN
    for i = 0 to m.visHistory.Count() - 1
        v = m.visHistory[i]
        if v < 0 then v = 0
        if v > 100 then v = 100
        h = Int(v / 100.0 * (stageH - 8))
        r = VisRect(i)
        r.visible = true
        r.width = Int(bw) - 3
        r.height = h
        r.translation = [i * bw, (stageH - h) / 2]
    end for
end sub

' graphics.triangle coordinates live in the website's 316x140 canvas space; scale to the stage.
' Roku has no polygon node, so each triangle is rasterized into thin horizontal strips
' (Rectangle nodes, drawn in call order so overlaps layer like the website's canvas).
sub DrawVisTriangles(tris as object)
    sx = 1264 / 316.0
    sy = 560 / 140.0
    ' strip height adapts to how much there is to draw so a busy frame can't run out of strips
    totalH = 0.0
    for each a0 in tris
        for k = 0 to 2
            if type(a0[k]) = "roArray" and a0[k].Count() >= 2 and a0[k][1] <> invalid
                if k = 0 then lo = a0[k][1] + 0.0 : hi = lo
                y = a0[k][1] + 0.0
                if y < lo then lo = y
                if y > hi then hi = y
            end if
        end for
        totalH = totalH + (hi - lo)
    end for
    stepY = 2.0
    if totalH / 900.0 > stepY then stepY = totalH / 900.0
    used = 0
    for each a in tris
        pts = []
        for k = 0 to 2
            p = a[k]
            if type(p) = "roArray" and p.Count() >= 2 and p[0] <> invalid and p[1] <> invalid
                pts.Push([p[0] + 0.0, p[1] + 0.0])
            else
                pts.Push([0.0, 0.0])
            end if
        end for
        ymin = pts[0][1]
        ymax = pts[0][1]
        for k = 1 to 2
            if pts[k][1] < ymin then ymin = pts[k][1]
            if pts[k][1] > ymax then ymax = pts[k][1]
        end for
        col = "0x" + Hex2(a[3]) + Hex2(a[4]) + Hex2(a[5]) + "FF"
        yc = ymin + stepY / 2
        while yc < ymax and used < 1100
            xl = 100000.0
            xr = -100000.0
            for e = 0 to 2
                p0 = pts[e]
                p1 = pts[(e + 1) mod 3]
                if (p0[1] <= yc and yc < p1[1]) or (p1[1] <= yc and yc < p0[1])
                    x = p0[0] + (yc - p0[1]) * (p1[0] - p0[0]) / (p1[1] - p0[1])
                    if x < xl then xl = x
                    if x > xr then xr = x
                end if
            end for
            if xr > xl
                while m.visSpanPool.Count() <= used
                    r = CreateObject("roSGNode", "Rectangle")
                    m.visStage.appendChild(r)
                    m.visSpanPool.Push(r)
                end while
                r = m.visSpanPool[used]
                used = used + 1
                r.visible = true
                r.color = col
                r.translation = [Int(xl * sx), Int((yc - stepY / 2) * sy)]
                r.width = Int((xr - xl) * sx) + 1
                r.height = Int(stepY * sy) + 1
            end if
            yc = yc + stepY
        end while
    end for
    m.visPoolUsed = used
end sub

function Hex2(v as dynamic) as string
    n = 0
    if v <> invalid then n = Int(v)
    if n < 0 then n = 0
    if n > 255 then n = 255
    h = "0123456789ABCDEF"
    return Mid(h, Int(n / 16) + 1, 1) + Mid(h, (n mod 16) + 1, 1)
end function

' Load a script's bytecode; if it imports libraries (spec 6.11), fetch each pinned library's
' bytecode first (same public endpoint the website uses) and only then make it runnable.
sub VisAcceptModule(b64 as string)
    ld = AtclamLoad(b64)
    if not ld.ok
        m.top.findNode("visStatus").text = "Can't load this script: " + ld.msg
        return
    end if
    imports = ld.module.imports
    pending = 0
    if imports <> invalid
        for each imp in imports
            if imp.name <> invalid and imp.version <> invalid and imp.version <> ""
                pending = pending + 1
                ApiRequest("vis:lib:" + imp.name + ":" + imp.version, "GET", "/api/atclam/libraries/by-name/" + UrlEncode(imp.name) + "/" + UrlEncode(imp.version) + "/bytecode", invalid, "OnApiResponse")
            end if
        end for
    end if
    if pending = 0
        m.visLoaded = ld.module
    else
        m.visPendingLibs = pending
        m.visPendingModule = ld.module
    end if
end sub

' Event handlers other than visualizer.frame (track.started, ...) run once per track change.
' Draw calls aren't meaningful there; the result (host calls / storage ops) is summarized on screen.
sub VisRunTrackEvents()
    if m.currentTrack.id = m.visLastTrack then return
    m.visLastTrack = m.currentTrack.id
    ctxValues = {}
    ctxValues.SetModeCaseSensitive()
    ctxValues["atmusic.track.title"] = m.currentTrack.title
    ctxValues["atmusic.track.artist"] = m.currentTrack.artist
    ctx = AtclamNewContext(ctxValues, {}, 6000)
    ctx.linked = m.visLinked
    res = AtclamExecuteHandlersForEvent(m.visLoaded, ["track", "started"], ctx)
    if not res.ok
        m.top.findNode("visStatus").text = "track.started error: " + res.kind + " - " + res.msg
        return
    end if
    if res.host_calls.Count() > 0 or res.storage_ops.Count() > 0
        txt = "track.started ran: " + res.host_calls.Count().ToStr() + " host call(s), " + res.storage_ops.Count().ToStr() + " storage op(s)"
        if res.host_calls.Count() > 0 then txt = txt + "  [" + res.host_calls[0].name + "(" + AtclamShow(res.host_calls[0].args[0]) + ")]"
        m.top.findNode("visStatus").text = txt
        DLog("vis", txt)
    end if
end sub
