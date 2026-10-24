#Requires AutoHotkey v2.0

class BrowserScraper {
    static EnsureBrowserReady() {
        browserClass := "ahk_exe msedge.exe"
        if !WinExist(browserClass)
            browserClass := "ahk_exe chrome.exe"

        if !WinExist(browserClass) {
            Run("msedge.exe about:blank")
            if WinWait("ahk_exe msedge.exe", , 6) {
                browserClass := "ahk_exe msedge.exe"
                Sleep(800)
            } else {
                return 0
            }
        }
        hwnd := WinExist(browserClass)
        WinActivate("ahk_id " . hwnd)
        if !WinWaitActive("ahk_id " . hwnd, , 3)
            return 0
        return hwnd
    }

    static Navigate(hwnd, url) {
        WinActivate("ahk_id " . hwnd)
        if !WinWaitActive("ahk_id " . hwnd, , 2)
            throw Error("브라우저 창을 활성화할 수 없습니다.")
        Sleep(150)
        Send("^l")
        Sleep(120)
        A_Clipboard := url
        ClipWait(1)
        Send("^v{Enter}")
    }

    static FetchText(hwnd) {
        Sleep(2200)
        Loop 8 {
            WinActivate("ahk_id " . hwnd)
            if !WinWaitActive("ahk_id " . hwnd, , 2)
                throw Error("브라우저 창을 활성화할 수 없습니다.")
            Send("{Escape}")
            A_Clipboard := ""
            Send("^a")
            Sleep(120)
            Send("^c")

            if ClipWait(1.5) {
                txt := A_Clipboard
                if InStr(txt, "Just a moment...") || InStr(txt, "Checking if the site connection is secure") {
                    Sleep(2000)
                    continue
                }
                if (StrLen(txt) > 200 || this.IsError(txt))
                    return txt
            }
            Sleep(800)
        }
        throw Error("페이지를 읽지 못했거나 보안 확인이 끝나지 않았습니다.")
    }

    static IsError(txt) {
        if (txt == "")
            return false
        patterns := [
            "i)Error\s*(404|520|521|522|523|524)",
            "i)Connection\s*timed\s*out",
            "i)Host\s*Error",
            "i)Web\s*server\s*is\s*down",
            "i)404\s*Not\s*Found",
            "i)Nothing\s*Found",
            "i)Page\s*Not\s*Found",
            "i)No\s*posts\s*matched"
        ]
        for p in patterns {
            if RegExMatch(txt, p)
                return true
        }
        return false
    }

    ; --- [MAXJAV 검색] ---
    static QueryMaxjav(hwnd, dvdId) {
        this.Navigate(hwnd, "https://maxjav.com/?s=" . dvdId)
        txt := this.FetchText(hwnd)
        if (txt == "" || this.IsError(txt))
            return ""

        return this.ParseActressFromText(txt, dvdId)
    }

    static ParseActressFromText(txt, dvdId) {
        parts := StrSplit(dvdId, "-")
        prefix := parts[1]
        num := parts[2]
        dvdPattern := "i)(?:\[)?\b" . prefix . "[-_ ]?" . num . "(?![A-Z0-9])(?:\])?\s*([^\r\n]+)"

        for rawLine in StrSplit(txt, "`n", "`r") {
            lineStr := Trim(rawLine)
            if (lineStr == "" || RegExMatch(lineStr, "i)^(search|query|find|tag|category|view|filter)"))
                continue

            if RegExMatch(lineStr, dvdPattern, &m) {
                afterDvd := RegExReplace(Trim(m[1]), "\[[^\]]*\]", " ")
                tokens := []
                for item in StrSplit(afterDvd, [" ", "_", "-", "/", "|", ":", ",", " "]) {
                    c := Trim(item)
                    if (c == "")
                        continue
                    if RegExMatch(c, "i)^(VR|4K|8K|FHD|HD|60FPS|180|360|UNCENSORED|LEAKED|PART\d*|DISC\d*|JAV|SUB|KOR|ENG|MP4|MKV)$")
                        continue
                    if RegExMatch(c, "^[A-Za-z]{2,}$")
                        tokens.Push(this.FormatWord(c))
                    if (tokens.Length >= 3)
                        break
                }

                if (tokens.Length == 0)
                    continue
                if (tokens.Length == 1)
                    return tokens[1]

                w1 := tokens[1], w2 := tokens[2]
                if RegExMatch(w2, "i)^(Special|Vol|Best|The|Collection|Festa|Debut)$")
                    return w1

                pairCount := this.CountRegex(txt, "i)\b" . w1 . "\s+" . w2 . "\b")
                singleCount := this.CountRegex(txt, "i)\b" . w1 . "\b")
                if (pairCount <= 1 && singleCount >= 3)
                    return w1

                return w1 . " " . w2
            }
        }
        return ""
    }

