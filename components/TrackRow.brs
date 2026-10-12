' ============================================================================
' TrackRow.brs
'
' One item renderer, reused for every kind of row the app shows in a
' MarkupGrid: tracks (feed/trending/search/favorites/playlist contents),
' playlists (the playlists list), and a synthetic "Load more" row for
' pagination. Which one it is comes from itemContent.kind.
' ============================================================================

sub init()
    m.rowBg = m.top.findNode("rowBg")
    m.focusBg = m.top.findNode("focusBg")
    m.nowPlayingBar = m.top.findNode("nowPlayingBar")
    m.cover = m.top.findNode("cover")
    m.coverFallback = m.top.findNode("coverFallback")
    m.titleLabel = m.top.findNode("titleLabel")
    m.subtitleLabel = m.top.findNode("subtitleLabel")
    m.metaLabel = m.top.findNode("metaLabel")
    m.favLabel = m.top.findNode("favLabel")
end sub

sub onContentChange()
    content = m.top.itemContent
    if content = invalid then return

    kind = content.kind

    if kind = "loadMore"
        m.titleLabel.text = content.title
        m.titleLabel.color = "0x4FD1C5FF"
        m.subtitleLabel.text = ""
        m.metaLabel.text = ""
        m.favLabel.text = ""
        m.cover.visible = false
        m.coverFallback.visible = false
        m.nowPlayingBar.visible = false
        return
    end if

    m.titleLabel.color = "0xFFFFFFFF"
    m.titleLabel.text = content.title

    if kind = "playlist" or kind = "card"
        m.subtitleLabel.text = content.subtitle
        m.metaLabel.text = content.meta
        m.favLabel.text = ""
        m.cover.visible = false
        m.coverFallback.visible = true
        m.nowPlayingBar.visible = false
        return
    end if

    ' kind = "track" (default)
    m.subtitleLabel.text = content.subtitle
    m.metaLabel.text = content.meta

    if content.isFavorited = true
        m.favLabel.text = "* Favorited"
    else
        m.favLabel.text = ""
    end if

    if content.coverUrl <> invalid and content.coverUrl <> ""
        m.cover.uri = content.coverUrl
        m.cover.visible = true
        m.coverFallback.visible = false
    else
        m.cover.visible = false
        m.coverFallback.visible = true
    end if

    m.nowPlayingBar.visible = (content.isPlaying = true)
end sub

sub onFocusChange()
    pct = m.top.focusPercent
    m.focusBg.visible = (pct > 0.01)
    m.focusBg.opacity = pct
end sub