    ; --- [JAVGURU: 검색 후 글 클릭 진입 -> 상세페이지 Actress 추출] ---
    static QueryJavguruDetail(hwnd, dvdId) {
        ; 1. JAVGURU 검색 페이지 이동
        searchUrl := "https://jav.guru/?s=" . dvdId
        this.Navigate(hwnd, searchUrl)
        Sleep(2000)

        ; 2. 검색 결과 유무 확인
        checkText := this.FetchText(hwnd)
        if (checkText == "" || this.IsError(checkText))
            return ""

        ; 3. 요청 품번과 일치하는 제목 링크만 선택합니다.
        ; JAVGURU 워드프레스 테마의 글 링크 선택자: article h2 a 또는 .inside-article a
        jsClick := "(function(){var id='" . dvdId . "';var links=document.querySelectorAll('article h2 a, .entry-title a');for(var i=0;i<links.length;i++){var t=links[i].textContent.toUpperCase().replace(/[_ ]/g,'-');if(new RegExp('(^|[^A-Z0-9])'+id+'([^A-Z0-9]|$)').test(t)){links[i].click();return;}}})();"

        WinActivate("ahk_id " . hwnd)
        if !WinWaitActive("ahk_id " . hwnd, , 2)
            throw Error("브라우저 창을 활성화할 수 없습니다.")
        Sleep(150)
        Send("^l")
        Sleep(120)
        SendText("javascript:")
        A_Clipboard := jsClick
        ClipWait(1)
        Send("^v{Enter}")

        ; 4. 상세 페이지 로딩 대기 후 본문 텍스트 복사
        Sleep(2500)
        detailText := this.FetchText(hwnd)
        if (detailText == "" || detailText == checkText || this.IsError(detailText))
            return ""

        idPattern := "i)(?<![A-Z0-9])" . StrReplace(dvdId, "-", "[-_ ]?") . "(?![A-Z0-9])"
        ; A search page also contains the ID: require a detail-page marker.
        if !RegExMatch(detailText, idPattern) || !RegExMatch(detailText, "i)\b(?:Actress|Starring|Model)\s*[:：]")
            return ""

        ; 5. 상세 페이지 내에서 Actress: 항목 추출
        ; 예시: Actress: Ayumi Ryo 또는 줄바꿈 형태
        actressPattern := "im)^\h*(?:Actress|Starring|Model)\h*[:：]\h*(?:\R\h*)?([A-Za-z]+(?:\h+[A-Za-z]+)?)\h*$"
        if RegExMatch(detailText, actressPattern, &mAct) {
            rawCandidate := Trim(mAct[1])

            words := []
            for w in StrSplit(rawCandidate, [" ", "`r", "`n", "`t"]) {
                cw := Trim(w)
                if (cw == "")
                    continue
                if RegExMatch(cw, "i)^(HD|FHD|VR|4K|Tags|Genre|Studio|Label|Director|Duration|Release|Date)$")
                    break
                if RegExMatch(cw, "^[A-Za-z]{2,}$")
                    words.Push(this.FormatWord(cw))
            }

            if (words.Length >= 2)
                return words[1] . " " . words[2]
            else if (words.Length == 1)
                return words[1]
        }

        return ""
    }

    static MatchesName(text, name) {
        text := StrReplace(text, "_", " ")
        tokens := StrSplit(Trim(name), " ")
        for token in tokens {
            if (token != "" && !RegExMatch(text, "i)(?<![A-Z])" . this.EscapeRegex(token) . "(?![A-Z])"))
                return false
        }
        return tokens.Length > 0
    }

    static EscapeRegex(text) {
        return RegExReplace(text, "([\\.^$|?*+(){}\[\]])", "\$1")
    }

    static CountRegex(text, pattern) {
        c := 0, pos := 1
        while RegExMatch(text, pattern, &m, pos) {
            c++, pos := m.Pos + m.Len
        }
        return c
    }

    static FormatWord(str) {
        return (StrLen(str) <= 1) ? StrUpper(str) : (StrUpper(SubStr(str, 1, 1)) . StrLower(SubStr(str, 2)))
    }
}